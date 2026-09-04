/**
 * Safety Alert callables for JVA Safety.
 *
 * Stores one document per alert, FLAT at
 * `organizations/{orgId}/safety_alerts/{id}` — a sibling of
 * `corrective_actions` and `daily_safety_meetings`, so any authorized
 * user's Safety Alerts screen can query every alert across every site in one
 * collection, and a worker/foreman's own site view is a query narrowed to
 * `siteId`, not a different collection. `firestore.rules` denies every
 * client write to that collection outright, so these three callables are
 * the only path that can create one or transition its status.
 *
 * WHAT THIS IS AND IS NOT
 *
 * This is RECORD-KEEPING only, exactly like every other feature built so
 * far in this codebase. There is no automated alert generation (nothing
 * here ever creates an alert on its own from a hazard, an overdue
 * corrective action, weather data, or anything else), no push
 * notification, and no Gemini involvement anywhere in this file. An alert
 * exists because an authorized human explicitly created it.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireOrganizationScopedReviewer`, IMPORTED from
 * `corrective_action_callable.ts` rather than duplicated: the caller's own
 * stored profile must be `active` and hold a role for which
 * `canReviewPendingAccounts` is true (`admin`/`siteManager` — see
 * `account_approval.ts`), scoped to the target organization for every role
 * except `admin`. A `foreman` or `worker` can create, acknowledge or
 * resolve NOTHING here, matching the task's "authorized users" boundary
 * exactly.
 *
 * A worker/foreman still READS every alert for their own organization/site
 * — see `firestore.rules`'s org-member-or-Admin read grant on this
 * collection, matching `corrective_actions`. Read access and write
 * authority are deliberately different boundaries, exactly like everywhere
 * else in this codebase.
 *
 * THE VALIDATION CHAIN ON CREATE
 *
 * `requireSiteMatches`, IMPORTED from `daily_safety_meeting_callable.ts`
 * rather than duplicated: the named site must exist within
 * `organizationId` and its own `projectId` must match the one given —
 * re-fetched fresh, never trusted from the request. `organizationId`,
 * `projectId` and `siteId` are stored exactly as validated; there is no
 * later mutation of any of the three.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create, acknowledge or resolve an alert without an authorized reviewer
 *   role, or outside their own organization (system administrator excepted,
 *   as everywhere else in this codebase) — nobody can grant themselves this
 *   authority by any argument to any of these callables, since none of them
 *   accept a role/organization-membership argument at all.
 * - Create an alert for a site that does not belong to the given
 *   organization/project.
 * - Acknowledge or resolve an alert belonging to another organization.
 * - Resolve an alert that has already been resolved — resolution is a
 *   one-way terminal transition, matching every other terminal status in
 *   this codebase (e.g. a completed `DailySafetyMeeting`).
 * - Delete an alert — there is no delete callable, and `firestore.rules`
 *   denies every client write including delete. A safety alert, like a
 *   completed meeting's concerns or a corrective action, is a permanent
 *   part of the safety record once created.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {requireOrganizationScopedReviewer} from "./corrective_action_callable";
import {requireSiteMatches} from "./daily_safety_meeting_callable";

/**
 * Reads and validates a required non-empty string argument. Duplicated
 * per-file per this codebase's existing convention.
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

const SAFETY_ALERT_SEVERITIES = ["low", "medium", "high", "critical"] as const;
type SafetyAlertSeverityValue = (typeof SAFETY_ALERT_SEVERITIES)[number];

/**
 * Validates and returns the `severity` argument, refusing anything outside
 * the fixed set this stage supports.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {SafetyAlertSeverityValue} the validated severity.
 */
function requireSeverity(request: CallableRequest): SafetyAlertSeverityValue {
  const value = requireString(request, "severity");
  if (!(SAFETY_ALERT_SEVERITIES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "severity must be one of: " + SAFETY_ALERT_SEVERITIES.join(", ")
    );
  }
  return value as SafetyAlertSeverityValue;
}

const SAFETY_ALERT_CATEGORIES = [
  "safety",
  "equipment",
  "environment",
  "weather",
  "site",
  "other",
] as const;
type SafetyAlertCategoryValue = (typeof SAFETY_ALERT_CATEGORIES)[number];

/**
 * Validates and returns the `category` argument, refusing anything outside
 * the fixed set this stage supports.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {SafetyAlertCategoryValue} the validated category.
 */
function requireCategory(request: CallableRequest): SafetyAlertCategoryValue {
  const value = requireString(request, "category");
  if (!(SAFETY_ALERT_CATEGORIES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "category must be one of: " + SAFETY_ALERT_CATEGORIES.join(", ")
    );
  }
  return value as SafetyAlertCategoryValue;
}

/**
 * Loads the target alert and confirms it belongs to [organizationId] —
 * re-fetched fresh, never trusted from the request payload. Mirrors
 * `requireOwnMeeting`-style guards elsewhere in this codebase, applied to an
 * alert instead of a meeting.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} alertId the alert's id.
 * @return {Promise<FirebaseFirestore.DocumentReference>} a reference to the
 * validated alert document, alongside its stored data.
 */
async function requireOrganizationAlert(
  organizationId: string,
  alertId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_alerts/${alertId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) {
    throw new HttpsError("not-found", "That safety alert no longer exists.");
  }
  if (data.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That safety alert does not belong to the given organization."
    );
  }
  return {ref, data};
}

/**
 * Creates a safety alert at `organizations/{orgId}/safety_alerts/{id}`.
 *
 * Only an authorized reviewer role may call this (see
 * `requireOrganizationScopedReviewer`). `organizationId`, `projectId` and
 * `siteId` are validated against a freshly-fetched site document (see
 * `requireSiteMatches`) before anything is written, so an alert can never be
 * created for a site that does not belong to the given organization/
 * project.
 */
export const createSafetyAlert = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const projectId = requireString(request, "projectId");
  const siteId = requireString(request, "siteId");
  const title = requireString(request, "title");
  const description = requireString(request, "description");
  const severity = requireSeverity(request);
  const category = requireCategory(request);

  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  await requireSiteMatches(organizationId, projectId, siteId);

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/safety_alerts`)
    .doc();
  await ref.set({
    organizationId,
    projectId,
    siteId,
    title,
    description,
    severity,
    category,
    status: "active",
    createdBy: uid,
    createdAt: FieldValue.serverTimestamp(),
    acknowledgedAt: null,
    acknowledgedBy: null,
    resolvedAt: null,
    resolvedBy: null,
  });

  return {id: ref.id, organizationId};
});

/**
 * Acknowledges an active alert, moving it to `acknowledged`. Only an
 * authorized reviewer role within the alert's own organization may call
 * this (see `requireOrganizationScopedReviewer`). Refuses when the alert is
 * not currently `active` — an already-acknowledged or resolved alert cannot
 * be re-acknowledged.
 */
export const acknowledgeSafetyAlert = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const alertId = requireString(request, "alertId");

  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  const {ref, data} = await requireOrganizationAlert(organizationId, alertId);

  if (data.status !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "Only an active alert can be acknowledged."
    );
  }

  await ref.update({
    status: "acknowledged",
    acknowledgedAt: FieldValue.serverTimestamp(),
    acknowledgedBy: uid,
  });

  return {id: alertId, organizationId, status: "acknowledged"};
});

/**
 * Resolves an alert, moving it to `resolved` — a terminal state. Only an
 * authorized reviewer role within the alert's own organization may call
 * this. Refuses an already-resolved alert: resolution is one-way, matching
 * every other terminal status in this codebase.
 */
export const resolveSafetyAlert = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const alertId = requireString(request, "alertId");

  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  const {ref, data} = await requireOrganizationAlert(organizationId, alertId);

  if (data.status === "resolved") {
    throw new HttpsError(
      "failed-precondition",
      "That safety alert has already been resolved."
    );
  }

  await ref.update({
    status: "resolved",
    resolvedAt: FieldValue.serverTimestamp(),
    resolvedBy: uid,
  });

  return {id: alertId, organizationId, status: "resolved"};
});
