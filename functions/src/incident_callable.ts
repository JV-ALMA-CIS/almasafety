/**
 * Incident callables for JVA Safety.
 *
 * Stores one document per incident, FLAT at
 * `organizations/{orgId}/incidents/{id}` — a sibling of `hazards` and
 * `corrective_actions`. `firestore.rules` denies every client write to that
 * collection outright, so these callables are the only path that can create
 * one or move it through its lifecycle. See FIRESTORE_DATA_MODEL.md §7a.
 *
 * AN INCIDENT IS NOT A HAZARD. A hazard is something that COULD happen and a
 * near-miss (a hazard `kind`) is something that NEARLY happened; an incident
 * is something that ACTUALLY happened — someone hurt, something damaged, a
 * spill, a dangerous occurrence. It carries its own fields (when it
 * happened, who was hurt, what was done straight away) and its own
 * lifecycle, so it is its own collection rather than a third hazard kind.
 *
 * WORKFLOW: Report → Investigate (classify severity, raise corrective
 * actions) → Close (record root cause, only once every action is complete)
 *
 * Lifecycle: `reported -> underInvestigation -> closed`. `closed` is
 * TERMINAL.
 *
 * WHO CAN SEE AN INCIDENT
 *
 * Unlike a hazard, an incident can name an injured person and describe an
 * injury, so `firestore.rules` restricts reads to the reporter themselves,
 * reviewer roles (`admin`/`siteManager`/`foreman`) in the incident's own
 * organization, and the System Administrator — not every org member.
 *
 * WHAT AUTHORIZES EACH CALL
 *
 * - `createIncident`: `requireReporterAtSite`, shared with `createHazard` —
 *   a Site Manager/Admin at any site of their organization, anyone else at
 *   a site in their own `siteIds`. `reportedByUid` is always the
 *   caller's own uid; `projectId` is always looked up from the site.
 * - `startIncidentInvestigation`/`closeIncident`/
 *   `linkIncidentCorrectiveAction`: a Site Manager/Admin of the incident's
 *   organization (`requireIncidentInvestigator`). A Foreman can READ
 *   incidents (rules) and submits evidence on the actions assigned to them,
 *   but the investigation itself is the Site Manager's.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Report an incident for a site they do not have access to, or as
 *   someone else.
 * - Report an incident that happened in the future.
 * - Edit the original report content after creation — there is no update
 *   callable for it.
 * - Close an incident that is not under investigation, without a root
 *   cause, while any of its corrective actions is still incomplete, or
 *   before its reporting is done (level set, every reporting step ticked —
 *   see `incident_reporting.ts`).
 * - Delete an incident — it is a permanent part of the safety record.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {
  createCorrectiveActionForIncident,
  requireIncidentInvestigator,
} from "./corrective_action_callable";
import {requireReporterAtSite} from "./hazard_callable";
import {requireReportingComplete} from "./incident_reporting";

/**
 * Reads and validates a required non-empty string argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string} the validated value.
 */
function requireString(request: CallableRequest, field: string): string {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return value.trim();
}

/**
 * Reads an optional, trimmed string argument, returning `null` when absent
 * or blank.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string | null} the trimmed value, or `null`.
 */
function optionalString(
  request: CallableRequest,
  field: string
): string | null {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) return null;
  return value.trim();
}

/**
 * Validates that [field] is one of [allowed].
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @param {Array<string>} allowed the accepted values.
 * @return {string} the validated value.
 */
function requireOneOf(
  request: CallableRequest,
  field: string,
  allowed: readonly string[]
): string {
  const value = requireString(request, field);
  if (!allowed.includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      `${field} must be one of: ` + allowed.join(", ")
    );
  }
  return value;
}

const INCIDENT_TYPES = [
  "injury",
  "propertyDamage",
  "environmental",
  "dangerousOccurrence",
  // Anything that doesn't fit the above — sites differ; the description
  // says what happened.
  "other",
] as const;

const INCIDENT_SEVERITIES = ["minor", "moderate", "serious"] as const;

/**
 * How far into the future `occurredAt` may be before it is refused — a small
 * allowance for a phone clock running slightly fast.
 */
const CLOCK_SKEW_MS = 5 * 60 * 1000;

/**
 * Reads and validates `occurredAt` — when the incident happened, which is
 * often earlier than when it is reported. Must be a valid ISO-8601
 * date-time and not in the future.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Date} the parsed time.
 */
function requireOccurredAt(request: CallableRequest): Date {
  const value = requireString(request, "occurredAt");
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new HttpsError(
      "invalid-argument",
      "occurredAt must be a valid ISO-8601 date-time."
    );
  }
  if (parsed.getTime() > Date.now() + CLOCK_SKEW_MS) {
    throw new HttpsError(
      "invalid-argument",
      "occurredAt cannot be in the future."
    );
  }
  return parsed;
}

/**
 * Looks up [siteId]'s own `projectId` within [organizationId].
 *
 * @param {string} organizationId the organization the site belongs to.
 * @param {string} siteId the site's id.
 * @return {Promise<string>} the site's own `projectId`.
 */
async function requireSiteProjectId(
  organizationId: string,
  siteId: string
): Promise<string> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/sites/${siteId}`)
    .get();
  const site = snapshot.data();
  if (!snapshot.exists || !site) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  if (site.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That site does not belong to the given organization."
    );
  }
  return site.projectId as string;
}

/**
 * Loads the target incident and confirms it belongs to [organizationId].
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} incidentId the incident's id.
 * @return {Promise<{ref: FirebaseFirestore.DocumentReference, data:
 * FirebaseFirestore.DocumentData}>} the incident's reference and data.
 */
async function requireOrganizationIncident(
  organizationId: string,
  incidentId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/incidents/${incidentId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) {
    throw new HttpsError("not-found", "That incident no longer exists.");
  }
  if (data.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That incident does not belong to the given organization."
    );
  }
  return {ref, data};
}

/**
 * Reports an incident at `organizations/{orgId}/incidents/{id}`.
 *
 * `incidentId` is accepted (pre-allocated by the client) for the same
 * photo-upload-first reason as `createHazard`; creation fails if a document
 * already exists at that id.
 */
export const createIncident = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const incidentId = requireString(request, "incidentId");
  const type = requireOneOf(request, "type", INCIDENT_TYPES);
  const description = requireString(request, "description");
  const occurredAt = requireOccurredAt(request);
  const location = optionalString(request, "location");
  const injuredPersonName = optionalString(request, "injuredPersonName");
  const immediateAction = optionalString(request, "immediateAction");
  const photoUrl = optionalString(request, "photoUrl");

  const reporterId = await requireReporterAtSite(
    request,
    organizationId,
    siteId
  );
  const projectId = await requireSiteProjectId(organizationId, siteId);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/incidents/${incidentId}`
  );
  const existing = await ref.get();
  if (existing.exists) {
    throw new HttpsError(
      "already-exists",
      "An incident with that id already exists."
    );
  }

  const now = FieldValue.serverTimestamp();
  await ref.set({
    organizationId,
    projectId,
    siteId,
    reportedByUid: reporterId,
    type,
    description,
    occurredAt,
    location,
    // Only meaningful for an injury; dropped for any other type so a stray
    // name typed before switching type is never stored.
    injuredPersonName: type === "injury" ? injuredPersonName : null,
    immediateAction,
    photoUrl,
    status: "reported",
    severity: null,
    investigationStartedBy: null,
    investigationStartedAt: null,
    correctiveActionIds: [],
    rootCause: null,
    closingNotes: null,
    closedBy: null,
    closedAt: null,
    createdAt: now,
    createdBy: reporterId,
    updatedAt: now,
    updatedBy: reporterId,
  });

  return {id: incidentId, organizationId, status: "reported"};
});

/**
 * Starts the investigation of a reported incident, classifying its
 * `severity`. Only an authorized reviewer may call this, and only on a
 * `reported` incident.
 */
export const startIncidentInvestigation = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const incidentId = requireString(request, "incidentId");
  const severity = requireOneOf(request, "severity", INCIDENT_SEVERITIES);

  const uid = await requireIncidentInvestigator(request, organizationId);
  const {ref, data} = await requireOrganizationIncident(
    organizationId,
    incidentId
  );

  if (data.status !== "reported") {
    throw new HttpsError(
      "failed-precondition",
      "Only a newly reported incident can be put under investigation."
    );
  }

  const now = FieldValue.serverTimestamp();
  await ref.update({
    status: "underInvestigation",
    severity,
    investigationStartedBy: uid,
    investigationStartedAt: now,
    updatedAt: now,
    updatedBy: uid,
  });

  return {id: incidentId, organizationId, status: "underInvestigation"};
});

/**
 * Raises a corrective action from an incident under investigation. Thin
 * wrapper around `corrective_action_callable.ts`'s
 * `createCorrectiveActionForIncident` — see that function for the full
 * authorization and validation chain.
 */
export const linkIncidentCorrectiveAction = onCall(async (request) => {
  return createCorrectiveActionForIncident(request);
});

/**
 * Closes an incident under investigation, recording its `rootCause` (and
 * optional `closingNotes`). Only an authorized reviewer may call this.
 * Refuses while any corrective action raised from this incident is not yet
 * `completed` — closing is the sign-off that the fixes are in place.
 */
export const closeIncident = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const incidentId = requireString(request, "incidentId");
  const rootCause = requireString(request, "rootCause");
  const closingNotes = optionalString(request, "closingNotes");

  const uid = await requireIncidentInvestigator(request, organizationId);
  const {ref, data} = await requireOrganizationIncident(
    organizationId,
    incidentId
  );

  if (data.status === "closed") {
    throw new HttpsError(
      "failed-precondition",
      "That incident has already been closed."
    );
  }
  if (data.status !== "underInvestigation") {
    throw new HttpsError(
      "failed-precondition",
      "An incident must be investigated before it can be closed."
    );
  }

  requireReportingComplete(data);

  const actions = await getFirestore()
    .collection(`organizations/${organizationId}/corrective_actions`)
    .where("incidentId", "==", incidentId)
    .get();
  const incomplete = actions.docs.filter(
    (doc) => doc.data().status !== "completed"
  );
  if (incomplete.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      `${incomplete.length} corrective action(s) from this incident are ` +
        "not yet completed."
    );
  }

  const now = FieldValue.serverTimestamp();
  await ref.update({
    status: "closed",
    rootCause,
    closingNotes,
    closedBy: uid,
    closedAt: now,
    updatedAt: now,
    updatedBy: uid,
  });

  return {id: incidentId, organizationId, status: "closed"};
});
