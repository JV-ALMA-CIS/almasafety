import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../domain/activity.dart';

/// Client for the activity management callables in
/// `functions/src/activity_callable.ts`.
///
/// Creating and editing an activity writes fields `firestore.rules` denies
/// to every client — there is therefore deliberately no Firestore repository
/// method for it, only this class invoking server-side functions that
/// verify the caller is a System Administrator or an Organization
/// Administrator of the activity's own organization.
///
/// Nothing this class sends is trusted by the server: `createActivity`
/// re-verifies that the named site actually belongs to the named
/// organization and project before writing, mirroring
/// [OrganizationAdminService.createSite]'s doc comment.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [OrganizationAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class ActivityAdminService {
  ActivityAdminService({FirebaseFunctions? functions}) : _injected = functions;

  final FirebaseFunctions? _injected;

  FirebaseFunctions? get _functions {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFunctions.instance;
  }

  FirebaseFunctions _require() {
    final functions = _functions;
    if (functions == null) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return functions;
  }

  /// Creates an activity within [organizationId], [projectId] and [siteId],
  /// all of which must already exist, with the named site's own
  /// `organizationId`/`projectId` matching the given pair — the server
  /// refuses a mismatched combination. Returns the new document id.
  Future<String> createActivity({
    required String organizationId,
    required String projectId,
    required String siteId,
    required String name,
    required String code,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createActivity', {
      'organizationId': organizationId,
      'projectId': projectId,
      'siteId': siteId,
      'name': name,
      'code': code,
      'description': ?description,
      'status': status.id,
    });
    return result['id'] as String? ?? '';
  }

  /// Updates an activity's editable fields. `organizationId`, `projectId`
  /// and `siteId` cannot be changed — an activity may not be moved between
  /// organizations, projects or sites.
  Future<void> updateActivity(
    String organizationId,
    String id, {
    String? name,
    String? code,
    String? description,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateActivity', {
    'organizationId': organizationId,
    'id': id,
    'name': ?name,
    'code': ?code,
    'description': ?description,
    if (status != null) 'status': status.id,
  });

  /// Every activity at [siteId] within [organizationId] — the
  /// [ActivityRepository.watchBySite] equivalent for a Foreman/Worker
  /// caller, whose `firestore.rules` grant does not cover LIST queries on
  /// `activities` at all (see that rule's own comment on why: "rules are
  /// not filters" means a resource-data-dependent branch would poison the
  /// query for every caller). This callable re-derives and enforces the
  /// caller's own site scope server-side instead. An Admin/Site Manager
  /// may still prefer [ActivityRepository.watchBySite] directly (a live
  /// stream, unlike this one-shot fetch) — this exists specifically for
  /// the role that stream is unusable for.
  Future<List<Activity>> getSiteActivities({
    required String organizationId,
    required String siteId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('getSiteActivities', {
      'organizationId': organizationId,
      'siteId': siteId,
    });
    final activities = result['activities'];
    if (activities is! List) return const [];
    return activities
        .whereType<Map>()
        .map((a) => Activity.fromMap(a['id'] as String, a.cast()))
        .toList(growable: false);
  }

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
