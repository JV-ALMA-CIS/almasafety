/**
 * Safety Meeting Point management callables for JVA Safety.
 *
 * These are the only path that can create or edit an
 * `organizations/{orgId}/safety_meeting_points/{id}` document —
 * `firestore.rules` denies every client write to that collection outright,
 * mirroring `safety_learning_callable.ts`'s treatment of safety learning.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireAdmin` (imported from `organization_callable.ts`): `admin` only.
 * The Safety Meeting Point library is a platform-level, company-wide
 * responsibility deliberately NOT delegated to `siteManager`
 * (PROJECT_CONTEXT.md §4, §12) — same authority shape as safety learning
 * content management.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Move a meeting point to a different organization through
 *   `updateSafetyMeetingPoint`: `organizationId` is immutable after
 *   creation, exactly like every other record type in this codebase.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 *
 * `activateSafetyMeetingPoint`/`deactivateSafetyMeetingPoint` are thin
 * wrappers over the same status field `updateSafetyMeetingPoint` can already
 * set — kept as separate callables because the admin UI's activate/
 * deactivate action is a single-purpose control, not a general edit form.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  isRecordStatus,
  RecordStatus,
  requireAdmin,
} from "./organization_callable";
import type {CallableRequest} from "firebase-functions/v2/https";

/**
 * Reads and validates a required non-empty string argument. Duplicated
 * per-file per this codebase's existing convention — see
 * `safety_learning_callable.ts`'s copy for why.
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
 * Reads an optional string-array argument (e.g. `applicableActivities`,
 * `applicableRisks`), defaulting to an empty array. Mirrors
 * `optionalStringArray` in `safety_learning_callable.ts`.
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
 * Creates a safety meeting point within an existing organization.
 */
export const createSafetyMeetingPoint = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const title = requireString(request, "title");
  const category = requireString(request, "category");
  const description = optionalString(request, "description");
  const applicableActivities = stringArray(request, "applicableActivities");
  const applicableRisks = stringArray(request, "applicableRisks");
  const status = targetStatus(request);

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/safety_meeting_points`)
    .doc();
  await ref.set({
    organizationId,
    title,
    category,
    ...(description !== null ? {description} : {}),
    applicableActivities,
    applicableRisks,
    status,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId};
});

/**
 * Updates a safety meeting point's editable fields. `organizationId` is
 * immutable.
 */
export const updateSafetyMeetingPoint = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const id = requireString(request, "id");
  const title = optionalString(request, "title");
  const category = optionalString(request, "category");
  const description = optionalString(request, "description");
  const applicableActivities = optionalStringArray(
    request,
    "applicableActivities"
  );
  const applicableRisks = optionalStringArray(request, "applicableRisks");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_meeting_points/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError(
      "not-found",
      "That safety meeting point no longer exists."
    );
  }

  await ref.update({
    ...(title !== null ? {title} : {}),
    ...(category !== null ? {category} : {}),
    ...(description !== null ? {description} : {}),
    ...(applicableActivities !== null ? {applicableActivities} : {}),
    ...(applicableRisks !== null ? {applicableRisks} : {}),
    ...(status !== null ? {status} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});

/**
 * Sets a safety meeting point's status directly, for the admin UI's
 * activate/deactivate action. Thin wrapper over the same write
 * `updateSafetyMeetingPoint` performs when given a `status` argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {RecordStatus} status the status to set.
 * @return {Promise<{id: string, organizationId: string}>} the updated id and
 * organization.
 */
async function setStatus(
  request: CallableRequest,
  status: RecordStatus
): Promise<{id: string; organizationId: string}> {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireAdmin(request);
  const id = requireString(request, "id");

  const ref = getFirestore().doc(
    `organizations/${organizationId}/safety_meeting_points/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError(
      "not-found",
      "That safety meeting point no longer exists."
    );
  }

  await ref.update({
    status,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
}

/**
 * Activates a safety meeting point.
 */
export const activateSafetyMeetingPoint = onCall(
  (request) => setStatus(request, "active")
);

/**
 * Deactivates a safety meeting point.
 */
export const deactivateSafetyMeetingPoint = onCall(
  (request) => setStatus(request, "inactive")
);
