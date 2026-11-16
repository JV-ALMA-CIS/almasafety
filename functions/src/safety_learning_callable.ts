/**
 * Safety Learning and Safety Requirement content-management callables for
 * JVA Safety.
 *
 * These are the only path that can create or edit an
 * `organizations/{orgId}/safety_learning/{id}` or
 * `organizations/{orgId}/safety_requirements/{id}` document —
 * `firestore.rules` denies every client write to either collection
 * outright, mirroring `activity_callable.ts`'s treatment of activities.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `createSafetyLearning`/`updateSafetyLearning` and the knowledge-check
 * question callables use `requireLibraryAuthor` (below): an `admin` may
 * author every learning type; a `siteManager` of THIS organization (the
 * existing `requireOrganizationScopedManager` check) may author VIDEO items
 * only — create, edit, activate/deactivate, and their knowledge checks —
 * for the whole organization, not just their own sites, and whoever
 * created the item. Everything else in the Safety Learning LIBRARY
 * (documents, courses, guides, knowledge-check items) stays a platform-
 * level, `admin`-only responsibility (PROJECT_CONTEXT.md §4, §12). The
 * video-only limit is enforced here on every call, against the STORED
 * item's type, never the client's word: a Site Manager can neither create
 * a non-video item, nor edit one, nor turn a video into another type.
 * This is content management, not worker progress — see
 * `worker_learning_callable.ts` for the separate, worker-facing
 * authorization model used by `startLearning`/`completeLearning`.
 *
 * `createSafetyRequirement`/`updateSafetyRequirement` instead use
 * `requireOrganizationScopedManager`: `admin` (any organization) OR
 * `siteManager` of THIS organization — the same authority a Site Manager
 * already has over activities/projects/sites/workforce. Unlike the library
 * itself, a safety REQUIREMENT (which learning is mandatory, for whom, org-
 * wide or scoped to one site/activity) is an operational decision about
 * this organization's own workforce, which a Site Manager already owns
 * everywhere else in this codebase — an Admin working from the office and a
 * Site Manager working the site can each define what's required, exactly
 * like they can each create an activity or a site.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Move a safety learning item or safety requirement to a different
 *   organization through the update callables: `organizationId` is
 *   immutable after creation, exactly like every other record type in this
 *   codebase.
 * - Set `requiredLearningIds` on a safety requirement to an id that does
 *   not refer to an existing `SafetyLearning` document in the same
 *   organization — every id is validated by a fresh server-side fetch
 *   before the write, mirroring `createSite`'s multi-doc validation style.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 *
 * KNOWLEDGE CHECK QUESTIONS
 *
 * `addKnowledgeCheckQuestion`/`updateKnowledgeCheckQuestion`/
 * `removeKnowledgeCheckQuestion` manage
 * `safety_learning/{learningId}/knowledge_check_questions/{questionId}` — a
 * SUBCOLLECTION, unlike every other field on `SafetyLearning` itself, and
 * for one deliberate reason: `firestore.rules` grants any org member read
 * access to the PARENT `safety_learning` document (unchanged, and correct —
 * workers need to see a learning item's title/type/description), but a
 * question document carries `correctOptionId`, which a worker must NEVER be
 * able to read. Putting it in a separate subcollection lets `firestore.rules`
 * deny that subcollection outright (`allow read: if false`) while the parent
 * stays readable — a single merged document could not satisfy both at once,
 * since Firestore rules are document-level, not field-level. The only path a
 * worker ever sees question content through is `getKnowledgeCheckQuestions`
 * (`worker_learning_callable.ts`), which strips `correctOptionId` from every
 * question before the response is built — never merely omits it from a type.
 *
 * Authorized like the items themselves — `admin`, or a `siteManager` of
 * this organization for a VIDEO item's questions only; see
 * `requireLibraryAuthor`/`requireAuthorableItem` below. Each question is
 * multiple-choice: 2-6 options, exactly one of which is correct
 * (`correctOptionId` must match one of `options[].id`). `SafetyLearning`
 * itself gains `passingScorePercent` (0-100) — see
 * `optionalPassingScorePercent` — meaningful only once at least one question
 * exists for that item; see `worker_learning_callable.ts`'s
 * `completeLearning` doc comment for the "zero questions -> no
 * gate" rule this enables.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  isRecordStatus,
  RecordStatus,
  requireOrganizationScopedManager,
} from "./organization_callable";
import type {CallableRequest} from "firebase-functions/v2/https";
import {countQuestions, requireActiveWorker} from "./worker_learning_callable";

/**
 * Who may author learning items in [organizationId], and how far.
 *
 * Reuses `requireOrganizationScopedManager` — `admin` (any organization)
 * or an active `siteManager` of THIS organization, re-read from the
 * caller's own trusted profile and membership, never from the request —
 * then re-reads the caller's profile to tell the two apart: only a
 * platform `admin` may author every learning type.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<{uid: string, videoOnly: boolean}>} the caller's uid,
 * and whether they are limited to video items.
 */
export async function requireLibraryAuthor(
  request: CallableRequest,
  organizationId: string
): Promise<{uid: string; videoOnly: boolean}> {
  const uid = await requireOrganizationScopedManager(request, organizationId);
  const profile = (await getFirestore().doc(`users/${uid}`).get()).data();
  return {uid, videoOnly: profile?.platformRole !== "admin"};
}

/**
 * The refusal for a Site Manager acting on a non-video item.
 *
 * @return {HttpsError} a `permission-denied` error.
 */
function videoOnlyDenied(): HttpsError {
  return new HttpsError(
    "permission-denied",
    "You do not have permission to manage this learning item. Site " +
      "Managers can manage video learning items only."
  );
}

/**
 * Loads `safety_learning/{learningId}` and, for a video-only author,
 * refuses it unless its STORED type is `video`. Missing items are
 * `not-found`, as before.
 *
 * @param {string} organizationId the organization the item belongs to.
 * @param {string} learningId the learning item's id.
 * @param {boolean} videoOnly whether the caller may only touch videos.
 * @return {Promise<void>} resolves when the caller may act on the item.
 */
async function requireAuthorableItem(
  organizationId: string,
  learningId: string,
  videoOnly: boolean
): Promise<void> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/safety_learning/${learningId}`)
    .get();
  if (!snapshot.exists) {
    throw new HttpsError(
      "not-found",
      "That safety learning item no longer exists."
    );
  }
  if (videoOnly && snapshot.data()?.type !== "video") throw videoOnlyDenied();
  if (snapshot.data()?.deletion?.pending) throw beingDeleted();
}

/**
 * The refusal for changing an item that is part-way through deletion
 * (`learning_delete_callable.ts`): it is finished, never revived half-way.
 *
 * @return {HttpsError} a `failed-precondition` error.
 */
function beingDeleted(): HttpsError {
  return new HttpsError(
    "failed-precondition",
    "This item is being deleted. Choose Delete again to finish it."
  );
}

/** 2-6 options per multiple-choice knowledge-check question. */
const MIN_OPTIONS = 2;
const MAX_OPTIONS = 6;

/** One selectable option on a knowledge-check question. */
interface KnowledgeCheckOption {
  id: string;
  text: string;
}

const LEARNING_TYPES = [
  "video",
  "course",
  "visualGuide",
  "document",
  "knowledgeCheck",
] as const;
type LearningType = (typeof LEARNING_TYPES)[number];

/**
 * Narrows an unknown value to a [LearningType].
 *
 * @param {unknown} value the value to test.
 * @return {boolean} true when [value] is a recognised learning type.
 */
function isLearningType(value: unknown): value is LearningType {
  return typeof value === "string" &&
    (LEARNING_TYPES as readonly string[]).includes(value);
}

const RISK_LEVELS = ["low", "medium", "high"] as const;
type RiskLevel = (typeof RISK_LEVELS)[number];

/**
 * Narrows an unknown value to a [RiskLevel].
 *
 * @param {unknown} value the value to test.
 * @return {boolean} true when [value] is a recognised risk level.
 */
function isRiskLevel(value: unknown): value is RiskLevel {
  return typeof value === "string" &&
    (RISK_LEVELS as readonly string[]).includes(value);
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
 * Reads an optional string argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string | null} the validated value, or null.
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
 * Reads and validates the optional `minimumWatchSeconds` argument — a
 * non-negative integer, or null/absent meaning "no minimum enforced." See
 * `SafetyLearning.minimumWatchSeconds`'s doc comment for what this does and
 * does not verify.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {number | null} the validated value, or null.
 */
function optionalMinimumWatchSeconds(
  request: CallableRequest
): number | null {
  const value = (request.data ?? {}).minimumWatchSeconds;
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new HttpsError(
      "invalid-argument",
      "minimumWatchSeconds must be a non-negative number."
    );
  }
  return Math.floor(value);
}

/**
 * Reads and validates the optional `passingScorePercent` argument — an
 * integer 0-100, or null/absent meaning "no knowledge-check gate" (the same
 * effect as configuring zero questions — see
 * `completeLearning`'s doc comment in `worker_learning_callable.ts`).
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {number | null} the validated value, or null.
 */
function optionalPassingScorePercent(
  request: CallableRequest
): number | null {
  const value = (request.data ?? {}).passingScorePercent;
  if (value === undefined || value === null) return null;
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < 0 ||
    value > 100
  ) {
    throw new HttpsError(
      "invalid-argument",
      "passingScorePercent must be a number between 0 and 100."
    );
  }
  return Math.floor(value);
}

/**
 * Reads and validates the optional `status` argument, defaulting to
 * `"active"`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {RecordStatus} the validated status.
 */
function targetStatus(request: CallableRequest): RecordStatus {
  const status = (request.data ?? {}).status;
  if (status === undefined) return "active";
  if (!isRecordStatus(status)) {
    throw new HttpsError(
      "invalid-argument",
      "status must be active or inactive."
    );
  }
  return status;
}

/**
 * Reads and validates a required `type` argument (a [LearningType]).
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {LearningType} the validated type.
 */
function requireLearningType(request: CallableRequest): LearningType {
  const type = (request.data ?? {}).type;
  if (!isLearningType(type)) {
    throw new HttpsError(
      "invalid-argument",
      "type must be one of: " + LEARNING_TYPES.join(", ") + "."
    );
  }
  return type;
}

/**
 * Reads and validates an optional `type` argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {LearningType | null} the validated type, or null.
 */
function optionalLearningType(request: CallableRequest): LearningType | null {
  const type = (request.data ?? {}).type;
  if (type === undefined) return null;
  if (!isLearningType(type)) {
    throw new HttpsError(
      "invalid-argument",
      "type must be one of: " + LEARNING_TYPES.join(", ") + "."
    );
  }
  return type;
}

/**
 * Reads and validates a required `risk` argument (a [RiskLevel]).
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {RiskLevel} the validated risk level.
 */
function requireRiskLevel(request: CallableRequest): RiskLevel {
  const risk = (request.data ?? {}).risk;
  if (!isRiskLevel(risk)) {
    throw new HttpsError(
      "invalid-argument",
      "risk must be one of: " + RISK_LEVELS.join(", ") + "."
    );
  }
  return risk;
}

/**
 * Reads and validates an optional `risk` argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {RiskLevel | null} the validated risk level, or null.
 */
function optionalRiskLevel(request: CallableRequest): RiskLevel | null {
  const risk = (request.data ?? {}).risk;
  if (risk === undefined) return null;
  if (!isRiskLevel(risk)) {
    throw new HttpsError(
      "invalid-argument",
      "risk must be one of: " + RISK_LEVELS.join(", ") + "."
    );
  }
  return risk;
}

/**
 * Reads an optional string-array argument (e.g. `requiredLearningIds`), or
 * null when absent.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string[] | null} the validated array, or null.
 */
function optionalStringArray(
  request: CallableRequest,
  field: string
): string[] | null {
  const value = (request.data ?? {})[field];
  if (value === undefined) return null;
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
 * Validates that every id in [learningIds] refers to an existing
 * `SafetyLearning` document within [organizationId], and that every id NOT
 * already on the requirement ([alreadyListed]) is ACTIVE — an inactive
 * lesson is never newly made mandatory, while a requirement that already
 * lists one (since deactivated) can still be saved unchanged; the resolver
 * ignores inactive lessons either way. Fetched fresh, never trusted from
 * the request payload alone — mirrors `createSite`'s multi-doc-fetch
 * validation style.
 *
 * READ INSIDE THE REQUIREMENT'S OWN TRANSACTION ([tx]). A transaction
 * holds what it read until it commits, so this conflicts with a deletion
 * (`learning_delete_callable.ts`), whose mark and delete steps WRITE the
 * same item documents: either the requirement commits first (and the
 * deletion's re-checks see it and refuse/undo), or it reads the item after
 * the deletion marked or removed it and is refused here. A requirement can
 * therefore never newly list an item being deleted or already deleted.
 *
 * @param {FirebaseFirestore.Transaction} tx the requirement's transaction.
 * @param {string} organizationId the organization the requirement belongs
 * to.
 * @param {string[]} learningIds the ids to validate.
 * @param {Set<string>} alreadyListed ids the requirement already had.
 * @return {Promise<void>} resolves when every id is confirmed to exist.
 */
async function requireLearningItemsExist(
  tx: FirebaseFirestore.Transaction,
  organizationId: string,
  learningIds: string[],
  alreadyListed: Set<string> = new Set()
): Promise<void> {
  const snapshots = await tx.getAll(
    ...learningIds.map((id) =>
      getFirestore()
        .doc(`organizations/${organizationId}/safety_learning/${id}`)
    )
  );
  const missing = snapshots
    .map((snapshot, index) => ({snapshot, id: learningIds[index]}))
    .filter(({snapshot}) => !snapshot.exists);
  if (missing.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "One or more required learning items do not exist: " +
        missing.map(({id}) => id).join(", ")
    );
  }
  const beingDeleted = snapshots
    .map((snapshot, index) => ({snapshot, id: learningIds[index]}))
    .filter(({snapshot, id}) =>
      !alreadyListed.has(id) && snapshot.data()?.deletion?.pending);
  if (beingDeleted.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "Learning items being deleted cannot be made required: " +
        beingDeleted.map(({id}) => id).join(", ")
    );
  }
  const newlyInactive = snapshots
    .map((snapshot, index) => ({snapshot, id: learningIds[index]}))
    .filter(({snapshot, id}) =>
      !alreadyListed.has(id) && snapshot.data()?.status !== "active");
  if (newlyInactive.length > 0) {
    throw new HttpsError(
      "failed-precondition",
      "Inactive learning items cannot be made required: " +
        newlyInactive.map(({id}) => id).join(", ")
    );
  }
}

/**
 * Creates a safety learning item within an existing organization.
 */
export const createSafetyLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {uid: actorUid, videoOnly} = await requireLibraryAuthor(
    request,
    organizationId
  );
  const title = requireString(request, "title");
  const type = requireLearningType(request);
  if (videoOnly && type !== "video") throw videoOnlyDenied();
  const contentReference = requireString(request, "contentReference");
  const description = optionalString(request, "description");
  const status = targetStatus(request);
  const minimumWatchSeconds = optionalMinimumWatchSeconds(request);
  const passingScorePercent = optionalPassingScorePercent(request);

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/safety_learning`)
    .doc();
  await ref.set({
    organizationId,
    title,
    type,
    contentReference,
    ...(description !== null ? {description} : {}),
    status,
    ...(minimumWatchSeconds !== null ? {minimumWatchSeconds} : {}),
    ...(passingScorePercent !== null ? {passingScorePercent} : {}),
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId};
});

/**
 * Updates a safety learning item's editable fields. `organizationId` is
 * immutable.
 */
/**
 * The names of the ACTIVE Safety Requirements in [organizationId] whose
 * `requiredLearningIds` list [learningId]. Read from the authoritative
 * requirement documents; a failed read throws, so a caller can never
 * mistake "could not check" for "none".
 *
 * @param {string} organizationId the organization.
 * @param {string} learningId the learning item.
 * @return {Promise<string[]>} the requirement names (ids when unnamed).
 */
async function activeRequirementsListing(
  organizationId: string,
  learningId: string
): Promise<string[]> {
  const snapshot = await getFirestore()
    .collection(`organizations/${organizationId}/safety_requirements`)
    .where("requiredLearningIds", "array-contains", learningId)
    .get();
  return snapshot.docs
    .filter((doc) => doc.data().status === "active")
    .map((doc) => {
      const name = doc.data().name;
      return typeof name === "string" && name.trim() ? name.trim() : doc.id;
    });
}

export const updateSafetyLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {uid: actorUid, videoOnly} = await requireLibraryAuthor(
    request,
    organizationId
  );
  const id = requireString(request, "id");
  const title = optionalString(request, "title");
  const type = optionalLearningType(request);
  const contentReference = optionalString(request, "contentReference");
  const description = optionalString(request, "description");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;
  // Distinguished from "not supplied" (leave unchanged) by key PRESENCE,
  // not by value — 0 is a legitimate "no minimum" value, unlike
  // `optionalString`'s empty-string-means-absent convention, so it cannot
  // reuse that same sentinel.
  const minimumWatchSecondsGiven =
    (request.data ?? {}).minimumWatchSeconds !== undefined;
  const minimumWatchSeconds = minimumWatchSecondsGiven ?
    optionalMinimumWatchSeconds(request) :
    null;
  const passingScorePercentGiven =
    (request.data ?? {}).passingScorePercent !== undefined;
  const passingScorePercent = passingScorePercentGiven ?
    optionalPassingScorePercent(request) :
    null;

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_learning/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError(
      "not-found",
      "That safety learning item no longer exists."
    );
  }
  // A Site Manager may only touch an item that IS a video (as stored) and
  // must leave it one.
  if (
    videoOnly &&
    (snapshot.data()?.type !== "video" || (type !== null && type !== "video"))
  ) {
    throw videoOnlyDenied();
  }
  if (snapshot.data()?.deletion?.pending) throw beingDeleted();
  // A video still listed by an ACTIVE Safety Requirement cannot be
  // deactivated: the requirement would silently stop requiring it. Those
  // requirements are updated first. Inactive requirements do not block.
  if (status === "inactive" && snapshot.data()?.type === "video") {
    const usedBy = await activeRequirementsListing(organizationId, id);
    if (usedBy.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        "This video is required by active Safety Requirements: " +
          `${usedBy.join(", ")}. Remove it from those requirements (or ` +
          "deactivate them) before deactivating the video."
      );
    }
  }

  await ref.update({
    ...(title !== null ? {title} : {}),
    ...(type !== null ? {type} : {}),
    ...(contentReference !== null ? {contentReference} : {}),
    ...(description !== null ? {description} : {}),
    ...(status !== null ? {status} : {}),
    ...(minimumWatchSecondsGiven ?
      {
        minimumWatchSeconds: minimumWatchSeconds !== null ?
          minimumWatchSeconds :
          FieldValue.delete(),
      } :
      {}),
    ...(passingScorePercentGiven ?
      {
        passingScorePercent: passingScorePercent !== null ?
          passingScorePercent :
          FieldValue.delete(),
      } :
      {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});

/**
 * Reads the optional `projectId`/`siteId`/`activityId` scoping arguments and
 * validates them: at most ONE of the three may be set, and whichever is set
 * must name a real document within [organizationId] — mirroring
 * `createSite`'s multi-doc-fetch validation style, same as
 * `requireLearningItemsExist`.
 *
 * `projectId` is a coarser scope than `siteId`/`activityId`: it applies a
 * requirement to every site and activity under that project, without
 * enumerating each one. It is mutually exclusive with `siteId`/`activityId`
 * — a requirement targeting one specific site or activity should use that
 * narrower scope directly, exactly as before this field was added.
 *
 * An `activityId` alone is sufficient scope (the activity's own `siteId`
 * field already ties it to a site — see `Activity`'s doc comment) so this
 * never requires more than one of the three to be set.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the requirement belongs
 * to.
 * @return {Promise<object>} the validated `{projectId, siteId, activityId}`
 * scope, all null meaning organization-wide.
 */
async function optionalScope(
  request: CallableRequest,
  organizationId: string
): Promise<{
  projectId: string | null;
  siteId: string | null;
  activityId: string | null;
}> {
  const projectId = optionalString(request, "projectId");
  const siteId = optionalString(request, "siteId");
  const activityId = optionalString(request, "activityId");

  const scopeCount =
    [projectId, siteId, activityId].filter((v) => v !== null).length;
  if (scopeCount > 1) {
    throw new HttpsError(
      "invalid-argument",
      "A requirement may be scoped to a project, a site or an activity, " +
        "not more than one."
    );
  }

  if (projectId !== null) {
    const snapshot = await getFirestore()
      .doc(`organizations/${organizationId}/projects/${projectId}`)
      .get();
    if (!snapshot.exists) {
      throw new HttpsError(
        "failed-precondition",
        "That project does not exist."
      );
    }
  }

  if (siteId !== null) {
    const snapshot = await getFirestore()
      .doc(`organizations/${organizationId}/sites/${siteId}`)
      .get();
    if (!snapshot.exists) {
      throw new HttpsError("failed-precondition", "That site does not exist.");
    }
  }

  if (activityId !== null) {
    const snapshot = await getFirestore()
      .doc(`organizations/${organizationId}/activities/${activityId}`)
      .get();
    if (!snapshot.exists) {
      throw new HttpsError(
        "failed-precondition",
        "That activity does not exist."
      );
    }
  }

  return {projectId, siteId, activityId};
}

/**
 * Reads the optional `gatesAttendance` argument, defaulting to `true` when
 * absent — a NEW requirement with no explicit choice blocks attendance,
 * matching this field's "existing behavior is unchanged unless explicitly
 * opted out" backward-compatibility rule (see `SafetyRequirement`'s own doc
 * comment).
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {boolean} the validated value.
 */
function gatesAttendanceOrDefault(request: CallableRequest): boolean {
  return booleanOrDefault(request, "gatesAttendance", true);
}

/**
 * Reads the optional `requiredBeforeWork` argument, defaulting to `false`
 * when absent. Deliberately the OPPOSITE default to `gatesAttendance`: the
 * "required before work" concept is new, so no requirement — new or legacy
 * — becomes pre-work learning unless an administrator explicitly marks it.
 * Independent of `gatesAttendance`: neither field is ever derived from the
 * other. See `SafetyRequirement.requiredBeforeWork`'s own doc comment.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {boolean} the validated value.
 */
function requiredBeforeWorkOrDefault(request: CallableRequest): boolean {
  return booleanOrDefault(request, "requiredBeforeWork", false);
}

/**
 * Reads an optional boolean argument, returning [fallback] when absent and
 * refusing any non-boolean value.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @param {boolean} fallback the value used when the argument is absent.
 * @return {boolean} the validated value.
 */
function booleanOrDefault(
  request: CallableRequest,
  field: string,
  fallback: boolean
): boolean {
  const value = (request.data ?? {})[field];
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `${field} must be a boolean.`);
  }
  return value;
}

/**
 * One selected lesson's behavior WITHIN one requirement — the
 * requirement->learning relationship, stored on the requirement in
 * `learningSettings[learningId]`, never on the global `safety_learning`
 * document (the same lesson can behave differently under different
 * requirements). See `SafetyRequirement.learningSettings`.
 */
interface LearningSetting {
  gatesAttendance: boolean;
  requiredBeforeWork: boolean;
  /**
   * Whether the lesson's quiz (when it has one) must be passed to complete
   * it under this requirement. Optional: absent means mandatory — the only
   * behaviour before this setting existed — so older clients and stored
   * requirements are unaffected.
   */
  quizRequired?: boolean;
}

/**
 * Reads and validates the optional `learningSettings` argument: an object
 * keyed by learning id, each value `{gatesAttendance, requiredBeforeWork}`
 * with BOTH booleans present, plus an optional boolean `quizRequired`, and
 * no other fields. Returns null when absent.
 * Coverage against the requirement's own lesson list is checked separately
 * — see `requireCompleteLearningSettings`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Record<string, LearningSetting> | null} the validated settings.
 */
function optionalLearningSettings(
  request: CallableRequest
): Record<string, LearningSetting> | null {
  const value = (request.data ?? {}).learningSettings;
  if (value === undefined) return null;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpsError(
      "invalid-argument",
      "learningSettings must be an object keyed by learning id."
    );
  }
  const settings: Record<string, LearningSetting> = {};
  for (const [learningId, raw] of Object.entries(value)) {
    if (!learningId.trim()) {
      throw new HttpsError(
        "invalid-argument",
        "learningSettings keys must be learning ids."
      );
    }
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new HttpsError(
        "invalid-argument",
        `learningSettings.${learningId} must be an object.`
      );
    }
    const entry = raw as Record<string, unknown>;
    for (const key of Object.keys(entry)) {
      if (
        key !== "gatesAttendance" &&
        key !== "requiredBeforeWork" &&
        key !== "quizRequired"
      ) {
        throw new HttpsError(
          "invalid-argument",
          `learningSettings.${learningId}.${key} is not a recognised setting.`
        );
      }
    }
    if (
      typeof entry.gatesAttendance !== "boolean" ||
      typeof entry.requiredBeforeWork !== "boolean"
    ) {
      throw new HttpsError(
        "invalid-argument",
        `learningSettings.${learningId} must set gatesAttendance and ` +
          "requiredBeforeWork as booleans."
      );
    }
    if (
      entry.quizRequired !== undefined &&
      typeof entry.quizRequired !== "boolean"
    ) {
      throw new HttpsError(
        "invalid-argument",
        `learningSettings.${learningId}.quizRequired must be a boolean.`
      );
    }
    settings[learningId] = {
      gatesAttendance: entry.gatesAttendance,
      requiredBeforeWork: entry.requiredBeforeWork,
      ...(typeof entry.quizRequired === "boolean" ?
        {quizRequired: entry.quizRequired} :
        {}),
    };
  }
  return settings;
}

/**
 * Confirms [settings] covers EXACTLY [learningIds]: every selected lesson
 * has an entry, and no entry names a lesson that is not selected. Written
 * settings are therefore always authoritative for every lesson on the
 * requirement — none silently falls back to the requirement-level
 * `gatesAttendance`/`requiredBeforeWork` (which remain only for requirements
 * saved before per-lesson settings existed).
 *
 * @param {Record<string, LearningSetting>} settings the validated settings.
 * @param {string[]} learningIds the requirement's selected lessons.
 */
function requireCompleteLearningSettings(
  settings: Record<string, LearningSetting>,
  learningIds: string[]
): void {
  const selected = new Set(learningIds);
  for (const learningId of Object.keys(settings)) {
    if (!selected.has(learningId)) {
      throw new HttpsError(
        "invalid-argument",
        `learningSettings.${learningId} is not a selected learning item.`
      );
    }
  }
  const missing = learningIds.filter((id) => !(id in settings));
  if (missing.length > 0) {
    throw new HttpsError(
      "invalid-argument",
      "learningSettings is missing: " + missing.join(", ")
    );
  }
}

/**
 * [stored] narrowed to [learningIds], with any newly selected lesson given
 * the default `{gatesAttendance: false, requiredBeforeWork: false}` — used
 * when an update changes the lesson list without resending settings, on a
 * requirement that already has per-lesson settings, so the map stays
 * complete and authoritative. Returns null when [stored] is not a map (a
 * requirement that has never had per-lesson settings keeps its
 * requirement-level fallback untouched).
 *
 * @param {unknown} stored the requirement's current `learningSettings`.
 * @param {string[]} learningIds the new lesson list.
 * @return {Record<string, LearningSetting> | null} the reconciled map.
 */
function reconcileStoredLearningSettings(
  stored: unknown,
  learningIds: string[]
): Record<string, LearningSetting> | null {
  if (typeof stored !== "object" || stored === null || Array.isArray(stored)) {
    return null;
  }
  const current = stored as Record<string, Partial<LearningSetting>>;
  const reconciled: Record<string, LearningSetting> = {};
  for (const id of learningIds) {
    const entry = current[id];
    reconciled[id] = {
      gatesAttendance: entry?.gatesAttendance === true,
      requiredBeforeWork: entry?.requiredBeforeWork === true,
      // Kept when set; a newly added lesson leaves it unset (= mandatory,
      // the existing default).
      ...(typeof entry?.quizRequired === "boolean" ?
        {quizRequired: entry.quizRequired} :
        {}),
    };
  }
  return reconciled;
}

/**
 * Creates a safety requirement within an existing organization. Every id in
 * `requiredLearningIds` (if given) is validated to refer to an existing
 * `SafetyLearning` document in the same organization before writing. The
 * optional `projectId`/`siteId`/`activityId` scope is validated the same
 * way — see `optionalScope`. `gatesAttendance` defaults to `true` when
 * omitted — see `gatesAttendanceOrDefault` and `SafetyRequirement`'s own doc
 * comment for what this field means (required learning vs. learning that
 * blocks Daily Safety Meeting attendance). `requiredBeforeWork` defaults to
 * `false` when omitted — see `requiredBeforeWorkOrDefault`.
 *
 * `learningSettings` (optional) configures each selected lesson
 * individually and, when given, must cover exactly `requiredLearningIds` —
 * see `requireCompleteLearningSettings`. The requirement-level flags above
 * then only matter for lessons with no entry, which a complete map rules
 * out.
 */
export const createSafetyRequirement = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const name = requireString(request, "name");
  const category = requireString(request, "category");
  const risk = requireRiskLevel(request);
  const description = optionalString(request, "description");
  const requiredLearningIds =
    optionalStringArray(request, "requiredLearningIds") ?? [];
  const status = targetStatus(request);
  const gatesAttendance = gatesAttendanceOrDefault(request);
  const requiredBeforeWork = requiredBeforeWorkOrDefault(request);
  const learningSettings = optionalLearningSettings(request);
  if (learningSettings !== null) {
    requireCompleteLearningSettings(learningSettings, requiredLearningIds);
  }
  const {projectId, siteId, activityId} =
    await optionalScope(request, organizationId);

  const db = getFirestore();
  const ref = db
    .collection(`organizations/${organizationId}/safety_requirements`)
    .doc();
  // Validate the listed items and write in ONE transaction — see
  // `requireLearningItemsExist` for why this cannot race a deletion.
  await db.runTransaction(async (tx) => {
    if (requiredLearningIds.length > 0) {
      await requireLearningItemsExist(tx, organizationId, requiredLearningIds);
    }
    tx.set(ref, {
      organizationId,
      name,
      category,
      risk,
      ...(description !== null ? {description} : {}),
      requiredLearningIds,
      status,
      gatesAttendance,
      requiredBeforeWork,
      ...(learningSettings !== null ? {learningSettings} : {}),
      ...(projectId !== null ? {projectId} : {}),
      ...(siteId !== null ? {siteId} : {}),
      ...(activityId !== null ? {activityId} : {}),
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      createdBy: actorUid,
      updatedBy: actorUid,
    });
  });

  return {id: ref.id, organizationId};
});

/**
 * Updates a safety requirement's editable fields, including
 * `requiredLearningIds` and the `projectId`/`siteId`/`activityId` scope.
 * `organizationId` is immutable. Every id supplied in `requiredLearningIds`
 * is re-validated against real `SafetyLearning` documents in the same
 * organization before writing; a supplied scope is re-validated the same
 * way — see `optionalScope`.
 *
 * `projectId`/`siteId`/`activityId` are cleared (reverted to
 * organization-wide) by passing an empty string, matching how an absent
 * value is distinguished from an explicit clear elsewhere in this codebase
 * being impractical for optional string fields sent over a plain JSON
 * callable payload. `gatesAttendance`, when supplied, is written verbatim
 * (no clear-to-default sentinel needed — a boolean has no "absent" value
 * this codebase already reserves an empty-string convention for; passing
 * `true` reverts to the default explicitly). `requiredBeforeWork` follows
 * the same rule: written only when supplied, so an unrelated edit never
 * alters it.
 *
 * `learningSettings`, when supplied, replaces the whole map and must cover
 * exactly the requirement's lessons (the supplied `requiredLearningIds`, or
 * the stored list when that is not being changed). When only
 * `requiredLearningIds` changes on a requirement that already has
 * per-lesson settings, removed lessons' entries are dropped and newly
 * added lessons get `{false, false}` — see
 * `reconcileStoredLearningSettings`. An unrelated edit never touches it.
 */
export const updateSafetyRequirement = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const id = requireString(request, "id");
  const name = optionalString(request, "name");
  const category = optionalString(request, "category");
  const risk = optionalRiskLevel(request);
  const description = optionalString(request, "description");
  const requiredLearningIds = optionalStringArray(
    request,
    "requiredLearningIds"
  );
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;
  const gatesAttendanceGiven =
    (request.data ?? {}).gatesAttendance !== undefined;
  const gatesAttendance = gatesAttendanceGiven ?
    gatesAttendanceOrDefault(request) :
    null;
  const requiredBeforeWork =
    (request.data ?? {}).requiredBeforeWork !== undefined ?
      requiredBeforeWorkOrDefault(request) :
      null;
  const suppliedLearningSettings = optionalLearningSettings(request);
  const scopeGiven = (request.data ?? {}).projectId !== undefined ||
    (request.data ?? {}).siteId !== undefined ||
    (request.data ?? {}).activityId !== undefined;
  const scope = scopeGiven ?
    await optionalScope(request, organizationId) :
    null;

  const db = getFirestore();
  const ref = db.doc(
    `organizations/${organizationId}/safety_requirements/${id}`
  );
  // Read, validate the listed items and write in ONE transaction — see
  // `requireLearningItemsExist` for why this cannot race a deletion.
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) {
      throw new HttpsError(
        "not-found",
        "That safety requirement no longer exists."
      );
    }

    const stored = snapshot.data() ?? {};
    if (requiredLearningIds !== null && requiredLearningIds.length > 0) {
      await requireLearningItemsExist(
        tx,
        organizationId,
        requiredLearningIds,
        new Set(
          Array.isArray(stored.requiredLearningIds) ?
            stored.requiredLearningIds :
            []
        )
      );
    }

    const effectiveLearningIds: string[] = requiredLearningIds ??
    (Array.isArray(stored.requiredLearningIds) ?
      stored.requiredLearningIds.filter(
        (value: unknown): value is string => typeof value === "string"
      ) :
      []);
    let learningSettings: Record<string, LearningSetting> | null = null;
    if (suppliedLearningSettings !== null) {
      requireCompleteLearningSettings(
        suppliedLearningSettings,
        effectiveLearningIds
      );
      learningSettings = suppliedLearningSettings;
    } else if (requiredLearningIds !== null) {
      learningSettings = reconcileStoredLearningSettings(
        stored.learningSettings,
        requiredLearningIds
      );
    }

    tx.update(ref, {
      ...(name !== null ? {name} : {}),
      ...(category !== null ? {category} : {}),
      ...(risk !== null ? {risk} : {}),
      ...(description !== null ? {description} : {}),
      ...(requiredLearningIds !== null ? {requiredLearningIds} : {}),
      ...(status !== null ? {status} : {}),
      ...(gatesAttendance !== null ? {gatesAttendance} : {}),
      ...(requiredBeforeWork !== null ? {requiredBeforeWork} : {}),
      ...(learningSettings !== null ? {learningSettings} : {}),
      ...(scope !== null ? {
        projectId: scope.projectId !== null ?
          scope.projectId :
          FieldValue.delete(),
        siteId: scope.siteId !== null ? scope.siteId : FieldValue.delete(),
        activityId: scope.activityId !== null ?
          scope.activityId :
          FieldValue.delete(),
      } : {}),
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: actorUid,
    });
  });

  return {id, organizationId};
});

/**
 * Validates the required `options` argument: an array of 2-6
 * `{id, text}` objects with unique, non-empty ids and non-empty text.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {KnowledgeCheckOption[]} the validated options.
 */
function requireOptions(request: CallableRequest): KnowledgeCheckOption[] {
  const value = (request.data ?? {}).options;
  if (!Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "options must be an array.");
  }
  if (value.length < MIN_OPTIONS || value.length > MAX_OPTIONS) {
    throw new HttpsError(
      "invalid-argument",
      `A question must have between ${MIN_OPTIONS} and ${MAX_OPTIONS} ` +
        "options."
    );
  }
  const options: KnowledgeCheckOption[] = value.map((raw, index) => {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new HttpsError(
        "invalid-argument",
        `options[${index}] must be an object.`
      );
    }
    const record = raw as Record<string, unknown>;
    const id = record.id;
    const text = record.text;
    if (typeof id !== "string" || !id.trim()) {
      throw new HttpsError(
        "invalid-argument",
        `options[${index}].id is required.`
      );
    }
    if (typeof text !== "string" || !text.trim()) {
      throw new HttpsError(
        "invalid-argument",
        `options[${index}].text is required.`
      );
    }
    return {id: id.trim(), text: text.trim()};
  });
  const uniqueIds = new Set(options.map((option) => option.id));
  if (uniqueIds.size !== options.length) {
    throw new HttpsError(
      "invalid-argument",
      "options must have unique ids."
    );
  }
  return options;
}

/**
 * Validates the required `correctOptionId` argument refers to one of
 * [options]' own ids.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {KnowledgeCheckOption[]} options the question's own validated
 * options.
 * @return {string} the validated correct option id.
 */
function requireCorrectOptionId(
  request: CallableRequest,
  options: KnowledgeCheckOption[]
): string {
  const correctOptionId = requireString(request, "correctOptionId");
  if (!options.some((option) => option.id === correctOptionId)) {
    throw new HttpsError(
      "invalid-argument",
      "correctOptionId must match one of options[].id."
    );
  }
  return correctOptionId;
}

/**
 * Adds a multiple-choice knowledge-check question to `learningId`. `admin`,
 * or a `siteManager` for a video — see this file's header note ("KNOWLEDGE
 * CHECK QUESTIONS").
 * `correctOptionId` is stored here and here alone; it is never returned to
 * a worker-facing read path (see `getKnowledgeCheckQuestions` in
 * `worker_learning_callable.ts`).
 */
export const addKnowledgeCheckQuestion = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {videoOnly} = await requireLibraryAuthor(request, organizationId);
  const learningId = requireString(request, "learningId");
  const prompt = requireString(request, "prompt");
  const order = (request.data ?? {}).order;
  if (typeof order !== "number" || !Number.isFinite(order)) {
    throw new HttpsError("invalid-argument", "order must be a number.");
  }
  const options = requireOptions(request);
  const correctOptionId = requireCorrectOptionId(request, options);

  await requireAuthorableItem(organizationId, learningId, videoOnly);

  const ref = getFirestore()
    .collection(
      `organizations/${organizationId}/safety_learning/${learningId}` +
        "/knowledge_check_questions"
    )
    .doc();
  await ref.set({
    prompt,
    options,
    correctOptionId,
    order,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {id: ref.id, organizationId, learningId};
});

/**
 * Updates an existing knowledge-check question's editable fields. `admin`,
 * or a `siteManager` for a video. Every field is required on update
 * (unlike `updateSafetyLearning`'s partial-update style) — a question's
 * shape must always stay internally consistent (`correctOptionId` must
 * always match one of the CURRENT
 * `options`), so a partial update that changed `options` without also
 * re-validating `correctOptionId` against the new set could silently leave
 * a question with no valid correct answer.
 */
export const updateKnowledgeCheckQuestion = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {videoOnly} = await requireLibraryAuthor(request, organizationId);
  const learningId = requireString(request, "learningId");
  // An Admin's behaviour is unchanged; a Site Manager only for a video.
  if (videoOnly) {
    await requireAuthorableItem(organizationId, learningId, videoOnly);
  }
  const questionId = requireString(request, "questionId");
  const prompt = requireString(request, "prompt");
  const order = (request.data ?? {}).order;
  if (typeof order !== "number" || !Number.isFinite(order)) {
    throw new HttpsError("invalid-argument", "order must be a number.");
  }
  const options = requireOptions(request);
  const correctOptionId = requireCorrectOptionId(request, options);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_learning/${learningId}` +
      `/knowledge_check_questions/${questionId}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That question no longer exists.");
  }

  await ref.update({
    prompt,
    options,
    correctOptionId,
    order,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {id: questionId, organizationId, learningId};
});

/**
 * Removes a knowledge-check question. `admin`, or a `siteManager` for a
 * video. Unlike every other
 * record type in this codebase (which prefer an inactive/active status over
 * deletion), a question has no historical-reference concern the way a
 * `SafetyLearning` item or `SafetyRequirement` does — nothing else in this
 * codebase names a question by id (a `WorkerLearningRecord`'s own
 * `knowledgeCheckResult` stores a plain `score`/`passed` outcome, never a
 * per-question answer trail), so removing one outright, rather than
 * soft-deleting, does not orphan any reference.
 */
export const removeKnowledgeCheckQuestion = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {videoOnly} = await requireLibraryAuthor(request, organizationId);
  const learningId = requireString(request, "learningId");
  // An Admin's behaviour is unchanged; a Site Manager only for a video.
  if (videoOnly) {
    await requireAuthorableItem(organizationId, learningId, videoOnly);
  }
  const questionId = requireString(request, "questionId");

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_learning/${learningId}` +
      `/knowledge_check_questions/${questionId}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That question no longer exists.");
  }
  await ref.delete();

  return {id: questionId, organizationId, learningId};
});

/**
 * Lists every knowledge-check question for `learningId`, WITH
 * `correctOptionId` — the admin-authoring counterpart to
 * `getKnowledgeCheckQuestions` (`worker_learning_callable.ts`), which
 * strips it. `admin`, or a `siteManager` for a video (they author its
 * questions): this is the one callable in this codebase that
 * ever returns a question's correct answer, and it does so exactly because
 * `firestore.rules` denies every client (including an Admin's own client
 * SDK) a direct read of this subcollection — an admin editing a question
 * needs to see its current correct answer, so this callable is the
 * deliberate, narrow, audited path for that, mirroring
 * `getMeetingAttendeeLearningStatus`'s own "narrow callable over a loosened
 * rule" precedent (`daily_safety_meeting_callable.ts`).
 */
export const listKnowledgeCheckQuestions = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const {videoOnly} = await requireLibraryAuthor(request, organizationId);
  const learningId = requireString(request, "learningId");
  // An Admin's behaviour is unchanged; a Site Manager only for a video.
  if (videoOnly) {
    await requireAuthorableItem(organizationId, learningId, videoOnly);
  }

  const snapshot = await getFirestore()
    .collection(
      `organizations/${organizationId}/safety_learning/${learningId}` +
        "/knowledge_check_questions"
    )
    .orderBy("order")
    .get();

  const questions = snapshot.docs.map((doc) => ({id: doc.id, ...doc.data()}));
  return {organizationId, learningId, questions};
});

/**
 * How many knowledge-check questions each VIDEO item in [organizationId]
 * has — the quiz indicators and counts on Safety Videos. Only counts are
 * returned, never questions or answers.
 *
 * - A video author (`requireLibraryAuthor`) gets every video, inactive
 *   ones included, for the management page.
 * - Anyone else must be an active member of the organization (the same
 *   `requireActiveWorker` check every learner callable uses) and gets ACTIVE
 *   videos only — the learner library's "has a quiz" indicator, which must
 *   not depend on a Safety Requirement.
 */
export const getVideoQuizSummary = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  let activeOnly = false;
  try {
    await requireLibraryAuthor(request, organizationId);
  } catch (error) {
    if (!(error instanceof HttpsError) || error.code !== "permission-denied") {
      throw error;
    }
    await requireActiveWorker(request, organizationId);
    activeOnly = true;
  }

  const videos = await getFirestore()
    .collection(`organizations/${organizationId}/safety_learning`)
    .where("type", "==", "video")
    .get();
  const ids = videos.docs
    .filter((doc) => !activeOnly || doc.data().status === "active")
    .map((doc) => doc.id);
  const counts = await countQuestions(organizationId, ids);
  return {
    organizationId,
    questionCounts: Object.fromEntries(counts),
  };
});

