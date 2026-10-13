import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../corrective_actions/domain/corrective_action_evidence.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/storage_service.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the incident callables in `functions/src/incident_callable.ts`
/// (`createIncident`/`startIncidentInvestigation`/
/// `linkIncidentCorrectiveAction`/`closeIncident`), plus the photo upload
/// that precedes `createIncident` — the same pre-allocate-id, upload, then
/// create sequence as [HazardService].
class IncidentService {
  IncidentService({
    FirebaseFunctions? functions,
    FirestoreService? firestoreService,
    StorageService? storageService,
  }) : _injected = functions,
       _firestoreService = firestoreService ?? FirestoreService(),
       _storageService = storageService ?? StorageService();

  final FirebaseFunctions? _injected;
  final FirestoreService _firestoreService;
  final StorageService _storageService;

  FirebaseFunctions _require() {
    final injected = _injected;
    if (injected != null) return injected;
    if (Firebase.apps.isEmpty) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return FirebaseFunctions.instance;
  }

  /// Reports an incident end-to-end: pre-allocates the id, uploads
  /// [photoBytes] (when given) to a path scoped to it, then calls
  /// `createIncident`. Returns the new incident's id.
  Future<String> reportIncident({
    required String organizationId,
    required String siteId,
    required String type,
    required String description,
    required DateTime occurredAt,
    String? location,
    String? injuredPersonName,
    String? immediateAction,
    String? photoFileName,
    Uint8List? photoBytes,
  }) async {
    final incidentId = _firestoreService.require
        .collection(FirestorePaths.incidentsCollection(organizationId))
        .doc()
        .id;

    String? photoUrl;
    if (photoBytes != null && photoFileName != null) {
      try {
        final ref = _storageService
            .orgRef(organizationId)
            .child('incidents/$incidentId/$photoFileName');
        await ref.putData(photoBytes);
        photoUrl = await ref.getDownloadURL();
      } on FirebaseException catch (e) {
        throw DataException(
          e.message ?? 'Failed to upload the incident photo.',
          cause: e,
        );
      }
    }

    final result = await _call<Map<Object?, Object?>>('createIncident', {
      'organizationId': organizationId,
      'siteId': siteId,
      'incidentId': incidentId,
      'type': type,
      'description': description,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      'location': ?location,
      'injuredPersonName': ?injuredPersonName,
      'immediateAction': ?immediateAction,
      'photoUrl': ?photoUrl,
    });
    return result['id'] as String? ?? incidentId;
  }

  /// Starts the investigation, classifying [severity]. Reviewer roles only.
  Future<void> startInvestigation({
    required String organizationId,
    required String incidentId,
    required String severity,
  }) => _call<Object?>('startIncidentInvestigation', {
    'organizationId': organizationId,
    'incidentId': incidentId,
    'severity': severity,
  });

  /// Raises a corrective action from an incident under investigation.
  /// Returns the new action's id.
  Future<String> linkCorrectiveAction({
    required String organizationId,
    required String incidentId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    bool evidenceRequired = false,
    List<CorrectiveActionEvidenceKind> evidenceKinds = const [],
    String? evidenceInstructions,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'linkIncidentCorrectiveAction',
      {
        'organizationId': organizationId,
        'incidentId': incidentId,
        'title': title,
        'description': description,
        'assignedTo': assignedTo,
        'dueDate': dueDate.toIso8601String(),
        'evidenceRequired': evidenceRequired || evidenceKinds.isNotEmpty,
        'evidenceKinds': [for (final kind in evidenceKinds) kind.id],
        'evidenceInstructions': ?evidenceInstructions,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Closes an incident with its [rootCause]. The server refuses while any
  /// of its corrective actions is incomplete.
  Future<void> closeIncident({
    required String organizationId,
    required String incidentId,
    required String rootCause,
    String? closingNotes,
  }) => _call<Object?>('closeIncident', {
    'organizationId': organizationId,
    'incidentId': incidentId,
    'rootCause': rootCause,
    'closingNotes': ?closingNotes,
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
