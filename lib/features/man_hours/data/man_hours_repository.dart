import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/man_hours.dart';

/// Reads the monthly man-hours of one organization. Read-only: entries are
/// written through [ManHoursService].
class ManHoursRepository {
  ManHoursRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _entries = FirestoreRepository<ManHoursEntry>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.manHoursCollection(organizationId),
         fromFirestore: ManHoursEntry.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Man-hours are written server-side.'),
       ),
       _reports = FirestoreRepository<ManHoursReport>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.manHoursReportsCollection(
           organizationId,
         ),
         fromFirestore: ManHoursReport.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Reports are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<ManHoursEntry> _entries;
  final FirestoreRepository<ManHoursReport> _reports;

  String get organizationId => _organizationId;

  /// Every site's entry for [month].
  Stream<List<ManHoursEntry>> watchMonth(String month) =>
      _entries.watchCollection(
        queryBuilder: (query) => query.where('month', isEqualTo: month),
      );

  /// [month] as reported to the Safety Office, or null if not yet.
  Stream<ManHoursReport?> watchReport(String month) =>
      _reports.watchById(month);
}
