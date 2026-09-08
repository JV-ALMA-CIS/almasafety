/**
 * Worker-to-site assignment callables for JVA Safety.
 *
 * `siteIds` lives on `users/{uid}/memberships/{organizationId}` under the
 * multi-organization membership model — a worker's site access is inherently
 * per-organization, since the same worker may belong to more than one
 * organization with a different site grant in each. `firestore.rules` denies
 * every client write to the `memberships` subcollection outright (mirroring
 * how it denied `siteIds` directly on `users/{uid}` under the old model), so
 * these two callables are the only path that can grant or withdraw site
 * access — for BOTH a Foreman being placed on a site and a Worker being
 * assigned into a Foreman's crew.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireOrganizationScopedManagerOrForeman` (imported from
 * `organization_callable.ts`) resolves the caller as one of:
 *
 *  - UNRESTRICTED (`isManager: true`) — `admin` (any organization), or
 *    `siteManager` of the organization (read from
 *    `organizations/{orgId}.managedBy` or their own active `siteManager`
 *    membership in it — never trusted from the request). May assign/remove
 *    ANY membership at ANY site in the organization — this is how a Site
 *    Manager places a Foreman onto a site (PROJECT_CONTEXT.md §16: Site
 *    Manager -> Foreman -> Worker; there is no separate "assign Foreman"
 *    callable, this generic one already covers it and continues to).
 *  - SCOPED (`isManager: false`, an active `foreman` membership) — PHASE 3
 *    (authorization matrix): may assign/remove ONLY a Worker-role target,
 *    and ONLY at a site in the Foreman's own `siteIds` — see
 *    [requireForemanCanActOnWorkerAtSite] below. A Site Manager still has
 *    unrestricted authority over Workers too (this is additive, not a
 *    narrowing of what Site Manager could already do); the product intent
 *    (PROJECT_CONTEXT.md §16, "Site Manager -> Foreman -> Workers") is that
 *    a Foreman handles their own crew day-to-day, not that Site Manager
 *    loses the ability to intervene.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Assign a worker who belongs to a different organization than the one
 *   named — checked by re-fetching the worker's own profile server-side.
 * - Assign access to a site that does not belong to the named organization —
 *   checked by re-fetching the site document server-side.
 * - A Foreman caller cannot assign/remove a Foreman- or siteManager-role
 *   target, and cannot act at a site outside their own `siteIds` — enforced
 *   by [requireForemanCanActOnWorkerAtSite].
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
import {
  OrganizationScopedActor,
  requireOrganizationScopedManagerOrForeman,
} from "./organization_callable";

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
 * Confirms the target worker holds a membership in [organizationId], and
 * returns that membership's own `role` — needed by
 * [requireForemanCanActOnWorkerAtSite] to confirm a Foreman caller is only
 * ever acting on a Worker-role target, never a peer/superior.
 *
 * Looks up `users/{uid}/memberships/{organizationId}` rather than a scalar
 * `organizationId` field on the profile — a worker's org relationship now
 * lives entirely on their membership document, and a worker may belong to
 * more than one organization, so "does this worker belong to THIS
 * organization" is answered by that one membership doc's existence, not by
 * comparing a single profile field.
 *
 * @param {string} uid the target worker's uid.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<string | null>} the target's membership `role`, or null
 * if it is missing/unrecognised.
 */
async function requireWorkerInOrganization(
  uid: string,
  organizationId: string
): Promise<string | null> {
  const userSnapshot = await getFirestore().doc(`users/${uid}`).get();
  if (!userSnapshot.exists) {
    throw new HttpsError("not-found", "That user no longer exists.");
  }
  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) {
    throw new HttpsError(
      "failed-precondition",
      "That user does not belong to the given organization."
    );
  }
  return typeof membership.role === "string" ? membership.role : null;
}

/**
 * Confirms a SCOPED (`isManager: false`, i.e. Foreman) actor is only acting
 * on a Worker-role target, at a site within the Foreman's own `siteIds`. A
 * no-op for an UNRESTRICTED actor (`isManager: true` — Admin/Site Manager),
 * whose authority already covers any role at any site in the organization.
 *
 * @param {OrganizationScopedActor} actor the caller's resolved scope.
 * @param {string | null} targetRole the target's own membership role.
 * @param {string} siteId the site the action targets.
 * @return {void}
 */
function requireForemanCanActOnWorkerAtSite(
  actor: OrganizationScopedActor,
  targetRole: string | null,
  siteId: string
): void {
  if (actor.isManager) return;
  if (targetRole !== "worker") {
    throw new HttpsError(
      "permission-denied",
      "You do not have permission to do that."
    );
  }
  if (!actor.siteIds.includes(siteId)) {
    throw new HttpsError(
      "permission-denied",
      "You do not have permission to do that."
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
 *
 * Admin/Site Manager may target any membership (this is how a Site Manager
 * places a Foreman onto a site). A Foreman caller may only target a
 * Worker-role membership, and only at a site within their own `siteIds` —
 * see [requireForemanCanActOnWorkerAtSite].
 */
export const assignWorkerToSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actor = await requireOrganizationScopedManagerOrForeman(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const siteId = requireString(request, "siteId");

  const targetRole = await requireWorkerInOrganization(uid, organizationId);
  requireForemanCanActOnWorkerAtSite(actor, targetRole, siteId);
  await requireSiteInOrganization(organizationId, siteId);

  // siteIds lives on the worker's MEMBERSHIP document for this organization
  // under the new model, not on the top-level profile — a worker's site
  // access is inherently per-organization, matching every other per-org
  // field (role, workerType, trade, supervisorUid).
  const membershipRef = getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`);
  await membershipRef.update({
    siteIds: FieldValue.arrayUnion(siteId),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actor.uid,
  });

  return {uid, organizationId, siteId};
});

/**
 * Withdraws [uid]'s access to [siteId] within [organizationId]. Does not
 * cascade to activity assignments — see this file's header note.
 *
 * Same authorization shape as [assignWorkerToSite]: Admin/Site Manager may
 * remove any membership; a Foreman caller may only remove a Worker-role
 * membership from a site within their own `siteIds`.
 */
export const removeWorkerFromSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actor = await requireOrganizationScopedManagerOrForeman(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const siteId = requireString(request, "siteId");

  const targetRole = await requireWorkerInOrganization(uid, organizationId);
  requireForemanCanActOnWorkerAtSite(actor, targetRole, siteId);

  const membershipRef = getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`);
  await membershipRef.update({
    siteIds: FieldValue.arrayRemove(siteId),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actor.uid,
  });

  return {uid, organizationId, siteId};
});
