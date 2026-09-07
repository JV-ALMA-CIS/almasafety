/**
 * Organization/Project/Site management callables for JVA Safety.
 *
 * These are the only path that can create or edit an `organizations/{id}`,
 * `organizations/{orgId}/projects/{id}` or `organizations/{orgId}/sites/{id}`
 * document — `firestore.rules` denies every client write to all three
 * collections outright, mirroring how account review is Admin-SDK-only.
 * Deliberately one authorization path rather than a rules-language
 * implementation alongside this one that could drift — see
 * `approval_callable.ts`'s header note, which this file follows exactly.
 *
 * WHAT AUTHORIZES A CALLER
 *
 * `admin` (any organization) may create/edit any organization/project/site.
 * `siteManager` may also CREATE an organization (PROJECT_CONTEXT.md §12,
 * "Organization Hierarchy": "A Site Manager/Site Superintendent must be able
 * to create an organization because they are the field operational
 * manager") — see [createOrganization] — and may create/edit projects and
 * sites within the organization(s) they manage, read from
 * `organizations/{orgId}.managedBy` (an array of manager uids) — see
 * [requireOrganizationScopedManager], reused by `activity_callable.ts` and
 * `safety_learning_callable.ts`/`safety_meeting_point_callable.ts` decide
 * their own, narrower, `admin`-only authority independently (the Safety
 * Learning/Meeting Point libraries are deliberately NOT delegated to Site
 * Managers — PROJECT_CONTEXT.md §4).
 *
 * `organizations/{orgId}.managedBy` IS THE ORG-MANAGER ASSOCIATION. When a
 * `siteManager` creates an organization, their uid is written into that
 * array and their own profile's `organizationId` is set to the new
 * organization's id in the same operation (`account_approval.ts`'s
 * `approveAccount` sets `organizationId` at approval time for every other
 * path; `createOrganization` performs the equivalent write directly here,
 * since organization creation itself is what assigns it for a `siteManager`
 * who did not already have one).
 *
 * WHAT A CALLER CANNOT DO
 *
 * - Create a project without its organization already existing.
 * - Create a site whose `organizationId` does not match its project's
 *   `organizationId` — checked server-side against the stored project
 *   document, never trusted from the request payload alone.
 * - Move a project or site to a different organization through `update*`:
 *   `organizationId` (and, for a site, `projectId`) is immutable after
 *   creation. Reassigning either is a data-model change with implications
 *   for every operational record scoped beneath it, not an ordinary edit.
 * - A `siteManager` cannot create/edit a project or site in an organization
 *   they do not manage, and cannot add themselves (or anyone) to another
 *   organization's `managedBy` array — `updateOrganization`'s `managedBy`
 *   argument is `admin`-only; a `siteManager` calling `updateOrganization`
 *   may only touch `name`/`code`/`status` on an organization they manage.
 * - Learn anything from a refusal: every authorization failure returns the
 *   same opaque `permission-denied`, exactly as in `approval_callable.ts`.
 */

import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {CallableRequest, HttpsError, onCall} from "firebase-functions/v2/https";

/** The two values of the shared organization/project/site status field. */
export const RECORD_STATUSES = ["active", "inactive"] as const;

export type RecordStatus = (typeof RECORD_STATUSES)[number];

/**
 * Validates an untrusted record-status value.
 *
 * @param {unknown} value the candidate value.
 * @return {boolean} true when it is one of the two known statuses.
 */
export function isRecordStatus(value: unknown): value is RecordStatus {
  return typeof value === "string" &&
    (RECORD_STATUSES as readonly string[]).includes(value);
}

/**
 * The single refusal returned for every authorization failure. Mirrors
 * `denied()` in `approval_callable.ts`.
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
 * The caller's own uid and active profile, loaded once per callable.
 *
 * `role` here is the platform role (`admin`/`siteManager`/etc read off the
 * top-level profile when it is `admin`, since Admin holds no memberships at
 * all — see [requireActiveCaller]). For a non-admin caller, whether they may
 * act as a `siteManager` for a GIVEN organization is decided per-call by
 * [requireOrganizationScopedManager] against their membership subcollection,
 * not by this single cached `role` value — a siteManager caller may hold
 * that role in one organization and none in another.
 */
interface CallerProfile {
  uid: string;
  role: string;
}

/**
 * Loads and minimally validates the caller's own active profile. Every
 * authorization function in this file builds on this.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Promise<CallerProfile>} the authorized caller's uid and platform
 * role (`admin`, or their account's nominal role family — see
 * [requireOrganizationScopedManager] for how a non-admin's actual authority
 * over one specific organization is verified).
 */
async function requireActiveCaller(
  request: CallableRequest
): Promise<CallerProfile> {
  const uid = request.auth?.uid;
  if (!uid) throw denied();

  const snapshot = await getFirestore().doc(`users/${uid}`).get();
  const profile = snapshot.data();
  if (!snapshot.exists || !profile) throw denied();
  if (profile.accountStatus !== "active") throw denied();

  if (profile.platformRole === "admin") {
    return {uid, role: "admin"};
  }

  // The one narrow non-admin use of platformRole: a siteManager approved
  // with NO organization yet (see `approveAccount` in
  // `account_approval.ts`) has no membership document to carry a role at
  // all. Without this, such an account could never call `createOrganization`
  // — the very callable it needs to reach next — since it holds zero
  // memberships. This value is provisional: once a real membership exists
  // (created by `createOrganization` itself, or by a later approval into an
  // organization), the membership subcollection becomes authoritative and
  // this field is cleared — see `createOrganization` below.
  if (profile.platformRole === "siteManager") {
    return {uid, role: "siteManager"};
  }

  // A non-admin caller's "role" for the purposes of this file is otherwise
  // resolved per-organization from their memberships, not a single profile
  // field — see requireOrganizationScopedManager. Here we only need to know
  // they hold SOME siteManager membership somewhere in order to be a
  // plausible caller of the siteManager-only callables below; the
  // org-specific check happens later.
  const membershipSnapshot = await getFirestore()
    .collection(`users/${uid}/memberships`)
    .where("role", "==", "siteManager")
    .limit(1)
    .get();
  if (membershipSnapshot.empty) throw denied();

  return {uid, role: "siteManager"};
}

/**
 * Authorizes the caller as `admin`, or throws. Used by content-management
 * callables that are platform-level and deliberately NOT delegated to
 * `siteManager` — the Safety Learning and Safety Meeting Point libraries
 * (PROJECT_CONTEXT.md §4, §12) — see `safety_learning_callable.ts` and
 * `safety_meeting_point_callable.ts`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @return {Promise<string>} the authorized caller's uid.
 */
export async function requireAdmin(request: CallableRequest): Promise<string> {
  const caller = await requireActiveCaller(request);
  if (caller.role !== "admin") throw denied();
  return caller.uid;
}

/**
 * Authorizes the caller as `admin` (any organization) or `siteManager` of
 * [organizationId] (read from `organizations/{organizationId}.managedBy`, or
 * their own profile's `organizationId` — see this file's header note), or
 * throws. Exported for reuse by `activity_callable.ts` and
 * `site_assignment_callable.ts`.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} organizationId the organization the action targets.
 * @return {Promise<string>} the authorized caller's uid.
 */
export async function requireOrganizationScopedManager(
  request: CallableRequest,
  organizationId: string
): Promise<string> {
  const caller = await requireActiveCaller(request);
  if (caller.role === "admin") return caller.uid;
  if (caller.role !== "siteManager") throw denied();

  // Fast path: an active siteManager membership in THIS organization,
  // checked against the caller's own membership subcollection rather than a
  // scalar `organizationId` profile field — a siteManager may hold several
  // memberships, so "is this one of them" is the real question, not "is
  // this their one org".
  const membershipSnapshot = await getFirestore()
    .doc(`users/${caller.uid}/memberships/${organizationId}`)
    .get();
  const membership = membershipSnapshot.data();
  if (
    membershipSnapshot.exists && membership &&
    membership.role === "siteManager" && membership.status === "active"
  ) {
    return caller.uid;
  }

  const orgSnapshot = await getFirestore()
    .doc(`organizations/${organizationId}`)
    .get();
  const org = orgSnapshot.data();
  const managedBy: string[] = org && Array.isArray(org.managedBy) ?
    org.managedBy.filter(
      (id: unknown): id is string => typeof id === "string"
    ) :
    [];
  if (!managedBy.includes(caller.uid)) throw denied();

  return caller.uid;
}

/**
 * Reads and validates a required non-empty string argument.
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
 * Reads an optional string argument, treating an absent, null or blank value
 * as not supplied.
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
 * Reads and validates the optional `status` argument shared by all three
 * entities, defaulting to `"active"`.
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
 * Reads and validates an optional ISO-8601 date-string argument.
 *
 * @param {CallableRequest} request the incoming callable request.
 * @param {string} field the argument name.
 * @return {Date | null} the parsed date, or null when absent.
 */
function optionalDate(request: CallableRequest, field: string): Date | null {
  const value = (request.data ?? {})[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${field} must be a date string.`);
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    throw new HttpsError("invalid-argument", `${field} is not a valid date.`);
  }
  return parsed;
}

/**
 * Creates an organization.
 *
 * Callable by `admin` (any) or `siteManager` (becoming its operational
 * manager — PROJECT_CONTEXT.md §12). The creating `siteManager`'s uid is
 * written into `managedBy`, and — UNCONDITIONALLY, every time, not only the
 * first time — a new `users/{uid}/memberships/{organizationId}` document is
 * created for them with `role: siteManager`, `status: active`. There is no
 * longer a reason to skip this for a second/third organization the same
 * Site Manager creates: each organization they create or are placed into is
 * its own membership document (see the header note on the multi-org
 * membership model), unlike the old single-`organizationId`-backfill
 * behaviour this replaces.
 *
 * `code` is not enforced unique server-side at this stage — cross-
 * organization uniqueness checking is deferred rather than half-built.
 */
export const createOrganization = onCall(async (request) => {
  const caller = await requireActiveCaller(request);
  if (caller.role !== "admin" && caller.role !== "siteManager") {
    throw denied();
  }
  const name = requireString(request, "name");
  const code = requireString(request, "code");
  const status = targetStatus(request);

  const ref = getFirestore().collection("organizations").doc();
  await ref.set({
    name,
    code,
    status,
    managedBy: caller.role === "siteManager" ? [caller.uid] : [],
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: caller.uid,
    updatedBy: caller.uid,
  });

  if (caller.role === "siteManager") {
    await getFirestore()
      .doc(`users/${caller.uid}/memberships/${ref.id}`)
      .set({
        organizationId: ref.id,
        role: "siteManager",
        workerType: null,
        trade: null,
        siteIds: [],
        supervisorUid: null,
        status: "active",
        approvedAt: FieldValue.serverTimestamp(),
        approvedBy: caller.uid,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

    // Clears the provisional platformRole marker `approveAccount` writes for
    // an org-less siteManager (see `requireActiveCaller` above) now that a
    // real membership document exists to be authoritative instead. Harmless
    // no-op (an extra field-delete) for a siteManager who already had a
    // membership and so never carried this marker in the first place.
    await getFirestore().doc(`users/${caller.uid}`).update({
      platformRole: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  return {id: ref.id};
});

/**
 * Updates an organization's editable fields.
 *
 * `id` cannot be changed by construction (it is the document id, never a
 * field); there is no `organizationId` on an organization document to
 * reassign. `managedBy` may only be changed by `admin` — a `siteManager`
 * calling this on an organization they manage may still update
 * `name`/`code`/`status`, but cannot add or remove managers, which would
 * otherwise let a Site Manager grant or revoke another Site Manager's
 * authority over the organization unilaterally.
 */
export const updateOrganization = onCall(async (request) => {
  const id = requireString(request, "id");
  const actorUid = await requireOrganizationScopedManager(request, id);
  const name = optionalString(request, "name");
  const code = optionalString(request, "code");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;
  const managedByArg = (request.data ?? {}).managedBy;

  const ref = getFirestore().doc(`organizations/${id}`);
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That organization no longer exists.");
  }

  let managedBy: string[] | null = null;
  if (managedByArg !== undefined) {
    // admin-only, verified independently of requireOrganizationScopedManager
    // since a siteManager is otherwise authorized to call this callable at
    // all — see this file's header note.
    const caller = await requireActiveCaller(request);
    if (caller.role !== "admin") throw denied();
    if (
      !Array.isArray(managedByArg) ||
      !managedByArg.every((item) => typeof item === "string" && item)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "managedBy must be an array of uids."
      );
    }
    managedBy = managedByArg as string[];
  }

  await ref.update({
    ...(name !== null ? {name} : {}),
    ...(code !== null ? {code} : {}),
    ...(status !== null ? {status} : {}),
    ...(managedBy !== null ? {managedBy} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id};
});

/**
 * Creates a project within an existing organization.
 *
 * Refuses to create a project under an organization that does not exist,
 * so a project can never point at a dangling `organizationId`.
 */
export const createProject = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const name = requireString(request, "name");
  const code = requireString(request, "code");
  const description = optionalString(request, "description");
  const status = targetStatus(request);
  const startDate = optionalDate(request, "startDate");
  const endDate = optionalDate(request, "endDate");

  const orgRef = getFirestore().doc(`organizations/${organizationId}`);
  const orgSnapshot = await orgRef.get();
  if (!orgSnapshot.exists) {
    throw new HttpsError(
      "failed-precondition",
      "That organization does not exist."
    );
  }

  const ref = orgRef.collection("projects").doc();
  await ref.set({
    organizationId,
    name,
    code,
    ...(description !== null ? {description} : {}),
    status,
    ...(startDate !== null ? {startDate} : {}),
    ...(endDate !== null ? {endDate} : {}),
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId};
});

/**
 * Updates a project's editable fields.
 *
 * `organizationId` is immutable — see this file's header note. Moving a
 * project between organizations is out of scope for this stage.
 */
export const updateProject = onCall(async (request) => {
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
  const startDate = optionalDate(request, "startDate");
  const endDate = optionalDate(request, "endDate");

  const ref = getFirestore().doc(
    `organizations/${organizationId}/projects/${id}`
  );
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That project no longer exists.");
  }

  await ref.update({
    ...(name !== null ? {name} : {}),
    ...(code !== null ? {code} : {}),
    ...(description !== null ? {description} : {}),
    ...(status !== null ? {status} : {}),
    ...(startDate !== null ? {startDate} : {}),
    ...(endDate !== null ? {endDate} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});

/**
 * Creates a site within an existing organization and project.
 *
 * Refuses to create a site whose `organizationId` does not match the named
 * project's own `organizationId` — the server-side enforcement of
 * "a site must belong to both an organization and a project, and its
 * organization must match its project's."
 */
export const createSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const projectId = requireString(request, "projectId");
  const name = requireString(request, "name");
  const code = requireString(request, "code");
  const location = optionalString(request, "location");
  const description = optionalString(request, "description");
  const status = targetStatus(request);

  const orgRef = getFirestore().doc(`organizations/${organizationId}`);
  const projectRef = orgRef.collection("projects").doc(projectId);
  const [orgSnapshot, projectSnapshot] = await Promise.all([
    orgRef.get(),
    projectRef.get(),
  ]);
  if (!orgSnapshot.exists) {
    throw new HttpsError(
      "failed-precondition",
      "That organization does not exist."
    );
  }
  const project = projectSnapshot.data();
  if (!projectSnapshot.exists || !project) {
    throw new HttpsError("failed-precondition", "That project does not exist.");
  }
  if (project.organizationId !== organizationId) {
    // The relationship this callable exists to enforce: a site's
    // organization must match its project's, never a mismatched pair
    // supplied independently by the client.
    throw new HttpsError(
      "failed-precondition",
      "That project does not belong to the given organization."
    );
  }

  const ref = orgRef.collection("sites").doc();
  await ref.set({
    organizationId,
    projectId,
    name,
    code,
    ...(location !== null ? {location} : {}),
    ...(description !== null ? {description} : {}),
    status,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    createdBy: actorUid,
    updatedBy: actorUid,
  });

  return {id: ref.id, organizationId, projectId};
});

/**
 * Updates a site's editable fields.
 *
 * `organizationId` and `projectId` are both immutable — see this file's
 * header note.
 */
export const updateSite = onCall(async (request) => {
  const organizationId = requireString(request, "organizationId");
  const actorUid = await requireOrganizationScopedManager(
    request,
    organizationId
  );
  const id = requireString(request, "id");
  const name = optionalString(request, "name");
  const code = optionalString(request, "code");
  const location = optionalString(request, "location");
  const description = optionalString(request, "description");
  const status = (request.data ?? {}).status !== undefined ?
    targetStatus(request) :
    null;

  const ref = getFirestore().doc(`organizations/${organizationId}/sites/${id}`);
  const snapshot = await ref.get();
  if (!snapshot.exists) {
    throw new HttpsError("not-found", "That site no longer exists.");
  }

  await ref.update({
    ...(name !== null ? {name} : {}),
    ...(code !== null ? {code} : {}),
    ...(location !== null ? {location} : {}),
    ...(description !== null ? {description} : {}),
    ...(status !== null ? {status} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  });

  return {id, organizationId};
});
