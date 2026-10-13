import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/inspection.dart';

/// Reads inspections and their templates for one organization. Read-only:
/// every write goes through [InspectionService]'s callables.
class InspectionRepository {
  InspectionRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _inspections = FirestoreRepository<Inspection>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.inspectionsCollection(organizationId),
         fromFirestore: Inspection.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Inspections are written server-side.'),
       ),
       _templates = FirestoreRepository<InspectionTemplate>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.inspectionTemplatesCollection(
           organizationId,
         ),
         fromFirestore: InspectionTemplate.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Templates are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<Inspection> _inspections;
  final FirestoreRepository<InspectionTemplate> _templates;

  String get organizationId => _organizationId;

  /// Every inspection, newest first.
  Stream<List<Inspection>> watchInspections() => _inspections.watchCollection(
    queryBuilder: (query) => query.orderBy('startedAt', descending: true),
  );

  Stream<Inspection?> watchInspection(String id) => _inspections.watchById(id);

  /// Every template, active or not, sorted by name.
  Stream<List<InspectionTemplate>> watchTemplates() =>
      _templates.watchCollection().map(
        (templates) => [
          ...templates,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      );
}
