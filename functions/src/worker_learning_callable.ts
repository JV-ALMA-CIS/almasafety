/**
 * Worker learning-progress callables for JVA Safety.
 *
 * This is the FIRST surface in this codebase where an ordinary `worker` role
 * causes a write. It deliberately still goes through Cloud Functions rather
 * than direct client Firestore writes gated by rules-language self-checks:
 * `firestore.rules` denies every client write to
 * `organizations/{orgId}/worker_learning_records/{recordId}` outright, and
 * these three callables are the only path through. That keeps this
 * codebase's "one authorization path per privileged action, checked
 * server-side, records never trusted from the client" philosophy intact —
 * see `firestore.rules`'s header note on not maintaining a second
 * rules-language implementation of an authorization decision.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * The caller is the acting worker, always. `requireActiveWorker` resolves
 * `request.auth.uid` to that user's OWN stored profile and confirms it is
 * `active` and belongs to the named organization. **None of these callables
 * accept a `workerUid` argument.** That absence is the structural guarantee
 * — not a validation rule that could be forgotten — that a worker can never
 * create, advance or complete another worker's record: there is simply no
 * parameter through which to name one.
 *
 * SELF-ASSIGNMENT — WHAT THIS IS AND IS NOT
 *
 * A worker starting or completing learning that an administrator's
 * `SafetyRequirement` already made required is NOT self-assignment. It is
 * completing an obligation somebody else imposed. Self-assignment would be a
 * worker creating or editing a `SafetyRequirement`, or editing its
 * `requiredLearningIds` — and that is structurally unreachable from here:
 * content management lives in `safety_learning_callable.ts` behind
 * `requireOrganizationScopedManager`, which a `worker` role never satisfies.
 * Correspondingly, `startLearning`/`completeLearning` refuse a `learningId`
 * that is not in the caller's CURRENTLY-REQUIRED set, re-derived fresh
 * server-side on every call — a worker cannot conjure an obligation (or a
 * completion credential) for arbitrary content by passing its id.
 *
 * REQUIRED-LEARNING RESOLUTION
 *
 * `resolveRequiredLearning` below re-derives, in TypeScript, the same rule
 * `SafetyRequirementRepository.watchResolvedRequiredLearning` implements in
 * Dart: the de-duplicated union of `requiredLearningIds` across every ACTIVE
 * `SafetyRequirement` that applies to the caller, narrowed to
 * `SafetyLearning` items that exist and are themselves ACTIVE. A requirement
 * applies when it is organization-wide (no `siteId`/`activityId`), or its
 * `siteId`/`activityId` matches one of the caller's own ACTIVE
 * `ActivityAssignment` documents (read fresh via the `assignments`
 * collection-group query, never trusted from the client) — see
 * `workerWorkContext`. The duplication with the Dart resolver is deliberate
 * and matches this codebase's existing per-file convention for validation
 * helpers — the client copy drives display, this copy is the one that
 * decides, and the client's answer is never trusted.
 *
 * MINIMUM ENGAGEMENT TIME GATE
 *
 * See `completeLearning`'s own doc comment for the full mechanism. Summary:
 * ANY learning item (video, document, course, visual guide — not just
 * `type === "video"`) with a positive `SafetyLearning.minimumWatchSeconds`
 * cannot be completed until that many seconds have elapsed server-side
 * since `startLearning`'s own `startedAt` server timestamp — an honest,
 * unforgeable minimum-dwell-time signal. It is explicitly NOT proof of
 * actual watching/reading: this architecture (a direct-URL `video_player`
 * embed or an externally-opened link, no hosting/DRM/analytics service)
 * has no way to verify playback position, scroll position, or reading
 * completion from the server, and no client-reported value of any of
 * those is ever trusted or stored as if it were verified. Elapsed
 * wall-clock time since a genuine server timestamp is the strongest
 * signal this architecture can honestly enforce for any content type.
 *
 * KNOWLEDGE CHECK GRADING
 *
 * This REPLACES the earlier self-attested `knowledgeCheckResult` behavior
 * entirely — the client no longer submits `passed`/`score` at all (see
 * `optionalSelectedAnswers`: that shape has no field for either). It submits
 * only `selectedAnswers: [{questionId, optionId}]`; `gradeKnowledgeCheck`
 * then computes `score`/`totalQuestions`/`passed` SERVER-SIDE, from
 * `fetchStoredQuestions`' own Admin-SDK-only read (which includes
 * `correctOptionId` — a worker-facing read of the same subcollection, via
 * `getKnowledgeCheckQuestions`, strips it first). No client-submitted
 * `passed`/`score`/`percent`/`completedAt` value is ever read or trusted, by
 * construction — there is no such field in the request shape this file
 * parses, not merely a check that ignores one if present.
 *
 * A learning item can carry a knowledge-check gate REGARDLESS of its own
 * `type` — including a `video` item, so a video with both
 * `minimumWatchSeconds` and configured questions requires both to pass (see
 * `completeLearning`'s "GATE 1"/"GATE 2" comments) — see
 * `resolveKnowledgeCheckGate`'s "ZERO QUESTIONS -> NO GATE" doc comment for
 * why an item with no questions configured is never gated at all, keeping
 * every pre-existing `knowledgeCheck`-type item (created before this phase,
 * before any question ever existed for it) completable exactly as before.
 *
 * A FAILED knowledge check is an EXPECTED, not exceptional, outcome:
 * `completeLearning` does not throw when grading concludes `passed: false`
 * — it returns `{status: <unchanged>, knowledgeCheckResult: {passed: false,
 * score, totalQuestions}}` so the UI can show exactly what was missed, and
 * the record stays `inProgress`/`assigned` so the worker may resubmit. There
 * is deliberately no retry limit, certificate, or analytics event anywhere
 * in this phase.
 */

import {FieldValue, getFirestore, Timestamp} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {neededToday, neededTomorrow} from "./daily_learning_plan";
import {isAppRole} from "./account_approval";

/**
 * The AUTHORITATIVE, server-computed outcome of a worker's knowledge-check
 * submission — see `gradeKnowledgeCheck`. `passed`/`score`/`totalQuestions`
 * are never accepted from the client; this shape is only ever produced by
 * grading here and then stored/returned as-is. `totalQuestions` is absent
 * on records written before this field existed — see
 * `KnowledgeCheckResult.fromMap`'s Dart-side backward-compatibility note.
 */
type KnowledgeCheckResult = {
  passed: boolean;
  score: number;
  totalQuestions: number;
};

/** One selectable option on a knowledge-check question — mirrors
 * `safety_learning_callable.ts`'s own copy; duplicated per this codebase's
 * existing per-file convention. */
interface KnowledgeCheckOption {
  id: string;
  text: string;
}

/**
 * A worker-safe view of one knowledge-check question — `correctOptionId` is
 * deliberately absent from this type entirely (not just omitted from an
 * object at runtime): there is no field here to accidentally serialize.
 * Returned by `getKnowledgeCheckQuestions`.
 */
interface WorkerFacingQuestion {
  id: string;
  prompt: string;
  options: KnowledgeCheckOption[];
  order: number;
}

/** One authoritative question, as stored — includes `correctOptionId`.
 * Never leaves this file's own grading logic. */
interface StoredQuestion {
  id: string;
  prompt: string;
  options: KnowledgeCheckOption[];
  correctOptionId: string;
  order: number;
}

/** The client's submission for one question: which option they picked. */
interface SubmittedAnswer {
  questionId: string;
  optionId: string;
}

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `site_assignment_callable.ts`.
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
 * per-file per this codebase's existing convention — see
 * `activity_callable.ts`'s copy for why.
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
 * Authorizes the caller as an active user of [organizationId] acting on
 * their OWN behalf, and returns their uid.
 *
 * The returned uid is the ONLY worker identity any callable in this file
 * ever writes against — see this file's header note on why no `workerUid`
 * argument exists.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<string>} the authorized caller's own uid.
 */
async function requireActiveWorker(
  request: CallableRequest,
  organizationId: string
): Promise<string> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();
  // Cross-organization isolation: a worker acts only within an organization
  // they hold an ACTIVE membership in, checked against their own membership
  // subcollection rather than a scalar profile field — a worker may belong
  // to more than one organization. A System Administrator belongs to no
  // organization and has no learning obligations of their own, so they are
  // not special-cased in.
  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) throw denied();
  if (membership.status !== "active") throw denied();

  return uid;
}

/**
 * The deterministic document id for one worker's record of one learning
 * item — mirrors `FirestorePaths.workerLearningRecordId` in the Flutter
 * source. Deterministic (not an auto-id) so "create if absent" is
 * idempotent without a pre-query, and so at most one record can ever exist
 * per worker+learning pair.
 *
 * @param {string} workerUid the worker's uid.
 * @param {string} learningId the learning item's id.
 * @return {string} the composite document id.
 */
function recordId(workerUid: string, learningId: string): string {
  return `${workerUid}_${learningId}`;
}

/**
 * The caller's own actual work context: every site and activity they hold
 * an assignment for, within [organizationId]. Read fresh via the
 * `assignments` collection-group query — the same query
 * `ActivityAssignmentRepository.watchAssignmentsForWorker` uses client-side
 * — so a worker's set of applicable site/activity-scoped requirements can
 * never be inflated by a client-supplied claim.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {string} workerUid the worker whose context to resolve.
 * @return {Promise<{siteIds: Set<string>, activityIds: Set<string>,
 * projectIds: Set<string>}>} the worker's assigned site, activity and
 * (denormalized) project ids.
 */
async function workerWorkContext(
  organizationId: string,
  workerUid: string
): Promise<
  {siteIds: Set<string>; activityIds: Set<string>; projectIds: Set<string>}
  > {
  return scopeOfAssignments(
    await workerAssignments(organizationId, workerUid)
  );
}

/** One of a worker's own `ActivityAssignment` documents, as read here. */
export interface WorkerAssignment {
  siteId: string | null;
  activityId: string | null;
  projectId: string | null;
}

/**
 * Every `ActivityAssignment` [workerUid] holds within [organizationId] —
 * the raw rows behind `workerWorkContext`, kept per-assignment so
 * `getMyTodaysSafetyReadiness` can narrow them to one site.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {string} workerUid the worker whose assignments to read.
 * @return {Promise<WorkerAssignment[]>} the worker's assignments.
 */
export async function workerAssignments(
  organizationId: string,
  workerUid: string
): Promise<WorkerAssignment[]> {
  const assignments = await getFirestore()
    .collectionGroup("assignments")
    .where("organizationId", "==", organizationId)
    .where("uid", "==", workerUid)
    .get();

  return assignments.docs.map((doc) => {
    const data = doc.data();
    return {
      siteId: nonEmptyStringOrNull(data.siteId),
      activityId: nonEmptyStringOrNull(data.activityId),
      projectId: nonEmptyStringOrNull(data.projectId),
    };
  });
}

/**
 * The site/activity/project id sets covered by [assignments].
 *
 * @param {WorkerAssignment[]} assignments the assignments to summarize.
 * @return {{siteIds: Set<string>, activityIds: Set<string>,
 * projectIds: Set<string>}} the covered ids.
 */
export function scopeOfAssignments(assignments: WorkerAssignment[]): {
  siteIds: Set<string>;
  activityIds: Set<string>;
  projectIds: Set<string>;
} {
  const siteIds = new Set<string>();
  const activityIds = new Set<string>();
  const projectIds = new Set<string>();
  for (const assignment of assignments) {
    if (assignment.siteId !== null) siteIds.add(assignment.siteId);
    if (assignment.activityId !== null) {
      activityIds.add(assignment.activityId);
    }
    if (assignment.projectId !== null) projectIds.add(assignment.projectId);
  }
  return {siteIds, activityIds, projectIds};
}

/**
 * [value] when it is a non-empty string, otherwise null.
 *
 * @param {unknown} value the raw stored value.
 * @return {string | null} the string, or null.
 */
function nonEmptyStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}

/**
 * Re-derives the currently-required learning for a given site/activity
 * scope within [organizationId], server-side — the shared core of both
 * `resolveRequiredLearning` (a worker's own assignment-derived scope) and
 * `resolveRequiredLearningForMeeting` in `daily_safety_meeting_callable.ts`
 * (a Daily Safety Meeting's own `siteId`/`activityIds`, since a Foreman
 * holds no `ActivityAssignment` of their own — that mechanism is
 * `worker`-role only, see `activity_assignment_callable.ts`'s
 * `requireWorkerEligible`). Exported so both call sites resolve requirement
 * applicability with the exact same rule, never a re-implemented copy.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {object} scope the project, site and activity ids a requirement's
 * own `projectId`/`siteId`/`activityId` is matched against — see
 * `SafetyRequirement`'s doc comment for the applicability rule
 * (organization-wide, or a match on exactly one of the three sets).
 * `scope.projectIds` defaults to an empty set for callers that don't
 * resolve a project scope (e.g. the Daily Safety Meeting gate, whose
 * meeting doc does carry a `projectId` and should normally pass it).
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} required,
 * ACTIVE learning items by id.
 */
export async function resolveRequiredLearningForScope(
  organizationId: string,
  scope: {
    siteIds: Set<string>;
    activityIds: Set<string>;
    projectIds?: Set<string>;
  }
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  const {requiredIds} = await resolveApplicableRequirementLearningIds(
    organizationId,
    scope
  );
  return resolveLearningItemsById(organizationId, requiredIds);
}

/**
 * A site/activity/project scope a `SafetyRequirement` is matched against —
 * see `resolveRequiredLearningForScope`'s doc comment.
 */
export interface LearningScope {
  siteIds: Set<string>;
  activityIds: Set<string>;
  projectIds?: Set<string>;
}

/**
 * The per-learning-id classification produced by
 * `resolveApplicableRequirementLearningIds`.
 */
export interface ApplicableLearningIds {
  requiredIds: Set<string>;
  gatingIds: Set<string>;
  preWorkIds: Set<string>;
}

/**
 * Whether one `SafetyRequirement` document applies to [scope]: it is
 * organization-wide (no `projectId`/`siteId`/`activityId`), or its own
 * project, site or activity is in the matching set. The single source of
 * this rule — `resolveApplicableRequirementLearningIds` below and
 * `pre_start_check_callable.ts` both call it.
 *
 * @param {FirebaseFirestore.DocumentData} data the requirement document.
 * @param {LearningScope} scope the project/site/activity ids to match.
 * @return {boolean} whether the requirement applies.
 */
export function requirementApplies(
  data: FirebaseFirestore.DocumentData,
  scope: LearningScope
): boolean {
  const projectId =
    typeof data.projectId === "string" ? data.projectId : null;
  const siteId = typeof data.siteId === "string" ? data.siteId : null;
  const activityId =
    typeof data.activityId === "string" ? data.activityId : null;
  const projectIds = scope.projectIds ?? new Set<string>();

  return (projectId === null && siteId === null && activityId === null) ||
    (projectId !== null && projectIds.has(projectId)) ||
    (siteId !== null && scope.siteIds.has(siteId)) ||
    (activityId !== null && scope.activityIds.has(activityId));
}

/**
 * The requirement-level core shared by `resolveRequiredLearningForScope`
 * (the full "required" set — every applicable learning id, no matter which
 * requirement contributed it) and `resolveAttendanceGatingLearningIds`
 * below (the narrower "gates attendance" subset).
 *
 * A learning id can be contributed by MORE THAN ONE applicable requirement
 * — e.g. `L2` required by both a gating and a non-gating requirement. This
 * function is what makes that overlap resolvable correctly: it tracks, per
 * learning id, whether AT LEAST ONE contributing requirement gates
 * attendance, rather than filtering the flat union after the fact (which
 * would lose exactly the information needed to decide `L2` correctly — see
 * `SafetyRequirement.gatesAttendance`'s own doc comment for the worked
 * example this guards against).
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {object} scope see `resolveRequiredLearningForScope`'s own
 * doc comment.
 * The same per-learning-id tracking applies to `preWorkIds`: a learning id
 * is pre-work when AT LEAST ONE contributing requirement has
 * `requiredBeforeWork === true`, regardless of any other requirement that
 * also lists it.
 *
 * @return {Promise<ApplicableLearningIds>} `requiredIds` is every
 * applicable learning id (any requirement); `gatingIds` is the subset
 * contributed by at least one requirement whose own `gatesAttendance` is
 * `true` (or unset — see `SafetyRequirement.gatesAttendance`'s
 * backward-compatibility default); `preWorkIds` is the subset contributed
 * by at least one requirement whose own `requiredBeforeWork` is `true`
 * (unset means `false`). Both are always subsets of `requiredIds`, and
 * neither implies the other.
 */
export async function resolveApplicableRequirementLearningIds(
  organizationId: string,
  scope: {
    siteIds: Set<string>;
    activityIds: Set<string>;
    projectIds?: Set<string>;
  }
): Promise<ApplicableLearningIds> {
  const db = getFirestore();
  const projectIds = scope.projectIds ?? new Set<string>();

  const requirements = await db
    .collection(`organizations/${organizationId}/safety_requirements`)
    .where("status", "==", "active")
    .get();

  const requiredIds = new Set<string>();
  const gatingIds = new Set<string>();
  const preWorkIds = new Set<string>();
  for (const doc of requirements.docs) {
    const data = doc.data();
    if (!requirementApplies(data, {...scope, projectIds})) continue;

    for (const lesson of classifyRequirementLessons(data)) {
      requiredIds.add(lesson.id);
      if (lesson.gates) gatingIds.add(lesson.id);
      if (lesson.preWork) preWorkIds.add(lesson.id);
    }
  }
  return {requiredIds, gatingIds, preWorkIds};
}

/** One lesson on a requirement, with its per-lesson classification. */
export interface ClassifiedLesson {
  id: string;
  gates: boolean;
  preWork: boolean;
}

/**
 * Every lesson one `SafetyRequirement` lists, in the requirement's own
 * order, each classified as attendance-gating ("Before meeting") and/or
 * pre-work — the single source of the per-lesson rule, shared by
 * `resolveApplicableRequirementLearningIds` and `daily_learning_plan.ts`.
 *
 * @param {FirebaseFirestore.DocumentData} data the requirement document.
 * @return {ClassifiedLesson[]} its lessons.
 */
export function classifyRequirementLessons(
  data: FirebaseFirestore.DocumentData
): ClassifiedLesson[] {
  // Missing/undefined `gatesAttendance` means `true` — a legacy
  // requirement, written before this field existed, must keep blocking
  // attendance exactly as it did before. See `SafetyRequirement
  // .gatesAttendance`'s doc comment: "no migration required" is only
  // true if this default holds everywhere the field is read, not just
  // at write time.
  const requirementGates = data.gatesAttendance !== false;
  // Missing/undefined `requiredBeforeWork` means `false` — the OPPOSITE
  // default to `gatesAttendance`, deliberately: "required before work" is
  // a new concept, so no legacy requirement silently becomes pre-work
  // learning. Never derived from `gates` (nor vice versa) — the two are
  // independent administrator choices.
  const requirementPreWork = data.requiredBeforeWork === true;

  // PER-LESSON SETTINGS: `learningSettings[learningId]` configures one
  // selected lesson WITHIN this requirement (the requirement->learning
  // relationship, never the global lesson). An entry's own boolean wins;
  // a lesson with no entry — every lesson on a requirement saved before
  // per-lesson settings existed — falls back to the requirement-level
  // flags above, so existing requirements behave exactly as before.
  // Classification happens here, per requirement, BEFORE ids are
  // aggregated, so the any-requirement-wins overlap rule still holds per
  // lesson.
  const rawSettings = data.learningSettings;
  const settings: Record<string, unknown> =
    typeof rawSettings === "object" && rawSettings !== null &&
      !Array.isArray(rawSettings) ?
      rawSettings :
      {};

  const ids = data.requiredLearningIds;
  if (!Array.isArray(ids)) return [];
  const lessons: ClassifiedLesson[] = [];
  for (const rawId of ids) {
    if (typeof rawId !== "string" || !rawId.trim()) continue;
    const id = rawId.trim();
    const entry = settings[rawId] ?? settings[id];
    const setting = typeof entry === "object" && entry !== null ?
      entry as Record<string, unknown> :
      {};
    const gates = typeof setting.gatesAttendance === "boolean" ?
      setting.gatesAttendance :
      requirementGates;
    const preWork = typeof setting.requiredBeforeWork === "boolean" ?
      setting.requiredBeforeWork :
      requirementPreWork;
    lessons.push({id, gates, preWork});
  }
  return lessons;
}

/**
 * Resolves [ids] to their ACTIVE `SafetyLearning` documents — the shared
 * tail of both `resolveRequiredLearningForScope` and
 * `resolveAttendanceGatingLearningIds`, so an inactive/deleted learning
 * item is excluded identically either way.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {Set<string>} ids the learning ids to look up.
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} the
 * ACTIVE items among [ids], by id.
 */
export async function resolveLearningItemsById(
  organizationId: string,
  ids: Set<string>
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  if (ids.size === 0) return new Map();

  const db = getFirestore();
  const snapshots = await Promise.all(
    [...ids].map((id) =>
      db.doc(`organizations/${organizationId}/safety_learning/${id}`).get()
    )
  );

  const resolved = new Map<string, FirebaseFirestore.DocumentData>();
  for (const snapshot of snapshots) {
    const data = snapshot.data();
    // An inactive (or deleted) learning item drives no obligation, even if a
    // requirement still lists its id.
    if (!snapshot.exists || !data) continue;
    if (data.status !== "active") continue;
    resolved.set(snapshot.id, data);
  }
  return resolved;
}

/**
 * Re-derives the ATTENDANCE-GATING subset of required learning for a given
 * scope: only learning ids contributed by at least one ACTIVE
 * `SafetyRequirement` whose own `gatesAttendance` is `true` (or unset,
 * defaulting to `true`) — see `SafetyRequirement.gatesAttendance`'s doc
 * comment for the product rule this implements ("required learning" is
 * broader than "learning that blocks Daily Safety Meeting attendance").
 *
 * Used by the Daily Safety Meeting gates
 * (`requireForemanLearningComplete`, `recordMeetingAttendance`'s
 * present-check) INSTEAD OF `resolveRequiredLearningForScope` — every
 * other caller (`getMyRequiredLearning`, `startLearning`, `completeLearning`,
 * the compliance/worker-learning views) keeps using the full, unfiltered
 * resolver: `gatesAttendance` narrows what blocks a meeting, it does not
 * narrow what is required of a worker overall.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {object} scope see `resolveRequiredLearningForScope`'s own doc
 * comment.
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} the
 * ACTIVE, attendance-gating learning items, by id.
 */
export async function resolveAttendanceGatingLearningIds(
  organizationId: string,
  scope: {
    siteIds: Set<string>;
    activityIds: Set<string>;
    projectIds?: Set<string>;
  }
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  const {gatingIds} = await resolveApplicableRequirementLearningIds(
    organizationId,
    scope
  );
  return resolveLearningItemsById(organizationId, gatingIds);
}

/**
 * Re-derives the PRE-WORK subset of required learning for a given scope:
 * only learning ids contributed by at least one ACTIVE `SafetyRequirement`
 * whose own `requiredBeforeWork` is `true` (unset defaults to `false`) —
 * "complete this before performing the applicable activity." See
 * `SafetyRequirement.requiredBeforeWork`'s doc comment.
 *
 * Deliberately NOT an attendance gate: nothing in
 * `daily_safety_meeting_callable.ts` calls this. It drives only the
 * worker-facing "Today's Safety Readiness" view
 * (`getMyTodaysSafetyReadiness`). A learning item blocks attendance only
 * via `resolveAttendanceGatingLearningIds`, whatever its pre-work status.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {LearningScope} scope see `resolveRequiredLearningForScope`'s own
 * doc comment.
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} the
 * ACTIVE, pre-work learning items, by id.
 */
export async function resolvePreWorkLearningIds(
  organizationId: string,
  scope: LearningScope
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  const {preWorkIds} = await resolveApplicableRequirementLearningIds(
    organizationId,
    scope
  );
  return resolveLearningItemsById(organizationId, preWorkIds);
}

/**
 * Re-derives the caller's currently-required learning within
 * [organizationId], server-side, from the caller's OWN scope — see
 * `learnerScope`. See this file's header note for the rule and for why
 * this duplicates the Dart resolver rather than trusting it.
 *
 * @param {string} organizationId the organization to resolve within.
 * @param {string} workerUid the worker whose required learning to resolve.
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} required,
 * ACTIVE learning items by id.
 */
async function resolveRequiredLearning(
  organizationId: string,
  workerUid: string
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  return resolveRequiredLearningForScope(
    organizationId,
    await learnerScope(organizationId, workerUid)
  );
}

/** The caller's own membership fields this file needs. */
interface LearnerMembership {
  role: string | null;
  siteIds: string[];
}

/**
 * Reads [uid]'s own membership of [organizationId]. `requireActiveWorker`
 * has already confirmed it exists and is active by the time this runs.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the caller.
 * @return {Promise<LearnerMembership>} the role and membership sites.
 */
export async function readMembership(
  organizationId: string,
  uid: string
): Promise<LearnerMembership> {
  const data = (
    await getFirestore().doc(`users/${uid}/memberships/${organizationId}`).get()
  ).data();
  const rawSiteIds: unknown = data?.siteIds;
  return {
    role: typeof data?.role === "string" ? data.role : null,
    siteIds: Array.isArray(rawSiteIds) ?
      rawSiteIds.filter(
        (id: unknown): id is string => typeof id === "string" && id.length > 0
      ) :
      [],
  };
}

/**
 * A FOREMAN's learning scope: every site in their own membership `siteIds`,
 * each site's project, and every ACTIVE activity at those sites.
 *
 * WHY: a Foreman never holds an `ActivityAssignment` (that mechanism is
 * worker-only — see `activity_assignment_callable.ts`'s
 * `requireWorkerEligible`), yet `createDailySafetyMeeting` refuses to let
 * them start a meeting until they complete the attendance-gating learning
 * for the site and its activities. Resolving a Foreman's required set from
 * assignments alone therefore made that learning invisible to them AND
 * refused by `startLearning`/`completeLearning` ("not currently required of
 * you") — a Foreman could be blocked by learning they had no way to do.
 * Their operational scope is the site(s) they lead, so that is what their
 * learning resolves from. Workers are unaffected.
 *
 * @param {string} organizationId the organization.
 * @param {string[]} siteIds the Foreman's own membership sites.
 * @return {Promise<{siteIds: Set<string>, activityIds: Set<string>,
 * projectIds: Set<string>}>} the Foreman's scope.
 */
export async function foremanSiteScope(
  organizationId: string,
  siteIds: string[]
): Promise<{
  siteIds: Set<string>;
  activityIds: Set<string>;
  projectIds: Set<string>;
}> {
  const db = getFirestore();
  const siteSnapshots = await Promise.all(
    siteIds.map((id) =>
      db.doc(`organizations/${organizationId}/sites/${id}`).get()
    )
  );
  const validSiteIds: string[] = [];
  const projectIds = new Set<string>();
  for (const snapshot of siteSnapshots) {
    const site = snapshot.data();
    if (!snapshot.exists || !site || site.organizationId !== organizationId) {
      continue;
    }
    validSiteIds.push(snapshot.id);
    if (typeof site.projectId === "string" && site.projectId) {
      projectIds.add(site.projectId);
    }
  }

  const activityIds = new Set<string>();
  for (let i = 0; i < validSiteIds.length; i += 30) {
    const snapshot = await db
      .collection(`organizations/${organizationId}/activities`)
      .where("siteId", "in", validSiteIds.slice(i, i + 30))
      .where("status", "==", "active")
      .get();
    for (const doc of snapshot.docs) activityIds.add(doc.id);
  }
  return {siteIds: new Set(validSiteIds), activityIds, projectIds};
}

/**
 * The union of two scopes.
 *
 * @param {object} a one scope.
 * @param {object} b another scope.
 * @return {object} a scope covering both.
 */
function mergeScopes(
  a: {siteIds: Set<string>; activityIds: Set<string>; projectIds: Set<string>},
  b: {siteIds: Set<string>; activityIds: Set<string>; projectIds: Set<string>}
): {siteIds: Set<string>; activityIds: Set<string>; projectIds: Set<string>} {
  return {
    siteIds: new Set([...a.siteIds, ...b.siteIds]),
    activityIds: new Set([...a.activityIds, ...b.activityIds]),
    projectIds: new Set([...a.projectIds, ...b.projectIds]),
  };
}

/**
 * The scope the caller's own required learning resolves from: their own
 * `ActivityAssignment`s, plus — for a `foreman` only — the sites they lead
 * (`foremanSiteScope`). A `worker`'s scope is exactly what it always was.
 *
 * @param {string} organizationId the organization.
 * @param {string} uid the caller.
 * @return {Promise<object>} the caller's learning scope.
 */
async function learnerScope(
  organizationId: string,
  uid: string
): Promise<{
  siteIds: Set<string>;
  activityIds: Set<string>;
  projectIds: Set<string>;
}> {
  const [context, membership] = await Promise.all([
    workerWorkContext(organizationId, uid),
    readMembership(organizationId, uid),
  ]);
  if (membership.role !== "foreman") return context;
  return mergeScopes(
    context,
    await foremanSiteScope(organizationId, membership.siteIds)
  );
}

/**
 * Reads and validates the optional `selectedAnswers` argument: an array of
 * `{questionId, optionId}` pairs — the ONLY knowledge-check input this
 * codebase ever accepts from a client. There is deliberately no `passed`,
 * `score`, `percent` or `completedAt` field anywhere in this shape — see
 * this file's header note ("KNOWLEDGE CHECK GRADING") for why accepting any
 * of those would reopen the exact self-attestation hole this phase closes.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {SubmittedAnswer[] | null} the validated answers, or null when
 * absent.
 */
function optionalSelectedAnswers(
  request: CallableRequest
): SubmittedAnswer[] | null {
  const value = (request.data ?? {}).selectedAnswers;
  if (value === undefined) return null;
  if (!Array.isArray(value)) {
    throw new HttpsError(
      "invalid-argument",
      "selectedAnswers must be an array."
    );
  }
  return value.map((raw, index) => {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new HttpsError(
        "invalid-argument",
        `selectedAnswers[${index}] must be an object.`
      );
    }
    const record = raw as Record<string, unknown>;
    const questionId = record.questionId;
    const optionId = record.optionId;
    if (typeof questionId !== "string" || !questionId.trim()) {
      throw new HttpsError(
        "invalid-argument",
        `selectedAnswers[${index}].questionId is required.`
      );
    }
    if (typeof optionId !== "string" || !optionId.trim()) {
      throw new HttpsError(
        "invalid-argument",
        `selectedAnswers[${index}].optionId is required.`
      );
    }
    return {questionId: questionId.trim(), optionId: optionId.trim()};
  });
}

/**
 * Fetches every knowledge-check question configured for `learningId`,
 * ordered by `order` — the single Admin-SDK read both
 * `getKnowledgeCheckQuestions` (worker-safe) and `gradeKnowledgeCheck`
 * (authoritative) build on, so there is exactly one place that reads this
 * subcollection, never two implementations that could drift.
 *
 * @param {string} organizationId the organization the item belongs to.
 * @param {string} learningId the learning item's id.
 * @return {Promise<StoredQuestion[]>} every question, including
 * `correctOptionId` — callers that expose this to a worker MUST strip it.
 */
async function fetchStoredQuestions(
  organizationId: string,
  learningId: string
): Promise<StoredQuestion[]> {
  const snapshot = await getFirestore()
    .collection(
      `organizations/${organizationId}/safety_learning/${learningId}` +
        "/knowledge_check_questions"
    )
    .orderBy("order")
    .get();
  return snapshot.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      prompt: typeof data.prompt === "string" ? data.prompt : "",
      options: Array.isArray(data.options) ? data.options : [],
      correctOptionId: typeof data.correctOptionId === "string" ?
        data.correctOptionId :
        "",
      order: typeof data.order === "number" ? data.order : 0,
    };
  });
}

/**
 * Grades [answers] against [questions] SERVER-SIDE — the sole source of
 * truth for `score`/`passed`. A `questionId` in [answers] that does not
 * match one of [questions] is silently IGNORED, never counted toward
 * either the numerator or the denominator: the denominator is always
 * `questions.length`, the authoritative question count, never derived from
 * what the client happened to submit — so a worker cannot inflate their
 * score by submitting extra, fabricated question ids, nor shrink the
 * denominator by omitting real ones (an omitted real question is simply
 * counted wrong, like any other unanswered/incorrect question).
 *
 * @param {StoredQuestion[]} questions the authoritative questions,
 * including `correctOptionId`.
 * @param {SubmittedAnswer[]} answers the worker's submission.
 * @param {number} passingScorePercent the configured passing threshold.
 * @return {KnowledgeCheckResult} the authoritative, server-computed result.
 */
function gradeKnowledgeCheck(
  questions: StoredQuestion[],
  answers: SubmittedAnswer[],
  passingScorePercent: number
): KnowledgeCheckResult {
  const selectedByQuestionId = new Map<string, string>();
  for (const answer of answers) {
    // First submission for a given questionId wins; a duplicate is not an
    // attempt to inflate anything (there is only one correctOptionId to
    // match regardless), so no special-case rejection is needed.
    if (!selectedByQuestionId.has(answer.questionId)) {
      selectedByQuestionId.set(answer.questionId, answer.optionId);
    }
  }

  let correct = 0;
  for (const question of questions) {
    if (selectedByQuestionId.get(question.id) === question.correctOptionId) {
      correct += 1;
    }
  }

  const totalQuestions = questions.length;
  const percent = totalQuestions === 0 ? 100 : (correct / totalQuestions) * 100;
  return {
    passed: percent >= passingScorePercent,
    score: correct,
    totalQuestions,
  };
}

/**
 * Resolves whether `learningId` has an active knowledge-check gate at all,
 * and grades [answers] against it if so.
 *
 * "ZERO QUESTIONS -> NO GATE": a `knowledgeCheck`-type item with no
 * questions configured behaves exactly like any other learning item —
 * `completeLearning` completes it without requiring a submission. This
 * matches the video gate's own "nothing configured, nothing enforced" rule
 * (`minimumWatchSeconds` unset/zero) and keeps every EXISTING
 * `knowledgeCheck` item (created before this phase, with no questions
 * subcollection at all) completable exactly as before, rather than
 * suddenly becoming permanently stuck.
 *
 * @param {string} organizationId the organization the item belongs to.
 * @param {string} learningId the required-learning item's own id.
 * @param {FirebaseFirestore.DocumentData} learning the required-learning
 * item's own stored data (from `resolveRequiredLearning`).
 * @param {SubmittedAnswer[] | null} answers the worker's submission, if any.
 * @return {Promise<KnowledgeCheckResult | null>} the graded result, or null
 * when there is no gate to grade (zero questions configured).
 */
async function resolveKnowledgeCheckGate(
  organizationId: string,
  learningId: string,
  learning: FirebaseFirestore.DocumentData,
  answers: SubmittedAnswer[] | null
): Promise<KnowledgeCheckResult | null> {
  const questions = await fetchStoredQuestions(organizationId, learningId);
  if (questions.length === 0) return null;

  if (answers === null) {
    throw new HttpsError(
      "invalid-argument",
      "This learning item has a knowledge check — selectedAnswers is " +
        "required."
    );
  }

  const passingScorePercent =
    typeof learning.passingScorePercent === "number" ?
      learning.passingScorePercent :
      100;
  return gradeKnowledgeCheck(questions, answers, passingScorePercent);
}

/**
 * Resolves the CALLER'S OWN required learning within their organization and
 * lazily materializes an `assigned` record for each required item that has
 * no record yet.
 *
 * Materializing real documents (rather than resolving requirements at read
 * time on every view) is the point of this callable: afterwards, both the
 * worker's own `watchMine()` and an administrator's
 * `watchForOrganization()` are plain Firestore queries over real documents,
 * not runtime resolution logic re-run per viewer.
 *
 * Idempotent: an existing record is never overwritten, so a worker calling
 * this repeatedly cannot reset their own `inProgress`/`completed` progress
 * back to `assigned`.
 */
export const getMyRequiredLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);

  const required = await resolveRequiredLearning(organizationId, workerUid);
  if (required.size === 0) return {organizationId, assigned: 0, total: 0};

  const db = getFirestore();
  const collection = db.collection(
    `organizations/${organizationId}/worker_learning_records`
  );

  const learningIds = [...required.keys()];
  const existing = await Promise.all(
    learningIds.map((id) => collection.doc(recordId(workerUid, id)).get())
  );

  const batch = db.batch();
  let created = 0;
  existing.forEach((snapshot, index) => {
    if (snapshot.exists) return;
    batch.set(collection.doc(snapshot.id), {
      workerUid,
      organizationId,
      learningId: learningIds[index],
      status: "assigned",
      assignedAt: FieldValue.serverTimestamp(),
    });
    created += 1;
  });
  if (created > 0) await batch.commit();

  return {organizationId, assigned: created, total: learningIds.length};
});

/**
 * Advances the CALLER'S OWN record for `learningId` to `inProgress`.
 *
 * The learning item must exist, be ACTIVE, and be in the caller's
 * currently-required set — all re-derived server-side, never trusted from
 * the request. Already-completed learning is refused rather than silently
 * reopened.
 */
export const startLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);
  const learningId = requireString(request, "learningId");

  const required = await resolveRequiredLearning(organizationId, workerUid);
  if (!required.has(learningId)) {
    throw new HttpsError(
      "failed-precondition",
      "That learning item is not currently required of you."
    );
  }

  const ref = getFirestore().doc(
    `organizations/${organizationId}/worker_learning_records/` +
      recordId(workerUid, learningId)
  );
  const snapshot = await ref.get();
  if (snapshot.exists && snapshot.data()?.status === "completed") {
    throw new HttpsError(
      "failed-precondition",
      "You have already completed that learning item."
    );
  }

  await ref.set(
    {
      workerUid,
      organizationId,
      learningId,
      status: "inProgress",
      ...(snapshot.exists ? {} : {assignedAt: FieldValue.serverTimestamp()}),
      startedAt: FieldValue.serverTimestamp(),
    },
    {merge: true}
  );

  return {organizationId, learningId, status: "inProgress"};
});

/**
 * Completes the CALLER'S OWN record for `learningId`.
 *
 * The record must already exist and be `assigned` or `inProgress` — a
 * worker cannot fabricate a completion for something never assigned to
 * them, because the required-set check above and the record-exists check
 * here both stand between them and a `completed` document. When the
 * learning item's type is `knowledgeCheck`, a `knowledgeCheckResult` is
 * required; the server validates its shape and stores it, and does not
 * grade it (see `optionalKnowledgeCheckResult`).
 *
 * MINIMUM ENGAGEMENT TIME GATE
 *
 * When the item has a positive `minimumWatchSeconds` — of ANY type, not
 * just `video` — this refuses completion unless at least that many seconds
 * have elapsed, SERVER-SIDE, between `current.startedAt` (a real
 * `FieldValue.serverTimestamp()` written by `startLearning`, entirely
 * outside the caller's control) and now. This is deliberately NOT a
 * watch-position/percentage or reading-progress check: nothing in this
 * architecture (a direct-URL `video_player` embed or an externally-opened
 * content link, no hosting/DRM/analytics service) gives the server any way
 * to independently confirm actual playback or reading, so treating a
 * client-reported position or percentage as proof would be fake security
 * — see `SafetyLearning.minimumWatchSeconds`'s doc comment. Elapsed
 * wall-clock time since a genuine server timestamp is the strongest signal
 * this architecture can honestly enforce: it cannot be satisfied by tapping
 * Complete immediately, and it cannot be forged by a modified client, since
 * `startedAt` was never client-supplied in the first place. A record with
 * no `startedAt` at all (still `assigned` — `startLearning` was never
 * called) is refused outright, since there is then no timestamp to measure
 * elapsed time from.
 */
export const completeLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);
  const learningId = requireString(request, "learningId");
  const selectedAnswers = optionalSelectedAnswers(request);

  const required = await resolveRequiredLearning(organizationId, workerUid);
  const learning = required.get(learningId);
  if (!learning) {
    throw new HttpsError(
      "failed-precondition",
      "That learning item is not currently required of you."
    );
  }

  const ref = getFirestore().doc(
    `organizations/${organizationId}/worker_learning_records/` +
      recordId(workerUid, learningId)
  );
  const snapshot = await ref.get();
  const current = snapshot.data();
  if (!snapshot.exists || !current) {
    throw new HttpsError(
      "failed-precondition",
      "That learning item has not been assigned to you yet."
    );
  }
  if (current.status !== "assigned" && current.status !== "inProgress") {
    throw new HttpsError(
      "failed-precondition",
      "That learning item cannot be completed from its current state."
    );
  }

  // GATE 1: minimum engagement time — see this file's header note. Applies
  // to ANY learning type (not just `video`) with a positive
  // `minimumWatchSeconds` configured, since the same honest "elapsed
  // server time since startLearning" signal is equally the strongest thing
  // this architecture can verify for a document/course/guide as for a
  // video — there is no type-specific reading/viewing proof available for
  // any of them. Runs independently of and before the knowledge-check gate
  // below: an item with BOTH a `minimumWatchSeconds` and configured
  // questions must satisfy both, and this ordering means a worker who
  // hasn't waited long enough never even reaches grading.
  const minimumWatchSeconds = learning.minimumWatchSeconds;
  if (
    typeof minimumWatchSeconds === "number" &&
    minimumWatchSeconds > 0
  ) {
    const startedAt = current.startedAt;
    if (!(startedAt instanceof Timestamp)) {
      throw new HttpsError(
        "failed-precondition",
        "You must start this learning item before completing it."
      );
    }
    const elapsedSeconds = (Date.now() - startedAt.toMillis()) / 1000;
    if (elapsedSeconds < minimumWatchSeconds) {
      const remaining = Math.ceil(minimumWatchSeconds - elapsedSeconds);
      throw new HttpsError(
        "failed-precondition",
        `Keep this item open for ${remaining} more ` +
          `second${remaining === 1 ? "" : "s"} before completing it.`
      );
    }
  }

  // GATE 2: knowledge check — applies to ANY learning item (not just
  // `type === "knowledgeCheck"`) that has at least one question configured;
  // see `resolveKnowledgeCheckGate`'s "ZERO QUESTIONS -> NO GATE" doc
  // comment. A video item can carry both gates at once — this is a
  // deliberate, explicit design decision (a knowledge check attached to a
  // video), not the original narrower "type === knowledgeCheck only" model.
  const knowledgeCheckResult = await resolveKnowledgeCheckGate(
    organizationId,
    learningId,
    learning,
    selectedAnswers
  );

  // A FAILED knowledge check is an EXPECTED outcome, not an error: the
  // record stays exactly as it was (still `inProgress`/`assigned`, never
  // silently advanced) and the graded result is returned to the caller so
  // the UI can show what was missed — see this file's header note. The
  // worker may resubmit; there is deliberately no retry limit in this
  // phase.
  if (knowledgeCheckResult !== null && !knowledgeCheckResult.passed) {
    return {
      organizationId,
      learningId,
      status: current.status,
      knowledgeCheckResult,
    };
  }

  await ref.update({
    status: "completed",
    completedAt: FieldValue.serverTimestamp(),
    ...(knowledgeCheckResult !== null ? {knowledgeCheckResult} : {}),
  });

  return {
    organizationId,
    learningId,
    status: "completed",
    ...(knowledgeCheckResult !== null ? {knowledgeCheckResult} : {}),
  };
});

/**
 * Returns the worker-safe view of `learningId`'s knowledge-check questions
 * — `correctOptionId` is stripped from every question before this response
 * is built (see `WorkerFacingQuestion`'s doc comment: there is no field in
 * that type to accidentally serialize, not merely an omitted one at
 * runtime). The caller must still be the item's own required-learning
 * context — the same `resolveRequiredLearning` check every other callable
 * in this file uses — so a worker cannot probe questions for content
 * unrelated to their own work.
 *
 * Returns an empty `questions` array when none are configured — this is
 * not an error; see `resolveKnowledgeCheckGate`'s "ZERO QUESTIONS -> NO
 * GATE" rule.
 */
export const getKnowledgeCheckQuestions = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);
  const learningId = requireString(request, "learningId");

  const required = await resolveRequiredLearning(organizationId, workerUid);
  if (!required.has(learningId)) {
    throw new HttpsError(
      "failed-precondition",
      "That learning item is not currently required of you."
    );
  }

  const questions = await fetchStoredQuestions(organizationId, learningId);
  const workerFacing: WorkerFacingQuestion[] = questions.map((question) => ({
    id: question.id,
    prompt: question.prompt,
    options: question.options,
    order: question.order,
  }));

  return {organizationId, learningId, questions: workerFacing};
});

/**
 * One incomplete learning item in `getMyTodaysSafetyReadiness`'s response.
 * `canStart` is false for an item that gates today's meeting (resolved from
 * the MEETING's own scope) but is not in the worker's own assignment-derived
 * required set: `startLearning` would refuse it, so the client shows it
 * without a start action rather than offering one that cannot succeed.
 */
interface ReadinessItem {
  learningId: string;
  title: string;
  type: string | null;
  status: "notStarted" | "assigned" | "inProgress";
  canStart: boolean;
}

/** An id/name pair used to label today's scope for the worker. */
interface NamedRef {
  id: string;
  name: string;
}

/**
 * Today's date as `createDailySafetyMeeting` stores it — the server's UTC
 * `YYYY-MM-DD` — so a lookup here always matches the stored `date` field.
 *
 * @return {string} today's date.
 */
export function todaysMeetingDate(): string {
  return new Date().toISOString().slice(0, 10);
}

/**
 * Finds today's Daily Safety Meeting at one of [siteIds], if any. With more
 * than one (a worker at several sites), an `inProgress` meeting is
 * preferred over a completed one, then the most recently started.
 *
 * @param {string} organizationId the organization to search within.
 * @param {string[]} siteIds the worker's own membership sites.
 * @param {string} date today's date, see `todaysMeetingDate`.
 * @param {string | null} foremanId when set, only that Foreman's OWN
 * meeting counts — a Foreman is gated by the meeting they run, not by
 * another Foreman's meeting at a shared site.
 * @return {Promise<FirebaseFirestore.QueryDocumentSnapshot | null>} the
 * meeting, or null when none has been started today.
 */
export async function findTodaysMeeting(
  organizationId: string,
  siteIds: string[],
  date: string,
  foremanId: string | null = null
): Promise<FirebaseFirestore.QueryDocumentSnapshot | null> {
  if (siteIds.length === 0) return null;
  const collection = getFirestore().collection(
    `organizations/${organizationId}/daily_safety_meetings`
  );
  // Firestore `in` queries cap at 30 values.
  const chunks: string[][] = [];
  for (let i = 0; i < siteIds.length; i += 30) {
    chunks.push(siteIds.slice(i, i + 30));
  }
  const snapshots = await Promise.all(
    chunks.map((chunk) =>
      collection.where("siteId", "in", chunk).where("date", "==", date).get()
    )
  );
  const meetings = snapshots
    .flatMap((snapshot) => snapshot.docs)
    .filter((doc) => foremanId === null || doc.data().foremanId === foremanId);
  if (meetings.length === 0) return null;

  const startMillis = (doc: FirebaseFirestore.QueryDocumentSnapshot) => {
    const startTime = doc.data().startTime;
    return startTime instanceof Timestamp ? startTime.toMillis() : 0;
  };
  meetings.sort((a, b) => {
    const aActive = a.data().status === "inProgress" ? 1 : 0;
    const bActive = b.data().status === "inProgress" ? 1 : 0;
    if (aActive !== bActive) return bActive - aActive;
    return startMillis(b) - startMillis(a);
  });
  return meetings[0];
}

/**
 * Resolves [ids] within [collectionName] to `{id, name}` pairs, skipping
 * any that no longer exist. Used only to label today's scope — bounded by
 * the worker's own assignment count.
 *
 * @param {string} organizationId the organization to read within.
 * @param {string} collectionName `projects`, `sites` or `activities`.
 * @param {Iterable<string>} ids the ids to name.
 * @return {Promise<NamedRef[]>} the named references.
 */
export async function namesFor(
  organizationId: string,
  collectionName: "projects" | "sites" | "activities",
  ids: Iterable<string>
): Promise<NamedRef[]> {
  const db = getFirestore();
  const snapshots = await Promise.all(
    [...new Set(ids)].map((id) =>
      db.doc(`organizations/${organizationId}/${collectionName}/${id}`).get()
    )
  );
  const named: NamedRef[] = [];
  for (const snapshot of snapshots) {
    const name = snapshot.data()?.name;
    if (!snapshot.exists) continue;
    named.push({id: snapshot.id, name: typeof name === "string" ? name : ""});
  }
  return named;
}

/**
 * The CALLER'S OWN focused learning view for today — "Today's Safety
 * Readiness" — rather than their full required-learning inventory (which
 * `getMyRequiredLearning`/`MySafetyLearningScreen` continue to cover,
 * unchanged).
 *
 * WHICH SCOPE
 *
 * - When a Daily Safety Meeting has been started today at one of the
 *   caller's own membership sites, "before today's meeting" is resolved
 *   from THAT MEETING's own `projectId`/`siteId`/`activityIds` — exactly the
 *   scope `recordMeetingAttendance` enforces, so this view can never
 *   disagree with the real gate. "Before you work" is resolved from the
 *   caller's own assignments AT THAT MEETING'S SITE.
 * - Before any meeting exists (a meeting document is only created when the
 *   Foreman starts it), both are resolved from the caller's own
 *   `ActivityAssignment`s — `gatingSource: "assignments"` tells the client
 *   this is the expected, not yet meeting-confirmed, gating set.
 * - A FOREMAN resolves from the sites they lead (`learnerScope`), and only
 *   their OWN meeting counts. Before it starts, "before today's meeting" is
 *   the learning `createDailySafetyMeeting` will require of them for their
 *   site's active activities; once started, the meeting's own scope —
 *   exactly what `completeDailySafetyMeeting` re-checks. `role` in the
 *   response tells the client which wording to use.
 *
 * WHICH SECTION (requirement-level, never inferred from records)
 *
 * 1. `beforeMeeting`: incomplete learning contributed by at least one
 *    applicable `gatesAttendance` requirement
 *    (`resolveApplicableRequirementLearningIds`' `gatingIds`).
 * 2. `beforeWork`: incomplete learning contributed by at least one
 *    applicable `requiredBeforeWork` requirement, EXCLUDING anything already
 *    in `beforeMeeting` — an item that is both appears once, in the
 *    higher-priority section.
 * 3. `additional`: the rest of the caller's overall required set.
 *
 * Completed learning never appears — completion is the same persistent
 * `worker_learning_records` `status == "completed"` rule used everywhere
 * else; there is no daily reset.
 *
 * Read-only. Like every callable in this file there is no `workerUid`
 * argument: the caller only ever sees their own readiness.
 */
export const getMyTodaysSafetyReadiness = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);
  const db = getFirestore();

  const membership = await readMembership(organizationId, workerUid);
  const isForeman = membership.role === "foreman";

  const assignments = await workerAssignments(organizationId, workerUid);
  const workerScope = isForeman ?
    mergeScopes(
      scopeOfAssignments(assignments),
      await foremanSiteScope(organizationId, membership.siteIds)
    ) :
    scopeOfAssignments(assignments);

  const date = todaysMeetingDate();
  const meetingDoc = await findTodaysMeeting(
    organizationId,
    membership.siteIds,
    date,
    isForeman ? workerUid : null
  );
  const meeting = meetingDoc?.data() ?? null;

  const overall = await resolveApplicableRequirementLearningIds(
    organizationId,
    workerScope
  );

  let preWorkIds = overall.preWorkIds;
  let todaysScope = workerScope;
  if (meeting) {
    const meetingSiteId = meeting.siteId as string;
    const meetingProjectIds = new Set<string>(
      typeof meeting.projectId === "string" ? [meeting.projectId] : []
    );
    const meetingActivityIds: string[] = Array.isArray(meeting.activityIds) ?
      meeting.activityIds :
      [];

    // A Foreman leads every activity on their meeting; a worker performs
    // only the ones they are assigned to at that site.
    const atMeetingSite = isForeman ?
      {
        activityIds: new Set(meetingActivityIds),
        projectIds: new Set<string>(),
      } :
      scopeOfAssignments(
        assignments.filter((a) => a.siteId === meetingSiteId)
      );
    todaysScope = {
      siteIds: new Set([meetingSiteId]),
      activityIds: atMeetingSite.activityIds,
      projectIds: new Set([
        ...atMeetingSite.projectIds,
        ...meetingProjectIds,
      ]),
    };
    preWorkIds = (
      await resolveApplicableRequirementLearningIds(organizationId, todaysScope)
    ).preWorkIds;
  }

  // "Needed today" — the small daily plan (see `daily_learning_plan.ts`)
  // — replaces "every attendance-gating lesson" as what must be done
  // before the meeting. Gating lessons not in today's plan move to
  // `additional` ("When you can") and are planned on later days.
  const today = await neededToday(organizationId, workerUid, date);
  const neededIds = new Set(today.lessons.map((l) => l.learningId));
  const tomorrowIds = (
    await neededTomorrow(organizationId, workerUid, date)
  ).map((l) => l.learningId);

  const beforeMeetingIds = [...neededIds];
  const beforeWorkIds = [...preWorkIds].filter((id) => !neededIds.has(id));
  const additionalIds = [...overall.requiredIds].filter(
    (id) => !neededIds.has(id) && !preWorkIds.has(id)
  );

  const learningById = await resolveLearningItemsById(
    organizationId,
    new Set([
      ...beforeMeetingIds,
      ...beforeWorkIds,
      ...additionalIds,
      ...tomorrowIds,
    ])
  );
  const activeIds = [...learningById.keys()];
  const records = await Promise.all(
    activeIds.map((id) =>
      db
        .doc(
          `organizations/${organizationId}/worker_learning_records/` +
            recordId(workerUid, id)
        )
        .get()
    )
  );
  const statusById = new Map<string, unknown>();
  records.forEach((snapshot, index) => {
    statusById.set(activeIds[index], snapshot.data()?.status);
  });

  const toItems = (ids: string[]): ReadinessItem[] => {
    const items: ReadinessItem[] = [];
    for (const id of ids) {
      const learning = learningById.get(id);
      if (!learning) continue;
      const status = statusById.get(id);
      if (status === "completed") continue;
      items.push({
        learningId: id,
        title: typeof learning.title === "string" ? learning.title : id,
        type: typeof learning.type === "string" ? learning.type : null,
        status: status === "assigned" || status === "inProgress" ?
          status :
          "notStarted",
        canStart: overall.requiredIds.has(id),
      });
    }
    return items.sort((a, b) => a.title.localeCompare(b.title));
  };

  const [projects, sites, activities] = await Promise.all([
    namesFor(organizationId, "projects", todaysScope.projectIds),
    namesFor(organizationId, "sites", todaysScope.siteIds),
    namesFor(organizationId, "activities", todaysScope.activityIds),
  ]);

  const startTime = meeting?.startTime;
  return {
    organizationId,
    date,
    role: isForeman ? "foreman" : "worker",
    gatingSource: meeting ? "meeting" : "assignments",
    meeting: meetingDoc && meeting ? {
      id: meetingDoc.id,
      status: meeting.status,
      siteId: meeting.siteId,
      projectId: meeting.projectId ?? null,
      startTime: startTime instanceof Timestamp ?
        startTime.toDate().toISOString() :
        null,
    } : null,
    scope: {projects, sites, activities},
    beforeMeeting: toItems(beforeMeetingIds),
    beforeWork: toItems(beforeWorkIds),
    additional: toItems(additionalIds),
    neededTomorrow: toItems(tomorrowIds),
  };
});

/**
 * One worker's learning-progress record, as returned to a reviewer by
 * `getCrewLearningRecords` — the same shape `WorkerLearningRecord.fromMap`
 * parses client-side, with Firestore `Timestamp`s converted to ISO strings
 * (callable results are plain JSON).
 */
interface CrewLearningRecordRow {
  id: string;
  workerUid: string;
  organizationId: string;
  learningId: string;
  status: string;
  completedAt: string | null;
}

/**
 * Authorizes the caller as an active REVIEWER (`admin`/`siteManager`/
 * `foreman`) of [organizationId] and returns their role and — for a
 * `foreman` specifically — their own assigned `siteIds`, which
 * `getCrewLearningRecords` uses to bound which workers' records they may
 * see. `admin`/`siteManager` need no site scope: both already see every
 * site in the organization elsewhere in this codebase (PROJECT_CONTEXT.md
 * §12/§16), matching `SafetyComplianceRepository`'s own Site -> Activity ->
 * Workers authorization shape.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<{role: string, siteIds: string[]}>} the caller's own
 * role and (for a foreman) site scope within [organizationId].
 */
async function requireReviewer(
  request: CallableRequest,
  organizationId: string
): Promise<{role: string; siteIds: string[]}> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const db = getFirestore();
  const profileSnapshot = await db.doc(`users/${uid}`).get();
  const profile = profileSnapshot.data();
  if (!profileSnapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  if (profile.platformRole === "admin") return {role: "admin", siteIds: []};

  const membershipSnapshot = await db
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) throw denied();
  if (membership.status !== "active") throw denied();

  const role = membership.role;
  if (!isAppRole(role) || (role !== "siteManager" && role !== "foreman")) {
    throw denied();
  }

  const siteIds: string[] = Array.isArray(membership.siteIds) ?
    membership.siteIds.filter(
      (id: unknown): id is string => typeof id === "string"
    ) :
    [];
  return {role, siteIds};
}

/**
 * Returns the learning-progress records for [workerUids] within
 * [organizationId] — the completion-status half of
 * `SafetyComplianceRepository.buildSiteCompliance`'s Site -> Activity ->
 * Workers view.
 *
 * WHY THIS EXISTS: `firestore.rules` deliberately does NOT grant a
 * `foreman` direct read access to `worker_learning_records` — that
 * collection's own rule comment says a Foreman's visibility into their
 * crew's training "is provided elsewhere via the callables, not this
 * rule." `SafetyComplianceRepository` previously called
 * `WorkerLearningRepository.watchForOrganization()` directly instead — an
 * unconstrained collection LISTING that `firestore.rules` refuses outright
 * for a `foreman` caller (the rule can only grant `siteManager`/`admin`/
 * "your own record" for that query shape), which surfaced as
 * `permission-denied` the moment a Foreman opened Learning Compliance for
 * any site. This callable is the missing path: Admin SDK, so it bypasses
 * that rule, but re-derives and enforces the SAME scope server-side rather
 * than trusting the client's claim of which workers belong to the
 * caller's crew.
 *
 * SCOPE ENFORCEMENT: `admin`/`siteManager` may request any [workerUids] —
 * both already see every worker in the organization elsewhere. A
 * `foreman` may request ONLY workers whose own membership `siteIds`
 * (checked fresh here, never trusted from the request) intersects the
 * foreman's own `siteIds` — a requested uid that fails this check is
 * silently OMITTED from the response rather than causing the whole call to
 * fail, mirroring `resolveRequiredLearning`'s "never trust the client's
 * claim" posture without turning "you asked about one worker outside your
 * crew" into a hard error for an otherwise-valid batch request.
 */
export const getCrewLearningRecords = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {role, siteIds: reviewerSiteIds} = await requireReviewer(
    request,
    organizationId
  );

  const rawWorkerUids = (request.data ?? {}).workerUids;
  if (!Array.isArray(rawWorkerUids) || rawWorkerUids.length === 0) {
    throw new HttpsError("invalid-argument", "workerUids is required.");
  }
  const requestedUids = [
    ...new Set(
      rawWorkerUids.filter(
        (id): id is string => typeof id === "string" && id.trim().length > 0
      )
    ),
  ];
  if (requestedUids.length === 0) {
    throw new HttpsError("invalid-argument", "workerUids is required.");
  }

  const db = getFirestore();

  // A foreman's request is narrowed to workers who share at least one of
  // the foreman's own sites, re-checked fresh against each worker's OWN
  // membership document — never the request's own claim of who is on the
  // foreman's crew.
  let authorizedUids = requestedUids;
  if (role === "foreman") {
    const reviewerSites = new Set(reviewerSiteIds);
    const memberships = await Promise.all(
      requestedUids.map((uid) =>
        db.doc(`users/${uid}/memberships/${organizationId}`).get()
      )
    );
    authorizedUids = requestedUids.filter((uid, index) => {
      const membership = memberships[index].data();
      if (!memberships[index].exists || !membership) return false;
      const workerSiteIds: unknown = membership.siteIds;
      if (!Array.isArray(workerSiteIds)) return false;
      return workerSiteIds.some(
        (id) => typeof id === "string" && reviewerSites.has(id)
      );
    });
  }

  if (authorizedUids.length === 0) {
    return {organizationId, records: [] as CrewLearningRecordRow[]};
  }

  // Firestore `in` queries cap at 30 values — chunk to stay within that
  // regardless of crew size.
  const chunks: string[][] = [];
  for (let i = 0; i < authorizedUids.length; i += 30) {
    chunks.push(authorizedUids.slice(i, i + 30));
  }

  const collection = db.collection(
    `organizations/${organizationId}/worker_learning_records`
  );
  const snapshots = await Promise.all(
    chunks.map((chunk) =>
      collection.where("workerUid", "in", chunk).get()
    )
  );

  const records: CrewLearningRecordRow[] = [];
  for (const snapshot of snapshots) {
    for (const doc of snapshot.docs) {
      const data = doc.data();
      const workerUid = data.workerUid;
      const learningId = data.learningId;
      const status = data.status;
      if (
        typeof workerUid !== "string" ||
        typeof learningId !== "string" ||
        typeof status !== "string"
      ) {
        continue;
      }
      const completedAt = data.completedAt;
      records.push({
        id: doc.id,
        workerUid,
        organizationId,
        learningId,
        status,
        completedAt:
          completedAt instanceof Timestamp ?
            completedAt.toDate().toISOString() :
            null,
      });
    }
  }

  return {organizationId, records};
});
