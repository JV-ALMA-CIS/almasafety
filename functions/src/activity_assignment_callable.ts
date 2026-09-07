/**
 * Worker-to-activity assignment callables for JVA Safety.
 *
 * Stores one document per worker per activity at
 * `organizations/{orgId}/activities/{activityId}/assignments/{uid}` —
 * `firestore.rules` denies every client write to that subcollection, so
 * these two callables are the only path that can create or remove one.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `requireOrganizationScopedManager` (imported from
 * `organization_callable.ts` via `site_assignment_callable.ts`): an `admin`
 * (any organization), or a `siteManager` acting within an organization they
 * manage. A Worker or Foreman can never reach this callable at all, since
 * neither role satisfies that check — which is what makes "Workers/Foremen
 * cannot assign themselves" true structurally, before the explicit
 * self-assignment guard below even runs.
 *
 * THE VALIDATION CHAIN (this is the security core of the feature)
 *
 * 1. The activity must exist and belong to `organizationId` — fetched fresh,
 *    never trusted from the request payload.
 * 2. The target worker must hold a `users/{uid}/memberships/{organizationId}`
 *    document for the given organization — cross-organization assignment is
 *    refused. (Role/org relationship lives on the membership subcollection
 *    under the multi-organization model, not a scalar profile field.)
 * 3. That membership's own `siteIds` (an array, defaulting to empty) must
 *    already contain the activity's `siteId` — a worker cannot be assigned
 *    to an activity at a site they have no access to. This is the whole
 *    reason `site_assignment_callable.ts` exists as a prerequisite.
 * 4. The caller must not be assigning themselves (`request.auth.uid !==
 *    uid`) — checked explicitly as defense in depth, even though the role
 *    gate above already makes self-assignment unreachable for every
 *    non-admin role. This still stops an `admin` or `siteManager` from
 *    assigning themselves to an activity, which the task specification calls
 *    out as a case worth blocking outright rather than leaving to the role
 *    gate alone.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Assign a worker across organizations, or to an activity at a site the
 *   worker has no access to, or assign themselves — see the four checks
 *   above, every one of which is enforced here, not in `firestore.rules`.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`; every validation failure returns
 *   `failed-precondition` with a message describing which relationship
 *   failed, since those are ordinary data-integrity refusals rather than
 *   authorization probes.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {requireOrganizationScopedManager} from "./organization_callable";

/**
 * Reads and validates a required non-empty string argument. Duplicated from
 * `organization_callable.ts` — see `site_assignment_callable.ts`'s copy for
 * why.
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
 * Loads the target activity and confirms it belongs to [organizationId].
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} activityId the target activity's id.
 * @return {Promise<{siteId: string}>} the activity's `siteId`.
 */
async function requireActivityInOrganization(
  organizationId: string,
  activityId: string
): Promise<{ siteId: string }> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/activities/${activityId}`)
    .get();
  const activity = snapshot.data();
  if (!snapshot.exists || !activity) {
    throw new HttpsError("not-found", "That activity no longer exists.");
  }
  if (activity.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That activity does not belong to the given organization."
    );
  }
  const siteId = activity.siteId;
  if (typeof siteId !== "string" || !siteId) {
    throw new HttpsError(
      "failed-precondition",
      "That activity has no site."
    );
  }
  return {siteId};
}

/**
 * Loads the target worker's profile and MEMBERSHIP document for
 * [organizationId], and — for assignment only — confirms the membership's
 * `siteIds` already contains [siteId].
 *
 * `organizationId` and `siteIds` both moved off the top-level profile onto
 * `users/{uid}/memberships/{organizationId}` under the multi-organization
 * model — a worker's org membership and per-org site access are no longer
 * scalar profile fields, so this now checks the membership document's
 * existence (and its own `siteIds`) instead of a profile field comparison.
 *
 * @param {string} uid the target worker.
 * @param {string} organizationId the organization the action targets.
 * @param {string} siteId the activity's site, required to already be in the
 * worker's membership `siteIds` when [requireSiteAccess] is true.
 * @param {boolean} requireSiteAccess whether to enforce the site-membership
 * check (true for assignment, false for removal — a worker being removed
 * need not still have site access).
 * @return {Promise<void>} resolves when every check passes.
 */
async function requireWorkerEligible(
  uid: string,
  organizationId: string,
  siteId: string,
  requireSiteAccess: boolean
): Promise<void> {
  const userSnapshot = await getFirestore().doc(`users/${uid}`).get();
  if (!userSnapshot.exists) {
    throw new HttpsError("not-found", "That worker no longer exists.");
  }

  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) {
    throw new HttpsError(
      "failed-precondition",
      "That worker does not belong to the given organization."
    );
  }
  if (requireSiteAccess) {
    const siteIds: unknown = membership.siteIds;
    const hasSiteAccess = Array.isArray(siteIds) && siteIds.includes(siteId);
    if (!hasSiteAccess) {
      throw new HttpsError(
        "failed-precondition",
        "Worker is not assigned to this activity's site."
      );
    }
  }
}

/**
 * Assigns worker [uid] to [activityId] within [organizationId].
 *
 * See this file's header note for the full validation chain: organization
 * match, site-membership, and the explicit self-assignment guard, on top of
 * the `requireOrganizationScopedManager` role gate.
 */
export const assignWorkerToActivity = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const activityId = requireString(request, "activityId");

  // Explicit self-assignment guard — defense in depth on top of the role
  // gate above. See this file's header note for why this check exists even
  // though the role gate already makes self-assignment unreachable for
  // every non-admin caller.
  if (uid === actorUid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot assign yourself to an activity."
    );
  }

  const {siteId} = await requireActivityInOrganization(
    organizationId,
    activityId
  );
  await requireWorkerEligible(uid, organizationId, siteId, true);

  const assignmentPath =
    `organizations/${organizationId}/activities/${activityId}` +
    `/assignments/${uid}`;
  await getFirestore().doc(assignmentPath).set({
    uid,
    organizationId,
    siteId,
    activityId,
    assignedAt: FieldValue.serverTimestamp(),
    assignedBy: actorUid,
  });

  return {uid, organizationId, activityId, siteId};
});

/**
 * Removes worker [uid]'s assignment to [activityId] within
 * [organizationId].
 *
 * Site-membership is deliberately NOT re-checked here — removal must always
 * be possible regardless of the worker's current `siteIds` (e.g. after
 * `removeWorkerFromSite` has already withdrawn their site access, this is
 * exactly the cleanup path an administrator would use). The self-assignment
 * guard and organization check still apply.
 */
export const removeWorkerFromActivity = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const uid = requireString(request, "uid");
  const activityId = requireString(request, "activityId");

  if (uid === actorUid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot modify your own activity assignment."
    );
  }

  const {siteId} = await requireActivityInOrganization(
    organizationId,
    activityId
  );
  await requireWorkerEligible(uid, organizationId, siteId, false);

  const assignmentPath =
    `organizations/${organizationId}/activities/${activityId}` +
    `/assignments/${uid}`;
  await getFirestore().doc(assignmentPath).delete();

  return {uid, organizationId, activityId};
});
