/**
 * In-app account approval callables for JVA Safety.
 *
 * These are the callable front door to the privileged operations in
 * `account_approval.ts`. Until now the only way to approve an account was to
 * run `scripts/approve_account.ts` with service-account credentials, which
 * meant only the developer could approve anyone — too much friction for
 * ongoing use.
 *
 * Nine callables in total: `listPendingApprovals` / `approvePendingAccount` /
 * `rejectPendingAccount` review the pending queue; `listOrganizationUsers` /
 * `suspendActiveAccount` / `reinstateSuspendedAccount` manage the ACCOUNT
 * level for users who have already been reviewed (the Active Users and
 * Suspended/Rejected Users lists); `suspendMembership` / `reinstateMembership`
 * manage one MEMBERSHIP's own status, independent of the account and of the
 * person's other memberships; `addOrganizationMembership` places an
 * already-active user into an additional organization. Every one of them
 * funnels through `requireApprover`, so the authorization boundary below
 * applies to all of them identically.
 *
 * MULTI-ORGANIZATION MEMBERSHIP MODEL
 *
 * A person's relationship to a given organization — role, workerType, trade,
 * siteIds, supervisorUid, and a per-org `active`/`suspended` status — lives
 * on `users/{uid}/memberships/{organizationId}`, not as scalar fields on the
 * profile, because a Site Manager or Foreman may hold more than one
 * membership at once. `accountStatus` on the profile stays the single,
 * ACCOUNT-level gate, set once at a person's first-ever approval alongside
 * their first membership document (`approveAccount` in
 * `account_approval.ts`). Because a `siteManager`/`foreman` reviewer may
 * themselves hold more than one membership, "the organization this reviewer
 * acts in" can no longer be read off a single profile field: every callable
 * here that acts within an organization requires an explicit
 * `organizationId` argument from such a reviewer, and [requireApprover]
 * verifies server-side that the caller holds an ACTIVE membership in that
 * specific organization with a role authorized for the action. `admin` is
 * unaffected — still organization-less, still "any organization, always
 * explicit" — no behavior change for Admin.
 *
 * THE APPROVAL HIERARCHY (PROJECT_CONTEXT.md §16)
 *
 * The caller's own role — `platformRole` on the profile for `admin`, or the
 * `role` on their membership document for the organization named by the
 * request otherwise (see [Approver]/[requireApprover]):
 *
 *  - `admin` may approve/assign `siteManager` (or reinstate any account) for
 *    anyone, in any organization.
 *  - `siteManager` may approve/assign `foreman` only, within the
 *    organization(s) they manage — see `organizations/{orgId}.managedBy` in
 *    `organization_callable.ts`, plus any organization they hold an active
 *    `siteManager` membership in.
 *  - `foreman` may approve/assign `worker` only, within their own assigned
 *    site(s) in the organization they are acting within (their membership's
 *    own `siteIds` intersecting the target's assigned site).
 *  - `worker` has no review authority at all.
 *
 * No one may grant a role equal to or above their own — see `grantableRoles`
 * in `account_approval.ts`, which encodes this directly: there is no entry
 * that lists its own role or anything above it.
 *
 * `admin` is the one platform-level exception to "organization-scoped
 * reviewer": it has no membership of its own to default to. When granting
 * `siteManager` (the only role an admin ever grants), `organizationId` is
 * OPTIONAL — an Admin approving a colleague they know by name typically has
 * no way to know which of possibly several organizations that person
 * operates in, so the new Site Manager is approved with no organization yet
 * and creates (or is assigned into) one afterward via `createOrganization`,
 * which creates their first membership document at that point
 * (PROJECT_CONTEXT.md §12/§16/§18). Admin MAY still supply `organizationId`
 * explicitly if they do know it (e.g. approving into an organization that
 * already exists). Every other reviewer role has its acting organization
 * resolved from an explicit `organizationId` request argument, verified
 * against a real active membership — never assumed from a stored scalar.
 *
 * WHY THE CHECK LIVES HERE AND NOT IN firestore.rules
 *
 * Approval is not a single field write — it is a conditional multi-document
 * transition (verify the target is pending, create their first membership
 * document alongside activating the profile, stamp the audit trail, disable
 * the Auth account on rejection) with an audit-log write beside it.
 * Expressing that in the rules language would mean a second, independent
 * implementation of the same authorization decision that could silently
 * drift from this one. Instead, `firestore.rules` continues to deny every
 * client write to `accountStatus`, `platformRole`, and anything under
 * `users/{uid}/memberships/{organizationId}` outright, and these callables —
 * which run on the Admin SDK and so bypass rules — are the only path
 * through.
 *
 * WHAT A REVIEWER CANNOT DO
 *
 * - Approve into, or act within, any organization other than one they
 *   actually manage/hold an authorized ACTIVE membership in — unless they
 *   are `admin`, the one role with no "own organization" to restrict them
 *   to. A `siteManager`'s managed organizations are read from `organizations`
 *   records they manage (`managedBy` array — see `organization_callable.ts`)
 *   PLUS their own active `siteManager` memberships, never from the request
 *   payload alone.
 * - Act on their own account: the target uid is compared against the
 *   caller's uid and refused if equal, before anything else runs. This is
 *   the only path in the app that can change `accountStatus`, create a
 *   membership, or toggle a membership's `status`, so this one check is what
 *   makes "cannot approve, reject, suspend, or activate yourself, and cannot
 *   change your own role or organization" true everywhere — including for
 *   the Admin.
 * - Grant a role they could not themselves hold as a reviewer. See
 *   `grantableRoles` in `account_approval.ts`.
 * - Act on an account that is not `pending` through the three review
 *   callables: re-homing an already-active user into another organization is
 *   [addOrganizationMembership] instead, and resurrecting a rejected account
 *   is not reachable from any of them.
 * - Suspend, reinstate, or list a user outside their own acting
 *   organization's scope — enforced by
 *   `requireSameOrganizationMembershipTarget` for the ACCOUNT-level
 *   callables (`listOrganizationUsers`, `suspendActiveAccount`,
 *   `reinstateSuspendedAccount`) and equivalently within
 *   `membershipStatusCallable`/`addOrganizationMembership` for the
 *   MEMBERSHIP-level ones. `admin` is exempt, as everywhere else.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {HttpsError, CallableRequest, onCall} from "firebase-functions/v2/https";
import {
  AccountStatus,
  AppRole,
  WorkerTypeValue,
  addMembership,
  approveAccount,
  canReviewPendingAccounts,
  denyAccount,
  grantableRoles,
  isAppRole,
  isWorkerType,
  reinstateAccount,
} from "./account_approval";

/**
 * The single refusal returned for every authorization failure.
 *
 * Deliberately one shared, contentless error: distinguishing "you are not an
 * approver" from "your account is not active" from "you have no organization"
 * would tell an unauthorized caller which condition to attack next.
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
 * An authorized approver: their uid, role, and the ONE organization they are
 * acting within for this call.
 *
 * `organizationId` is null only for `admin`, who has no fixed organization
 * of their own — see [resolveTargetOrganization], the only place that reads
 * a caller-supplied organization at all, and only for this one role. For a
 * `siteManager`/`foreman` — who may hold several memberships — this is NOT
 * simply "their org": it is the specific organization named by the request's
 * `organizationId` argument, verified to be one they hold an ACTIVE,
 * authorized-role membership in (see [requireApprover]). A caller with two
 * memberships must therefore say which one they are acting in for every
 * call; there is no implicit "the" organization for them any more.
 *
 * `siteIds` is populated only for a `foreman` approver, whose approval
 * authority (granting `worker`) is scoped to their own assigned site(s)
 * within THIS organization rather than their whole organization — see
 * [requireApprover] and [requireGrantWithinScope].
 */
interface Approver {
  uid: string;
  role: AppRole;
  organizationId: string | null;
  siteIds: string[];
}

/**
 * Reads and validates the `organizationId` argument required of any
 * `siteManager`/`foreman` caller (who may hold several memberships and so
 * must say which organization they are acting in). Not used for `admin`,
 * who is org-less by construction — see [resolveTargetOrganization].
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {string} the requested organization id.
 */
function requireRequestOrganizationId(request: CallableRequest): string {
  const organizationId = (request.data ?? {}).organizationId;
  if (typeof organizationId !== "string" || !organizationId) {
    throw new HttpsError(
      "invalid-argument",
      "organizationId is required."
    );
  }
  return organizationId;
}

/**
 * Loads the caller's own membership document for [organizationId], or null
 * if none exists.
 *
 * @param {string} uid the caller's own uid.
 * @param {string} organizationId the organization to check.
 * @return {Promise<Record<string, unknown> | null>} the membership data, or
 * null.
 */
async function loadOwnMembership(
  uid: string,
  organizationId: string
): Promise<Record<string, unknown> | null> {
  const snapshot = await getFirestore()
    .doc(`users/${uid}/memberships/${organizationId}`)
    .get();
  const data = snapshot.data();
  return snapshot.exists && data ? data : null;
}

/**
 * Resolves the organization(s) a `siteManager` approver manages, for
 * confining their review authority. A `siteManager` manages every
 * organization whose `organizations/{orgId}.managedBy` array contains their
 * uid, PLUS every organization they hold an active `siteManager` membership
 * in (covering a `siteManager` who was approved into an organization someone
 * else created, e.g. by an `admin`, rather than one they created themselves
 * via `createOrganization`).
 *
 * @param {string} uid the site manager's own uid.
 * @return {Promise<string[]>} the organization ids they manage.
 */
async function resolveManagedOrganizationIds(uid: string): Promise<string[]> {
  const [orgSnapshot, membershipSnapshot] = await Promise.all([
    getFirestore()
      .collection("organizations")
      .where("managedBy", "array-contains", uid)
      .get(),
    getFirestore()
      .collection(`users/${uid}/memberships`)
      .where("role", "==", "siteManager")
      .where("status", "==", "active")
      .get(),
  ]);
  const managed = new Set(orgSnapshot.docs.map((doc) => doc.id));
  membershipSnapshot.docs.forEach((doc) => managed.add(doc.id));
  return Array.from(managed);
}

/**
 * Authorizes the caller as an approver acting within a specific
 * organization, or throws.
 *
 * Every condition is checked server-side against the caller's own stored
 * profile and membership documents — nothing here trusts the request
 * payload or the client's session state, except for WHICH organization a
 * multi-membership caller (`siteManager`/`foreman`) intends to act in, which
 * is necessarily a request argument now that a caller may hold several. That
 * argument is never trusted blindly: it is used only to look up the
 * caller's OWN membership document, and the call is refused unless that
 * membership is `active` and its `role` is one authorized to review pending
 * accounts.
 *
 * `admin` is exempt from the organization argument entirely — it is not
 * scoped to any organization to begin with, and [resolveTargetOrganization]
 * is the only place its own, separate, optional `organizationId` is
 * consulted.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Promise<Approver>} the authorized caller's uid, role and scope.
 */
async function requireApprover(request: CallableRequest): Promise<Approver> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  if (profile.platformRole === "admin") {
    return {uid, role: "admin", organizationId: null, siteIds: []};
  }

  const organizationId = requireRequestOrganizationId(request);
  const membership = await loadOwnMembership(uid, organizationId);
  if (!membership) throw denied();
  if (membership.status !== "active") throw denied();

  const role = membership.role;
  if (!isAppRole(role) || !canReviewPendingAccounts(role)) throw denied();

  const siteIds: string[] = Array.isArray(membership.siteIds) ?
    membership.siteIds.filter(
      (id: unknown): id is string => typeof id === "string"
    ) :
    [];

  return {uid, role, organizationId, siteIds};
}

/**
 * Resolves the organization an approval targets, or null.
 *
 * For a `siteManager`/`foreman` reviewer, this is always the organization
 * they authenticated as an approver for (see [requireApprover]) — the same
 * value, never re-read from the request a second time, so there is no
 * opportunity for the organization checked at authorization time to differ
 * from the one written. `admin` has no organization of its own; it MAY
 * supply `organizationId` explicitly (e.g. to stand up a brand-new
 * organization's first Site Manager by naming an id that does not exist yet
 * — `approveAccount` creates the membership document with no separate
 * organization document required), but for a `siteManager` grant it is NOT
 * required: an Admin approving a colleague they know by name typically has
 * no way to know which organization that person will operate in — the
 * organization is the Site Manager's own to create afterward via
 * `createOrganization`, not the Admin's to guess (PROJECT_CONTEXT.md
 * §12/§16/§18). Every other grant (`foreman`, `worker`) still requires an
 * organization, since only `admin` is ever org-less.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {Approver} approver the authorized, reviewing caller.
 * @param {AppRole} role the role being granted.
 * @return {string | null} the organization to assign, or null.
 */
function resolveTargetOrganization(
  request: CallableRequest,
  approver: Approver,
  role: AppRole
): string | null {
  if (approver.organizationId !== null) return approver.organizationId;

  const organizationId = (request.data ?? {}).organizationId;
  if (typeof organizationId === "string" && organizationId) {
    return organizationId;
  }
  if (role === "siteManager") return null;
  throw new HttpsError(
    "invalid-argument",
    "organizationId is required."
  );
}

/**
 * Reads and validates the `role` argument of the approval callable.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {Approver} approver the authorized, reviewing caller.
 * @return {AppRole} the validated role to assign.
 */
function targetRole(request: CallableRequest, approver: Approver): AppRole {
  const role = (request.data ?? {}).role;
  if (!isAppRole(role)) {
    throw new HttpsError("invalid-argument", "A valid role is required.");
  }
  if (!grantableRoles(approver.role).includes(role)) {
    // Same opaque refusal as every other authorization failure — a caller
    // attempting to escalate learns nothing about which roles it may grant.
    throw denied();
  }
  return role;
}

/**
 * Reads and validates the optional `workerType` argument of the approval
 * callable.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {WorkerTypeValue | null} the validated worker type, or null.
 */
function targetWorkerType(request: CallableRequest): WorkerTypeValue | null {
  const workerType = (request.data ?? {}).workerType;
  if (workerType === undefined || workerType === null) return null;
  if (!isWorkerType(workerType)) {
    throw new HttpsError("invalid-argument", "workerType is not recognised.");
  }
  return workerType;
}

/**
 * Reads and validates the optional `siteIds` argument, used when granting a
 * `worker` (or, incidentally, harmlessly ignored for other roles). Defaults
 * to an empty array.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {string[]} the validated site ids.
 */
function requestSiteIds(request: CallableRequest): string[] {
  const siteIds = (request.data ?? {}).siteIds;
  if (siteIds === undefined) return [];
  if (
    !Array.isArray(siteIds) ||
    !siteIds.every((id) => typeof id === "string" && id)
  ) {
    throw new HttpsError(
      "invalid-argument",
      "siteIds must be an array of ids."
    );
  }
  return siteIds;
}

/**
 * Reads and validates the `uid` argument of a decision callable.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {string} the target uid.
 */
function targetUid(request: CallableRequest): string {
  const uid = (request.data ?? {}).uid;
  if (typeof uid !== "string" || !uid) {
    throw new HttpsError("invalid-argument", "A user id is required.");
  }
  return uid;
}

/**
 * Reads and validates the optional `accountStatus` argument of
 * `listOrganizationUsers`. Defaults to `"active"` — the common case — and
 * refuses `"pending"`, which is served by `listPendingApprovals` instead.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Exclude<AccountStatus, "pending">} the validated status to list.
 */
function targetListStatus(
  request: CallableRequest
): Exclude<AccountStatus, "pending"> {
  const status = (request.data ?? {}).accountStatus;
  if (status === undefined) return "active";
  if (status === "active" || status === "suspended" || status === "rejected") {
    return status;
  }
  throw new HttpsError(
    "invalid-argument",
    "accountStatus must be active, suspended or rejected."
  );
}

/**
 * Loads a target profile and confirms it is awaiting review.
 *
 * Checked here as well as inside `approveAccount` so that rejection — whose
 * underlying `denyAccount` accepts any current status, because it also serves
 * suspension of active users from the operator script — cannot be used
 * through this path to reject an already-active colleague.
 *
 * @param {string} uid the account being acted on.
 * @return {Promise<Record<string, unknown>>} the target's profile data.
 */
async function requirePendingTarget(
  uid: string
): Promise<Record<string, unknown>> {
  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new HttpsError("not-found", "That account no longer exists.");
  }
  if (profile.accountStatus !== "pending") {
    throw new HttpsError(
      "failed-precondition",
      "That account has already been reviewed."
    );
  }
  return profile;
}

/**
 * For a `siteManager` approver granting `foreman`, confirms
 * [organizationId] is one they manage. For a `foreman` approver granting
 * `worker`, confirms the target's requested site(s) — read from the
 * `siteIds` request argument, defaulting to the approver's own first site —
 * intersect the approver's own assigned sites. `admin` and any approval
 * that is not organization/site-scoped by this hierarchy pass through
 * untouched.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {Approver} approver the authorized, reviewing caller.
 * @param {AppRole} role the role being granted.
 * @param {string | null} organizationId the resolved target organization,
 * or null (only possible for an `admin` approving a `siteManager` with no
 * organization yet — see [resolveTargetOrganization]).
 * @return {Promise<void>} resolves when the scope check passes.
 */
async function requireGrantWithinScope(
  request: CallableRequest,
  approver: Approver,
  role: AppRole,
  organizationId: string | null
): Promise<void> {
  if (approver.role === "admin") return;

  if (approver.role === "siteManager") {
    // Only an org-less `admin` can produce a null organizationId (see
    // [resolveTargetOrganization]); a siteManager approver always has one
    // (requireApprover refuses otherwise), so this is unreachable in
    // practice — checked explicitly rather than asserted, fail-closed.
    if (organizationId === null) throw denied();
    const managedOrgIds = await resolveManagedOrganizationIds(approver.uid);
    if (!managedOrgIds.includes(organizationId)) throw denied();
    return;
  }

  if (approver.role === "foreman" && role === "worker") {
    // A Foreman's approval authority is confined to their own assigned
    // site(s) (PROJECT_CONTEXT.md §16). requireApprover already refused a
    // Foreman with no organization; here we additionally require they have
    // at least one assigned site to approve a worker into, and that any
    // explicitly requested siteId is one of theirs.
    if (approver.siteIds.length === 0) throw denied();
    const requestedSiteId = (request.data ?? {}).siteId;
    if (requestedSiteId !== undefined) {
      if (
        typeof requestedSiteId !== "string" ||
        !approver.siteIds.includes(requestedSiteId)
      ) {
        throw denied();
      }
    }
  }
}

/** A pending account as shown in the approvals inbox. */
interface PendingAccount {
  uid: string;
  name: string;
  email: string;
  phone: string | null;
  createdAt: string | null;
}

/**
 * Lists the accounts awaiting review.
 *
 * Pending accounts have no `organizationId` yet — nobody has decided which
 * organization they belong to, which is precisely what is being asked. The
 * queue is therefore a shared inbox across reviewers rather than an
 * org-scoped list, and `requireApprover`'s role check is the whole of what
 * keeps it private. The projection is deliberately narrow: only what the
 * approval decision needs is returned, never the whole document.
 */
export const listPendingApprovals = onCall(async (request) => {
  await requireApprover(request);

  const snapshot = await getFirestore()
    .collection("users")
    .where("accountStatus", "==", "pending")
    .get();

  const accounts: PendingAccount[] = snapshot.docs.map((doc) => {
    const data = doc.data();
    const createdAt = data.createdAt;
    return {
      uid: doc.id,
      name: typeof data.name === "string" ? data.name : "",
      email: typeof data.email === "string" ? data.email : "",
      phone: typeof data.phone === "string" ? data.phone : null,
      createdAt: createdAt?.toDate ?
        createdAt.toDate().toISOString() :
        null,
    };
  });

  return {accounts};
});

/**
 * Approves a pending account into an organization, assigning the requested
 * role and worker type.
 *
 * For every reviewer except `admin`, the organization is the caller's own,
 * read from their profile — there is no parameter for it. `admin` has no
 * organization of its own and must supply `organizationId` explicitly (see
 * [resolveTargetOrganization]). `role` is required and validated against
 * what the caller's own role is authorized to grant (see [grantableRoles]),
 * further scoped by [requireGrantWithinScope]; `workerType` is optional.
 */
export const approvePendingAccount = onCall(async (request) => {
  const approver = await requireApprover(request);
  const uid = targetUid(request);

  // Checked before reading the role/workerType/organizationId arguments so a
  // self-approval attempt is refused uniformly regardless of payload shape.
  if (uid === approver.uid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot act on your own account."
    );
  }

  const role = targetRole(request, approver);
  const workerType = targetWorkerType(request);
  const organizationId = resolveTargetOrganization(request, approver, role);

  await requirePendingTarget(uid);
  await requireGrantWithinScope(request, approver, role, organizationId);
  await approveAccount({
    uid,
    organizationId,
    role,
    workerType,
    siteIds: requestSiteIds(request),
    approvedBy: approver.uid,
  });

  return {uid, accountStatus: "active", role, organizationId};
});

/**
 * Rejects a pending account.
 *
 * Rejection is a status, not a deletion: the profile is retained and the
 * Firebase Auth account disabled by `denyAccount`.
 */
export const rejectPendingAccount = onCall(async (request) => {
  const approver = await requireApprover(request);
  const uid = targetUid(request);

  if (uid === approver.uid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot act on your own account."
    );
  }

  await requirePendingTarget(uid);
  await denyAccount({uid, status: "rejected", actorUid: approver.uid});

  return {uid, accountStatus: "rejected"};
});

/**
 * Loads a target's membership document within the reviewer's ONE acting
 * organization (`approver.organizationId`) and confirms the reviewer is
 * authorized to act on it there — i.e. the target actually has a membership
 * in that organization, and (for `siteManager`/`foreman`) the reviewer's own
 * scope covers it. `admin` is exempt, exactly as it is everywhere else: it
 * has no organization to be confined to, and may act on any target uid.
 *
 * Approval (`requirePendingTarget`) never needed this: a pending account has
 * no membership yet, so there is nothing to match.
 *
 * @param {string} uid the account being acted on.
 * @param {Approver} approver the authorized, reviewing caller, already
 * resolved to the one organization they are acting within.
 * @return {Promise<Record<string, unknown>>} the target's membership data,
 * or an empty object for `admin` (who is not organization-scoped).
 */
async function requireSameOrganizationMembershipTarget(
  uid: string,
  approver: Approver
): Promise<Record<string, unknown>> {
  if (approver.role === "admin") return {};
  if (approver.organizationId === null) throw denied();

  const membership = await loadOwnMembershipOf(uid, approver.organizationId);
  if (!membership) {
    throw new HttpsError("not-found", "That membership does not exist.");
  }

  if (approver.role === "siteManager") {
    const managedOrgIds = await resolveManagedOrganizationIds(approver.uid);
    if (!managedOrgIds.includes(approver.organizationId)) throw denied();
    return membership;
  }

  if (approver.role === "foreman") {
    // A Foreman may only act on accounts within their own site(s), within
    // the organization they are acting in.
    const targetSiteIds: string[] = Array.isArray(membership.siteIds) ?
      membership.siteIds.filter(
        (id: unknown): id is string => typeof id === "string"
      ) :
      [];
    const sharesSite = targetSiteIds.some((id) =>
      approver.siteIds.includes(id));
    if (!sharesSite) throw denied();
    return membership;
  }

  throw denied();
}

/**
 * Loads uid's own membership document for [organizationId] — the same shape
 * as [loadOwnMembership], but named distinctly since here it is the TARGET's
 * membership being loaded, not the caller's own.
 *
 * @param {string} uid the target account's uid.
 * @param {string} organizationId the organization to check.
 * @return {Promise<Record<string, unknown> | null>} the membership data, or
 * null.
 */
async function loadOwnMembershipOf(
  uid: string,
  organizationId: string
): Promise<Record<string, unknown> | null> {
  return loadOwnMembership(uid, organizationId);
}

/** A row in `listOrganizationUsers` — one person, one organization. */
interface OrganizationUserRow {
  uid: string;
  name: string;
  email: string;
  phone: string | null;
  accountStatus: string;
  organizationId: string;
  role: string | null;
  workerType: string | null;
  trade: string | null;
  siteIds: string[];
  membershipStatus: string;
  createdAt: string | null;
}

/**
 * Lists the users belonging to the reviewer's ONE acting organization (or,
 * for `admin`, every organization), optionally narrowed to one
 * `accountStatus`.
 *
 * This is the read side of user management: the approvals inbox
 * (`listPendingApprovals`) only ever returns `pending` accounts, so the
 * Active Users / Suspended & Rejected Users lists need their own query. It
 * is now a query over the `memberships` collection group rather than
 * `users` directly, since role/workerType/siteIds live there — a person
 * with two memberships in different organizations shows up once per
 * organization they belong to (never twice for the same organization),
 * each row carrying that organization's own role/status. `accountStatus`
 * (account-level) still defaults to `"active"` when omitted, but a person
 * whose account itself is not that status is filtered out after the join
 * back to their profile — membership `status` and account `accountStatus`
 * are independent, and this list is scoped by the account-level field, to
 * match its historical meaning ("who is in the active/suspended/rejected
 * account queue"), with `membershipStatus` returned alongside for the
 * per-organization state.
 */
export const listOrganizationUsers = onCall(async (request) => {
  const approver = await requireApprover(request);
  const status = targetListStatus(request);

  let query: FirebaseFirestore.Query = getFirestore().collectionGroup(
    "memberships"
  );
  if (approver.organizationId !== null) {
    query = query.where("organizationId", "==", approver.organizationId);
  }
  const membershipSnapshot = await query.get();

  const rows: OrganizationUserRow[] = [];
  await Promise.all(membershipSnapshot.docs.map(async (doc) => {
    // Collection-group membership docs live at
    // users/{uid}/memberships/{organizationId}; the owning uid is the
    // parent-of-parent segment.
    const uid = doc.ref.parent.parent?.id;
    if (!uid) return;

    const membership = doc.data();
    const organizationId = typeof membership.organizationId === "string" ?
      membership.organizationId :
      doc.id;

    const userSnapshot = await getFirestore().doc(`users/${uid}`).get();
    const profile = userSnapshot.data();
    if (!userSnapshot.exists || !profile) return;
    if (profile.accountStatus !== status) return;

    rows.push({
      uid,
      name: typeof profile.name === "string" ? profile.name : "",
      email: typeof profile.email === "string" ? profile.email : "",
      phone: typeof profile.phone === "string" ? profile.phone : null,
      accountStatus: status,
      organizationId,
      role: typeof membership.role === "string" ? membership.role : null,
      workerType: typeof membership.workerType === "string" ?
        membership.workerType :
        null,
      trade: typeof membership.trade === "string" ? membership.trade : null,
      siteIds: Array.isArray(membership.siteIds) ?
        membership.siteIds.filter((id: unknown) => typeof id === "string") :
        [],
      membershipStatus: typeof membership.status === "string" ?
        membership.status :
        "active",
      createdAt: profile.createdAt?.toDate ?
        profile.createdAt.toDate().toISOString() :
        null,
    });
  }));

  return {users: rows};
});

/**
 * Suspends an active account, withdrawing its operational access without
 * deleting it. ACCOUNT-level: this touches `accountStatus` alone, not any
 * individual membership's own `status` — see [suspendMembership] for the
 * per-organization equivalent.
 *
 * Confined to the reviewer's own acting organization (see
 * [requireSameOrganizationMembershipTarget]) and, like every other decision
 * callable, refuses a reviewer acting on their own account — an Admin
 * cannot suspend themselves any more than a Site Manager can.
 */
export const suspendActiveAccount = onCall(async (request) => {
  const approver = await requireApprover(request);
  const uid = targetUid(request);

  if (uid === approver.uid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot act on your own account."
    );
  }

  const userSnapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = userSnapshot.data();
  if (!userSnapshot.exists || !profile) {
    throw new HttpsError("not-found", "That account no longer exists.");
  }
  await requireSameOrganizationMembershipTarget(uid, approver);
  if (profile.accountStatus !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "Only an active account can be suspended."
    );
  }

  await denyAccount({uid, status: "suspended", actorUid: approver.uid});

  return {uid, accountStatus: "suspended"};
});

/**
 * Restores a suspended account to `active`. ACCOUNT-level, mirroring
 * [suspendActiveAccount] — does not touch any individual membership's own
 * `status`; see [reinstateMembership] for that.
 *
 * Confined to the reviewer's own acting organization and refuses
 * self-action, for the same reasons as [suspendActiveAccount].
 */
export const reinstateSuspendedAccount = onCall(async (request) => {
  const approver = await requireApprover(request);
  const uid = targetUid(request);

  if (uid === approver.uid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot act on your own account."
    );
  }

  await requireSameOrganizationMembershipTarget(uid, approver);
  await reinstateAccount({uid, actorUid: approver.uid});

  return {uid, accountStatus: "active"};
});

/**
 * Toggles one membership's own `status` field between `active` and
 * `suspended`, leaving `accountStatus` and every other membership the
 * person holds completely untouched. This is the per-organization
 * counterpart to suspendActiveAccount/reinstateSuspendedAccount: a manager
 * can withdraw a Foreman's access to just THIS organization without
 * touching their access to any other organization they also belong to.
 *
 * @param {string} newStatus the status to set: "active" or "suspended".
 * @return {object} the shared onCall implementation behind both
 * `suspendMembership` and `reinstateMembership`.
 */
function membershipStatusCallable(newStatus: "active" | "suspended") {
  return onCall(async (request) => {
    const approver = await requireApprover(request);
    const uid = targetUid(request);

    if (uid === approver.uid) {
      throw new HttpsError(
        "failed-precondition",
        "You cannot act on your own account."
      );
    }
    if (approver.organizationId === null) {
      // admin is not organization-scoped; membership status is inherently
      // per-organization, so admin must still say which one — the same
      // requireRequestOrganizationId enforced inside requireApprover for
      // every non-admin caller. For symmetry and simplicity, admin uses the
      // same required-argument path here rather than a separate one.
      throw denied();
    }

    await requireSameOrganizationMembershipTarget(uid, approver);

    const membershipRef = getFirestore().doc(
      `users/${uid}/memberships/${approver.organizationId}`
    );
    await membershipRef.update({
      status: newStatus,
      updatedAt: FieldValue.serverTimestamp(),
    });

    await getFirestore().collection("audit_logs").add({
      organizationId: approver.organizationId,
      actorUid: approver.uid,
      action: `membership.${newStatus}`,
      targetDocId: uid,
      targetCollection: "users",
      metadata: {organizationId: approver.organizationId},
      createdAt: FieldValue.serverTimestamp(),
    });

    return {
      uid,
      organizationId: approver.organizationId,
      membershipStatus: newStatus,
    };
  });
}

/**
 * Suspends the caller's target's membership in the caller's acting
 * organization only. See [membershipStatusCallable].
 */
export const suspendMembership = membershipStatusCallable("suspended");

/**
 * Reinstates the caller's target's membership in the caller's acting
 * organization only. See [membershipStatusCallable].
 */
export const reinstateMembership = membershipStatusCallable("active");

/**
 * Places an ALREADY-ACTIVE user into an additional organization: creates one
 * more `users/{uid}/memberships/{organizationId}` document, without
 * touching `accountStatus` or any of their other memberships.
 *
 * Same authorization shape as the org-assignment step of
 * `approvePendingAccount` — the reviewer must hold an active,
 * authorized-role membership in the target organization (see
 * [requireApprover]/[requireGrantWithinScope]) — but the target is an
 * existing active uid rather than a pending one. Refuses with
 * `already-exists` if a membership already exists for that uid+organization,
 * rather than silently overwriting it (see `addMembership` in
 * `account_approval.ts`).
 */
export const addOrganizationMembership = onCall(async (request) => {
  const approver = await requireApprover(request);
  const uid = targetUid(request);

  if (uid === approver.uid) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot act on your own account."
    );
  }

  const role = targetRole(request, approver);
  const workerType = targetWorkerType(request);
  const organizationId = resolveTargetOrganization(request, approver, role);
  if (organizationId === null) {
    throw new HttpsError("invalid-argument", "organizationId is required.");
  }

  const userSnapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = userSnapshot.data();
  if (!userSnapshot.exists || !profile) {
    throw new HttpsError("not-found", "That account no longer exists.");
  }
  if (profile.accountStatus !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "Only an active account can be placed into another organization."
    );
  }

  const existing = await loadOwnMembershipOf(uid, organizationId);
  if (existing) {
    throw new HttpsError(
      "already-exists",
      "That user already has a membership in that organization."
    );
  }

  await requireGrantWithinScope(request, approver, role, organizationId);
  await addMembership({
    uid,
    organizationId,
    role,
    workerType,
    siteIds: requestSiteIds(request),
    approvedBy: approver.uid,
  });

  return {uid, organizationId, role};
});
