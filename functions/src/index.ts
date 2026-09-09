/**
 * JVA Safety Cloud Functions.
 *
 * Current scope: the authentication/user identity/account-review foundation,
 * plus the Organization -> Project -> Site record foundation.
 *
 * The privileged operations in this stage — approving a registered account,
 * assigning its organization/role/worker type, rejecting it — live in
 * `account_approval.ts` as plain functions, invoked two ways:
 *
 *  - `scripts/approve_account.ts`, run by an operator under service-account
 *    credentials. Its `bootstrap-admin` command is the ONLY path anywhere
 *    that can create the platform-level System Administrator
 *    (PROJECT_CONTEXT.md §18) — there is no in-app path to it, and no
 *    "first registered user becomes admin" shortcut. Once that account
 *    exists, it can review pending accounts in-app like any other reviewer
 *    role, including bootstrapping the first Organization Administrator or
 *    Site Superintendent for a new organization.
 *  - the callables in `approval_callable.ts`, which let an in-app reviewer
 *    act on the pending queue. Their caller check reads the caller's own
 *    `role` field and verifies it is one of the reviewer-authorized roles.
 *
 * `organization_callable.ts` holds the second privileged surface: creating
 * and editing organizations, projects and sites, gated on `admin` (any
 * organization) or `siteManager` (the organization(s) they manage). Same
 * pattern — `firestore.rules` denies every client write to those three
 * collections, and these callables are the only path through.
 *
 * The Admin SDK app is initialized here so both the callables and the
 * operator scripts resolve getAuth()/getFirestore() against one app.
 */

import {setGlobalOptions} from "firebase-functions";
import {initializeApp} from "firebase-admin/app";

// For cost control, cap the number of concurrently running containers.
setGlobalOptions({maxInstances: 10});

initializeApp();

export {
  approveAccount,
  addMembership,
  denyAccount,
  reinstateAccount,
  isAccountStatus,
  isAppRole,
  isWorkerType,
  ACCOUNT_STATUSES,
  APP_ROLES,
  WORKER_TYPES,
} from "./account_approval";

export {
  listPendingApprovals,
  approvePendingAccount,
  rejectPendingAccount,
  listOrganizationUsers,
  suspendActiveAccount,
  reinstateSuspendedAccount,
  suspendMembership,
  reinstateMembership,
  addOrganizationMembership,
} from "./approval_callable";

export {
  createOrganization,
  updateOrganization,
  createProject,
  updateProject,
  createSite,
  updateSite,
  isRecordStatus,
  RECORD_STATUSES,
} from "./organization_callable";

export {
  assignWorkerToSite,
  removeWorkerFromSite,
} from "./site_assignment_callable";

export {createActivity, updateActivity} from "./activity_callable";

export {
  assignWorkerToActivity,
  removeWorkerFromActivity,
} from "./activity_assignment_callable";

export {
  createSafetyLearning,
  updateSafetyLearning,
  createSafetyRequirement,
  updateSafetyRequirement,
} from "./safety_learning_callable";

export {
  getMyRequiredLearning,
  startLearning,
  completeLearning,
} from "./worker_learning_callable";

export {
  createSafetyMeetingPoint,
  updateSafetyMeetingPoint,
  activateSafetyMeetingPoint,
  deactivateSafetyMeetingPoint,
} from "./safety_meeting_point_callable";

export {
  createDailySafetyMeeting,
  updateDailySafetyMeeting,
  completeDailySafetyMeeting,
  recordMeetingAttendance,
  addMeetingConcern,
  updateMeetingConcern,
  removeMeetingConcern,
  setMeetingPointNote,
  removeMeetingPointNote,
  addMeetingEvidence,
  removeMeetingEvidence,
} from "./daily_safety_meeting_callable";

export {
  createCorrectiveAction,
  updateCorrectiveActionStatus,
} from "./corrective_action_callable";

export {
  createHazard,
  acknowledgeHazard,
  linkHazardCorrectiveAction,
  closeHazard,
} from "./hazard_callable";

export {
  createSafetyAlert,
  acknowledgeSafetyAlert,
  resolveSafetyAlert,
} from "./safety_alert_callable";

export {
  markNotificationRead,
  markAllNotificationsRead,
} from "./notification_callable";
