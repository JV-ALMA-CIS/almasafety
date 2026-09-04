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
 * `SafetyRequirement` in the organization, narrowed to `SafetyLearning`
 * items that exist and are themselves ACTIVE. The duplication is deliberate
 * and matches this codebase's existing per-file convention for validation
 * helpers — the client copy drives display, this copy is the one that
 * decides, and the client's answer is never trusted.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

/**
 * A worker's knowledge-check submission, as accepted and stored by
 * `completeLearning`. Shape-validated only, never graded — see
 * `optionalKnowledgeCheckResult`.
 */
type KnowledgeCheckResult = {
  passed: boolean;
  score?: number;
};

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
  // Cross-organization isolation: a worker acts only within the
  // organization their own stored profile names, never one supplied by the
  // request. A System Administrator belongs to no organization and has no
  // learning obligations of their own, so they are not special-cased in.
  if (profile.organizationId !== organizationId) throw denied();

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
 * Re-derives the caller's currently-required learning within
 * [organizationId], server-side. See this file's header note for the rule
 * and for why this duplicates the Dart resolver rather than trusting it.
 *
 * @param {string} organizationId the organization to resolve within.
 * @return {Promise<Map<string, FirebaseFirestore.DocumentData>>} required,
 * ACTIVE learning items by id.
 */
async function resolveRequiredLearning(
  organizationId: string
): Promise<Map<string, FirebaseFirestore.DocumentData>> {
  const db = getFirestore();

  const requirements = await db
    .collection(`organizations/${organizationId}/safety_requirements`)
    .where("status", "==", "active")
    .get();

  const requiredIds = new Set<string>();
  for (const doc of requirements.docs) {
    const ids = doc.data().requiredLearningIds;
    if (!Array.isArray(ids)) continue;
    for (const id of ids) {
      if (typeof id === "string" && id.trim()) requiredIds.add(id.trim());
    }
  }
  if (requiredIds.size === 0) return new Map();

  const snapshots = await Promise.all(
    [...requiredIds].map((id) =>
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
 * Validates the optional `knowledgeCheckResult` argument's SHAPE only.
 *
 * There is deliberately no grading and no answer key here: knowledge-check
 * authoring is out of scope for this stage. The server confirms `passed` is
 * a boolean and `score`, if present, is a number, then stores what was
 * submitted. The record is still trustworthy as an audit trail of what the
 * worker attested to, at a server timestamp, under their own authenticated
 * uid.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {KnowledgeCheckResult | null} the validated result, or null.
 */
function optionalKnowledgeCheckResult(
  request: CallableRequest
): KnowledgeCheckResult | null {
  const value = (request.data ?? {}).knowledgeCheckResult;
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new HttpsError(
      "invalid-argument",
      "knowledgeCheckResult must be an object."
    );
  }
  const record = value as Record<string, unknown>;
  if (typeof record.passed !== "boolean") {
    throw new HttpsError(
      "invalid-argument",
      "knowledgeCheckResult.passed must be a boolean."
    );
  }
  if (record.score !== undefined && typeof record.score !== "number") {
    throw new HttpsError(
      "invalid-argument",
      "knowledgeCheckResult.score must be a number when present."
    );
  }
  return {
    passed: record.passed,
    ...(typeof record.score === "number" ? {score: record.score} : {}),
  };
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

  const required = await resolveRequiredLearning(organizationId);
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

  const required = await resolveRequiredLearning(organizationId);
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
 */
export const completeLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const workerUid = await requireActiveWorker(request, organizationId);
  const learningId = requireString(request, "learningId");
  const knowledgeCheckResult = optionalKnowledgeCheckResult(request);

  const required = await resolveRequiredLearning(organizationId);
  const learning = required.get(learningId);
  if (!learning) {
    throw new HttpsError(
      "failed-precondition",
      "That learning item is not currently required of you."
    );
  }

  if (learning.type === "knowledgeCheck" && knowledgeCheckResult === null) {
    throw new HttpsError(
      "invalid-argument",
      "That learning item requires a knowledge check result."
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

  await ref.update({
    status: "completed",
    completedAt: FieldValue.serverTimestamp(),
    ...(knowledgeCheckResult !== null ? {knowledgeCheckResult} : {}),
  });

  return {organizationId, learningId, status: "completed"};
});
