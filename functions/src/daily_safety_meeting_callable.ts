/**
 * Daily Safety Meeting callables for JVA Safety.
 *
 * Stores one document per meeting at
 * `organizations/{orgId}/daily_safety_meetings/{id}` —
 * `firestore.rules` denies every client write to that collection outright,
 * so these callables are the only path that can create, edit or complete
 * one. Mirrors `worker_learning_callable.ts`'s shape: this is the SECOND
 * surface in this codebase where an ordinary operational role (`foreman`)
 * causes a write, and it follows the same "derive the acting identity from
 * `request.auth.uid` alone, never accept it as an argument" discipline.
 *
 * WHAT THE PLATFORM DOES AND DOES NOT DO
 *
 * This is a RECORD-KEEPING tool, not a meeting-conduct tool. The physical
 * toolbox talk happens off-platform; the foreman comes back afterward and
 * records what was covered — which activities, which meeting points, any
 * concerns raised, and that the meeting happened. There is deliberately no
 * audio, transcription, translation or language requirement anywhere in this
 * file or the data it writes: `concerns` is a caller-supplied list of plain
 * strings, stored and returned verbatim, never processed.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireActiveForeman`: the caller's OWN stored profile must be `active`,
 * belong to the named `organizationId`, hold the `foreman` role, and have
 * the named `siteId` in their own `siteIds` (granted only through
 * `assignWorkerToSite` — see `site_assignment_callable.ts`). This is
 * narrower than `requireOrganizationScopedManager`: a `siteManager` does not
 * automatically get to create or edit a site's daily meeting through this
 * file, because running a toolbox talk is a foreman's operational duty, not
 * an administrative one. `siteManager`/`admin` instead review the resulting
 * meeting record read-only — see PROJECT_CONTEXT.md §22A.
 *
 * None of these callables accept a `foremanId` argument on create, and every
 * subsequent callable re-fetches the stored meeting and checks
 * `meeting.foremanId === request.auth.uid` before allowing any edit — a
 * foreman can only ever act on a meeting they themselves started.
 *
 * THE VALIDATION CHAIN ON CREATE
 *
 * 1. The named site must exist within `organizationId` and its own
 *    `projectId` must match the one given — re-fetched fresh, never trusted
 *    from the request, mirroring `createActivity`'s site check.
 * 2. Every id in `activityIds` must name an existing, ACTIVE activity that
 *    belongs to that same site.
 * 3. Every id in `meetingPointIds` must name an existing, ACTIVE safety
 *    meeting point in the organization.
 *
 * A caller cannot create a meeting for an organization/project/site their
 * own profile does not grant them access to — see `requireActiveForeman`
 * above; nothing here trusts `organizationId`/`siteId` from the request
 * beyond using them to look up real documents to check against the caller's
 * own stored profile.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create a meeting for an organization, project or site they do not have
 *   foreman access to (see the validation chain above).
 * - Edit or complete another foreman's meeting — every edit callable
 *   re-checks `meeting.foremanId === request.auth.uid` against the freshly
 *   fetched document, not the request payload.
 * - Move a meeting to a different organization/project/site after creation:
 *   `organizationId`, `projectId`, `siteId` and `foremanId` are all
 *   immutable.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 *
 * ATTENDANCE
 *
 * `recordMeetingAttendance` stores one `present`/`absent` record per worker
 * per meeting at `daily_safety_meetings/{id}/attendance/{workerId}` —
 * deterministic id, mirroring `worker_learning_callable.ts`'s
 * `${workerUid}_${learningId}` idempotency pattern. It is deliberately
 * unrelated to Safety Learning: it never reads or writes
 * `worker_learning_records`.
 *
 * Authorization for attendance is the SAME `requireOwnMeeting` chain as
 * `updateDailySafetyMeeting` (only the meeting's own foreman, only while
 * `inProgress`), plus two more checks specific to attendance:
 *
 * 1. `workerId` must belong to the meeting's own site — the caller cannot
 *    mark attendance for a worker outside their site, even one in the same
 *    organization.
 * 2. `workerId` must not equal the caller's own uid — a worker cannot mark
 *    themselves present, because the whole point of foreman-recorded
 *    attendance is that someone else vouches for who showed up.
 *
 * CONCERNS
 *
 * `addMeetingConcern`/`updateMeetingConcern`/`removeMeetingConcern` manage
 * structured concerns at `daily_safety_meetings/{id}/concerns/{concernId}` —
 * an auto-id subcollection (unlike `attendance`'s deterministic worker-uid
 * id, since a meeting can have many concerns and there is no natural unique
 * key to key them by). Each stores a `description`, a `category` (fixed
 * enum: `safety`/`equipment`/`environment`/`worker`/`other`) and a `status`
 * (`open`/`resolved`, always written `open` — resolving a concern is a later
 * feature's job, not this one's).
 *
 * Authorization is the SAME `requireOwnMeeting` chain as
 * `updateDailySafetyMeeting` and attendance: only the meeting's own foreman,
 * only while the meeting is still `inProgress`. Once a meeting is
 * `completed`, ALL THREE of these callables refuse — concerns become part of
 * the permanent meeting record at that point, and nothing (not even the
 * meeting's own foreman) may add, edit or remove one after the fact. This is
 * what "prevent silently altering historical meeting data" means at the data
 * layer: the callable itself is the only write path, and it hard-stops once
 * `status !== "inProgress"`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `worker_learning_callable.ts`.
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
 * Reads an optional string-array argument (e.g. `activityIds`,
 * `meetingPointIds`, `concerns`), defaulting to an empty array.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string[]} the validated array.
 */
function stringArray(request: CallableRequest, field: string): string[] {
  const value = (request.data ?? {})[field];
  if (value === undefined) return [];
  if (
    !Array.isArray(value) ||
    !value.every((item) => typeof item === "string" && item.trim())
  ) {
    throw new HttpsError(
      "invalid-argument",
      `${field} must be an array of non-empty strings.`
    );
  }
  return value.map((item) => (item as string).trim());
}

/**
 * Reads an optional string-array argument, returning null when absent so an
 * update callable can distinguish "not supplied" from "set to empty".
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string[] | null} the validated array, or null.
 */
function optionalStringArray(
  request: CallableRequest,
  field: string
): string[] | null {
  if ((request.data ?? {})[field] === undefined) return null;
  return stringArray(request, field);
}

/**
 * Authorizes the caller as an active `foreman` of [organizationId] with
 * access to [siteId] through their own `siteIds`, and returns their uid.
 *
 * Every condition is checked server-side against the caller's own stored
 * profile — see this file's header note.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @param {string} siteId the site the action targets.
 * @return {Promise<string>} the authorized caller's own uid.
 */
async function requireActiveForeman(
  request: CallableRequest,
  organizationId: string,
  siteId: string
): Promise<string> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  // Role, organization membership and siteIds all live on the caller's own
  // membership document for THIS organization under the multi-organization
  // model, not on scalar profile fields — a Foreman may hold more than one
  // membership, so their role/site-access is necessarily per-organization.
  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) throw denied();
  if (membership.status !== "active") throw denied();
  if (membership.role !== "foreman") throw denied();

  const siteIds: unknown = membership.siteIds;
  const hasSiteAccess = Array.isArray(siteIds) && siteIds.includes(siteId);
  if (!hasSiteAccess) throw denied();

  return uid;
}

/**
 * Loads the target site and confirms it belongs to [organizationId] and
 * [projectId].
 *
 * Exported so `safety_alert_callable.ts` can import this exact
 * implementation instead of maintaining its own copy — mirrors
 * `requireOrganizationScopedManager`'s own "define once, export, import
 * elsewhere" shape in `site_assignment_callable.ts`.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} projectId the project the action targets.
 * @param {string} siteId the target site's id.
 * @return {Promise<void>} resolves when every check passes.
 */
export async function requireSiteMatches(
  organizationId: string,
  projectId: string,
  siteId: string
): Promise<void> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/sites/${siteId}`)
    .get();
  const site = snapshot.data();
  if (!snapshot.exists || !site) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  if (site.organizationId !== organizationId || site.projectId !== projectId) {
    throw new HttpsError(
      "failed-precondition",
      "That site does not belong to the given organization and project."
    );
  }
}

/**
 * Validates that every id in [activityIds] refers to an existing, ACTIVE
 * `Activity` document within [organizationId] that belongs to [siteId].
 * Fetched fresh, never trusted from the request payload alone — mirrors
 * `requireLearningItemsExist` in `safety_learning_callable.ts`.
 *
 * @param {string} organizationId the organization the meeting belongs to.
 * @param {string} siteId the site the meeting belongs to.
 * @param {string[]} activityIds the ids to validate.
 * @return {Promise<void>} resolves when every id is confirmed valid.
 */
async function requireActivitiesAtSite(
  organizationId: string,
  siteId: string,
  activityIds: string[]
): Promise<void> {
  if (activityIds.length === 0) return;
  const db = getFirestore();
  const snapshots = await Promise.all(
    activityIds.map((id) =>
      db.doc(`organizations/${organizationId}/activities/${id}`).get()
    )
  );
  const invalid = snapshots
    .map((snapshot, index) => ({snapshot, id: activityIds[index]}))
    .filter(({snapshot}) => {
      const data = snapshot.data();
      return !snapshot.exists ||
        !data ||
        data.siteId !== siteId ||
        data.status !== "active";
    });
  if (invalid.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "One or more activities are not active at this site: " +
        invalid.map(({id}) => id).join(", ")
    );
  }
}

/**
 * Validates that every id in [meetingPointIds] refers to an existing,
 * ACTIVE `SafetyMeetingPoint` document within [organizationId]. Mirrors
 * `requireActivitiesAtSite` above.
 *
 * @param {string} organizationId the organization the meeting belongs to.
 * @param {string[]} meetingPointIds the ids to validate.
 * @return {Promise<void>} resolves when every id is confirmed valid.
 */
async function requireActiveMeetingPoints(
  organizationId: string,
  meetingPointIds: string[]
): Promise<void> {
  if (meetingPointIds.length === 0) return;
  const db = getFirestore();
  const snapshots = await Promise.all(
    meetingPointIds.map((id) =>
      db
        .doc(`organizations/${organizationId}/safety_meeting_points/${id}`)
        .get()
    )
  );
  const invalid = snapshots
    .map((snapshot, index) => ({snapshot, id: meetingPointIds[index]}))
    .filter(({snapshot}) => {
      const data = snapshot.data();
      return !snapshot.exists || !data || data.status !== "active";
    });
  if (invalid.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "One or more safety meeting points are not active: " +
        invalid.map(({id}) => id).join(", ")
    );
  }
}

/**
 * Loads the target meeting, confirms it belongs to [organizationId], and
 * confirms the caller is its own foreman. Returns the stored data.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} id the meeting's id.
 * @param {string} callerUid the caller's own uid.
 * @return {Promise<FirebaseFirestore.DocumentData>} the meeting's stored
 * data.
 */
async function requireOwnMeeting(
  organizationId: string,
  id: string,
  callerUid: string
): Promise<FirebaseFirestore.DocumentData> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/daily_safety_meetings/${id}`)
    .get();
  const meeting = snapshot.data();
  if (!snapshot.exists || !meeting) {
    throw new HttpsError("not-found", "That meeting no longer exists.");
  }
  if (meeting.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That meeting does not belong to the given organization."
    );
  }
  if (meeting.foremanId !== callerUid) {
    throw denied();
  }
  return meeting;
}

/**
 * Creates a Daily Safety Meeting for today, within an existing organization,
 * project and site the caller has foreman access to.
 *
 * `activityIds` and `meetingPointIds` are optional at creation — the
 * foreman-facing flow creates the meeting first (from the site's today's
 * activities and the recommended meeting points), then the foreman
 * accepts/removes/adds points via `updateDailySafetyMeeting` before
 * completing it. Both, when given, are validated exactly as
 * `updateDailySafetyMeeting` validates them — see the two validation
 * helpers above.
 */
export const createDailySafetyMeeting = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const foremanId = await requireActiveForeman(request, organizationId, siteId);
  const projectId = requireString(request, "projectId");
  const activityIds = stringArray(request, "activityIds");
  const meetingPointIds = stringArray(request, "meetingPointIds");

  await requireSiteMatches(organizationId, projectId, siteId);
  await requireActivitiesAtSite(organizationId, siteId, activityIds);
  await requireActiveMeetingPoints(organizationId, meetingPointIds);

  const now = new Date();
  const date = now.toISOString().slice(0, 10);

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/daily_safety_meetings`)
    .doc();
  await ref.set({
    organizationId,
    projectId,
    siteId,
    date,
    startTime: FieldValue.serverTimestamp(),
    endTime: null,
    foremanId,
    activityIds,
    meetingPointIds,
    status: "inProgress",
    concerns: [],
    correctiveActionIds: [],
    createdAt: FieldValue.serverTimestamp(),
    completedAt: null,
  });

  return {id: ref.id, organizationId, projectId, siteId};
});

/**
 * Updates an in-progress meeting's `activityIds`, `meetingPointIds` and/or
 * `concerns` — the foreman accepting/removing/adding recommended meeting
 * points and recording concerns after the physical meeting. Only the
 * meeting's own foreman may call this (see `requireOwnMeeting`), and only
 * while it is still `inProgress`: a completed meeting is a closed record.
 */
export const updateDailySafetyMeeting = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const id = requireString(request, "id");
  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireOwnMeeting(organizationId, id, foremanId);
  if (meeting.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "That meeting has already been completed."
    );
  }

  const activityIds = optionalStringArray(request, "activityIds");
  const meetingPointIds = optionalStringArray(request, "meetingPointIds");
  const concerns = optionalStringArray(request, "concerns");

  if (activityIds !== null) {
    await requireActivitiesAtSite(
      organizationId,
      meeting.siteId as string,
      activityIds
    );
  }
  if (meetingPointIds !== null) {
    await requireActiveMeetingPoints(organizationId, meetingPointIds);
  }

  await getFirestore()
    .doc(`organizations/${organizationId}/daily_safety_meetings/${id}`)
    .update({
      ...(activityIds !== null ? {activityIds} : {}),
      ...(meetingPointIds !== null ? {meetingPointIds} : {}),
      ...(concerns !== null ? {concerns} : {}),
    });

  return {id, organizationId};
});

/**
 * Completes an in-progress meeting: sets `status` to `completed`,
 * `endTime`/`completedAt` to the server time. Only the meeting's own
 * foreman may call this, and only while it is still `inProgress` —
 * completion is a one-way transition, matching every other terminal status
 * in this codebase (e.g. a completed `WorkerLearningRecord`).
 *
 * At least one activity and one meeting point must be recorded before a
 * meeting can be completed — an empty completed meeting would be a record
 * of nothing having been discussed, which defeats the point of keeping this
 * record at all.
 */
export const completeDailySafetyMeeting = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const id = requireString(request, "id");
  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireOwnMeeting(organizationId, id, foremanId);
  if (meeting.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "That meeting has already been completed."
    );
  }

  const activityIds = (meeting.activityIds as string[] | undefined) ?? [];
  const meetingPointIds =
    (meeting.meetingPointIds as string[] | undefined) ?? [];
  if (activityIds.length === 0 || meetingPointIds.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "At least one activity and one meeting point must be recorded before " +
        "completing this meeting."
    );
  }

  const now = FieldValue.serverTimestamp();
  await getFirestore()
    .doc(`organizations/${organizationId}/daily_safety_meetings/${id}`)
    .update({
      status: "completed",
      endTime: now,
      completedAt: now,
    });

  return {id, organizationId, status: "completed"};
});

/**
 * Validates that [workerId] refers to an existing, active user who belongs
 * to [siteId] within [organizationId] — re-fetched fresh, never trusted from
 * the request payload. Mirrors `requireActiveForeman`'s own profile checks,
 * applied to the TARGET worker instead of the caller.
 *
 * Exported so `hazard_callable.ts` can import this exact implementation
 * instead of maintaining its own copy — mirrors `requireSiteMatches`'s own
 * "define once, export, import elsewhere" shape in this same file. There, it
 * confirms a hazard reporter actually has site access before a hazard can be
 * filed against that site.
 *
 * @param {string} organizationId the organization the meeting belongs to.
 * @param {string} siteId the meeting's own site.
 * @param {string} workerId the worker being marked present/absent.
 * @return {Promise<void>} resolves when every check passes.
 */
export async function requireWorkerAtSite(
  organizationId: string,
  siteId: string,
  workerId: string
): Promise<void> {
  const snapshot = await getFirestore().doc(`users/${workerId}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new HttpsError("failed-precondition", "That worker does not exist.");
  }
  if (profile.accountStatus !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "That worker is not an active member of this organization."
    );
  }

  // Organization membership and siteIds live on the worker's own membership
  // document for this organization under the multi-organization model, not
  // scalar profile fields.
  const membershipSnapshot = await getFirestore()
    .doc(`users/${workerId}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (
    !membershipSnapshot.exists || !membership ||
    membership.status !== "active"
  ) {
    throw new HttpsError(
      "failed-precondition",
      "That worker does not belong to the given organization."
    );
  }
  const siteIds: unknown = membership.siteIds;
  const hasSiteAccess = Array.isArray(siteIds) && siteIds.includes(siteId);
  if (!hasSiteAccess) {
    throw new HttpsError(
      "failed-precondition",
      "That worker does not belong to this meeting's site."
    );
  }
}

/**
 * Records or updates one worker's `present`/`absent` attendance status for
 * an in-progress meeting, at
 * `daily_safety_meetings/{id}/attendance/{workerId}`.
 *
 * Only the meeting's own foreman may call this (see `requireOwnMeeting`),
 * only while the meeting is still `inProgress`, and never for the caller's
 * own uid — a worker cannot mark themselves present, and since only the
 * foreman may call this at all, the foreman cannot record their own
 * attendance either. `workerId` must belong to the meeting's own site (see
 * `requireWorkerAtSite`). Idempotent: calling again for the same worker
 * overwrites their previous status rather than creating a duplicate,
 * because the document id is the worker's own uid.
 *
 * Deliberately separate from Safety Learning: this callable never reads or
 * writes `worker_learning_records`.
 */
export const recordMeetingAttendance = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const workerId = requireString(request, "workerId");
  const statusValue = requireString(request, "status");
  if (statusValue !== "present" && statusValue !== "absent") {
    throw new HttpsError(
      "invalid-argument",
      "status must be 'present' or 'absent'."
    );
  }

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  if (workerId === foremanId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot record your own attendance."
    );
  }

  const meeting = await requireOwnMeeting(organizationId, meetingId, foremanId);
  if (meeting.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "That meeting has already been completed."
    );
  }

  const siteId = meeting.siteId as string;
  await requireWorkerAtSite(organizationId, siteId, workerId);

  await getFirestore()
    .doc(
      `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
        `/attendance/${workerId}`
    )
    .set({
      meetingId,
      organizationId,
      siteId,
      workerId,
      status: statusValue,
      recordedAt: FieldValue.serverTimestamp(),
      recordedBy: foremanId,
    });

  return {organizationId, meetingId, workerId, status: statusValue};
});

const CONCERN_CATEGORIES = [
  "safety",
  "equipment",
  "environment",
  "worker",
  "other",
] as const;
type ConcernCategory = (typeof CONCERN_CATEGORIES)[number];

/**
 * Validates and returns the `category` argument, refusing anything outside
 * the fixed set this stage supports.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {ConcernCategory} the validated category.
 */
function requireConcernCategory(request: CallableRequest): ConcernCategory {
  const value = requireString(request, "category");
  if (!(CONCERN_CATEGORIES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "category must be one of: " + CONCERN_CATEGORIES.join(", ")
    );
  }
  return value as ConcernCategory;
}

/**
 * Loads the target meeting via `requireOwnMeeting` and additionally confirms
 * it is still `inProgress` — the shared precondition for every concern
 * write. Concerns become part of the permanent meeting record once
 * completed, so every one of `addMeetingConcern`/`updateMeetingConcern`/
 * `removeMeetingConcern` refuses past that point, with no exception for the
 * meeting's own foreman.
 *
 * Exported so `corrective_action_callable.ts` can import this exact
 * implementation instead of maintaining its own (behaviorally identical)
 * copy — mirrors `requireOrganizationScopedManager`'s own "define once,
 * export, import elsewhere" shape in `site_assignment_callable.ts`.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} meetingId the meeting's id.
 * @param {string} callerUid the caller's own uid.
 * @return {Promise<FirebaseFirestore.DocumentData>} the meeting's stored
 * data.
 */
export async function requireInProgressOwnMeeting(
  organizationId: string,
  meetingId: string,
  callerUid: string
): Promise<FirebaseFirestore.DocumentData> {
  const meeting = await requireOwnMeeting(organizationId, meetingId, callerUid);
  if (meeting.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "That meeting has already been completed."
    );
  }
  return meeting;
}

/**
 * Loads the target concern and confirms it belongs to [organizationId] and
 * [meetingId] — re-fetched fresh, never trusted from the request payload.
 * Mirrors `requireOwnMeeting`'s own shape, applied to a concern instead of
 * the meeting itself.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} meetingId the meeting the concern must belong to.
 * @param {string} concernId the concern's id.
 * @return {Promise<FirebaseFirestore.DocumentReference>} a reference to the
 * validated concern document.
 */
async function requireOwnMeetingConcern(
  organizationId: string,
  meetingId: string,
  concernId: string
): Promise<FirebaseFirestore.DocumentReference> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
      `/concerns/${concernId}`
  );
  const snapshot = await ref.get();
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
  return ref;
}

/**
 * Adds a new concern to an in-progress meeting, at
 * `daily_safety_meetings/{id}/concerns/{concernId}`.
 *
 * Only the meeting's own foreman may call this (see
 * `requireInProgressOwnMeeting`). `organizationId` and `siteId` are always
 * copied from the freshly-fetched meeting document, never accepted from the
 * request, so a concern can never be created for an organization/site other
 * than the one its own meeting belongs to.
 */
export const addMeetingConcern = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const description = requireString(request, "description");
  const category = requireConcernCategory(request);

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireInProgressOwnMeeting(
    organizationId,
    meetingId,
    foremanId
  );

  const ref = getFirestore()
    .collection(
      `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
        "/concerns"
    )
    .doc();
  await ref.set({
    meetingId,
    organizationId,
    siteId: meeting.siteId,
    description,
    category,
    reportedBy: foremanId,
    status: "open",
    createdAt: FieldValue.serverTimestamp(),
  });

  return {id: ref.id, organizationId, meetingId};
});

/**
 * Edits an existing concern's `description` and/or `category` while its
 * meeting is still `inProgress` — the foreman correcting a concern before
 * completing the meeting. Only the meeting's own foreman may call this, and
 * only for a concern that actually belongs to the named meeting (see
 * `requireOwnMeetingConcern`). Refuses once the meeting is `completed`,
 * exactly like `addMeetingConcern`.
 */
export const updateMeetingConcern = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const concernId = requireString(request, "concernId");

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  await requireInProgressOwnMeeting(organizationId, meetingId, foremanId);
  const ref = await requireOwnMeetingConcern(
    organizationId,
    meetingId,
    concernId
  );

  const descriptionValue = (request.data ?? {}).description;
  const categoryValue = (request.data ?? {}).category;
  if (descriptionValue === undefined && categoryValue === undefined) {
    throw new HttpsError(
      "invalid-argument",
      "Provide at least one of description or category to update."
    );
  }

  const update: Record<string, unknown> = {};
  if (descriptionValue !== undefined) {
    update.description = requireString(request, "description");
  }
  if (categoryValue !== undefined) {
    update.category = requireConcernCategory(request);
  }

  await ref.update(update);

  return {id: concernId, organizationId, meetingId};
});

/**
 * Removes a concern from an in-progress meeting before it is completed.
 * Only the meeting's own foreman may call this, and only for a concern that
 * actually belongs to the named meeting — see `updateMeetingConcern`'s doc
 * comment for the shared preconditions.
 */
export const removeMeetingConcern = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const concernId = requireString(request, "concernId");

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  await requireInProgressOwnMeeting(organizationId, meetingId, foremanId);
  const ref = await requireOwnMeetingConcern(
    organizationId,
    meetingId,
    concernId
  );

  await ref.delete();

  return {id: concernId, organizationId, meetingId};
});
