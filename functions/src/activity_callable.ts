/**
 * Activity management callables for JVA Safety.
 *
 * These are the only path that can create or edit an
 * `organizations/{orgId}/activities/{id}` document — `firestore.rules`
 * denies every client write to that collection outright, mirroring
 * `organization_callable.ts`'s treatment of organizations/projects/sites.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireOrganizationScopedManager` (imported from
 * `organization_callable.ts`): `admin` (any organization), or `siteManager`
 * of the activity's own organization (the organization(s) they manage —
 * PROJECT_CONTEXT.md §12).
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create an activity whose `organizationId`/`projectId` do not match the
 *   named site's own `organizationId`/`projectId` — checked server-side
 *   against the stored site document, never trusted from the request
 *   payload alone.
 * - Move an activity to a different organization, project or site through
 *   `updateActivity`: all three are immutable after creation.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  isRecordStatus,
  RecordStatus,
  requireOrganizationScopedManager,
} from "./organization_callable";
import type {CallableRequest} from "firebase-functions/v2/https";

/**
 * Reads and validates a required non-empty string argument. Mirrors
 * `requireString` in `organization_callable.ts`.
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
 * Reads an optional string argument. Mirrors `optionalString` in
 * `organization_callable.ts`.
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
 * `"active"`. Mirrors `targetStatus` in `organization_callable.ts`.
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
 * Creates an activity within an existing organization, project and site.
 *
 * Refuses to create an activity whose `organizationId`/`projectId` do not
 * match the named site's own `organizationId`/`projectId` — the server-side
 * enforcement of "an activity must belong to a site that itself belongs to
 * the named organization and project."
 */
export const createActivity = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const projectId = requireString(request, "projectId");
  const siteId = requireString(request, "siteId");
  const name = requireString(request, "name");
  const code = requireString(request, "code");
  const description = optionalString(request, "description");
  const status = targetStatus(request);

  const siteRef = getFirestore().doc(
    `organizations/${organizationId}/sites/${siteId}`
  );
  const siteSnapshot = await siteRef.get();
  const site = siteSnapshot.data();
  if (!siteSnapshot.exists || !site) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  if (site.organizationId !== organizationId || site.projectId !== projectId) {
    // The relationship this callable exists to enforce: an activity's
    // organization and project must match its site's, never a mismatched
    // combination supplied independently by the client.
    throw new HttpsError(
      "failed-precondition",
      "That site does not belong to the given organization and project."
    );
  }

  const ref = getFirestore()
    .collection(`organizations/${organizationId}/activities`)
    .doc();
  await ref.set({
    organizationId,
    projectId,
    siteId,
    name,
    code,
    ...(description !== null ? {description} : {}),
    status,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId, projectId, siteId};
});

/**
 * Updates an activity's editable fields.
 *
 * `organizationId`, `projectId` and `siteId` are all immutable — see this
 * file's header note.
 */
export const updateActivity = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const id = requireString(request, "id");
  const name = optionalString(request, "name");
  const code = optionalString(request, "code");
  const description = optionalString(request, "description");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;

  const ref = getFirestore().doc(
    `organizations/${organizationId}/activities/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That activity no longer exists.");
  }

  await ref.update({
    ...(name !== null ? {name} : {}),
    ...(code !== null ? {code} : {}),
    ...(description !== null ? {description} : {}),
    ...(status !== null ? {status} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});
