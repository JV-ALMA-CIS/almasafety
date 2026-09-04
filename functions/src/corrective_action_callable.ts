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
 * `daily_safety_meeting_callable.ts`'s own `requireInProgressOwnMeeting`
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
 * moves through `open` -> `inProgress` -> `completed` (or `overdue`,
 * settable in place of `open`/`inProgress` by an authorized updater — there
 * is no scheduled function that flips it automatically; see
 * `CorrectiveActionStatus`'s doc comment in the Flutter source) exclusively
 * through `updateCorrectiveActionStatus`, restricted to the same reviewer
 * roles that already review pending accounts. `completed` is TERMINAL: once
 * reached, no further status update of any kind is accepted — see that
 * callable's own doc comment.
 *
 * WHAT AUTHORIZES CREATION
 *
 * `requireInProgressOwnMeeting`, IMPORTED from
 * `daily_safety_meeting_callable.ts` rather than duplicated: the caller must
 * be the meeting's own foreman, and the meeting must still be `inProgress`.
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
 *   for one that is no longer `inProgress` — completed meetings remain
 *   historically auditable, never retroactively editable.
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
import {requireInProgressOwnMeeting} from "./daily_safety_meeting_callable";

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
  if (profile.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That assignee does not belong to the given organization."
    );
  }
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

  const role: unknown = profile.platformRole;
  if (!isAppRole(role) || !canReviewPendingAccounts(role as AppRole)) {
    throw denied();
  }
  if (role === "admin") return uid;
  if (profile.organizationId !== organizationId) throw denied();

  return uid;
}

const CORRECTIVE_ACTION_STATUSES = [
  "open",
  "inProgress",
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
  const evidenceRequiredValue = (request.data ?? {}).evidenceRequired;
  const evidenceRequired = evidenceRequiredValue === true;

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
    title,
    description,
    assignedTo,
    assignedBy: callerId,
    dueDate,
    status: "open",
    evidenceRequired,
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
 * Creates a corrective action either from an in-progress meeting (optionally
 * naming one of that meeting's own concerns) OR from a hazard, at
 * `organizations/{orgId}/corrective_actions/{id}`. Exactly one of
 * `meetingId` or `hazardId` must be given — a corrective action names at
 * most one origin, never both (see FIRESTORE_DATA_MODEL.md §7).
 *
 * MEETING-ORIGINATED (`meetingId` given): only the meeting's own foreman may
 * call this (see `requireInProgressOwnMeeting`). `organizationId`,
 * `projectId` and `siteId` are always copied from the freshly-fetched
 * meeting, never accepted from the request. `concernId`, when given, must
 * belong to the same meeting.
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

  if (hasMeetingId === hasHazardId) {
    throw new HttpsError(
      "invalid-argument",
      "Exactly one of meetingId or hazardId is required."
    );
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
  const evidenceRequiredValue = data.evidenceRequired;
  const evidenceRequired = evidenceRequiredValue === true;

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  if (assignedTo === foremanId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot assign a corrective action to yourself."
    );
  }

  const meeting = await requireInProgressOwnMeeting(
    organizationId,
    meetingId,
    foremanId
  );

  if (concernId !== null) {
    await requireMeetingConcern(organizationId, meetingId, concernId);
  }
  await requireActiveOrganizationMember(organizationId, assignedTo);

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/corrective_actions`)
    .doc();
  const now = FieldValue.serverTimestamp();
  await ref.set({
    organizationId,
    projectId: meeting.projectId,
    siteId: meeting.siteId,
    meetingId,
    concernId,
    hazardId: null,
    title,
    description,
    assignedTo,
    assignedBy: foremanId,
    dueDate,
    status: "open",
    evidenceRequired,
    createdAt: now,
    updatedAt: now,
    completedAt: null,
  });

  return {id: ref.id, organizationId, meetingId};
});

/**
 * Transitions an existing corrective action's `status`. Only an authorized
 * supervisor/manager role (see `requireOrganizationScopedReviewer`) within
 * the action's own organization may call this — never the meeting's own
 * foreman by virtue of having created it, and never the assignee by virtue
 * of being assigned it. There is no delete callable and no path back to
 * removing a corrective action once created — see this file's header note
 * on why completed meetings and their corrective actions stay historically
 * auditable.
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
 */
export const updateCorrectiveActionStatus = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actionId = requireString(request, "actionId");
  const status = requireCorrectiveActionStatus(request);

  await requireOrganizationScopedReviewer(request, organizationId);

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
  if (action.status === "completed") {
    throw new HttpsError(
      "failed-precondition",
      "That corrective action has already been completed."
    );
  }

  await ref.update({
    status,
    updatedAt: FieldValue.serverTimestamp(),
    ...(status === "completed" ?
      {completedAt: FieldValue.serverTimestamp()} :
      {}),
  });

  return {id: actionId, organizationId, status};
});
