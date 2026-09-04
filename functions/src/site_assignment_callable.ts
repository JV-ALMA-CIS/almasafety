/**
 * Worker-to-site assignment callables for JVA Safety.
 *
 * `firestore.rules` blocks every client write to `siteIds` on `users/{uid}`
 * (it is in both `registrationOmitsPrivilegedFields()` and
 * `touchesProtectedFields()`), exactly like `platformRole`, `workerType` and
 * `organizationId` — so these two callables are the only path that can grant
 * or withdraw a worker's site access.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireOrganizationScopedManager` (imported from
 * `organization_callable.ts`): `admin` (any organization), or `siteManager`
 * of the organization (read from `organizations/{orgId}.managedBy` or their
 * own profile's `organizationId` — never trusted from the request).
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Assign a worker who belongs to a different organization than the one
 *   named — checked by re-fetching the worker's own profile server-side.
 * - Assign access to a site that does not belong to the named organization —
 *   checked by re-fetching the site document server-side.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 *
 * CASCADE DECISION (documented, not implemented)
 *
 * `removeWorkerFromSite` does NOT cascade to delete the worker's activity
 * assignments at that site. The simpler alternative — leaving those
 * assignment documents in place — is deliberate: every read of an activity
 * assignment that matters for authorization (see
 * `activity_assignment_callable.ts`) re-validates the worker's current
 * `siteIds` at the time it is used, so a stale assignment document confers
 * no access on its own. A cross-collection cascade delete would need to
 * scan every activity in the organization for a matching subcollection
 * document, which is more moving parts for a case the re-validation already
 * covers safely.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {requireOrganizationScopedManager} from "./organization_callable";

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
 * Loads the target worker's profile and confirms it belongs to
 * [organizationId].
 *
 * @param {string} uid the target worker's uid.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<void>} resolves when the check passes.
 */
async function requireWorkerInOrganization(
  uid: string,
  organizationId: string
): Promise<void> {
  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new HttpsError("not-found", "That user no longer exists.");
  }
  if (profile.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That user does not belong to the given organization."
    );
  }
}

/**
 * Loads the target site and confirms it belongs to [organizationId].
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} siteId the target site's id.
 * @return {Promise<void>} resolves when the check passes.
 */
async function requireSiteInOrganization(
  organizationId: string,
  siteId: string
): Promise<void> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/sites/${siteId}`)
    .get();
  if (!snapshot.exists) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
}

/**
 * Grants [uid] access to [siteId] within [organizationId].
 */
export const assignWorkerToSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const siteId = requireString(request, "siteId");

  await requireWorkerInOrganization(uid, organizationId);
  await requireSiteInOrganization(organizationId, siteId);

  await getFirestore().doc(`users/${uid}`).update({
    siteIds: FieldValue.arrayUnion(siteId),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {uid, organizationId, siteId};
});

/**
 * Withdraws [uid]'s access to [siteId] within [organizationId]. Does not
 * cascade to activity assignments — see this file's header note.
 */
export const removeWorkerFromSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const siteId = requireString(request, "siteId");

  await requireWorkerInOrganization(uid, organizationId);

  await getFirestore().doc(`users/${uid}`).update({
    siteIds: FieldValue.arrayRemove(siteId),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {uid, organizationId, siteId};
});
