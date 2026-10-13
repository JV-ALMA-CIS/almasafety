import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/activity.dart';

/// Reads activities from `organizations/{organizationId}/activities`.
///
/// Read-only — see [SiteRepository]'s doc comment for why creating and
/// editing an activity goes through a callable instead. Scoped to one
/// organization at a time by construction, matching [SiteRepository].
class ActivityRepository {
  ActivityRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<Activity>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.activitiesCollection(organizationId),
         fromFirestore: Activity.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Activities are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<Activity> _repository;

  Future<Activity?> getById(String id) => _repository.getById(id);

  Stream<Activity?> watchById(String id) => _repository.watchById(id);

  /// Streams every activity in this organization.
  Stream<List<Activity>> watchAll() => _repository.watchCollection();

  /// Streams every activity belonging to one site within this organization.
  ///
  /// An activity is flat under the organization (`siteId` is a field, not a
  /// path segment — see [Activity]'s doc comment), so narrowing to one site
  /// is a query, not a different collection path.
  Stream<List<Activity>> watchBySite(String siteId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('siteId', isEqualTo: siteId),
    );
  }

  /// Streams every activity across several sites within this organization.
  ///
  /// Required for a caller whose `firestore.rules` read grant is scoped to
  /// activities whose OWN `siteId` is in their own membership's `siteIds`
  /// (a Foreman or Worker — see `firestore.rules`'s
  /// `activities/{activityId}` rule) rather than "any activity in this
  /// organization": Firestore refuses an unconstrained [watchAll] outright
  /// for such a caller, since a security rule cannot partially filter a
  /// query's results. Returns an empty stream for an empty [siteIds] —
  /// `whereIn` rejects an empty list rather than matching nothing.
  Stream<List<Activity>> watchBySites(List<String> siteIds) {
    if (siteIds.isEmpty) return Stream.value(const []);
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('siteId', whereIn: siteIds),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
