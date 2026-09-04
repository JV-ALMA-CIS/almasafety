/// Centralized Firestore collection paths.
///
/// Keeping paths here avoids magic strings scattered across data sources and
/// gives Security Rules and client code a single source of truth to stay in
/// sync with. Data is organization-scoped: every top-level record carries an
/// `organizationId`, and most operational collections are nested under
/// `organizations/{organizationId}` to support organization-level isolation.
class FirestorePaths {
  FirestorePaths._();

  static const String organizations = 'organizations';
  static const String users = 'users';
  static const String projects = 'projects';
  static const String sites = 'sites';
  static const String activities = 'activities';
  static const String workers = 'workers';
  static const String safetyLearning = 'safety_learning';
  static const String safetyRequirements = 'safety_requirements';
  static const String workerLearningRecords = 'worker_learning_records';
  static const String safetyMeetingPoints = 'safety_meeting_points';
  static const String dailySafetyMeetings = 'daily_safety_meetings';
  static const String hazards = 'hazards';
  static const String correctiveActions = 'corrective_actions';
  static const String safetyAlerts = 'safety_alerts';
  static const String notifications = 'notifications';
  static const String auditLogs = 'audit_logs';

  static String organization(String organizationId) =>
      '$organizations/$organizationId';

  /// `users/{uid}` — the identity/profile document.
  ///
  /// Top-level rather than organization-scoped: under the self-registration
  /// model a user registers before any organization is known, so at creation
  /// time there is no `organizations/{orgId}` path to write into. The
  /// organization is a nullable *field* on this document, assigned by an
  /// approver. Operational collections remain org-scoped.
  static String userProfile(String uid) => '$users/$uid';

  /// `organizations/{organizationId}/projects` — a collection, not a single
  /// document, for building collection references and queries.
  static String projectsCollection(String organizationId) =>
      '${organization(organizationId)}/$projects';

  /// `organizations/{organizationId}/projects/{projectId}`.
  static String project(String organizationId, String projectId) =>
      '${projectsCollection(organizationId)}/$projectId';

  /// `organizations/{organizationId}/sites` — a collection, not a single
  /// document.
  ///
  /// Flat under the organization, matching FIRESTORE_DATA_MODEL.md §3: a
  /// site's project is an `projectId` field, not an extra path segment,
  /// which keeps a site addressable by organization alone without knowing
  /// its project.
  static String sitesCollection(String organizationId) =>
      '${organization(organizationId)}/$sites';

  /// `organizations/{organizationId}/sites/{siteId}`.
  static String site(String organizationId, String siteId) =>
      '${sitesCollection(organizationId)}/$siteId';

  /// `organizations/{organizationId}/activities` — a collection, not a
  /// single document.
  ///
  /// Flat under the organization, matching [sitesCollection]: an activity's
  /// project and site are `projectId`/`siteId` fields, not extra path
  /// segments, which keeps an activity addressable by organization alone
  /// without knowing its project or site.
  static String activitiesCollection(String organizationId) =>
      '${organization(organizationId)}/$activities';

  /// `organizations/{organizationId}/activities/{activityId}`.
  static String activity(String organizationId, String activityId) =>
      '${activitiesCollection(organizationId)}/$activityId';

  /// `organizations/{organizationId}/activities/{activityId}/assignments` —
  /// the subcollection of worker assignments for one activity.
  static String activityAssignmentsCollection(
    String organizationId,
    String activityId,
  ) => '${activity(organizationId, activityId)}/assignments';

  /// `organizations/{organizationId}/activities/{activityId}/assignments/{uid}`.
  static String activityAssignment(
    String organizationId,
    String activityId,
    String uid,
  ) => '${activityAssignmentsCollection(organizationId, activityId)}/$uid';

  /// `organizations/{organizationId}/safety_learning` — a collection, not a
  /// single document.
  ///
  /// Flat under the organization, matching [activitiesCollection].
  static String safetyLearningCollection(String organizationId) =>
      '${organization(organizationId)}/$safetyLearning';

  /// `organizations/{organizationId}/safety_learning/{id}`.
  static String safetyLearningDoc(String organizationId, String id) =>
      '${safetyLearningCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/safety_requirements` — a collection,
  /// not a single document.
  static String safetyRequirementsCollection(String organizationId) =>
      '${organization(organizationId)}/$safetyRequirements';

  /// `organizations/{organizationId}/safety_requirements/{id}`.
  static String safetyRequirement(String organizationId, String id) =>
      '${safetyRequirementsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/worker_learning_records` — a
  /// collection, not a single document.
  static String workerLearningRecordsCollection(String organizationId) =>
      '${organization(organizationId)}/$workerLearningRecords';

  /// `organizations/{organizationId}/worker_learning_records/{recordId}`,
  /// where `recordId` is `${workerUid}_${learningId}` — see
  /// [WorkerLearningRecord]'s doc comment for why a deterministic id is
  /// used instead of an auto-id.
  static String workerLearningRecord(
    String organizationId,
    String workerUid,
    String learningId,
  ) => '${workerLearningRecordsCollection(organizationId)}/'
      '${workerLearningRecordId(workerUid, learningId)}';

  /// The deterministic document id for a worker's learning record:
  /// `${workerUid}_${learningId}`.
  static String workerLearningRecordId(String workerUid, String learningId) =>
      '${workerUid}_$learningId';

  /// `organizations/{organizationId}/safety_meeting_points` — a collection,
  /// not a single document.
  ///
  /// Flat under the organization, matching [safetyLearningCollection].
  static String safetyMeetingPointsCollection(String organizationId) =>
      '${organization(organizationId)}/$safetyMeetingPoints';

  /// `organizations/{organizationId}/safety_meeting_points/{id}`.
  static String safetyMeetingPoint(String organizationId, String id) =>
      '${safetyMeetingPointsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/daily_safety_meetings` — a collection,
  /// not a single document.
  ///
  /// Flat under the organization, matching [safetyMeetingPointsCollection]:
  /// a meeting's project and site are `projectId`/`siteId` fields, not path
  /// segments.
  static String dailySafetyMeetingsCollection(String organizationId) =>
      '${organization(organizationId)}/$dailySafetyMeetings';

  /// `organizations/{organizationId}/daily_safety_meetings/{id}`.
  static String dailySafetyMeeting(String organizationId, String id) =>
      '${dailySafetyMeetingsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/attendance`
  /// — a subcollection of one meeting, not a single document.
  static String meetingAttendanceCollection(
    String organizationId,
    String meetingId,
  ) => '${dailySafetyMeeting(organizationId, meetingId)}/attendance';

  /// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/attendance/{workerId}`.
  static String meetingAttendance(
    String organizationId,
    String meetingId,
    String workerId,
  ) => '${meetingAttendanceCollection(organizationId, meetingId)}/$workerId';

  /// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/concerns`
  /// — a subcollection of one meeting, not a single document.
  static String meetingConcernsCollection(
    String organizationId,
    String meetingId,
  ) => '${dailySafetyMeeting(organizationId, meetingId)}/concerns';

  /// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/concerns/{id}`.
  static String meetingConcern(
    String organizationId,
    String meetingId,
    String id,
  ) => '${meetingConcernsCollection(organizationId, meetingId)}/$id';

  /// `organizations/{organizationId}/hazards` — a collection, not a single
  /// document.
  ///
  /// Flat under the organization, matching [dailySafetyMeetingsCollection]: a
  /// hazard's project/site are `projectId`/`siteId` fields, not path
  /// segments, which keeps the whole organization's hazards queryable in one
  /// collection rather than fanned out per site.
  static String hazardsCollection(String organizationId) =>
      '${organization(organizationId)}/$hazards';

  /// `organizations/{organizationId}/hazards/{id}`.
  static String hazard(String organizationId, String id) =>
      '${hazardsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/corrective_actions` — a collection, not
  /// a single document.
  ///
  /// Flat under the organization, matching [dailySafetyMeetingsCollection]:
  /// a corrective action's meeting/concern are `meetingId`/`concernId`
  /// fields, not path segments, which keeps the whole organization's
  /// corrective actions queryable in one collection rather than fanned out
  /// per meeting.
  static String correctiveActionsCollection(String organizationId) =>
      '${organization(organizationId)}/$correctiveActions';

  /// `organizations/{organizationId}/corrective_actions/{id}`.
  static String correctiveAction(String organizationId, String id) =>
      '${correctiveActionsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/safety_alerts` — a collection, not a
  /// single document.
  ///
  /// Flat under the organization, matching [correctiveActionsCollection]: an
  /// alert's project/site are `projectId`/`siteId` fields, not path
  /// segments, which keeps the whole organization's alerts queryable in one
  /// collection.
  static String safetyAlertsCollection(String organizationId) =>
      '${organization(organizationId)}/$safetyAlerts';

  /// `organizations/{organizationId}/safety_alerts/{id}`.
  static String safetyAlert(String organizationId, String id) =>
      '${safetyAlertsCollection(organizationId)}/$id';

  /// `organizations/{organizationId}/notifications` — a collection, not a
  /// single document.
  ///
  /// Flat under the organization, matching [safetyAlertsCollection]. Unlike
  /// every other operational collection so far, a notification is personal
  /// data scoped to one `recipientUid` — see [AppNotification]'s doc
  /// comment.
  static String notificationsCollection(String organizationId) =>
      '${organization(organizationId)}/$notifications';

  /// `organizations/{organizationId}/notifications/{id}`.
  static String notification(String organizationId, String id) =>
      '${notificationsCollection(organizationId)}/$id';
}
