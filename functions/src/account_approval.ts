/**
 * Account approval for JVA Safety.
 *
 * The self-registration model leaves exactly one privileged operation:
 * moving an account out of `pending`. This module is the only trusted path
 * for it. It runs with the Admin SDK (which bypasses Firestore security
 * rules), so it is also the only code that can write `accountStatus`,
 * `approvedAt`, `approvedBy`, `platformRole`, or a
 * `users/{uid}/memberships/{organizationId}` document at all — the rules
 * deny all of those to every client.
 *
 * MULTI-ORGANIZATION MEMBERSHIP MODEL. A person's relationship to a specific
 * organization — role, workerType, trade, siteIds, supervisorUid, and a
 * per-org `active`/`suspended` status — lives on
 * `users/{uid}/memberships/{organizationId}`, not on the top-level profile,
 * because a Site Manager/Foreman may belong to more than one organization.
 * `accountStatus` on the top-level profile stays a single, ACCOUNT-level
 * field: it is set once, at a person's first-ever approval, and gates
 * sign-in/app access globally regardless of how many organizations they
 * later join. [approveAccount] therefore does two things atomically on first
 * approval: activates the account AND creates its first membership document.
 * A later placement into a second organization is [addMembership] instead —
 * it creates one more membership document and touches nothing else.
 *
 * These are plain functions with NO caller authorization of their own — they
 * assume the caller has already been authorized. There are exactly two
 * callers, each supplying its own gate:
 *
 *  - `scripts/approve_account.ts`, where possession of service-account
 *    credentials is the check. This remains the only path that can create
 *    the first Admin (PROJECT_CONTEXT.md §18).
 *  - `approval_callable.ts`, whose `onCall` wrappers verify the caller's
 *    [AppRole] and organization/site scope server-side before delegating
 *    here, following the approval HIERARCHY documented on [grantableRoles]
 *    below.
 *
 * Do not add a third caller without an explicit gate in front of it. The
 * business logic below trusts its arguments completely: `organizationId`,
 * `role`, `workerType` and `approvedBy` are written as given.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {getAuth} from "firebase-admin/auth";

/** The four values of the authoritative account-state field. */
export const ACCOUNT_STATUSES = [
  "pending",
  "active",
  "suspended",
  "rejected",
] as const;

export type AccountStatus = (typeof ACCOUNT_STATUSES)[number];

/**
 * Validates an untrusted account status value.
 *
 * @param {unknown} value the candidate value.
 * @return {boolean} true when it is one of the four known statuses.
 */
export function isAccountStatus(value: unknown): value is AccountStatus {
  return typeof value === "string" &&
    (ACCOUNT_STATUSES as readonly string[]).includes(value);
}

/**
 * The four platform authorization roles (PROJECT_CONTEXT.md §12-19),
 * mirroring `lib/features/authentication/domain/app_role.dart` and stored on
 * `users/{uid}.platformRole`. Keep the two lists in sync — this is the
 * server-side source of truth for what is a valid role.
 *
 * This is a migration down from an earlier 7-value model
 * (`systemAdministrator` / `organizationAdministrator` / `safetyManager` /
 * `siteSuperintendent` / `siteSupervisor` / `foreman` / `worker`):
 * `systemAdministrator` -> `admin`; `organizationAdministrator` /
 * `safetyManager` / `siteSuperintendent` -> `siteManager` (with the
 * platform-level pieces of the old `organizationAdministrator` — Safety
 * Learning/Meeting Point library management, org-wide oversight — moved to
 * `admin` instead); `siteSupervisor` merged into `foreman`.
 *
 * `admin` is platform-level, not organization-scoped — see that role's
 * documentation in the Flutter source. It is never reachable through
 * registration or the in-app review callables; only
 * `scripts/approve_account.ts`'s `bootstrap-admin` command, gated on
 * possession of service-account credentials, can grant it.
 */
export const APP_ROLES = [
  "admin",
  "siteManager",
  "foreman",
  "worker",
] as const;

export type AppRole = (typeof APP_ROLES)[number];

/** Roles authorized to review pending accounts and assign role/org/type. */
const REVIEWER_ROLES: readonly AppRole[] = [
  "admin",
  "siteManager",
  "foreman",
];

/**
 * Validates an untrusted role value.
 *
 * @param {unknown} value the candidate value.
 * @return {boolean} true when it is one of the known roles.
 */
export function isAppRole(value: unknown): value is AppRole {
  return typeof value === "string" &&
    (APP_ROLES as readonly string[]).includes(value);
}

/**
 * Whether [role] may review pending accounts. Mirrors
 * `AppRole.canReviewPendingAccounts` in the Flutter client.
 *
 * This says only that the role FAMILY is capable of reviewing at all — the
 * actual approval HIERARCHY (who may grant which specific role to whom, and
 * within what organization/site scope) is enforced by [grantableRoles] and
 * the scope checks in `approval_callable.ts`, not by this flag.
 *
 * @param {AppRole} role the role to check.
 * @return {boolean} true when the role is one of the reviewer roles.
 */
export function canReviewPendingAccounts(role: AppRole): boolean {
  return REVIEWER_ROLES.includes(role);
}

/**
 * The APPROVAL HIERARCHY (PROJECT_CONTEXT.md §16): the roles a reviewer of
 * [reviewerRole] may grant to a pending or existing account.
 *
 *  - `admin` may grant `siteManager` (or reinstate any role — see
 *    `approval_callable.ts`'s reinstatement path, which does not call this
 *    function since it does not change the role). `admin` may NOT grant
 *    `admin` itself: that role remains reachable only through the operator
 *    script's `bootstrap-admin` command, so review — an in-app, callable
 *    action — can never mint a second Admin no matter who calls it.
 *  - `siteManager` may grant `foreman` only, within the organization(s) they
 *    manage.
 *  - `foreman` may grant `worker` only, within their own assigned site(s).
 *  - `worker` may grant nothing: it is not a reviewer role at all.
 *
 * No reviewer may ever grant a role equal to or above their own — this
 * table encodes that directly: no entry lists its own key or anything
 * "above" it. This is the server-side enforcement of "no self-escalation"
 * and "no minting a peer or superior" from PROJECT_CONTEXT.md §17/§41.
 *
 * @param {AppRole} reviewerRole the reviewing caller's own role.
 * @return {AppRole[]} the roles that reviewer may assign.
 */
export function grantableRoles(reviewerRole: AppRole): readonly AppRole[] {
  switch (reviewerRole) {
  case "admin":
    return ["siteManager"];
  case "siteManager":
    return ["foreman"];
  case "foreman":
    return ["worker"];
  case "worker":
    return [];
  }
}

/** The four workforce-type values. Carries no authorization weight. */
export const WORKER_TYPES = [
  "jva_employee",
  "contractor",
  "subcontractor",
  "other",
] as const;

export type WorkerTypeValue = (typeof WORKER_TYPES)[number];

/**
 * Validates an untrusted worker-type value.
 *
 * @param {unknown} value the candidate value.
 * @return {boolean} true when it is one of the known worker types.
 */
export function isWorkerType(value: unknown): value is WorkerTypeValue {
  return typeof value === "string" &&
    (WORKER_TYPES as readonly string[]).includes(value);
}

/**
 * Writes an append-only record of a privileged account change.
 *
 * @param {object} entry the audit entry to record.
 * @return {Promise<void>} resolves once the log is written.
 */
async function writeAuditLog(entry: {
  organizationId: string | null;
  actorUid: string;
  action: string;
  targetDocId: string;
  metadata: Record<string, unknown>;
}): Promise<void> {
  await getFirestore().collection("audit_logs").add({
    ...entry,
    targetCollection: "users",
    createdAt: FieldValue.serverTimestamp(),
  });
}

/**
 * Approves a pending account: activates it (account-level, once, forever)
 * and — except for an `admin` approving a `siteManager` with no organization
 * yet — creates its first `users/{uid}/memberships/{organizationId}`
 * document with the given role/workerType/trade/siteIds/supervisorUid.
 * `platformRole` is set on the profile only for `admin`-family grants that
 * carry no per-org role (in practice this module never writes `admin` here —
 * see the header note — but the field is retained on the profile for the
 * `admin` bootstrap script's own use of `approveAccount`-adjacent logic;
 * ordinary role grants live entirely on the membership document instead).
 *
 * Both writes happen in the same batch, so a reader can never observe an
 * account that is `active` but has no membership yet (other than the
 * org-less Admin/siteManager-with-no-org-yet cases, which are the documented
 * exceptions).
 *
 * Refuses any account that is not currently `pending`, so this cannot be
 * used to silently re-home an already-active user into another organization
 * or change their role — that would be a separate, explicitly-audited
 * operation ([addMembership]).
 *
 * @param {object} params the approval parameters.
 * @param {string} params.uid the account being approved.
 * @param {string | null} params.organizationId the organization to place
 * them into, or null (only valid for an admin approving a siteManager).
 * @param {AppRole} params.role the role to assign.
 * @param {WorkerTypeValue | null} params.workerType the worker type to
 * assign, or null when none applies.
 * @param {string | null} params.trade the trade to assign, or null.
 * @param {string[]} params.siteIds the site(s) to grant, if any.
 * @param {string | null} params.supervisorUid the assigned supervisor, or
 * null.
 * @param {string} params.approvedBy uid of the approving authority.
 * @return {Promise<void>} resolves once the account is active.
 */
export async function approveAccount(params: {
  uid: string;
  organizationId: string | null;
  role: AppRole;
  workerType: WorkerTypeValue | null;
  trade?: string | null;
  siteIds?: string[];
  supervisorUid?: string | null;
  approvedBy: string;
}): Promise<void> {
  const {
    uid, organizationId, role, workerType, approvedBy,
    trade = null, siteIds = [], supervisorUid = null,
  } = params;
  // organizationId is required for every grant EXCEPT admin approving
  // siteManager: an Admin in the office approving a colleague they know by
  // name has no way to know which of possibly several organizations that
  // Site Manager operates in — see PROJECT_CONTEXT.md §12/§16/§18. The new
  // Site Manager instead creates (or is later assigned into) their own
  // organization via `createOrganization`, which creates their first
  // membership document at that point. Every other grant (siteManager
  // approving foreman, foreman approving worker) still requires one, since
  // those reviewers are already scoped to a real organization themselves.
  if (!organizationId && role !== "siteManager") {
    throw new Error("organizationId is required to approve an account.");
  }

  const ref = getFirestore().doc(`users/${uid}`);
  const snapshot = await ref.get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new Error(`No profile found for uid ${uid}.`);
  }
  if (profile.accountStatus !== "pending") {
    throw new Error(
      `Account ${uid} is "${profile.accountStatus}", not "pending".`
    );
  }

  const batch = getFirestore().batch();
  batch.update(ref, {
    accountStatus: "active",
    approvedAt: FieldValue.serverTimestamp(),
    approvedBy,
    updatedAt: FieldValue.serverTimestamp(),
    // The one case with no membership document to carry a role at all: an
    // admin approving a siteManager with no organization yet (see this
    // function's own org-required check above). Without SOME marker, this
    // account would be active but authorization-invisible — able to reach
    // no organization-scoped callable, including createOrganization itself,
    // which is exactly what it needs to call next. platformRole (otherwise
    // reserved for `admin`) carries that one narrow signal here; it is
    // overwritten/ignored the moment a real membership exists — see
    // `createOrganization` and `requireActiveCaller` in
    // `organization_callable.ts`, the only readers of this value for a
    // non-admin account.
    ...(!organizationId && role === "siteManager" ?
      {platformRole: "siteManager"} :
      {}),
  });

  if (organizationId) {
    const membershipRef = ref.collection("memberships").doc(organizationId);
    batch.set(membershipRef, {
      organizationId,
      role,
      workerType: workerType ?? null,
      trade: trade ?? null,
      siteIds: siteIds ?? [],
      supervisorUid: supervisorUid ?? null,
      status: "active",
      approvedAt: FieldValue.serverTimestamp(),
      approvedBy,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();

  await writeAuditLog({
    organizationId: organizationId ?? null,
    actorUid: approvedBy,
    action: "account.approved",
    targetDocId: uid,
    metadata: {organizationId: organizationId ?? null, role, workerType},
  });
}

/**
 * Places an already-ACTIVE account into an additional organization: creates
 * one more `users/{uid}/memberships/{organizationId}` document without
 * touching `accountStatus` or any of the person's other memberships.
 *
 * This is the multi-organization counterpart to the membership half of
 * [approveAccount] — used once a person already has an account (and, for a
 * Site Manager/Foreman, likely already at least one membership) and is being
 * placed into one more organization.
 *
 * Refuses if a membership already exists for this uid+organizationId, so a
 * reviewer cannot silently overwrite an existing membership's role/status
 * through this path — see `approval_callable.ts`'s `addOrganizationMembership`
 * for the caller-facing `already-exists` refusal built on this check.
 *
 * @param {object} params the placement parameters.
 * @param {string} params.uid the account being placed.
 * @param {string} params.organizationId the organization to place them into.
 * @param {AppRole} params.role the role to assign within that organization.
 * @param {WorkerTypeValue | null} params.workerType the worker type, or
 * null.
 * @param {string | null} params.trade the trade, or null.
 * @param {string[]} params.siteIds the site(s) to grant, if any.
 * @param {string | null} params.supervisorUid the assigned supervisor, or
 * null.
 * @param {string} params.approvedBy uid of the approving authority.
 * @return {Promise<void>} resolves once the membership exists.
 */
export async function addMembership(params: {
  uid: string;
  organizationId: string;
  role: AppRole;
  workerType: WorkerTypeValue | null;
  trade?: string | null;
  siteIds?: string[];
  supervisorUid?: string | null;
  approvedBy: string;
}): Promise<void> {
  const {
    uid, organizationId, role, workerType, approvedBy,
    trade = null, siteIds = [], supervisorUid = null,
  } = params;

  const userRef = getFirestore().doc(`users/${uid}`);
  const userSnapshot = await userRef.get();
  const profile = userSnapshot.data();
  if (!userSnapshot.exists || !profile) {
    throw new Error(`No profile found for uid ${uid}.`);
  }
  if (profile.accountStatus !== "active") {
    throw new Error(`Account ${uid} is not active.`);
  }

  const membershipRef = userRef.collection("memberships").doc(organizationId);
  const membershipSnapshot = await membershipRef.get();
  if (membershipSnapshot.exists) {
    throw new Error(
      `Account ${uid} already has a membership in ${organizationId}.`
    );
  }

  await membershipRef.set({
    organizationId,
    role,
    workerType: workerType ?? null,
    trade: trade ?? null,
    siteIds: siteIds ?? [],
    supervisorUid: supervisorUid ?? null,
    status: "active",
    approvedAt: FieldValue.serverTimestamp(),
    approvedBy,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  await writeAuditLog({
    organizationId,
    actorUid: approvedBy,
    action: "membership.added",
    targetDocId: uid,
    metadata: {organizationId, role, workerType},
  });
}

/**
 * Sets an account to `rejected` or `suspended`.
 *
 * The Firebase Auth account is disabled alongside the status so an existing
 * session cannot keep refreshing its token. The profile document is retained
 * rather than deleted, so historical safety records keep referring to a real
 * user.
 *
 * @param {object} params the denial parameters.
 * @param {string} params.uid the account being denied.
 * @param {AccountStatus} params.status either "rejected" or "suspended".
 * @param {string} params.actorUid uid of the deciding authority.
 * @return {Promise<void>} resolves once the account is denied.
 */
export async function denyAccount(params: {
  uid: string;
  status: Extract<AccountStatus, "rejected" | "suspended">;
  actorUid: string;
}): Promise<void> {
  const {uid, status, actorUid} = params;
  if (status !== "rejected" && status !== "suspended") {
    throw new Error(`"${status}" is not a denial status.`);
  }

  const ref = getFirestore().doc(`users/${uid}`);
  const snapshot = await ref.get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new Error(`No profile found for uid ${uid}.`);
  }

  await getAuth().updateUser(uid, {disabled: true});
  await ref.update({
    accountStatus: status,
    updatedAt: FieldValue.serverTimestamp(),
  });

  // organizationId is no longer a single scalar on the profile — this is an
  // ACCOUNT-level action (accountStatus), not scoped to one organization, so
  // the audit entry carries no organizationId. A person's memberships are
  // untouched by account-level suspension/rejection; see `suspendMembership`
  // in `approval_callable.ts` for the per-membership equivalent.
  await writeAuditLog({
    organizationId: null,
    actorUid,
    action: `account.${status}`,
    targetDocId: uid,
    metadata: {from: profile.accountStatus, to: status},
  });
}

/**
 * Restores a suspended account to `active`.
 *
 * @param {object} params the reinstatement parameters.
 * @param {string} params.uid the account being reinstated.
 * @param {string} params.actorUid uid of the deciding authority.
 * @return {Promise<void>} resolves once the account is active again.
 */
export async function reinstateAccount(params: {
  uid: string;
  actorUid: string;
}): Promise<void> {
  const {uid, actorUid} = params;

  const ref = getFirestore().doc(`users/${uid}`);
  const snapshot = await ref.get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new Error(`No profile found for uid ${uid}.`);
  }
  if (profile.accountStatus !== "suspended") {
    throw new Error(`Account ${uid} is not suspended.`);
  }

  await getAuth().updateUser(uid, {disabled: false});
  await ref.update({
    accountStatus: "active",
    updatedAt: FieldValue.serverTimestamp(),
  });

  // Account-level, like denyAccount above: no single organizationId to
  // attribute this to any more. Reinstating the account does not touch any
  // individual membership's own `status` — see `reinstateMembership`.
  await writeAuditLog({
    organizationId: null,
    actorUid,
    action: "account.reinstated",
    targetDocId: uid,
    metadata: {},
  });
}
