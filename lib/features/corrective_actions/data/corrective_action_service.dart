import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/storage_service.dart';
import '../domain/corrective_action_evidence.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `createCorrectiveAction`/`updateCorrectiveActionStatus`
/// callables in `functions/src/corrective_action_callable.ts`.
///
/// Mirrors [MeetingConcernService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has
/// run — e.g. in widget tests. Neither callable accepts an `assignedBy`
/// argument: the server derives the acting foreman from `request.auth.uid`,
/// mirroring every other write surface in this feature.
class CorrectiveActionService {
  CorrectiveActionService({
    FirebaseFunctions? functions,
    StorageService? storageService,
  }) : _injected = functions,
       _storageService = storageService ?? StorageService();

  final FirebaseFunctions? _injected;
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

  /// Creates a corrective action within [organizationId], from EITHER
  /// [meetingId] (optionally naming a specific [concernId]) OR [hazardId] —
  /// exactly one of the two must be given, mirroring
  /// `createCorrectiveAction`'s own "exactly one of meetingId or hazardId"
  /// server-side validation.
  ///
  /// MEETING-ORIGINATED: the server re-validates the caller is the meeting's
  /// own foreman on an `inProgress` meeting, and that [concernId] (when
  /// given) belongs to that meeting.
  ///
  /// HAZARD-ORIGINATED: the server re-validates the caller holds an
  /// authorized reviewer role, and that the hazard is not already closed or
  /// already linked to another corrective action — same path as
  /// `HazardService.linkCorrectiveAction`, which calls the same underlying
  /// implementation server-side.
  ///
  /// In both cases, [assignedTo] must be an active member of this
  /// organization — nothing here is trusted from the client alone. Returns
  /// the new action's id.
  Future<String> createCorrectiveAction({
    required String organizationId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    String? meetingId,
    String? concernId,
    String? hazardId,
    String? incidentId,
    bool evidenceRequired = false,
    List<CorrectiveActionEvidenceKind> evidenceKinds = const [],
    String? evidenceInstructions,
  }) async {
    assert(
      [meetingId, hazardId, incidentId].nonNulls.length == 1,
      'Exactly one of meetingId, hazardId or incidentId must be given.',
    );
    final result = await _call<Map<Object?, Object?>>(
      'createCorrectiveAction',
      {
        'organizationId': organizationId,
        'title': title,
        'description': description,
        'assignedTo': assignedTo,
        'dueDate': dueDate.toIso8601String(),
        'meetingId': ?meetingId,
        'concernId': ?concernId,
        'hazardId': ?hazardId,
        'incidentId': ?incidentId,
        'evidenceRequired': evidenceRequired || evidenceKinds.isNotEmpty,
        'evidenceKinds': [for (final kind in evidenceKinds) kind.id],
        'evidenceInstructions': ?evidenceInstructions,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Transitions [actionId]'s status. The server re-validates the caller
  /// holds an authorized supervisor/manager role (`admin`/`siteManager`)
  /// within [organizationId] — see `requireOrganizationScopedReviewer` in
  /// the callable file. `completed` is only accepted from
  /// `submittedForReview` — see [submitForReview] for the assignee's own
  /// half of that split.
  Future<void> updateCorrectiveActionStatus({
    required String organizationId,
    required String actionId,
    required String status,
    String? reviewFeedback,
  }) => _call<Object?>('updateCorrectiveActionStatus', {
    'organizationId': organizationId,
    'actionId': actionId,
    'status': status,
    'reviewFeedback': ?reviewFeedback,
  });

  /// Submits [actionId] for review — the assignee's own claim that the work
  /// is done, moving `open`/`inProgress` to `submittedForReview`. The server
  /// re-validates the caller IS the action's own `assignedTo`; a reviewer
  /// role has no special standing here and is refused, exactly like anyone
  /// else who is not the assignee. See `updateCorrectiveActionStatus` for
  /// the reviewer's subsequent verification step.
  ///
  /// [completionNote] is the assignee's account of what was done and
  /// [evidencePhotos] the photos already uploaded with [uploadEvidencePhoto];
  /// the server refuses a submission missing evidence the action requires.
  Future<void> submitForReview({
    required String organizationId,
    required String actionId,
    String? completionNote,
    List<EvidencePhoto> evidencePhotos = const [],
  }) => _call<Object?>('submitCorrectiveActionForReview', {
    'organizationId': organizationId,
    'actionId': actionId,
    'completionNote': ?completionNote,
    'evidencePhotos': [for (final photo in evidencePhotos) photo.toJson()],
  });

  /// Uploads one evidence photo to this action's own Storage folder,
  /// `organizations/{organizationId}/corrective_actions/{actionId}/` — the
  /// only folder `submitCorrectiveActionForReview` accepts photos from.
  Future<EvidencePhoto> uploadEvidencePhoto({
    required String organizationId,
    required String actionId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'corrective_actions/$actionId/${stamp}_$fileName';
    try {
      final ref = _storageService.orgRef(organizationId).child(path);
      await ref.putData(bytes);
      return EvidencePhoto(
        storagePath: 'organizations/$organizationId/$path',
        downloadUrl: await ref.getDownloadURL(),
      );
    } on FirebaseException catch (e) {
      throw DataException(
        e.message ?? 'Failed to upload the evidence photo.',
        cause: e,
      );
    }
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
