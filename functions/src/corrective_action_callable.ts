/**
 * Corrective Action callables for JVA Safety.
 *
 * Stores one document per corrective action, FLAT at
 * `organizations/{orgId}/corrective_actions/{id}` — a sibling of
 * `daily_safety_meetings`, not a subcollection of one, so an authorized
 * supervisor/manager can query every corrective action across every site and
 * meeting in one collection. `firestore.rules` denies every client write to
 * that collection outright, so these two callables are the only path that
 * can create one or transition its status. Creation imports and reuses
 * `daily_safety_meeting_callable.ts`'s own `requireOwnMeeting`
 * directly (see WHAT AUTHORIZES CREATION below), and status updates reuse
 * `account_approval.ts`'s existing reviewer-role authority
 * (`canReviewPendingAccounts`) rather than inventing a third authorization
 * concept for "supervisors and management."
 *
 * WORKFLOW: Concern → Corrective Action → Assigned Person → Due Date →
 * Completion
 *
 * A corrective action is created by the meeting's own foreman, FROM an
 * in-progress meeting (optionally naming one of that meeting's own
 * concerns), naming who it is assigned to and when it is due. Status then
 * moves through `open` -> `inProgress` -> `submittedForReview` ->
 * `completed` (or `overdue`, settable in place of `open`/`inProgress` by an
 * authorized updater — there is no scheduled function that flips it
 * automatically; see `CorrectiveActionStatus`'s doc comment in the Flutter
 * source). The assignee moves `open`/`inProgress` to `submittedForReview`
 * themselves, through `submitCorrectiveActionForReview` — "I've done the
 * work." Every OTHER transition, including `submittedForReview` ->
 * `completed` — "a reviewer verified that claim" — goes exclusively through
 * `updateCorrectiveActionStatus`, restricted to the same reviewer roles that
 * already review pending accounts; `completed` is only reachable FROM
 * `submittedForReview`, never directly from `open`/`inProgress`. `completed`
 * is TERMINAL: once reached, no further status update of any kind is
 * accepted — see that callable's own doc comment. Completing a
 * hazard-originated action also atomically closes its linked hazard — see
 * `updateCorrectiveActionStatus`'s own doc comment.
 *
 * WHAT AUTHORIZES CREATION
 *
 * `requireOwnMeeting`, IMPORTED from `daily_safety_meeting_callable.ts`
 * rather than duplicated: the caller must be the meeting's own foreman. The
 * meeting must still be `inProgress`, unless the action is raised from one
 * of its concerns (a concern may be added to a completed meeting — see
 * `createCorrectiveAction`).
 * `organizationId`, `projectId` and `siteId` are always copied from the
 * freshly-fetched meeting document, never accepted from the request, so a
 * corrective action can never be created for an organization/project/site
 * other than the one its own meeting belongs to.
 *
 * WHAT AUTHORIZES A STATUS UPDATE
 *
 * `requireOrganizationScopedReviewer`: the caller's OWN stored profile must
 * be `active` and hold a role for which `canReviewPendingAccounts` is true
 * (`admin`/`siteManager`/`foreman` — see `account_approval.ts`), scoped to
 * the target action's own organization/site for every role except `admin`.
 * A `foreman` may update the status of a corrective action on their own
 * site (FIRESTORE_DATA_MODEL.md §10) — including one they themselves
 * created, since the Foreman is the direct operational owner of remediation
 * on their site; a `siteManager`/`admin` may act on any corrective action
 * within their scope.
 *
 * PRIVILEGE ESCALATION VIA SELF-ASSIGNMENT
 *
 * `assignedTo` must name an existing, ACTIVE member of the SAME organization
 * as the meeting — re-fetched fresh, never trusted from the request beyond
 * using it to look up a real profile. A worker cannot use `assignedTo` to
 * grant themselves anything: this callable writes no role, no site access
 * and no organization membership — `assignedTo` is a plain uid reference
 * naming who is responsible for the work, carrying no privilege of its own.
 * The one thing it CANNOT be is the caller's own uid: a foreman cannot
 * assign a corrective action to themselves, which would let the same person
 * who raised the concern also be the one accountable for fixing it and
 * (eventually, once that stage exists) marking their own work complete —
 * mirroring `recordMeetingAttendance`'s "cannot record your own attendance"
 * refusal.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create a corrective action for a meeting they are not the foreman of, or
 *   for one that is no longer `inProgress` without naming one of its
 *   concerns — completed meetings remain historically auditable, never
 *   retroactively editable.
 * - Assign a corrective action to themselves (see above).
 * - Assign a corrective action to a worker outside the meeting's own
 *   organization.
 * - Name a `concernId` that does not belong to the named meeting.
 * - Update a corrective action's status without an authorized
 *   supervisor/manager role, or outside their own organization/site scope
 *   (admin excepted, as everywhere else in this codebase).
 * - Delete a corrective action — there is no delete callable, and
 *   `firestore.rules` denies every client write including delete. A
 *   corrective action, like a completed meeting's concerns, is a permanent
 *   part of the safety record once created.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {AppRole, canReviewPendingAccounts, isAppRole} from "./account_approval";
import {requireOwnMeeting} from "./daily_safety_meeting_callable";
import {meetingAuditEntry} from "./meeting_audit";

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `daily_safety_meeting_callable.ts`.
 *
 * @return {HttpsError} the opaque permission-denied error.
 */
function denied(): HttpsError {
  return new HttpsError(
    "permission-denied",
    "You do not have permission to do that."
  );
}

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

/**
 * Reads and validates a required ISO-8601 date-time string argument,
 * returning the parsed [Date].
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {Date} the parsed due date.
 */
function requireDate(request: CallableRequest, field: string): Date {
  const value = requireString(request, field);
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new HttpsError(
      "invalid-argument",
      `${field} must be a valid ISO-8601 date-time.`
    );
  }
  return parsed;
}

/**
 * Validates that [concernId] refers to an existing concern belonging to
 * [meetingId] within [organizationId] — re-fetched fresh, never trusted from
 * the request payload. Mirrors `requireOwnMeetingConcern` in
 * `daily_safety_meeting_callable.ts`.
 *
 * @param {string} organizationId the organization the meeting belongs to.
 * @param {string} meetingId the meeting the concern must belong to.
 * @param {string} concernId the concern's id.
 * @return {Promise<void>} resolves when the concern is confirmed valid.
 */
async function requireMeetingConcern(
  organizationId: string,
  meetingId: string,
  concernId: string
): Promise<void> {
  const snapshot = await getFirestore()
    .doc(
      `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
        `/concerns/${concernId}`
    )
    .get();
  const concern = snapshot.data();
  if (!snapshot.exists || !concern) {
    throw new HttpsError("not-found", "That concern no longer exists.");
  }
  if (
    concern.organizationId !== organizationId ||
    concern.meetingId !== meetingId
  ) {
    throw new HttpsError(
      "failed-precondition",
      "That concern does not belong to the given meeting."
    );
  }
}

/**
 * Validates that [assignedTo] refers to an existing, ACTIVE user who
 * belongs to [organizationId] — re-fetched fresh, never trusted from the
 * request payload. Mirrors `requireWorkerAtSite` in
 * `daily_safety_meeting_callable.ts`, but scoped to organization membership
 * only (not a specific site) since a corrective action's assignee may be a
 * supervisor overseeing the site rather than a worker assigned to it.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} assignedTo the candidate assignee's uid.
 * @return {Promise<void>} resolves when every check passes.
 */
async function requireActiveOrganizationMember(
  organizationId: string,
  assignedTo: string
): Promise<void> {
  const snapshot = await getFirestore().doc(`users/${assignedTo}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new HttpsError(
      "failed-precondition",
      "That assignee does not exist."
    );
  }
  if (profile.accountStatus !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "That assignee is not an active member of this organization."
    );
  }

  // Organization membership lives on the assignee's own membership document
  // for this organization, not a scalar profile field.
  const membershipSnapshot = await getFirestore()
    .doc(`users/${assignedTo}/memberships/${organizationId}`)
    .get();
  if (!membershipSnapshot.exists) {
    throw new HttpsError(
      "failed-precondition",
      "That assignee does not belong to the given organization."
    );
  }
}

/**
 * What kinds of evidence completing a corrective action can require: a
 * photo of the finished work, and/or a written confirmation (e.g. "guard
 * rail fitted and inspected"). Chosen by whoever creates the action.
 */
const EVIDENCE_KINDS = ["photo", "confirmation"] as const;
type EvidenceKind = (typeof EVIDENCE_KINDS)[number];

/** The most photos one submission may carry. */
const MAX_EVIDENCE_PHOTOS = 5;

/**
 * Reads what evidence a new corrective action requires: `evidenceKinds`
 * (a subset of [EVIDENCE_KINDS]) and optional `evidenceInstructions`.
 * An older client that sends only `evidenceRequired: true` gets
 * `["photo"]`, matching what that flag always meant on screen.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {{evidenceRequired: boolean, evidenceKinds: EvidenceKind[],
 * evidenceInstructions: (string|null)}} the fields to store.
 */
function readEvidenceSpec(request: CallableRequest): {
  evidenceRequired: boolean;
  evidenceKinds: EvidenceKind[];
  evidenceInstructions: string | null;
} {
  const data = request.data ?? {};
  let kinds: EvidenceKind[] = [];
  const raw: unknown = data.evidenceKinds;
  if (raw !== undefined && raw !== null) {
    if (
      !Array.isArray(raw) ||
      raw.some((k) => !(EVIDENCE_KINDS as readonly unknown[]).includes(k))
    ) {
      throw new HttpsError(
        "invalid-argument",
        "evidenceKinds must be a list of: " + EVIDENCE_KINDS.join(", ")
      );
    }
    kinds = [...new Set(raw as EvidenceKind[])];
  }
  if (kinds.length === 0 && data.evidenceRequired === true) kinds = ["photo"];
  const rawInstructions: unknown = data.evidenceInstructions;
  const instructions =
    typeof rawInstructions === "string" && rawInstructions.trim() ?
      rawInstructions.trim().slice(0, 500) :
      null;
  return {
    evidenceRequired: kinds.length > 0,
    evidenceKinds: kinds,
    evidenceInstructions: kinds.length > 0 ? instructions : null,
  };
}

/**
 * The evidence kinds a STORED action requires — its `evidenceKinds`, or
 * `["photo"]` for an action created before kinds existed with only
 * `evidenceRequired: true`.
 *
 * @param {FirebaseFirestore.DocumentData} action the stored action.
 * @return {string[]} the required kinds.
 */
function requiredEvidenceKinds(
  action: FirebaseFirestore.DocumentData
): string[] {
  if (Array.isArray(action.evidenceKinds) && action.evidenceKinds.length) {
    return action.evidenceKinds as string[];
  }
  return action.evidenceRequired === true ? ["photo"] : [];
}

/**
 * A person's display name from their own profile, or null when it has
 * none — stored on the action so every screen (including a worker's, who
 * cannot list the organization's people) can show a name, never a uid.
 *
 * @param {string} uid the person's uid.
 * @return {Promise<string|null>} their name, or null.
 */
async function displayNameOf(uid: string): Promise<string | null> {
  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const name: unknown = snapshot.data()?.name;
  return typeof name === "string" && name.trim() ? name.trim() : null;
}

/**
 * Authorizes the caller as an active reviewer-role user
 * (`canReviewPendingAccounts`) scoped to [organizationId] — the same
 * "authorized supervisors/management" role set `approval_callable.ts`'s
 * `requireApprover` already trusts, reused rather than re-derived. `admin`
 * is exempt from the organization check, exactly like every other reuse of
 * this role set in this codebase. Note this does NOT further narrow a
 * `foreman` reviewer to their own site — callers that need that (e.g.
 * `hazard_callable.ts`'s `acknowledgeHazard`) perform the additional site
 * check themselves after calling this, since the required scoping differs
 * per collection (see FIRESTORE_DATA_MODEL.md §10).
 *
 * Exported so `hazard_callable.ts` and `safety_alert_callable.ts` can import
 * this exact implementation instead of maintaining their own copies —
 * mirrors `requireOrganizationScopedManager`'s own "define once, export,
 * import elsewhere" shape in `organization_callable.ts`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<string>} the authorized caller's own uid.
 */
export async function requireOrganizationScopedReviewer(
  request: CallableRequest,
  organizationId: string
): Promise<string> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  if (profile.platformRole === "admin") return uid;

  // A non-admin reviewer's role is per-organization, read from their own
  // membership document for THIS organization rather than a scalar profile
  // field — a siteManager/foreman may hold more than one membership.
  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) throw denied();
  if (membership.status !== "active") throw denied();

  const role: unknown = membership.role;
  if (!isAppRole(role) || !canReviewPendingAccounts(role as AppRole)) {
    throw denied();
  }

  return uid;
}

const CORRECTIVE_ACTION_STATUSES = [
  "open",
  "inProgress",
  "submittedForReview",
  "completed",
  "overdue",
] as const;
type CorrectiveActionStatusValue = (typeof CORRECTIVE_ACTION_STATUSES)[number];

/**
 * Validates and returns the `status` argument, refusing anything outside
 * the fixed set this stage supports.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {CorrectiveActionStatusValue} the validated status.
 */
function requireCorrectiveActionStatus(
  request: CallableRequest
): CorrectiveActionStatusValue {
  const value = requireString(request, "status");
  if (!(CORRECTIVE_ACTION_STATUSES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "status must be one of: " + CORRECTIVE_ACTION_STATUSES.join(", ")
    );
  }
  return value as CorrectiveActionStatusValue;
}

/**
 * Loads the target hazard and confirms it belongs to [organizationId] —
 * re-fetched fresh, never trusted from the request payload. Mirrors
 * `requireOwnMeeting`-style guards elsewhere in this codebase, applied to a
 * hazard instead of a meeting.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} hazardId the hazard's id.
 * @return {Promise<{ref: FirebaseFirestore.DocumentReference, data:
 * FirebaseFirestore.DocumentData}>} the validated hazard's reference and
 * stored data.
 */
async function requireOrganizationHazard(
  organizationId: string,
  hazardId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/hazards/${hazardId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) {
    throw new HttpsError("not-found", "That hazard no longer exists.");
  }
  if (data.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That hazard does not belong to the given organization."
    );
  }
  return {ref, data};
}

/**
 * The shared body behind BOTH `createCorrectiveAction` (hazard branch) and
 * `hazard_callable.ts`'s `linkHazardCorrectiveAction` — exported so the two
 * callable entry points invoke exactly one implementation rather than
 * maintaining parallel copies, mirroring `requireOrganizationScopedReviewer`
 * and `requireInProgressOwnMeeting`'s own "define once, export, import
 * elsewhere" shape.
 *
 * Only an authorized reviewer role may call this (see
 * `requireOrganizationScopedReviewer`) — a hazard has no owning foreman the
 * way a meeting does, so authorization reuses the same reviewer set already
 * trusted to acknowledge/close hazards and to update a corrective action's
 * status, rather than inventing a third authorization concept.
 * `organizationId`, `projectId` and `siteId` are always copied from the
 * freshly-fetched hazard, never accepted from the request. The hazard must
 * not already be `closed` or already linked to a corrective action
 * (`correctiveActionId` must be null) — a hazard can produce at most one
 * corrective action. `assignedTo` must be an active member of the same
 * organization and must not be the caller's own uid — see this file's header
 * note on self-assignment. On success, the hazard is atomically updated to
 * `status: "correctiveActionCreated"` with `correctiveActionId` set to the
 * new action's id, in the same batched write as the new action's creation.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Promise<{id: string, organizationId: string, hazardId: string}>}
 * the new action's id.
 */
export async function createCorrectiveActionForHazard(
  request: CallableRequest
): Promise<{id: string; organizationId: string; hazardId: string}> {
  const organizationId = requireString(request, "organizationId");
  const hazardId = requireString(request, "hazardId");
  const title = requireString(request, "title");
  const description = requireString(request, "description");
  const assignedTo = requireString(request, "assignedTo");
  const dueDate = requireDate(request, "dueDate");
  const evidence = readEvidenceSpec(request);

  const callerId = request.auth?.uid;
  if (!callerId) throw denied();

  if (assignedTo === callerId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot assign a corrective action to yourself."
    );
  }

  await requireOrganizationScopedReviewer(request, organizationId);
  await requireActiveOrganizationMember(organizationId, assignedTo);
  const {ref: hazardRef, data: hazard} = await requireOrganizationHazard(
    organizationId,
    hazardId
  );
  if (hazard.status === "closed") {
    throw new HttpsError(
      "failed-precondition",
      "That hazard has already been closed."
    );
  }
  if (hazard.correctiveActionId) {
    throw new HttpsError(
      "failed-precondition",
      "That hazard already has a corrective action."
    );
  }

  const db = getFirestore();
  const now = FieldValue.serverTimestamp();
  const ref = db
    .collection(`organizations/${organizationId}/corrective_actions`)
    .doc();

  const batch = db.batch();
  batch.set(ref, {
    organizationId,
    projectId: hazard.projectId,
    siteId: hazard.siteId,
    meetingId: null,
    concernId: null,
    hazardId,
    incidentId: null,
    title,
    description,
    assignedTo,
    assignedBy: callerId,
    assignedToName: await displayNameOf(assignedTo),
    assignedByName: await displayNameOf(callerId),
    dueDate,
    status: "open",
    ...evidence,
    completionNote: null,
    evidencePhotos: [],
    submittedAt: null,
    reviewFeedback: null,
    createdAt: now,
    updatedAt: now,
    completedAt: null,
  });
  batch.update(hazardRef, {
    status: "correctiveActionCreated",
    correctiveActionId: ref.id,
    updatedAt: now,
    updatedBy: callerId,
  });
  await batch.commit();

  return {id: ref.id, organizationId, hazardId};
}

/**
 * Authorizes the caller to INVESTIGATE an incident — start the
 * investigation, raise its corrective actions, close it: the System
 * Administrator, or an `admin`/`siteManager` of [organizationId]. A Foreman
 * is deliberately not included: on site the Site Manager investigates and
 * the Foreman implements the fixes (they submit evidence on the corrective
 * actions assigned to them). Exported for `incident_callable.ts`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the incident's organization.
 * @return {Promise<string>} the caller's uid.
 */
export async function requireIncidentInvestigator(
  request: CallableRequest,
  organizationId: string
): Promise<string> {
  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  if (profile?.platformRole === "admin") return uid;
  const membership = (
    await getFirestore().doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  if (membership?.role === "admin" || membership?.role === "siteManager") {
    return uid;
  }
  throw denied();
}

/**
 * Creates a corrective action from an incident under investigation — the
 * incident counterpart of [createCorrectiveActionForHazard], exported so
 * `incident_callable.ts`'s `linkIncidentCorrectiveAction` and
 * `createCorrectiveAction`'s incident branch share exactly one
 * implementation.
 *
 * Same reviewer authorization and assignee rules as the hazard path. Unlike
 * a hazard, an incident may produce SEVERAL corrective actions (an
 * investigation often finds more than one fix), so the incident's
 * `correctiveActionIds` array is appended to rather than a single id being
 * set once. The incident must be `underInvestigation` — a reviewer first
 * classifies its severity via `startIncidentInvestigation`, and a `closed`
 * incident takes no new actions. Completing one of these actions does NOT
 * close the incident (contrast the hazard path): closure is a separate,
 * deliberate sign-off with a recorded root cause — see `closeIncident`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Promise<{id: string, organizationId: string, incidentId: string}>}
 * the new action's id.
 */
export async function createCorrectiveActionForIncident(
  request: CallableRequest
): Promise<{id: string; organizationId: string; incidentId: string}> {
  const organizationId = requireString(request, "organizationId");
  const incidentId = requireString(request, "incidentId");
  const title = requireString(request, "title");
  const description = requireString(request, "description");
  const assignedTo = requireString(request, "assignedTo");
  const dueDate = requireDate(request, "dueDate");
  const evidence = readEvidenceSpec(request);

  const callerId = request.auth?.uid;
  if (!callerId) throw denied();

  if (assignedTo === callerId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot assign a corrective action to yourself."
    );
  }

  await requireIncidentInvestigator(request, organizationId);
  await requireActiveOrganizationMember(organizationId, assignedTo);

  const db = getFirestore();
  const incidentRef = db.doc(
    `organizations/${organizationId}/incidents/${incidentId}`
  );
  const incidentSnapshot = await incidentRef.get();
  const incident = incidentSnapshot.data();
  if (!incidentSnapshot.exists || !incident) {
    throw new HttpsError("not-found", "That incident no longer exists.");
  }
  if (incident.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That incident does not belong to the given organization."
    );
  }
  if (incident.status !== "underInvestigation") {
    throw new HttpsError(
      "failed-precondition",
      "Corrective actions can only be raised while an incident is under " +
        "investigation."
    );
  }

  const now = FieldValue.serverTimestamp();
  const ref = db
    .collection(`organizations/${organizationId}/corrective_actions`)
    .doc();

  const batch = db.batch();
  batch.set(ref, {
    organizationId,
    projectId: incident.projectId,
    siteId: incident.siteId,
    meetingId: null,
    concernId: null,
    hazardId: null,
    incidentId,
    title,
    description,
    assignedTo,
    assignedBy: callerId,
    assignedToName: await displayNameOf(assignedTo),
    assignedByName: await displayNameOf(callerId),
    dueDate,
    status: "open",
    ...evidence,
    completionNote: null,
    evidencePhotos: [],
    submittedAt: null,
    reviewFeedback: null,
    createdAt: now,
    updatedAt: now,
    completedAt: null,
  });
  batch.update(incidentRef, {
    correctiveActionIds: FieldValue.arrayUnion(ref.id),
    updatedAt: now,
    updatedBy: callerId,
  });
  await batch.commit();

  return {id: ref.id, organizationId, incidentId};
}

/**
 * Creates a corrective action either from an in-progress meeting (optionally
 * naming one of that meeting's own concerns) OR from a hazard, at
 * `organizations/{orgId}/corrective_actions/{id}`. Exactly one of
 * `meetingId`, `hazardId` or `incidentId` must be given — a corrective
 * action names exactly one origin (see FIRESTORE_DATA_MODEL.md §7). The
 * incident branch delegates to `createCorrectiveActionForIncident`.
 *
 * MEETING-ORIGINATED (`meetingId` given): only the meeting's own foreman may
 * call this (see `requireOwnMeeting`). `organizationId`, `projectId` and
 * `siteId` are always copied from the freshly-fetched meeting, never
 * accepted from the request. `concernId`, when given, must belong to the
 * same meeting. While the meeting is in progress `concernId` is optional;
 * once it is COMPLETED a `concernId` is REQUIRED — a concern may still be
 * added to a completed meeting (`addMeetingConcern`), and this is how it
 * gets its corrective action, but nothing else about a completed meeting
 * reopens. The new action's id is added to the meeting's own
 * `correctiveActionIds` (`arrayUnion`, so a retry never duplicates it) in
 * the same batch as the action and its `audit_logs` entry, so the link
 * holds in both directions.
 *
 * HAZARD-ORIGINATED (`hazardId` given, `concernId` forbidden): delegates
 * entirely to `createCorrectiveActionForHazard` above — same authorization,
 * same validation chain, same write, whether reached through this callable
 * or directly through `hazard_callable.ts`'s `linkHazardCorrectiveAction`.
 *
 * In both cases, `assignedTo` must be an active member of the same
 * organization and must not be the caller's own uid — see this file's header
 * note on self-assignment.
 */
export const createCorrectiveAction = onCall(async (request) => {
  const data = request.data ?? {};
  const meetingIdValue = data.meetingId;
  const hasMeetingId =
    typeof meetingIdValue === "string" && meetingIdValue.trim() !== "";
  const hazardIdValue = data.hazardId;
  const hasHazardId =
    typeof hazardIdValue === "string" && hazardIdValue.trim() !== "";
  const incidentIdValue = data.incidentId;
  const hasIncidentId =
    typeof incidentIdValue === "string" && incidentIdValue.trim() !== "";

  if ([hasMeetingId, hasHazardId, hasIncidentId].filter(Boolean).length !== 1) {
    throw new HttpsError(
      "invalid-argument",
      "Exactly one of meetingId, hazardId or incidentId is required."
    );
  }

  if (hasIncidentId) {
    const concernIdValue = data.concernId;
    if (typeof concernIdValue === "string" && concernIdValue.trim() !== "") {
      throw new HttpsError(
        "invalid-argument",
        "concernId cannot be given together with incidentId."
      );
    }
    return createCorrectiveActionForIncident(request);
  }

  if (hasHazardId) {
    const concernIdValue = data.concernId;
    const hasConcernId =
      typeof concernIdValue === "string" && concernIdValue.trim() !== "";
    if (hasConcernId) {
      throw new HttpsError(
        "invalid-argument",
        "concernId cannot be given together with hazardId."
      );
    }
    return createCorrectiveActionForHazard(request);
  }

  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const title = requireString(request, "title");
  const description = requireString(request, "description");
  const assignedTo = requireString(request, "assignedTo");
  const dueDate = requireDate(request, "dueDate");
  const concernIdValue = data.concernId;
  const hasConcernId =
    typeof concernIdValue === "string" && concernIdValue.trim() !== "";
  const concernId = hasConcernId ? (concernIdValue as string).trim() : null;
  const evidence = readEvidenceSpec(request);

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  if (assignedTo === foremanId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot assign a corrective action to yourself."
    );
  }

  const meeting = await requireOwnMeeting(organizationId, meetingId, foremanId);
  const afterCompletion = meeting.status !== "inProgress";
  if (afterCompletion && concernId === null) {
    throw new HttpsError(
      "failed-precondition",
      "That meeting has already been completed. A corrective action can " +
        "only be raised from one of its concerns."
    );
  }

  if (concernId !== null) {
    await requireMeetingConcern(organizationId, meetingId, concernId);
  }
  await requireActiveOrganizationMember(organizationId, assignedTo);

  const db = getFirestore();
  const ref = db
    .collection(`organizations/${organizationId}/corrective_actions`)
    .doc();
  const now = FieldValue.serverTimestamp();
  const audit = meetingAuditEntry({
    organizationId,
    meetingId,
    actorUid: foremanId,
    action: "meeting.correctiveActionRaised",
    metadata: {
      correctiveActionId: ref.id,
      concernId,
      assignedTo,
      afterCompletion,
    },
  });
  const batch = db.batch();
  batch.update(
    db.doc(
      `organizations/${organizationId}/daily_safety_meetings/${meetingId}`
    ),
    {correctiveActionIds: FieldValue.arrayUnion(ref.id)}
  );
  batch.set(audit.ref, audit.data);
  batch.set(ref, {
    organizationId,
    projectId: meeting.projectId,
    siteId: meeting.siteId,
    meetingId,
    concernId,
    hazardId: null,
    incidentId: null,
    title,
    description,
    assignedTo,
    assignedBy: foremanId,
    assignedToName: await displayNameOf(assignedTo),
    assignedByName: await displayNameOf(foremanId),
    dueDate,
    status: "open",
    ...evidence,
    completionNote: null,
    evidencePhotos: [],
    submittedAt: null,
    reviewFeedback: null,
    createdAt: now,
    updatedAt: now,
    completedAt: null,
  });
  await batch.commit();

  return {id: ref.id, organizationId, meetingId};
});

/**
 * Transitions an existing corrective action's `status`. Only an authorized
 * supervisor/manager role (see `requireOrganizationScopedReviewer`) within
 * the action's own organization may call this — never the meeting's own
 * foreman by virtue of having created it, and never the assignee, who
 * reports their own work done through `submitCorrectiveActionForReview`
 * instead (see that callable). There is no delete callable and no path back
 * to removing a corrective action once created — see this file's header
 * note on why completed meetings and their corrective actions stay
 * historically auditable.
 *
 * `completed` is only reachable FROM `submittedForReview` — a reviewer
 * cannot skip straight from `open`/`inProgress` to `completed` without the
 * assignee having reported the work done first. This is the
 * "assignee-reports, reviewer-verifies" split: `submittedForReview` is the
 * assignee's claim, `completed` is the reviewer's verification of that
 * claim. A reviewer who disagrees moves a `submittedForReview` action back
 * to `open`/`inProgress` (an ordinary, allowed transition) rather than
 * completing it — there is no separate "reject" status; sending it back to
 * an earlier status IS the rejection.
 *
 * `completed` is a TERMINAL state, mirroring `resolveSafetyAlert` in
 * `safety_alert_callable.ts`: once an action's stored `status` is
 * `completed`, every further call — including a no-op re-completion —
 * refuses, so `completedAt` can never be reset or overwritten after the
 * fact. Before this guard existed, any status update unconditionally wrote
 * `completedAt: status === "completed" ? serverTimestamp() : null`, which
 * let an authorized reviewer move a completed action back to `open`/
 * `inProgress` and silently erase its original completion timestamp — this
 * callable no longer allows that under any argument.
 *
 * HAZARD-ORIGINATED COMPLETION: when the action being completed carries a
 * `hazardId`, the linked hazard is atomically closed in the SAME batched
 * write as the action's own `completed` update — `status: "closed"`,
 * `closedAt`/`closedBy` set to this reviewer. This is the promised
 * counterpart to `closeHazard`'s own refusal message ("close it by
 * completing the corrective action instead"): before this, nothing actually
 * performed that closure, leaving such a hazard permanently stuck at
 * `correctiveActionCreated`. The hazard is only touched when it is not
 * already `closed` (defensive; should be unreachable in practice, since a
 * hazard's `correctiveActionId` is set exactly once and `closeHazard`
 * itself refuses a hazard with a linked action).
 */
export const updateCorrectiveActionStatus = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actionId = requireString(request, "actionId");
  const status = requireCorrectiveActionStatus(request);

  const uid = await requireOrganizationScopedReviewer(request, organizationId);

  const db = getFirestore();
  const ref = db.doc(
    `organizations/${organizationId}/corrective_actions/${actionId}`
  );
  const snapshot = await ref.get();
  const action = snapshot.data();
  if (!snapshot.exists || !action) {
    throw new HttpsError(
      "not-found",
      "That corrective action no longer exists."
    );
  }
  if (action.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That corrective action does not belong to the given organization."
    );
  }
  if (action.status === "completed") {
    throw new HttpsError(
      "failed-precondition",
      "That corrective action has already been completed."
    );
  }
  if (status === "completed" && action.assignedTo === uid) {
    throw new HttpsError(
      "failed-precondition",
      "You can't approve work assigned to you — another reviewer must " +
        "check it."
    );
  }
  if (status === "completed" && action.status !== "submittedForReview") {
    throw new HttpsError(
      "failed-precondition",
      "That corrective action must be submitted for review before it can " +
        "be marked completed."
    );
  }

  const now = FieldValue.serverTimestamp();

  // Sending submitted work back (to open/inProgress) is how a reviewer
  // rejects it; the optional reason is shown to the assignee, and cleared
  // again when they resubmit.
  const rawFeedback: unknown = (request.data ?? {}).reviewFeedback;
  const sendingBack =
    action.status === "submittedForReview" &&
    (status === "open" || status === "inProgress");
  const feedbackFields = sendingBack ?
    {
      reviewFeedback:
          typeof rawFeedback === "string" && rawFeedback.trim() ?
            rawFeedback.trim().slice(0, 1000) :
            null,
    } :
    {};
  const completionFields =
    status === "completed" ?
      {
        completedAt: now,
        completedBy: uid,
        completedByName: await displayNameOf(uid),
      } :
      {};

  if (status === "completed" && action.hazardId) {
    const hazardRef = db.doc(
      `organizations/${organizationId}/hazards/${action.hazardId}`
    );
    const hazardSnapshot = await hazardRef.get();
    const hazard = hazardSnapshot.data();

    const batch = db.batch();
    batch.update(ref, {
      status,
      updatedAt: now,
      ...completionFields,
    });
    if (hazardSnapshot.exists && hazard && hazard.status !== "closed") {
      batch.update(hazardRef, {
        status: "closed",
        closedAt: now,
        closedBy: uid,
        updatedAt: now,
        updatedBy: uid,
      });
    }
    await batch.commit();
    return {id: actionId, organizationId, status};
  }

  await ref.update({
    status,
    updatedAt: now,
    ...completionFields,
    ...feedbackFields,
  });

  return {id: actionId, organizationId, status};
});

/**
 * Lets the corrective action's own `assignedTo` submit their work for
 * review, moving `open`/`inProgress` -> `submittedForReview`. This is the
 * "assignee reports done" half of the completion split (see
 * `updateCorrectiveActionStatus`'s own doc comment for the reviewer half):
 * a reviewer can only complete an action once the assignee has claimed it
 * here first, distinguishing "the person who did the work says it's done"
 * from "an authorized reviewer verified that claim."
 *
 * Only the caller named in `assignedTo` may call this — NOT a reviewer
 * (reviewers act through `updateCorrectiveActionStatus`), and not anyone
 * else. Refuses from `submittedForReview` or `completed` (already
 * submitted/verified; resubmitting is a no-op refusal, not silently
 * accepted) and from `overdue` (a reviewer must first move it back to
 * `open`/`inProgress` — `overdue` is a reviewer-set status, not one the
 * assignee can submit out of directly, mirroring how `overdue` itself is
 * never assignee-settable).
 */
export const submitCorrectiveActionForReview = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actionId = requireString(request, "actionId");

  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const ref = getFirestore().doc(
    `organizations/${organizationId}/corrective_actions/${actionId}`
  );
  const snapshot = await ref.get();
  const action = snapshot.data();
  if (!snapshot.exists || !action) {
    throw new HttpsError(
      "not-found",
      "That corrective action no longer exists."
    );
  }
  if (action.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That corrective action does not belong to the given organization."
    );
  }
  if (action.assignedTo !== uid) throw denied();
  if (action.status !== "open" && action.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "Only work that is open or in progress can be submitted for review."
    );
  }

  // The assignee's evidence: what they did (always allowed), and photos
  // already uploaded under this action's own Storage folder.
  const data = request.data ?? {};
  const rawNote: unknown = data.completionNote;
  const completionNote =
    typeof rawNote === "string" && rawNote.trim() ?
      rawNote.trim().slice(0, 2000) :
      null;
  const rawPhotos: unknown = data.evidencePhotos ?? [];
  if (!Array.isArray(rawPhotos) || rawPhotos.length > MAX_EVIDENCE_PHOTOS) {
    throw new HttpsError(
      "invalid-argument",
      `evidencePhotos must be a list of at most ${MAX_EVIDENCE_PHOTOS}.`
    );
  }
  const folder = `organizations/${organizationId}/corrective_actions/` +
    `${actionId}/`;
  const evidencePhotos = rawPhotos.map((photo) => {
    const storagePath: unknown = photo?.storagePath;
    const downloadUrl: unknown = photo?.downloadUrl;
    if (
      typeof storagePath !== "string" ||
      !storagePath.startsWith(folder) ||
      typeof downloadUrl !== "string" ||
      !downloadUrl.trim()
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Each evidence photo must be uploaded to this action's own folder."
      );
    }
    return {storagePath, downloadUrl};
  });

  const required = requiredEvidenceKinds(action);
  if (required.includes("photo") && evidencePhotos.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "This action needs at least one photo as evidence."
    );
  }
  if (required.includes("confirmation") && !completionNote) {
    throw new HttpsError(
      "failed-precondition",
      "This action needs a written confirmation of what was done."
    );
  }

  const now = FieldValue.serverTimestamp();
  await ref.update({
    status: "submittedForReview",
    completionNote,
    evidencePhotos,
    submittedAt: now,
    submittedBy: uid,
    reviewFeedback: null,
    updatedAt: now,
  });

  return {id: actionId, organizationId, status: "submittedForReview"};
});
