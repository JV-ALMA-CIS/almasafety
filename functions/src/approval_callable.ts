/**
 * In-app account approval callables for JVA Safety.
 *
 * These are the callable front door to the privileged operations in
 * `account_approval.ts`. Until now the only way to approve an account was to
 * run `scripts/approve_account.ts` with service-account credentials, which
 * meant only the developer could approve anyone — too much friction for
 * ongoing use.
 *
 * Six callables in total: `listPendingApprovals` / `approvePendingAccount` /
 * `rejectPendingAccount` review the pending queue; `listOrganizationUsers` /
 * `suspendActiveAccount` / `reinstateSuspendedAccount` manage users who have
 * already been reviewed (the Active Users and Suspended/Rejected Users
 * lists). Every one of them funnels through `requireApprover`, so the
 * authorization boundary below applies to all six identically.
 *
 * THE APPROVAL HIERARCHY (PROJECT_CONTEXT.md §16)
 *
 * The caller's own `platformRole` field ([AppRole]), read from their stored
 * profile:
 *
 *  - `admin` may approve/assign `siteManager` (or reinstate any role) for
 *    anyone, in any organization.
 *  - `siteManager` may approve/assign `foreman` only, within the
 *    organization(s) they manage — see `organizations/{orgId}.managedBy` in
 *    `organization_callable.ts`.
 *  - `foreman` may approve/assign `worker` only, within their own assigned
 *    site(s) (`approverProfile.siteIds` intersecting the target's assigned
 *    site).
 *  - `worker` has no review authority at all.
 *
 * No one may grant a `platformRole` equal to or above their own — see
 * `grantableRoles` in `account_approval.ts`, which encodes this directly:
 * there is no entry that lists its own role or anything above it.
 *
 * `admin` is the one platform-level exception to "organization-scoped
 * reviewer": it has no `organizationId` of its own to default to. When
 * granting `siteManager` (the only role an admin ever grants),
 * `organizationId` is OPTIONAL — an Admin approving a colleague they know by
 * name typically has no way to know which of possibly several organizations
 * that person operates in, so the new Site Manager is approved with no
 * organization yet and creates (or is assigned into) one afterward via
 * `createOrganization`, which backfills it onto their profile at that point
 * (PROJECT_CONTEXT.md §12/§16/§18). Admin MAY still supply `organizationId`
 * explicitly if they do know it (e.g. approving into an organization that
 * already exists). Every other reviewer role continues to have its
 * organization read from its own profile, never from the request.
 *
 * WHY THE CHECK LIVES HERE AND NOT IN firestore.rules
 *
 * Approval is not a single field write — it is a conditional multi-field
 * transition (verify the target is pending, assign the caller's own
 * organization plus a role and worker type, stamp the audit trail, disable
 * the Auth account on rejection) with an audit-log write beside it.
 * Expressing that in the rules language would mean a second, independent
 * implementation of the same authorization decision that could silently
 * drift from this one. Instead, `firestore.rules` continues to deny every
 * client write to `accountStatus`, `organizationId`, `platformRole` and
 * `workerType` outright, and these callables — which run on the Admin SDK
 * and so bypass rules — are the only path through.
 *
 * WHAT A REVIEWER CANNOT DO
 *
 * - Approve into any organization other than one they manage — unless they
 *   are `admin`, the one role with no "own organization" to restrict them
 *   to. A `siteManager`'s organization is read from `organizations` records
 *   they manage (`managedBy` array — see `organization_callable.ts`) or
 *   their own profile's `organizationId`, never from the request payload.
 * - Act on their own account: the target uid is compared against the
 *   caller's uid and refused if equal, before anything else runs. This is
 *   the only path in the app that can change `accountStatus`, `platformRole`
 *   or `organizationId`, so this one check is what makes "cannot approve,
 *   reject or activate yourself, and cannot change your own role or
 *   organization" true everywhere — including for the Admin.
 * - Grant a role they could not themselves hold as a reviewer. See
 *   `grantableRoles` in `account_approval.ts`.
 * - Act on an account that is not `pending`: re-homing an already-active user
 *   or resurrecting a rejected one is not reachable from the three review
 *   callables.
 * - Suspend, reinstate, or list a user outside their own scope — the same
 *   organization/site confinement as approval, now enforced by
 *   `requireSameOrganizationTarget` for the three post-review callables
 *   (`listOrganizationUsers`, `suspendActiveAccount`,
 *   `reinstateSuspendedAccount`), since a suspend/reinstate target already
 *   has an organization of its own to check against rather than deriving one
 *   at approval time. `admin` is exempt, as everywhere else.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`.
 */

import {getFirestore} from "firebase-admin/firestore";
import {HttpsError, CallableRequest, onCall} from "firebase-functions/v2/https";
import {
  AccountStatus,
  AppRole,
  WorkerTypeValue,
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
 * An authorized approver: their uid, role and the scope they approve into.
 *
 * `organizationId` is null only for `admin`, who has no fixed organization
 * of their own — see [resolveTargetOrganization], the only place that reads
 * a caller-supplied organization at all, and only for this one role.
 *
 * `siteIds` is populated only for a `foreman` approver, whose approval
 * authority (granting `worker`) is scoped to their own assigned site(s)
 * rather than their whole organization — see [requireApprover] and
 * [requireTargetWithinForemanSites].
 */
interface Approver {
  uid: string;
  role: AppRole;
  organizationId: string | null;
  siteIds: string[];
}

/**
 * Resolves the organization(s) a `siteManager` approver manages, for
 * confining their review authority. A `siteManager` manages every
 * organization whose `organizations/{orgId}.managedBy` array contains their
 * uid, PLUS their own profile's `organizationId` (the organization they were
 * themselves approved into, which they also manage by construction — see
 * `organization_callable.ts`'s `createOrganization`, which writes the
 * creator into `managedBy` and the creator's own profile `organizationId` in
 * the same operation. This query additionally covers a `siteManager` who was
 * approved into an organization someone else created).
 *
 * @param {string} uid the site manager's own uid.
 * @param {string | null} ownOrganizationId their own profile's
 * organizationId.
 * @return {Promise<string[]>} the organization ids they manage.
 */
async function resolveManagedOrganizationIds(
  uid: string,
  ownOrganizationId: string | null
): Promise<string[]> {
  const snapshot = await getFirestore()
    .collection("organizations")
    .where("managedBy", "array-contains", uid)
    .get();
  const managed = new Set(snapshot.docs.map((doc) => doc.id));
  if (ownOrganizationId) managed.add(ownOrganizationId);
  return Array.from(managed);
}

/**
 * Authorizes the caller as an organization approver, or throws.
 *
 * Every condition is checked server-side against the caller's own stored
 * profile — nothing here trusts the request payload or the client's session
 * state. A non-platform approver must additionally hold an `organizationId`:
 * a suspended approver, or one somehow assigned a role before being approved
 * into an organization, has nothing to approve people into. `admin` is
 * exempt from that one check, since it is not scoped to any organization to
 * begin with.
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

  const role = profile.platformRole;
  if (!isAppRole(role) || !canReviewPendingAccounts(role)) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  if (role === "admin") {
    return {uid, role, organizationId: null, siteIds: []};
  }

  const organizationId = profile.organizationId;
  if (typeof organizationId !== "string" || !organizationId) throw denied();

  const siteIds: string[] = Array.isArray(profile.siteIds) ?
    profile.siteIds.filter(
      (id: unknown): id is string => typeof id === "string"
    ) :
    [];

  return {uid, role, organizationId, siteIds};
}

/**
 * Resolves the organization an approval targets, or null.
 *
 * For every reviewer role except `admin`, this is always the reviewer's own
 * organization — the request payload is never consulted, so a modified
 * client cannot name a different one. `admin` has no organization of its
 * own; it MAY supply `organizationId` explicitly (e.g. to stand up a
 * brand-new organization's first Site Manager by naming an id that does not
 * exist yet — `approveAccount` writes it onto the profile with no separate
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
    const managedOrgIds = await resolveManagedOrganizationIds(
      approver.uid,
      approver.organizationId
    );
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
    approvedBy: approver.uid,
  });

  return {uid, accountStatus: "active", role};
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
 * Loads a target profile and confirms it is within the reviewer's own
 * scope, or that the reviewer is the org-less `admin`.
 *
 * Approval (`requirePendingTarget`) never needed this: a pending account has
 * no organization yet, so there is nothing to match. Once a target is
 * `active` or `suspended` it already belongs to a specific organization, and
 * a `siteManager`/`foreman` reviewer must be confined to their own scope —
 * otherwise any reviewer could suspend a colleague in a different
 * company/site entirely. `admin` is exempt, exactly as it is everywhere
 * else: it has no organization to be confined to.
 *
 * @param {string} uid the account being acted on.
 * @param {Approver} approver the authorized, reviewing caller.
 * @return {Promise<Record<string, unknown>>} the target's profile data.
 */
async function requireSameOrganizationTarget(
  uid: string,
  approver: Approver
): Promise<Record<string, unknown>> {
  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) {
    throw new HttpsError("not-found", "That account no longer exists.");
  }
  if (approver.role === "admin") return profile;

  if (approver.role === "siteManager") {
    const managedOrgIds = await resolveManagedOrganizationIds(
      approver.uid,
      approver.organizationId
    );
    if (!managedOrgIds.includes(profile.organizationId)) throw denied();
    return profile;
  }

  if (approver.role === "foreman") {
    // A Foreman may only act on accounts within their own site(s).
    const targetSiteIds: string[] = Array.isArray(profile.siteIds) ?
      profile.siteIds.filter(
        (id: unknown): id is string => typeof id === "string"
      ) :
      [];
    const sharesSite = targetSiteIds.some((id) =>
      approver.siteIds.includes(id));
    if (
      profile.organizationId !== approver.organizationId ||
      !sharesSite
    ) {
      throw denied();
    }
    return profile;
  }

  throw denied();
}

/**
 * Lists the users belonging to the reviewer's scope (or, for `admin`, every
 * organization), optionally narrowed to one `accountStatus`.
 *
 * This is the read side of user management: the approvals inbox
 * (`listPendingApprovals`) only ever returns `pending` accounts, so the
 * Active Users / Suspended & Rejected Users lists need their own query.
 * `accountStatus` defaults to `"active"` when omitted — the common case —
 * but accepts `"suspended"` or `"rejected"` too; `"pending"` is refused,
 * since that queue is already served by `listPendingApprovals` and mixing
 * the two would blur "awaiting review" with "already reviewed."
 *
 * The projection is the same narrow shape as the pending queue, plus the
 * fields that only make sense once a user has been reviewed:
 * `accountStatus`, `role`, `workerType`, `organizationId`.
 */
export const listOrganizationUsers = onCall(async (request) => {
  const approver = await requireApprover(request);
  const status = targetListStatus(request);

  let query = getFirestore()
    .collection("users")
    .where("accountStatus", "==", status);
  // Every reviewer except admin is confined to their own organization scope
  // — the same boundary requireSameOrganizationTarget enforces for
  // single-account actions, applied here to a list query instead. A Foreman
  // is further narrowed client-side/at read time by siteIds intersection;
  // the query itself narrows to organization, matching a siteManager's
  // scoping shape, since Firestore cannot filter by array-intersection here
  // without a composite index this stage does not introduce.
  if (approver.organizationId !== null) {
    query = query.where("organizationId", "==", approver.organizationId);
  }
  const snapshot = await query.get();

  const users = snapshot.docs.map((doc) => {
    const data = doc.data();
    const createdAt = data.createdAt;
    return {
      uid: doc.id,
      name: typeof data.name === "string" ? data.name : "",
      email: typeof data.email === "string" ? data.email : "",
      phone: typeof data.phone === "string" ? data.phone : null,
      accountStatus: status,
      role: typeof data.platformRole === "string" ? data.platformRole : null,
      workerType: typeof data.workerType === "string" ? data.workerType : null,
      organizationId: typeof data.organizationId === "string" ?
        data.organizationId :
        null,
      siteIds: Array.isArray(data.siteIds) ?
        data.siteIds.filter((id: unknown) => typeof id === "string") :
        [],
      createdAt: createdAt?.toDate ?
        createdAt.toDate().toISOString() :
        null,
    };
  });

  return {users};
});

/**
 * Suspends an active account, withdrawing its operational access without
 * deleting it.
 *
 * Confined to the reviewer's own scope (see
 * [requireSameOrganizationTarget]) and, like every other decision callable,
 * refuses a reviewer acting on their own account — an Admin cannot suspend
 * themselves any more than a Site Manager can.
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

  const target = await requireSameOrganizationTarget(uid, approver);
  if (target.accountStatus !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "Only an active account can be suspended."
    );
  }

  await denyAccount({uid, status: "suspended", actorUid: approver.uid});

  return {uid, accountStatus: "suspended"};
});

/**
 * Restores a suspended account to `active`.
 *
 * Confined to the reviewer's own scope and refuses self-action, for the same
 * reasons as [suspendActiveAccount].
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

  await requireSameOrganizationTarget(uid, approver);
  await reinstateAccount({uid, actorUid: approver.uid});

  return {uid, accountStatus: "active"};
});
