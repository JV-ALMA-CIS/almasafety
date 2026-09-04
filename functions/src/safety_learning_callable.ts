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
 * `requireAdmin` (imported from `organization_callable.ts`): `admin` only.
 * The Safety Learning library is a platform-level, company-wide
 * responsibility deliberately NOT delegated to `siteManager`
 * (PROJECT_CONTEXT.md §4, §12) — unlike activities/projects/sites, which
 * `siteManager` does manage. This is content management, not worker
 * progress — see `worker_learning_callable.ts` for the separate,
 * worker-facing authorization model used by
 * `startLearning`/`completeLearning`.
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
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  isRecordStatus,
  RecordStatus,
  requireAdmin,
} from "./organization_callable";
import type {CallableRequest} from "firebase-functions/v2/https";

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
 * `SafetyLearning` document within [organizationId]. Fetched fresh, never
 * trusted from the request payload alone — mirrors `createSite`'s
 * multi-doc-fetch validation style.
 *
 * @param {string} organizationId the organization the requirement belongs
 * to.
 * @param {string[]} learningIds the ids to validate.
 * @return {Promise<void>} resolves when every id is confirmed to exist.
 */
async function requireLearningItemsExist(
  organizationId: string,
  learningIds: string[]
): Promise<void> {
  const snapshots = await Promise.all(
    learningIds.map((id) =>
      getFirestore()
        .doc(`organizations/${organizationId}/safety_learning/${id}`)
        .get()
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
}

/**
 * Creates a safety learning item within an existing organization.
 */
export const createSafetyLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const title = requireString(request, "title");
  const type = requireLearningType(request);
  const contentReference = requireString(request, "contentReference");
  const description = optionalString(request, "description");
  const status = targetStatus(request);

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
export const updateSafetyLearning = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const id = requireString(request, "id");
  const title = optionalString(request, "title");
  const type = optionalLearningType(request);
  const contentReference = optionalString(request, "contentReference");
  const description = optionalString(request, "description");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
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

  await ref.update({
    ...(title !== null ? {title} : {}),
    ...(type !== null ? {type} : {}),
    ...(contentReference !== null ? {contentReference} : {}),
    ...(description !== null ? {description} : {}),
    ...(status !== null ? {status} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});

/**
 * Creates a safety requirement within an existing organization. Every id in
 * `requiredLearningIds` (if given) is validated to refer to an existing
 * `SafetyLearning` document in the same organization before writing.
 */
export const createSafetyRequirement = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const name = requireString(request, "name");
  const category = requireString(request, "category");
  const risk = requireRiskLevel(request);
  const description = optionalString(request, "description");
  const requiredLearningIds =
    optionalStringArray(request, "requiredLearningIds") ?? [];
  const status = targetStatus(request);

  if (requiredLearningIds.length > 0) {
    await requireLearningItemsExist(organizationId, requiredLearningIds);
  }

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/safety_requirements`)
    .doc();
  await ref.set({
    organizationId,
    name,
    category,
    risk,
    ...(description !== null ? {description} : {}),
    requiredLearningIds,
    status,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId};
});

/**
 * Updates a safety requirement's editable fields, including
 * `requiredLearningIds`. `organizationId` is immutable. Every id supplied in
 * `requiredLearningIds` is re-validated against real `SafetyLearning`
 * documents in the same organization before writing.
 */
export const updateSafetyRequirement = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
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

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_requirements/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError(
      "not-found",
      "That safety requirement no longer exists."
    );
  }

  if (requiredLearningIds !== null && requiredLearningIds.length > 0) {
    await requireLearningItemsExist(organizationId, requiredLearningIds);
  }

  await ref.update({
    ...(name !== null ? {name} : {}),
    ...(category !== null ? {category} : {}),
    ...(risk !== null ? {risk} : {}),
    ...(description !== null ? {description} : {}),
    ...(requiredLearningIds !== null ? {requiredLearningIds} : {}),
    ...(status !== null ? {status} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});
