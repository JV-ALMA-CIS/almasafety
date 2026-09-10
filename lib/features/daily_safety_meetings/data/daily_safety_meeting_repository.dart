import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/daily_safety_meeting.dart';
import '../domain/daily_safety_meeting_status.dart';

/// Reads daily safety meetings from
/// `organizations/{organizationId}/daily_safety_meetings`.
///
/// Read-only — see [SafetyMeetingPointRepository]'s doc comment for why
/// creating and editing a meeting goes through a callable instead
/// ([DailySafetyMeetingService]). Scoped to one organization at a time by
/// construction, matching [SafetyMeetingPointRepository].
class DailySafetyMeetingRepository {
  DailySafetyMeetingRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<DailySafetyMeeting>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.dailySafetyMeetingsCollection(
           organizationId,
         ),
         fromFirestore: DailySafetyMeeting.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Daily safety meetings are written server-side.',
         ),
       );

  final String _organizationId;
  final FirestoreRepository<DailySafetyMeeting> _repository;

  Future<DailySafetyMeeting?> getById(String id) => _repository.getById(id);

  Stream<DailySafetyMeeting?> watchById(String id) =>
      _repository.watchById(id);

  /// Streams the given foreman's own meeting for [siteId] on [date]
  /// (`yyyy-MM-dd`) — at most one is expected, since the foreman-facing flow
  /// starts "today's meeting" once per site per day. Powers "today's
  /// meeting" resumption: if one already exists, the flow resumes it instead
  /// of starting a duplicate.
  Stream<List<DailySafetyMeeting>> watchForForemanSiteAndDate({
    required String foremanId,
    required String siteId,
    required String date,
  }) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('foremanId', isEqualTo: foremanId)
          .where('siteId', isEqualTo: siteId)
          .where('date', isEqualTo: date),
    );
  }

  /// Streams every meeting the given foreman has recorded, most recent
  /// first — the foreman's own meeting history view.
  Stream<List<DailySafetyMeeting>> watchHistoryForForeman(String foremanId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('foremanId', isEqualTo: foremanId)
          .orderBy('date', descending: true),
    );
  }

  /// Streams every meeting in this organization, most recent first —
  /// backs the Daily Safety Meeting report, mirroring
  /// [CorrectiveActionRepository.watchForOrganization]'s and
  /// [SafetyAlertRepository.watchForOrganization]'s own org-wide read.
  Stream<List<DailySafetyMeeting>> watchAll() {
    return _repository.watchCollection(
      queryBuilder: (query) => query.orderBy('date', descending: true),
    );
  }

  /// Streams every COMPLETED meeting in this organization, most recent
  /// first — what [AdminDailySafetyMeetingsScreen] shows a Site Manager.
  /// An in-progress meeting is a foreman's own working draft, not yet a
  /// reviewable record: a Site Manager reviewing meetings should never see
  /// one that has not been finished, since it may still be missing
  /// attendance, points, or simply forgotten mid-toolbox-talk. The Foreman's
  /// own history ([watchHistoryForForeman]) still shows every status, so
  /// they can find and resume a forgotten in-progress meeting.
  Stream<List<DailySafetyMeeting>> watchCompleted() {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('status', isEqualTo: DailySafetyMeetingStatus.completed.id)
          .orderBy('date', descending: true),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
