import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/storage_service.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the hazard callables in `functions/src/hazard_callable.ts`
/// (`createHazard`/`acknowledgeHazard`/`linkHazardCorrectiveAction`/
/// `closeHazard`), plus the photo-upload orchestration that precedes
/// `createHazard`.
///
/// Mirrors [DailySafetyMeetingService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has run
/// — e.g. in widget tests. None of these callables accept a `reportedByUid`/
/// `acknowledgedBy`/`closedBy` argument: every one derives the acting
/// identity from `request.auth.uid` server-side.
///
/// **Photo-upload sequencing** — see `FIRESTORE_DATA_MODEL.md` §7. The
/// client pre-allocates the hazard's own document id
/// ([FirestoreService.require]'s `collection(...).doc()` generates one
/// without writing anything), uploads the optional photo directly to
/// `organizations/{orgId}/hazards/{hazardId}/{fileName}` using that id, and
/// only then calls `createHazard` with both the pre-allocated id and the
/// resulting download URL. [reportHazard] does all three steps for the
/// caller; [createHazard] alone is exposed too for callers that already have
/// an uploaded `photoUrl` (or none) and a pre-allocated id.
class HazardService {
  HazardService({
    FirebaseFunctions? functions,
    FirestoreService? firestoreService,
    StorageService? storageService,
  }) : _injected = functions,
       _firestoreService = firestoreService ?? FirestoreService(),
       _storageService = storageService ?? StorageService();

  final FirebaseFunctions? _injected;
  final FirestoreService _firestoreService;
  final StorageService _storageService;

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

  /// Pre-allocates a hazard document id, without writing anything — the
  /// first step of [reportHazard], exposed separately so a caller (e.g. a
  /// report-hazard screen) can start an evidence-photo upload against a
  /// known path before the report form is even submitted.
  String allocateHazardId(String organizationId) {
    return _firestoreService.require
        .collection(FirestorePaths.hazardsCollection(organizationId))
        .doc()
        .id;
  }

  /// Uploads [bytes] to `organizations/{organizationId}/hazards/{hazardId}/
  /// {fileName}` and returns its download URL. Any org member may upload
  /// here — see `storage.rules`' org-scoped write grant — so this performs
  /// no separate authorization check of its own; `createHazard` is what
  /// authorizes the report itself.
  Future<String> uploadHazardPhoto({
    required String organizationId,
    required String hazardId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    try {
      final ref = _storageService
          .orgRef(organizationId)
          .child('hazards/$hazardId/$fileName');
      await ref.putData(bytes);
      return await ref.getDownloadURL();
    } on FirebaseException catch (e) {
      throw DataException(
        e.message ?? 'Failed to upload the hazard photo.',
        cause: e,
      );
    }
  }

  /// Reports a hazard end-to-end: pre-allocates the id, uploads
  /// [photoBytes] (when given) to a path scoped to that id, then calls
  /// [createHazard] with the resulting `photoUrl`. See this class's doc
  /// comment for why the upload must happen before the Firestore write.
  ///
  /// The server re-validates the caller has [siteId] in their own `siteIds`
  /// within [organizationId], and derives `projectId` from the site
  /// document — nothing here is trusted from the client alone.
  Future<String> reportHazard({
    required String organizationId,
    required String siteId,
    required String category,
    required String description,
    String? location,
    String? photoFileName,
    Uint8List? photoBytes,
  }) async {
    final hazardId = allocateHazardId(organizationId);

    String? photoUrl;
    if (photoBytes != null && photoFileName != null) {
      photoUrl = await uploadHazardPhoto(
        organizationId: organizationId,
        hazardId: hazardId,
        fileName: photoFileName,
        bytes: photoBytes,
      );
    }

    return createHazard(
      organizationId: organizationId,
      siteId: siteId,
      hazardId: hazardId,
      category: category,
      description: description,
      location: location,
      photoUrl: photoUrl,
    );
  }

  /// Calls `createHazard` directly, given a pre-allocated [hazardId] (see
  /// [allocateHazardId]) and, when there is one, an already-uploaded
  /// [photoUrl] (see [uploadHazardPhoto]). The server re-validates the
  /// caller has [siteId] in their own `siteIds` within [organizationId].
  /// Returns the new hazard's id.
  Future<String> createHazard({
    required String organizationId,
    required String siteId,
    required String hazardId,
    required String category,
    required String description,
    String? location,
    String? photoUrl,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createHazard', {
      'organizationId': organizationId,
      'siteId': siteId,
      'hazardId': hazardId,
      'category': category,
      'description': description,
      'location': ?location,
      'photoUrl': ?photoUrl,
    });
    return result['id'] as String? ?? hazardId;
  }

  /// Acknowledges a reported hazard. The server re-validates the caller
  /// holds an authorized reviewer role within [organizationId].
  Future<void> acknowledgeHazard({
    required String organizationId,
    required String hazardId,
  }) => _call<Object?>('acknowledgeHazard', {
    'organizationId': organizationId,
    'hazardId': hazardId,
  });

  /// Creates a corrective action from [hazardId], linking the two. The
  /// server re-validates the caller holds an authorized reviewer role, and
  /// that the hazard is not already closed or already linked. Returns the
  /// new corrective action's id.
  Future<String> linkCorrectiveAction({
    required String organizationId,
    required String hazardId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    bool evidenceRequired = false,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'linkHazardCorrectiveAction',
      {
        'organizationId': organizationId,
        'hazardId': hazardId,
        'title': title,
        'description': description,
        'assignedTo': assignedTo,
        'dueDate': dueDate.toIso8601String(),
        'evidenceRequired': evidenceRequired,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Closes a hazard directly (no remediation needed). The server
  /// re-validates the caller holds an authorized reviewer role, and that the
  /// hazard is not already closed or already linked to a corrective action.
  Future<void> closeHazard({
    required String organizationId,
    required String hazardId,
  }) => _call<Object?>('closeHazard', {
    'organizationId': organizationId,
    'hazardId': hazardId,
  });

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
