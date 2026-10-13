import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/risk_assessment.dart';

/// Reads the Activity Hazard Analyses of one organization. Read-only: every
/// write goes through [RiskAssessmentService].
class RiskAssessmentRepository {
  RiskAssessmentRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _assessments = FirestoreRepository<RiskAssessment>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.riskAssessmentsCollection(
           organizationId,
         ),
         fromFirestore: RiskAssessment.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('AHAs are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<RiskAssessment> _assessments;

  String get organizationId => _organizationId;

  /// Every AHA, sorted by feature of work, newest revision first.
  Stream<List<RiskAssessment>> watchAll() => _assessments.watchCollection().map(
    (all) => [...all]
      ..sort((a, b) {
        final byName = a.featureOfWork.toLowerCase().compareTo(
          b.featureOfWork.toLowerCase(),
        );
        return byName != 0 ? byName : b.revision.compareTo(a.revision);
      }),
  );

  Stream<RiskAssessment?> watch(String id) => _assessments.watchById(id);
}
