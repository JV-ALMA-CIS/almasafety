import '../../../core/offline/outbox.dart';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../corrective_actions/domain/corrective_action_evidence.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/firestore_service.dart';
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
    Outbox? outbox,
  }) : _injected = functions,
       _firestoreService = firestoreService ?? FirestoreService(),
       _outbox = outbox ?? Outbox.instance;

  final FirebaseFunctions? _injected;
  final FirestoreService _firestoreService;
  final Outbox _outbox;

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

    // Through the outbox: with no signal the report (and its photo) waits on
    // this phone. The pre-allocated id makes a repeat send harmless, and
    // occurredAt is the person's own time, so a late send keeps it.
    final result = await _send(
      'createIncident',
      {
        'organizationId': organizationId,
        'siteId': siteId,
        'incidentId': incidentId,
        'type': type,
        'description': description,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
        'location': ?location,
        'injuredPersonName': ?injuredPersonName,
        'immediateAction': ?immediateAction,
      },
      label: 'Incident report',
      photo: photoBytes != null && photoFileName != null
          ? OutboxPhoto(
              storagePath:
                  'organizations/$organizationId/incidents/$incidentId/'
                  '$photoFileName',
              bytes: photoBytes,
            )
          : null,
    );
    return result is Map ? result['id'] as String? ?? incidentId : incidentId;
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

  /// Sets (or changes) the incident's reporting level — Site
  /// Manager/Admin only.
  Future<void> setReportingLevel({
    required String organizationId,
    required String incidentId,
    required String level,
  }) => _call<Object?>('setIncidentReportingLevel', {
    'organizationId': organizationId,
    'incidentId': incidentId,
    'level': level,
  });

  /// Ticks a reporting step done (with an optional [note]) or un-ticks it.
  Future<void> recordReportingStep({
    required String organizationId,
    required String incidentId,
    required String stepId,
    required bool done,
    String? note,
  }) => _call<Object?>('recordIncidentReportingStep', {
    'organizationId': organizationId,
    'incidentId': incidentId,
    'stepId': stepId,
    'done': done,
    'note': ?note,
  });

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

  /// Sends [name] through the [Outbox]: with no signal the entry is saved on
  /// this phone and [SavedOfflineException] is thrown, and it is sent once
  /// the connection comes back.
  Future<Object?> _send(
    String name,
    Map<String, Object?> data, {
    required String label,
    OutboxPhoto? photo,
  }) async {
    try {
      return await _outbox.send(
        callable: name,
        data: data,
        label: label,
        photo: photo,
        caller: (name, data) async =>
            (await _require().httpsCallable(name).call<Object?>(data)).data,
      );
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    } on FirebaseException catch (e) {
      throw DataException(e.message ?? 'Failed to upload the photo.', cause: e);
    }
  }
}
