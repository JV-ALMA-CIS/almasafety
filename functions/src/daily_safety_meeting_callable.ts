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
 * Authorization: only the meeting's own foreman, always — but NOT uniformly
 * `inProgress`-only. `addMeetingConcern` deliberately ALSO accepts a
 * COMPLETED meeting (a worker may raise something with the foreman a day
 * later, or the foreman remembers something back at the office) — see that
 * callable's own doc comment for why. `updateMeetingConcern`/
 * `removeMeetingConcern` remain `inProgress`-only: a concern once logged can
 * never be edited or retracted after the fact, completed or not. This is
 * what "prevent silently altering historical meeting data" means at the
 * data layer for THOSE two — the callable itself is the only write path,
 * and it hard-stops once `status !== "inProgress"`.
 *
 * DISCUSSION CONTEXT (point notes)
 *
 * `setMeetingPointNote`/`removeMeetingPointNote` manage a discussion note per
 * COVERED meeting point at
 * `daily_safety_meetings/{id}/point_notes/{meetingPointId}` — a
 * DETERMINISTIC id keyed by the meeting point itself, mirroring
 * `attendance/{workerId}`'s shape (one current record per key), unlike
 * `concerns`' auto-id subcollection. **This is deliberately NOT a Concern.**
 * A note is plain free text describing what was actually explained/
 * discussed/decided about a covered point — e.g. "reminded workers to
 * maintain three points of contact on ladders; team confirmed
 * understanding" — never an issue with a category or status. It exists to
 * close the specific evidentiary gap where checking a meeting point's
 * checkbox alone proves nothing about whether it was genuinely discussed.
 * Optional: a meeting completes with or without notes on any given point.
 *
 * Authorization: only the meeting's own foreman. `setMeetingPointNote`
 * deliberately ALSO accepts a COMPLETED meeting, matching
 * `addMeetingConcern`'s exception — see that callable's doc comment. It
 * additionally confirms the named `meetingPointId` is currently on the
 * meeting's own `meetingPointIds` — a note is meaningless for a point that
 * was never actually recorded as covered. `removeMeetingPointNote` remains
 * `inProgress`-only.
 *
 * EVIDENCE
 *
 * `addMeetingEvidence`/`removeMeetingEvidence` manage supporting proof (a
 * photo of the foreman's handwritten toolbox-talk book, a sign-in sheet, a
 * briefing/site photo, or another document) at
 * `daily_safety_meetings/{id}/evidence/{evidenceId}` — an auto-id
 * subcollection, mirroring `concerns`' shape (a meeting can have many
 * pieces of evidence, no natural unique key). The actual file bytes are
 * uploaded to Cloud Storage by the CLIENT before calling this — see
 * `DailySafetyMeetingService.uploadMeetingEvidence`'s doc comment for the
 * pre-allocate-id / upload / then-call-the-callable sequencing, which
 * mirrors `HazardService.reportHazard` exactly. This callable only writes
 * the Firestore METADATA row (`storagePath`, `downloadUrl`, `evidenceType`,
 * `fileType`, an optional `description`, `uploadedBy`, `createdAt`) — it
 * never touches Storage itself.
 *
 * **DELIBERATE EXCEPTION to the "everything freezes at completion" rule
 * that governs `activityIds`/`meetingPointIds`/`concerns`/point notes:
 * `addMeetingEvidence` may still be called on a COMPLETED meeting.** A
 * foreman may not have their physical safety book on hand at the exact
 * moment they complete the meeting on their phone; forcing them to keep
 * the meeting artificially `inProgress` until every photo is uploaded would
 * be worse for real field use than allowing evidence to arrive afterward.
 * This is why `addMeetingEvidence` calls the plain `requireOwnMeeting` (no
 * status check), not `requireInProgressOwnMeeting` — every other write
 * callable in this file uses the latter. Evidence METADATA is otherwise
 * immutable once written (no `updateMeetingEvidence` exists at all — a
 * wrong caption means delete-and-re-add, never a silent edit).
 * `removeMeetingEvidence`, by contrast, IS gated on `inProgress` — evidence
 * on a completed meeting may still be added to, but never removed, exactly
 * like `corrective_actions`' own "no delete" rule for a permanent record.
 *
 * SAFETY LEARNING GATE (LEARN -> BRIEF -> WORK, Phase 2/3)
 *
 * `createDailySafetyMeeting` and `completeDailySafetyMeeting` both require
 * the FOREMAN THEMSELF to have COMPLETED every ATTENDANCE-GATING
 * `SafetyLearning` item required for the meeting's own
 * `siteId`/`activityIds` — see `requireForemanLearningComplete`, called
 * once at creation (so a foreman cannot even START today's meeting with
 * outstanding gating learning) and again at completion (defense in depth,
 * in case a requirement newly applies mid-meeting — e.g. a meeting
 * point/activity is added via `updateDailySafetyMeeting` that carries its
 * own requirement). The rationale is that the foreman is the one
 * certifying, by running and then completing this record, that the toolbox
 * talk covered the required ground — that certification is not credible if
 * the foreman has not themselves completed the GATING learning the
 * organization requires for the very activities/site they are briefing on.
 *
 * `recordMeetingAttendance` requires the SAME of each individual WORKER
 * before they may be marked `present` (not `absent`) — resolved from the
 * meeting's own scope the same way. A worker with outstanding gating
 * learning may still attend and be marked `absent`, so the record is never
 * structurally stuck; they simply cannot be certified `present` until their
 * own gating learning is complete.
 *
 * **REQUIRED vs. ATTENDANCE-GATING — these are deliberately not the same
 * set.** `SafetyRequirement.gatesAttendance` (see that class's own doc
 * comment) distinguishes learning that is merely REQUIRED of a worker
 * (visible on `MySafetyLearningScreen`, counted in compliance — resolved by
 * `resolveRequiredLearningForScope`, unchanged) from the narrower subset
 * that additionally blocks Daily Safety Meeting attendance (resolved by
 * `resolveAttendanceGatingLearningIds`, both in
 * `worker_learning_callable.ts`). Every gate in THIS file —
 * `requireForemanLearningComplete`, `recordMeetingAttendance`'s
 * present-check, and `getMeetingAttendeeLearningStatus`'s preview below —
 * uses the GATING resolver exclusively. A requirement whose
 * `gatesAttendance` is `false` still contributes its learning ids to a
 * worker's overall required set (unaffected), it simply never appears in
 * `outstandingLearningTitles` here. A learning id required by BOTH a
 * gating and a non-gating requirement is still gating — see
 * `resolveAttendanceGatingLearningIds`'s own doc comment for exactly how
 * that overlap is resolved (per-learning-id, not per-requirement).
 *
 * The check re-derives gating learning from the MEETING's own
 * `siteId`/`activityIds` via `resolveAttendanceGatingLearningIds`
 * (`worker_learning_callable.ts`) — NOT from any `ActivityAssignment` the
 * foreman might hold, because that mechanism is `worker`-role only (see
 * `activity_assignment_callable.ts`'s `requireWorkerEligible`) and a foreman
 * is never assigned to an activity that way. Completion is checked against
 * the foreman's own `worker_learning_records` — the exact same collection
 * and `status == "completed"` rule `worker_learning_callable.ts` uses for a
 * worker's own progress, so "the foreman completed this" means the same
 * thing here as it does on `MySafetyLearningScreen`. A foreman with nothing
 * gating required of them for this meeting is never blocked.
 *
 * ATTENDEE LEARNING VISIBILITY (Phase 3, informational only)
 *
 * `getMeetingAttendeeLearningStatus` is the narrow, read-only counterpart to
 * the gate above: it lets a foreman see which of THEIR OWN meeting's
 * attendees have outstanding ATTENDANCE-GATING learning, without granting
 * any broader access to `worker_learning_records` — that collection's own
 * `firestore.rules` entry still denies `foreman` read access outright; this
 * callable is the deliberate, audited "elsewhere" its comment refers to. It
 * never blocks or gates anything (unlike `requireForemanLearningComplete`,
 * still the only hard gate, still checked only against the foreman) — it
 * exists purely so the workspace UI can show the foreman a heads-up before
 * they mark someone present, not to enforce a new rule on workers. It
 * deliberately uses the SAME gating resolver as the real gate (not the
 * broader "required" resolver) so this preview can never disagree with
 * what `recordMeetingAttendance` will actually enforce.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {createNotification} from "./notification_callable";
import {
  attachPendingPreStartStops,
  PRE_START_OUTCOMES,
  PreStartOutcome,
  siteManagersOf,
} from "./pre_start_check_callable";
import {MeetingHint, outstandingNeededToday} from "./daily_learning_plan";
import {todaysMeetingDate} from "./worker_learning_callable";

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
 * Titles of [uid]'s "Needed today" lessons they have NOT completed yet —
 * the only learning that blocks a worker from being marked present, or a
 * Foreman from starting/completing their meeting. "Needed today" is the
 * person's small daily plan (one lesson per activity they do today plus
 * one general lesson — see `daily_learning_plan.ts`), resolved from their
 * own work today, not every "Before meeting" lesson that applies.
 *
 * @param {string} organizationId the organization the records belong to.
 * @param {string} uid the worker/foreman whose completion to check.
 * @param {MeetingHint} meeting the meeting they are being checked against.
 * @return {Promise<string[]>} the outstanding lessons' titles.
 */
async function outstandingLearningTitles(
  organizationId: string,
  uid: string,
  meeting: MeetingHint
): Promise<string[]> {
  const outstanding = await outstandingNeededToday(
    organizationId,
    uid,
    todaysMeetingDate(),
    meeting
  );
  return outstanding.map((lesson) => lesson.title);
}

/**
 * Refuses to start or complete the meeting unless [foremanId] has completed
 * their own "Needed today" lessons — see `outstandingLearningTitles`.
 *
 * @param {string} organizationId the organization the meeting belongs to.
 * @param {string} foremanId the foreman starting/completing the meeting.
 * @param {MeetingHint} meeting the meeting being started/completed.
 * @return {Promise<void>} resolves when nothing needed today is
 * outstanding.
 */
async function requireForemanLearningComplete(
  organizationId: string,
  foremanId: string,
  meeting: MeetingHint
): Promise<void> {
  const outstanding = await outstandingLearningTitles(
    organizationId,
    foremanId,
    meeting
  );

  if (outstanding.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "You must complete the following safety learning before completing " +
        "this meeting: " + outstanding.join(", ")
    );
  }
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
 *
 * LEARN -> BRIEF -> WORK, at the START of the meeting too (Phase 3): a
 * foreman with outstanding required learning for this site/these
 * activities may not even START today's meeting — see this file's header
 * note ("SAFETY LEARNING GATE") and `requireForemanLearningComplete`,
 * previously checked only at `completeDailySafetyMeeting`. Checking again
 * here closes the gap where a foreman could open and run an entire meeting
 * before ever discovering, at the very end, that they are blocked — the
 * refusal now comes before the workspace even opens, naming exactly what
 * is outstanding.
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
  await requireForemanLearningComplete(organizationId, foremanId, {
    id: null,
    siteId,
    activityIds,
  });

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

  // A worker who answered STOP on their Pre-Start Check before this
  // meeting existed had nowhere to raise it; it becomes a concern now.
  await attachPendingPreStartStops(organizationId, siteId, date, ref.id);

  return {id: ref.id, organizationId, projectId, siteId};
});

/**
 * Validates the risk assessments (AHAs) a Foreman says were covered at this
 * meeting: each must be an ACCEPTED AHA for the meeting's own site. Returns
 * a snapshot of each (name and revision) to store on the meeting, so the
 * record still reads correctly after the AHA is revised.
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the meeting's site.
 * @param {string[]} ids the covered AHA ids.
 * @return {Promise<object[]>} id, featureOfWork and revision of each.
 */
async function requireAcceptedAhasAtSite(
  organizationId: string,
  siteId: string,
  ids: string[]
): Promise<{id: string; featureOfWork: string; revision: number}[]> {
  const db = getFirestore();
  return Promise.all(ids.map(async (id) => {
    const aha = (
      await db.doc(`organizations/${organizationId}/risk_assessments/${id}`)
        .get()
    ).data();
    if (!aha || aha.status !== "accepted" || aha.siteId !== siteId) {
      throw new HttpsError(
        "invalid-argument",
        "Only an accepted risk assessment for this site can be covered."
      );
    }
    return {
      id,
      featureOfWork: typeof aha.featureOfWork === "string" ?
        aha.featureOfWork :
        "",
      revision: typeof aha.revision === "number" ? aha.revision : 1,
    };
  }));
}

/**
 * Today's activities that still need their risk assessment (AHA) covered.
 * The Safety Plan: Foremen cover the activity hazard analysis with the crew
 * before work begins. An accepted AHA of the site applies to an activity
 * when it lists that activity, or lists none (it covers the whole site).
 * An activity with an applicable AHA is covered once ANY applicable AHA is
 * in [coveredIds]; an activity with none applicable needs nothing.
 *
 * @param {string} organizationId the organization.
 * @param {string} siteId the meeting's site.
 * @param {string[]} activityIds the meeting's activities.
 * @param {string[]} coveredIds the AHAs ticked as covered.
 * @return {Promise<string[]>} the names of the activities still needing
 * one (empty when the meeting may be completed).
 */
async function activitiesNeedingAha(
  organizationId: string,
  siteId: string,
  activityIds: string[],
  coveredIds: string[]
): Promise<string[]> {
  const db = getFirestore();
  const snapshot = await db
    .collection(`organizations/${organizationId}/risk_assessments`)
    .where("siteId", "==", siteId)
    .where("status", "==", "accepted")
    .get();
  const ahas = snapshot.docs.map((doc) => ({
    id: doc.id,
    activityIds: (doc.data().activityIds as string[] | undefined) ?? [],
  }));
  const missing = activityIds.filter((activityId) => {
    const applicable = ahas.filter(
      (a) => a.activityIds.length === 0 || a.activityIds.includes(activityId)
    );
    return applicable.length > 0 &&
      !applicable.some((a) => coveredIds.includes(a.id));
  });
  return Promise.all(missing.map(async (id) => {
    const activity = (
      await db.doc(`organizations/${organizationId}/activities/${id}`).get()
    ).data();
    return typeof activity?.name === "string" ? activity.name : id;
  }));
}

/**
 * Updates an in-progress meeting's `activityIds`, `meetingPointIds` and/or
 * `concerns` and/or `ahaIds` (the accepted risk assessments covered with
 * the crew) — the foreman accepting/removing/adding recommended meeting
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
  const ahaIds = optionalStringArray(request, "ahaIds");
  const ahasCovered = ahaIds === null ?
    null :
    await requireAcceptedAhasAtSite(
      organizationId,
      meeting.siteId as string,
      [...new Set(ahaIds)]
    );

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
      ...(ahasCovered !== null ?
        {ahaIds: ahasCovered.map((a) => a.id), ahasCovered} :
        {}),
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

  // Safety Plan: Foremen cover the activity hazard analysis with the crew
  // before work begins.
  const needingAha = await activitiesNeedingAha(
    organizationId,
    meeting.siteId as string,
    activityIds,
    (meeting.ahaIds as string[] | undefined) ?? []
  );
  if (needingAha.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "Cover the risk assessment (AHA) with the crew, and tick it, for: " +
        needingAha.join(", ") + "."
    );
  }

  await requireForemanLearningComplete(organizationId, foremanId, {
    id,
    siteId: meeting.siteId as string,
    activityIds,
  });

  const {crewOutcome, crewOutcomeNote} = optionalCrewOutcome(request);

  const now = FieldValue.serverTimestamp();
  await getFirestore()
    .doc(`organizations/${organizationId}/daily_safety_meetings/${id}`)
    .update({
      status: "completed",
      endTime: now,
      completedAt: now,
      crewOutcome,
      crewOutcomeNote,
    });

  if (crewOutcome === "stop") {
    const managers = await siteManagersOf(organizationId);
    await Promise.all(managers.map((recipientUid) => createNotification({
      organizationId,
      recipientUid,
      type: "safetyMeeting",
      title: "Crew STOP at today's safety meeting",
      message: `The Foreman stopped work for the crew: ${crewOutcomeNote}`,
      relatedEntityType: "dailySafetyMeeting",
      relatedEntityId: id,
    })));
  }

  return {id, organizationId, status: "completed", crewOutcome};
});

/**
 * Reads the Foreman's crew result for a meeting being completed — GO, GO
 * corrected, or STOP, the same three outcomes as a worker's Pre-Start Check
 * — and its note, which is required for anything other than GO.
 *
 * Optional on the server so a client built before crew results existed can
 * still complete a meeting (stored as null); the app always sends one.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {object} the validated `crewOutcome` (or null) and its
 * `crewOutcomeNote` (or null).
 */
function optionalCrewOutcome(request: CallableRequest): {
  crewOutcome: PreStartOutcome | null;
  crewOutcomeNote: string | null;
} {
  const data = request.data ?? {};
  const outcome = data.crewOutcome;
  if (outcome === undefined || outcome === null) {
    return {crewOutcome: null, crewOutcomeNote: null};
  }
  if (!(PRE_START_OUTCOMES as readonly unknown[]).includes(outcome)) {
    throw new HttpsError(
      "invalid-argument",
      "crewOutcome must be one of: " + PRE_START_OUTCOMES.join(", ")
    );
  }
  const note = typeof data.crewOutcomeNote === "string" ?
    data.crewOutcomeNote.trim() :
    "";
  if (outcome !== "go" && !note) {
    throw new HttpsError(
      "invalid-argument",
      "Please add a note explaining the crew result."
    );
  }
  if (note.length > 500) {
    throw new HttpsError(
      "invalid-argument",
      "The crew result note must be 500 characters or fewer."
    );
  }
  return {
    crewOutcome: outcome as PreStartOutcome,
    crewOutcomeNote: note || null,
  };
}

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
 * LEARN -> BRIEF -> WORK (Phase 3): marking a worker `present` also
 * requires that worker to have COMPLETED every ATTENDANCE-GATING
 * `SafetyLearning` item required for this meeting's own
 * `siteId`/`activityIds` — resolved via `resolveAttendanceGatingLearningIds`
 * and `outstandingLearningTitles`, the same helpers
 * `requireForemanLearningComplete` uses for the foreman (see this file's
 * header note, "REQUIRED vs. ATTENDANCE-GATING", for why this is
 * deliberately narrower than the worker's overall required-learning set).
 * A worker with outstanding gating learning may still be marked `absent`,
 * so the attendance record is never structurally stuck — only `present` is
 * gated.
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

  // "Briefed in person": the Foreman covered today's outstanding lesson(s)
  // with the worker face to face, so they may attend. Recorded on the
  // attendance document with the lesson titles; the lessons stay due.
  const briefedInPerson = (request.data ?? {}).briefedInPerson === true;
  let briefedLearningTitles: string[] = [];
  if (statusValue === "present") {
    const outstanding = await outstandingLearningTitles(
      organizationId,
      workerId,
      {
        id: meetingId,
        siteId,
        activityIds: (meeting.activityIds as string[] | undefined) ?? [],
      }
    );
    if (outstanding.length > 0 && !briefedInPerson) {
      throw new HttpsError(
        "failed-precondition",
        "This worker must complete the following safety learning before " +
          "being marked present: " + outstanding.join(", ") +
          ". If you have briefed them on it in person, mark them " +
          "\"Briefed in person\" instead."
      );
    }
    briefedLearningTitles = outstanding;
  }

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
      briefedInPerson: briefedLearningTitles.length > 0,
      briefedLearningTitles,
      recordedAt: FieldValue.serverTimestamp(),
      recordedBy: foremanId,
    });

  return {
    organizationId,
    meetingId,
    workerId,
    status: statusValue,
    briefedInPerson: briefedLearningTitles.length > 0,
  };
});

/**
 * Read-only preview of ATTENDEE safety-learning completion for one meeting
 * — the callable [SAFETY LEARNING GATE] (this file's header note) names as
 * the narrow, audited access path for attendee-level visibility, kept
 * deliberately separate from `firestore.rules`' `worker_learning_records`
 * boundary rather than loosening it.
 *
 * `worker_learning_records` denies read access to `foreman` outright
 * (`firestore.rules`'s own comment: "a Foreman's visibility into their own
 * crew's training is provided elsewhere via the callables, not this
 * rule") — this callable IS that "elsewhere," and it stays narrow on
 * purpose: a foreman calling this can only ever learn the outstanding
 * TITLES of learning required for a meeting THEY THEMSELVES own
 * (`requireOwnMeeting`), for workers who are actually assigned to one of
 * that meeting's own activities (never an arbitrary uid) — never full
 * record contents (no timestamps, no knowledge-check results), and never
 * anyone else's crew.
 *
 * Informational only: this callable and its result never block or gate
 * anything — see `requireForemanLearningComplete` for the actual
 * completion callable, `recordMeetingAttendance`, still enforces the real
 * hard rule (only on the FOREMAN themself). A worker with nothing required
 * of them for this meeting is simply omitted from `outstanding` — present
 * with an empty list, not absent from the result altogether, so the client
 * can distinguish "checked, nothing outstanding" from "not yet resolved."
 */
export const getMeetingAttendeeLearningStatus = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireOwnMeeting(organizationId, meetingId, foremanId);
  const activityIds = (meeting.activityIds as string[] | undefined) ?? [];

  // Only workers actually assigned to one of THIS meeting's own activities
  // — mirrors `_AttendanceSection`'s own client-side roster derivation
  // (`ActivityAssignmentRepository.watchAssignedWorkers` per activity), so
  // this callable can never be used to probe an arbitrary worker's status.
  const db = getFirestore();
  const assignmentSnapshots = await Promise.all(
    activityIds.map((activityId) =>
      db
        .collection(
          `organizations/${organizationId}/activities/${activityId}` +
            "/assignments"
        )
        .get()
    )
  );
  const workerIds = new Set<string>();
  for (const snapshot of assignmentSnapshots) {
    for (const doc of snapshot.docs) {
      const uid = doc.data().uid;
      if (typeof uid === "string" && uid && uid !== foremanId) {
        workerIds.add(uid);
      }
    }
  }

  const hint: MeetingHint = {
    id: meetingId,
    siteId: meeting.siteId as string,
    activityIds,
  };
  const workers = await Promise.all(
    [...workerIds].map(async (workerId) => ({
      workerId,
      outstanding: await outstandingLearningTitles(
        organizationId,
        workerId,
        hint
      ),
    }))
  );

  return {organizationId, meetingId, workers};
});

/**
 * The calling Foreman's OWN outstanding "Needed today" lessons for a
 * meeting they are about to start (no `meetingId`) or are running — exactly
 * what `requireForemanLearningComplete` will check, so the meeting screen
 * can show it before the Foreman taps Start / Complete instead of only
 * after a refusal. Read-only; the start/complete callables remain the
 * authority.
 *
 * The caller must be an active Foreman of `siteId`; `activityIds` are the
 * meeting's (or the proposed meeting's) activities.
 */
export const getMyMeetingLearningGate = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const foremanId = await requireActiveForeman(request, organizationId, siteId);
  const activityIds = optionalStringArray(request, "activityIds") ?? [];
  const rawMeetingId = (request.data ?? {}).meetingId;
  const meetingId = typeof rawMeetingId === "string" && rawMeetingId ?
    rawMeetingId :
    null;

  const outstanding = await outstandingNeededToday(
    organizationId,
    foremanId,
    todaysMeetingDate(),
    {id: meetingId, siteId, activityIds}
  );
  return {
    organizationId,
    outstanding: outstanding.map((lesson) => ({
      learningId: lesson.learningId,
      title: lesson.title,
    })),
  };
});

/**
 * Read-only PRE-MEETING crew readiness for one of the caller's own
 * authorized sites — the Foreman dashboard's view before today's meeting
 * has been started (a meeting document only exists once
 * `createDailySafetyMeeting` runs, so `getMeetingAttendeeLearningStatus`
 * has nothing to resolve from until then).
 *
 * AUTHORIZATION: `requireActiveForeman` — the caller must be an active
 * `foreman` of [organizationId] whose own membership `siteIds` includes the
 * named `siteId`. There is no way to name another foreman's site.
 *
 * SCOPE: the site's own `projectId`, the site itself, and every ACTIVE
 * activity at that site — the same activities the Foreman's meeting-start
 * flow proposes — resolved through `resolveAttendanceGatingLearningIds`,
 * the SAME gating resolver `recordMeetingAttendance` enforces with. The
 * roster is every worker holding an `ActivityAssignment` to one of those
 * activities (never an arbitrary uid), excluding the caller. Only
 * ATTENDANCE-GATING learning is ever reported: other required learning,
 * including `requiredBeforeWork` learning, is never shown as a meeting
 * blocker here.
 *
 * Informational only: it gates nothing, and it deliberately leaves
 * `getMeetingAttendeeLearningStatus` and `recordMeetingAttendance`
 * untouched. Once the meeting starts, the meeting's own (possibly edited)
 * `activityIds` are what count. Unlike `getMeetingAttendeeLearningStatus`,
 * every rostered worker is always returned (with an empty `outstanding`
 * list when ready), so the client can count "Ready" vs "Need attention".
 * All reads happen server-side in one call — no per-worker client reads.
 */
export const getSiteCrewReadiness = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const foremanId = await requireActiveForeman(request, organizationId, siteId);

  const db = getFirestore();
  const siteSnapshot = await db
    .doc(`organizations/${organizationId}/sites/${siteId}`)
    .get();
  const site = siteSnapshot.data();
  if (!siteSnapshot.exists || !site || site.organizationId !== organizationId) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  const projectId = typeof site.projectId === "string" ? site.projectId : null;

  const activitySnapshot = await db
    .collection(`organizations/${organizationId}/activities`)
    .where("siteId", "==", siteId)
    .where("status", "==", "active")
    .get();
  const activities = activitySnapshot.docs.map((doc) => ({
    id: doc.id,
    name: typeof doc.data().name === "string" ? doc.data().name : "",
  }));
  const activityIds = activities.map((activity) => activity.id);

  const assignmentSnapshots = await Promise.all(
    activityIds.map((activityId) =>
      db
        .collection(
          `organizations/${organizationId}/activities/${activityId}` +
            "/assignments"
        )
        .get()
    )
  );
  const workerIds = new Set<string>();
  for (const snapshot of assignmentSnapshots) {
    for (const doc of snapshot.docs) {
      const uid = doc.data().uid;
      if (typeof uid === "string" && uid && uid !== foremanId) {
        workerIds.add(uid);
      }
    }
  }

  const workers = await Promise.all(
    [...workerIds].sort().map(async (workerId) => ({
      workerId,
      // No meeting yet: the site and its active activities stand in for it.
      outstanding: await outstandingLearningTitles(
        organizationId,
        workerId,
        {id: null, siteId, activityIds}
      ),
    }))
  );

  return {organizationId, siteId, projectId, activities, workers};
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
 * Adds a new concern to a meeting, at
 * `daily_safety_meetings/{id}/concerns/{concernId}`.
 *
 * Only the meeting's own foreman may call this (see `requireOwnMeeting`).
 * `organizationId` and `siteId` are always copied from the freshly-fetched
 * meeting document, never accepted from the request, so a concern can never
 * be created for an organization/site other than the one its own meeting
 * belongs to.
 *
 * **DELIBERATE EXCEPTION, same as `addMeetingEvidence`: a concern may still
 * be ADDED to a COMPLETED meeting.** A worker may raise something with the
 * foreman a day after the toolbox talk, or the foreman may simply remember
 * something once back at the office — see this file's header note. Only
 * ADDING is exempted; `updateMeetingConcern`/`removeMeetingConcern` below
 * remain `inProgress`-only, so a concern once logged cannot be edited or
 * retracted after the fact, completed meeting or not.
 */
export const addMeetingConcern = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const description = requireString(request, "description");
  const category = requireConcernCategory(request);

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireOwnMeeting(organizationId, meetingId, foremanId);

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

/**
 * Confirms [meetingPointId] is currently on [meeting]'s own
 * `meetingPointIds` — the discussion note is meaningless (and could
 * otherwise reference a point that was never actually on this meeting, or
 * was already removed) for anything outside that set.
 *
 * @param {FirebaseFirestore.DocumentData} meeting the freshly-fetched
 * meeting document.
 * @param {string} meetingPointId the point id to check.
 * @return {void}
 */
function requireMeetingPointOnMeeting(
  meeting: FirebaseFirestore.DocumentData,
  meetingPointId: string
): void {
  const meetingPointIds: unknown = meeting.meetingPointIds;
  const isOnMeeting =
    Array.isArray(meetingPointIds) && meetingPointIds.includes(meetingPointId);
  if (!isOnMeeting) {
    throw new HttpsError(
      "failed-precondition",
      "That safety meeting point is not on this meeting."
    );
  }
}

/**
 * Sets (creates or overwrites) the discussion note for one meeting point, at
 * `daily_safety_meetings/{id}/point_notes/{meetingPointId}` — a
 * DETERMINISTIC id keyed by the meeting point itself (mirrors
 * `attendance/{workerId}`'s one-record-per-key shape, unlike `concerns`'
 * auto-id subcollection), since a meeting point can only ever have one
 * current note, not many.
 *
 * DISCUSSION CONTEXT vs. CONCERNS: this is deliberately a separate concept
 * from `MeetingConcern` — see this file's header note. A note is plain free
 * text describing what was actually explained/discussed about a covered
 * safety meeting point (e.g. "reminded workers to maintain three points of
 * contact on ladders; team confirmed understanding"), never an issue with a
 * category or status. Optional: a meeting completes with or without notes
 * on any given point, exactly like meeting points themselves are optional
 * beyond the one-activity-one-point completion gate.
 *
 * **DELIBERATE EXCEPTION, same as `addMeetingConcern`/`addMeetingEvidence`:
 * a note may still be SET on a COMPLETED meeting** — a foreman may
 * remember additional context worth recording after the fact. Authorization
 * is `requireOwnMeeting`, not `requireInProgressOwnMeeting`. Only
 * `removeMeetingPointNote` below remains `inProgress`-only.
 */
export const setMeetingPointNote = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const meetingPointId = requireString(request, "meetingPointId");
  const note = requireString(request, "note");

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  const meeting = await requireOwnMeeting(organizationId, meetingId, foremanId);
  requireMeetingPointOnMeeting(meeting, meetingPointId);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
      `/point_notes/${meetingPointId}`
  );
  await ref.set({
    meetingId,
    organizationId,
    siteId: meeting.siteId,
    meetingPointId,
    note,
    recordedBy: foremanId,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {meetingId, meetingPointId, organizationId};
});

/**
 * Removes a meeting point's discussion note from an in-progress meeting.
 * Only the meeting's own foreman may call this. A no-op-shaped success (not
 * a `not-found` error) if no note currently exists for that point — clearing
 * an already-empty note is not an error condition worth surfacing to the
 * caller, matching how the UI offers this as "clear note" rather than a
 * delete-a-specific-record action.
 *
 * Note removal is NOT gated on `requireMeetingPointOnMeeting`: unlike
 * `setMeetingPointNote`, this also runs as a side effect of REMOVING a
 * meeting point from the meeting entirely (see `updateDailySafetyMeeting`'s
 * own doc comment) — at that moment the point is no longer on
 * `meetingPointIds`, so gating removal on membership would make the note
 * un-removable exactly when it needs removing.
 */
export const removeMeetingPointNote = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const meetingPointId = requireString(request, "meetingPointId");

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  await requireInProgressOwnMeeting(organizationId, meetingId, foremanId);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
      `/point_notes/${meetingPointId}`
  );
  await ref.delete();

  return {meetingId, meetingPointId, organizationId};
});

const EVIDENCE_TYPES = [
  "handwrittenNotes",
  "signInSheet",
  "briefingPhoto",
  "document",
  "other",
] as const;
type EvidenceType = (typeof EVIDENCE_TYPES)[number];

/**
 * Validates and returns the `evidenceType` argument, refusing anything
 * outside the fixed set this stage supports. Mirrors
 * `requireConcernCategory`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {EvidenceType} the validated evidence type.
 */
function requireEvidenceType(request: CallableRequest): EvidenceType {
  const value = requireString(request, "evidenceType");
  if (!(EVIDENCE_TYPES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "evidenceType must be one of: " + EVIDENCE_TYPES.join(", ")
    );
  }
  return value as EvidenceType;
}

/**
 * Reads an optional string argument, returning undefined (not written at
 * all) rather than null when absent — used for `description`, which should
 * simply be omitted from the stored document when the caller supplies
 * nothing, not stored as an explicit null.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string | undefined} the trimmed value, or undefined.
 */
function optionalString(
  request: CallableRequest,
  field: string
): string | undefined {
  const value = (request.data ?? {})[field];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${field} must be a string.`);
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Records one piece of evidence's METADATA for a meeting, at
 * `daily_safety_meetings/{id}/evidence/{evidenceId}`. The caller must have
 * already uploaded the actual file to Cloud Storage and supplies the
 * resulting `storagePath`/`downloadUrl` here — see this file's header note
 * on EVIDENCE for the full client-side sequencing and why this callable
 * accepts a completed meeting (unlike every other write callable here).
 *
 * `evidenceId` is CALLER-SUPPLIED (pre-allocated client-side, mirroring
 * `HazardService.allocateHazardId`'s pattern) rather than server-generated
 * — the client must know the id before this call, since it names the
 * Storage upload path that happens first. Refuses if a document already
 * exists at that id (`.create()`, not `.set()`) so a modified client cannot
 * overwrite another piece of evidence's metadata by reusing its id.
 */
export const addMeetingEvidence = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const evidenceId = requireString(request, "evidenceId");
  const storagePath = requireString(request, "storagePath");
  const downloadUrl = requireString(request, "downloadUrl");
  const fileType = requireString(request, "fileType");
  const evidenceType = requireEvidenceType(request);
  const description = optionalString(request, "description");

  const uploaderId = request.auth?.uid;
  if (!uploaderId) throw denied();

  // Deliberately requireOwnMeeting, NOT requireInProgressOwnMeeting — see
  // this file's header note on EVIDENCE for why a completed meeting still
  // accepts new evidence.
  const meeting = await requireOwnMeeting(
    organizationId,
    meetingId,
    uploaderId
  );

  const expectedPathPrefix =
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}/`;
  if (!storagePath.startsWith(expectedPathPrefix)) {
    throw new HttpsError(
      "failed-precondition",
      "storagePath does not belong to this meeting."
    );
  }

  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
      `/evidence/${evidenceId}`
  );

  try {
    await ref.create({
      meetingId,
      organizationId,
      siteId: meeting.siteId,
      evidenceType,
      storagePath,
      downloadUrl,
      fileType,
      ...(description !== undefined ? {description} : {}),
      uploadedBy: uploaderId,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch {
    throw new HttpsError(
      "already-exists",
      "That evidence id has already been used."
    );
  }

  return {id: evidenceId, organizationId, meetingId};
});

/**
 * Removes one piece of evidence's metadata from an IN-PROGRESS meeting.
 * Unlike `addMeetingEvidence`, this is gated on `inProgress` — evidence on
 * a completed meeting may still be added to, but never removed, matching
 * `corrective_actions`' "no delete" rule for a permanent record. See this
 * file's header note on EVIDENCE.
 *
 * This deletes ONLY the Firestore metadata row — the underlying Storage
 * file is left in place (mirrors how removing other records in this
 * codebase never reaches into Storage); an orphaned file with no matching
 * metadata is a low-severity cleanup concern, not a security issue, since
 * nothing reads Storage independently of this metadata.
 */
export const removeMeetingEvidence = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const meetingId = requireString(request, "meetingId");
  const evidenceId = requireString(request, "evidenceId");

  const foremanId = request.auth?.uid;
  if (!foremanId) throw denied();

  await requireInProgressOwnMeeting(organizationId, meetingId, foremanId);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/daily_safety_meetings/${meetingId}` +
      `/evidence/${evidenceId}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That evidence no longer exists.");
  }

  await ref.delete();

  return {id: evidenceId, organizationId, meetingId};
});
