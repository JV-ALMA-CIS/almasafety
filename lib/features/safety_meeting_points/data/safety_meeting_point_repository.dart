import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../domain/safety_meeting_point.dart';

/// Reads safety meeting points from
/// `organizations/{organizationId}/safety_meeting_points`.
///
/// Read-only — see [SafetyLearningRepository]'s doc comment for why creating
/// and editing a meeting point goes through a callable instead. Scoped to
/// one organization at a time by construction, matching
/// [SafetyLearningRepository].
class SafetyMeetingPointRepository {
  SafetyMeetingPointRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<SafetyMeetingPoint>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyMeetingPointsCollection(
           organizationId,
         ),
         fromFirestore: SafetyMeetingPoint.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Safety meeting points are written server-side.',
         ),
       );

  final String _organizationId;
  final FirestoreRepository<SafetyMeetingPoint> _repository;

  Future<SafetyMeetingPoint?> getById(String id) => _repository.getById(id);

  Stream<SafetyMeetingPoint?> watchById(String id) => _repository.watchById(id);

  /// Streams every safety meeting point in this organization, active and
  /// inactive alike. Used by the admin management screen.
  Stream<List<SafetyMeetingPoint>> watchAll() => _repository.watchCollection();

  /// Streams only the active safety meeting points in this organization —
  /// what a foreman or worker sees. Filtered server-side on `status` via
  /// [queryBuilder] rather than client-side, matching the repository's other
  /// queries.
  ///
  /// [activityId] and [riskId], when given, additionally restrict the
  /// stream to meeting points whose [SafetyMeetingPoint.applicableActivities]
  /// or [SafetyMeetingPoint.applicableRisks] contain that id — the filtering
  /// a future Daily Safety Meeting will need to suggest relevant meeting
  /// points for the activity/risk it is being run for. An empty
  /// `applicableActivities`/`applicableRisks` list means "applies to
  /// everything", so it is never excluded by these filters.
  Stream<List<SafetyMeetingPoint>> watchActive({
    String? activityId,
    String? riskId,
  }) {
    return _repository
        .watchCollection(
          queryBuilder: (query) => query.where(
            'status',
            isEqualTo: OrganizationRecordStatus.active.id,
          ),
        )
        .map((points) {
          if (activityId == null && riskId == null) return points;
          return points.where((point) {
            final matchesActivity =
                activityId == null ||
                point.applicableActivities.isEmpty ||
                point.applicableActivities.contains(activityId);
            final matchesRisk =
                riskId == null ||
                point.applicableRisks.isEmpty ||
                point.applicableRisks.contains(riskId);
            return matchesActivity && matchesRisk;
          }).toList();
        });
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
