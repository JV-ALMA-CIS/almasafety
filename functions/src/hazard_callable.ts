/**
 * Hazard Reporting callables for JVA Safety.
 *
 * Stores one document per hazard, FLAT at
 * `organizations/{orgId}/hazards/{id}` — a sibling of `corrective_actions`
 * and `daily_safety_meetings`, so an authorized reviewer's Hazards screen can
 * query every hazard across every site in one collection, and a worker's own
 * "My Reports" view is a query narrowed to `reportedByUid`, not a different
 * collection. `firestore.rules` denies every client write to that collection
 * outright, so these four callables are the only path that can create one or
 * transition its status. See FIRESTORE_DATA_MODEL.md §7 for the full field
 * list and lifecycle rationale.
 *
 * WORKFLOW: Report → Acknowledge → (Corrective Action | direct Close)
 *
 * Lifecycle: `reported -> acknowledged -> correctiveActionCreated -> closed`.
 * A hazard does NOT require a corrective action to close — an authorized
 * reviewer may close a hazard directly (no remediation needed, duplicate
 * report, already resolved by observation) from either `reported` or
 * `acknowledged`. Once `correctiveActionCreated`, the linked
 * `corrective_actions` document's own status is the authoritative
 * remediation-progress record; closing a hazard past that point happens by
 * completing the corrective action, not by calling `closeHazard` again.
 * `closed` is TERMINAL, mirroring `resolveSafetyAlert` and
 * `updateCorrectiveActionStatus`'s own completed-is-terminal guard.
 *
 * WHAT AUTHORIZES CREATION
 *
 * `requireReporterAtSite` (below, also used by `createIncident`): a Site
 * Manager/Admin may report at any site of their own organization (they
 * oversee every site and are rarely "assigned" to one); a Foreman/Worker —
 * including a contracted worker, whose site access is granted through the
 * same `assignWorkerToSite` mechanism — only at a site in their own
 * `siteIds`; the System Administrator anywhere. `projectId` is always looked
 * up server-side from the site document, never accepted from the request.
 * `reportedByUid` is always the caller's own uid, never a request argument.
 *
 * WHAT AUTHORIZES ACKNOWLEDGE / CLOSE
 *
 * `requireOrganizationScopedReviewer`, IMPORTED from
 * `corrective_action_callable.ts` rather than duplicated: the caller's own
 * stored profile must be `active` and hold a role for which
 * `canReviewPendingAccounts` is true (`admin`/`siteManager`), scoped to the
 * hazard's own `organizationId` for every role except `admin`. The
 * reporting worker cannot
 * acknowledge or close their own report by virtue of having filed it —
 * triage and closure are deliberately different authorities from reporting,
 * mirroring how the foreman who raises a meeting concern is not
 * automatically the one who signs off on its remediation.
 *
 * LINKING A CORRECTIVE ACTION
 *
 * `linkHazardCorrectiveAction` delegates entirely to
 * `corrective_action_callable.ts`'s exported
 * `createCorrectiveActionForHazard` — the SAME implementation
 * `createCorrectiveAction` itself calls when given a `hazardId` — so there is
 * exactly one place this write happens, reachable through either callable
 * name.
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Report a hazard for a site they do not have access to, or for an
 *   organization other than their own.
 * - Report a hazard as someone else — `reportedByUid` is never a request
 *   argument.
 * - Acknowledge, link a corrective action to, or close a hazard without an
 *   authorized reviewer role, or outside their own organization (system
 *   administrator excepted, as everywhere else in this codebase).
 * - Close an already-closed hazard, or acknowledge an already-closed one —
 *   `closed` is terminal.
 * - Link a second corrective action to a hazard that already has one, or to
 *   one that is already closed.
 * - Edit the original report content (`kind`/`category`/`description`/
 *   `location`/`photoUrl`) after creation — there is no update callable
 *   for those fields; only status-transition fields are ever written after
 *   creation.
 * - Delete a hazard — there is no delete callable, and `firestore.rules`
 *   denies every client write including delete. A hazard, like a corrective
 *   action, is a permanent part of the safety record once created.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";
import {
  createCorrectiveActionForHazard,
  requireOrganizationScopedReviewer,
} from "./corrective_action_callable";

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `corrective_action_callable.ts`.
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
 * Reads an optional, trimmed string argument, returning `null` when absent
 * or blank.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {string | null} the trimmed value, or `null`.
 */
function optionalString(
  request: CallableRequest,
  field: string
): string | null {
  const value = (request.data ?? {})[field];
  if (typeof value !== "string" || !value.trim()) return null;
  return value.trim();
}

const HAZARD_CATEGORIES = [
  "workingAtHeight",
  "electrical",
  "equipment",
  "ppe",
  "housekeeping",
  "environment",
  "chemical",
  "fire",
  "other",
] as const;
type HazardCategoryValue = (typeof HAZARD_CATEGORIES)[number];

/**
 * Validates and returns the `category` argument, refusing anything outside
 * the fixed set PROJECT_CONTEXT.md §24 defines.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {HazardCategoryValue} the validated category.
 */
function requireCategory(request: CallableRequest): HazardCategoryValue {
  const value = requireString(request, "category");
  if (!(HAZARD_CATEGORIES as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "category must be one of: " + HAZARD_CATEGORIES.join(", ")
    );
  }
  return value as HazardCategoryValue;
}

const HAZARD_KINDS = ["hazard", "nearMiss"] as const;
type HazardKindValue = (typeof HAZARD_KINDS)[number];

/**
 * Validates and returns the optional `kind` argument: whether this report is
 * a hazard (something COULD happen) or a near-miss (something NEARLY
 * happened). Defaults to `hazard` when absent, so an older app build that
 * never sends `kind` keeps working unchanged. A near-miss is a kind of
 * report, not a category — a near-miss at height is still `workingAtHeight`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {HazardKindValue} the validated kind.
 */
function requireKind(request: CallableRequest): HazardKindValue {
  const value = optionalString(request, "kind");
  if (value === null) return "hazard";
  if (!(HAZARD_KINDS as readonly string[]).includes(value)) {
    throw new HttpsError(
      "invalid-argument",
      "kind must be one of: " + HAZARD_KINDS.join(", ")
    );
  }
  return value as HazardKindValue;
}

/**
 * Loads the target hazard and confirms it belongs to [organizationId] —
 * re-fetched fresh, never trusted from the request payload. Mirrors
 * `requireOrganizationAlert` in `safety_alert_callable.ts`, applied to a
 * hazard instead of an alert.
 *
 * @param {string} organizationId the organization the action targets.
 * @param {string} hazardId the hazard's id.
 * @return {Promise<{ref: FirebaseFirestore.DocumentReference, data:
 * FirebaseFirestore.DocumentData}>} the validated hazard's reference and
 * stored data.
 */
async function requireOrganizationHazard(
  organizationId: string,
  hazardId: string
): Promise<{
  ref: FirebaseFirestore.DocumentReference;
  data: FirebaseFirestore.DocumentData;
}> {
  const ref = getFirestore().doc(
    `organizations/${organizationId}/hazards/${hazardId}`
  );
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) {
    throw new HttpsError("not-found", "That hazard no longer exists.");
  }
  if (data.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That hazard does not belong to the given organization."
    );
  }
  return {ref, data};
}

/**
 * Confirms the caller may file a report (hazard, near-miss or incident) at
 * [siteId] within [organizationId], returning their uid. Shared by
 * `createHazard` and `incident_callable.ts`'s `createIncident`.
 *
 * - The System Administrator (`platformRole == "admin"`) may report at any
 *   site of any organization.
 * - An org-wide role (`admin`/`siteManager` membership) may report at any
 *   site of their organization — they oversee every site, and are rarely
 *   "assigned" to one.
 * - Everyone else (`foreman`/`worker`) only at a site in their own
 *   `siteIds`.
 *
 * The site's existence within the organization is checked separately by
 * `requireSiteProjectId`. Every refusal is the same opaque
 * `permission-denied`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the report belongs to.
 * @param {string} siteId the site the report is filed against.
 * @return {Promise<string>} the caller's own uid.
 */
export async function requireReporterAtSite(
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
  if (profile.platformRole === "admin") return uid;

  const membershipSnapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (!membershipSnapshot.exists || !membership) throw denied();
  if (membership.status !== "active") throw denied();

  if (membership.role === "admin" || membership.role === "siteManager") {
    return uid;
  }
  const siteIds: unknown = membership.siteIds;
  if (!Array.isArray(siteIds) || !siteIds.includes(siteId)) throw denied();
  return uid;
}

/**
 * Looks up [siteId]'s own `projectId` within [organizationId] — re-fetched
 * fresh, never trusted from the request. A hazard has no parent meeting to
 * copy `projectId` from (unlike `corrective_actions`/`daily_safety_meetings`
 * originated from one), so it is derived here instead.
 *
 * @param {string} organizationId the organization the site belongs to.
 * @param {string} siteId the site's id.
 * @return {Promise<string>} the site's own `projectId`.
 */
async function requireSiteProjectId(
  organizationId: string,
  siteId: string
): Promise<string> {
  const snapshot = await getFirestore()
    .doc(`organizations/${organizationId}/sites/${siteId}`)
    .get();
  const site = snapshot.data();
  if (!snapshot.exists || !site) {
    throw new HttpsError("failed-precondition", "That site does not exist.");
  }
  if (site.organizationId !== organizationId) {
    throw new HttpsError(
      "failed-precondition",
      "That site does not belong to the given organization."
    );
  }
  return site.projectId as string;
}

/**
 * Reports a hazard at `organizations/{orgId}/hazards/{id}`.
 *
 * Authorized by `requireReporterAtSite`: a Site Manager/Admin at any site
 * of their organization, anyone else at a site in their own `siteIds`.
 * `reportedByUid` is always the caller's own uid.
 * `projectId` is always looked up server-side from the site document.
 *
 * `hazardId` is accepted as an argument (unlike most create callables in
 * this codebase, which let Firestore mint the id) so the client can
 * pre-allocate the id, upload an evidence photo to a path scoped to it, and
 * only then call this — see FIRESTORE_DATA_MODEL.md §7's "Photo-upload
 * sequencing" note. Creation fails if a document already exists at that id,
 * so a caller cannot use this to overwrite an existing hazard.
 */
export const createHazard = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const siteId = requireString(request, "siteId");
  const hazardId = requireString(request, "hazardId");
  const category = requireCategory(request);
  const kind = requireKind(request);
  const description = requireString(request, "description");
  const location = optionalString(request, "location");
  const photoUrl = optionalString(request, "photoUrl");

  const reporterId = await requireReporterAtSite(
    request,
    organizationId,
    siteId
  );
  const projectId = await requireSiteProjectId(organizationId, siteId);

  const ref = getFirestore().doc(
    `organizations/${organizationId}/hazards/${hazardId}`
  );
  const existing = await ref.get();
  if (existing.exists) {
    throw new HttpsError(
      "already-exists",
      "A hazard with that id already exists."
    );
  }

  const now = FieldValue.serverTimestamp();
  await ref.set({
    organizationId,
    projectId,
    siteId,
    reportedByUid: reporterId,
    kind,
    category,
    description,
    location,
    photoUrl,
    status: "reported",
    correctiveActionId: null,
    acknowledgedBy: null,
    acknowledgedAt: null,
    closedBy: null,
    closedAt: null,
    createdAt: now,
    createdBy: reporterId,
    updatedAt: now,
    updatedBy: reporterId,
  });

  return {id: hazardId, organizationId, status: "reported"};
});

/**
 * Acknowledges a reported hazard, moving it to `acknowledged`. Only an
 * authorized reviewer role within the hazard's own organization may call
 * this (see `requireOrganizationScopedReviewer`). Refuses when the hazard is
 * not currently `reported` — an already-acknowledged, already-actioned or
 * closed hazard cannot be re-acknowledged.
 */
export const acknowledgeHazard = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const hazardId = requireString(request, "hazardId");

  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  const {ref, data} = await requireOrganizationHazard(organizationId, hazardId);

  if (data.status !== "reported") {
    throw new HttpsError(
      "failed-precondition",
      "Only a newly reported hazard can be acknowledged."
    );
  }

  await ref.update({
    status: "acknowledged",
    acknowledgedAt: FieldValue.serverTimestamp(),
    acknowledgedBy: uid,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: uid,
  });

  return {id: hazardId, organizationId, status: "acknowledged"};
});

/**
 * Creates a corrective action from a hazard, linking the two. Thin wrapper
 * around `corrective_action_callable.ts`'s exported
 * `createCorrectiveActionForHazard` — the SAME implementation
 * `createCorrectiveAction` calls when given a `hazardId`, so there is
 * exactly one place this write happens. See that function's doc comment for
 * the full authorization and validation chain.
 */
export const linkHazardCorrectiveAction = onCall(async (request) => {
  return createCorrectiveActionForHazard(request);
});

/**
 * Closes a hazard directly, moving it to `closed` — a terminal state. Only
 * an authorized reviewer role within the hazard's own organization may call
 * this (see `requireOrganizationScopedReviewer`). Used when no remediation
 * is warranted (duplicate report, already resolved by observation); a hazard
 * that already has a linked corrective action is closed by completing that
 * action instead, not by calling this again. Refuses an already-closed
 * hazard: closure is one-way, matching every other terminal status in this
 * codebase (e.g. a resolved `SafetyAlert`, a completed `CorrectiveAction`).
 */
export const closeHazard = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const hazardId = requireString(request, "hazardId");

  const uid = await requireOrganizationScopedReviewer(request, organizationId);
  const {ref, data} = await requireOrganizationHazard(organizationId, hazardId);

  if (data.status === "closed") {
    throw new HttpsError(
      "failed-precondition",
      "That hazard has already been closed."
    );
  }
  if (data.status === "correctiveActionCreated") {
    throw new HttpsError(
      "failed-precondition",
      "That hazard already has a corrective action in progress; close it " +
        "by completing the corrective action instead."
    );
  }

  await ref.update({
    status: "closed",
    closedAt: FieldValue.serverTimestamp(),
    closedBy: uid,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: uid,
  });

  return {id: hazardId, organizationId, status: "closed"};
});
