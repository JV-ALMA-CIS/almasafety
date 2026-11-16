import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/offline/outbox.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/storage_service.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../pre_start_checks/domain/pre_start_outcome.dart';
import '../domain/meeting_evidence_type.dart';

/// Client for the foreman-facing meeting callables in
/// `functions/src/daily_safety_meeting_callable.ts`.
///
/// **This platform does not conduct or record the physical meeting.** Every
/// method here writes only structured facts — which activities and meeting
/// points a meeting covers, plain-text concerns, and completion — never
/// audio, transcription or translation. None of these callables accept a
/// `foremanId` argument: every one derives the acting foreman from
/// `request.auth.uid` server-side, mirroring [WorkerLearningService]'s
/// "no `workerUid` argument" discipline exactly.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [SafetyMeetingPointAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class DailySafetyMeetingService {
  DailySafetyMeetingService({
    FirebaseFunctions? functions,
    FirestoreService? firestoreService,
    StorageService? storageService,
    this._outbox,
  }) : _injected = functions,
       _firestoreService = firestoreService ?? FirestoreService(),
       _storageService = storageService ?? StorageService();

  final FirebaseFunctions? _injected;
  final Outbox? _outbox;
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

  /// Starts today's meeting for [siteId] within [organizationId]/
  /// [projectId]. The server re-validates the caller is a `foreman` with
  /// [siteId] in their own `siteIds`, and that the site belongs to the given
  /// organization/project — nothing here is trusted from the client alone.
  /// Returns the new meeting's id.
  Future<String> createDailySafetyMeeting({
    required String organizationId,
    required String projectId,
    required String siteId,
    List<String> activityIds = const [],
    List<String> meetingPointIds = const [],
  }) async {
    final result =
        await _call<Map<Object?, Object?>>('createDailySafetyMeeting', {
          'organizationId': organizationId,
          'projectId': projectId,
          'siteId': siteId,
          'activityIds': activityIds,
          'meetingPointIds': meetingPointIds,
        });
    return result['id'] as String? ?? '';
  }

  /// Updates an in-progress meeting's activities, meeting points and/or
  /// concerns. Only the meeting's own foreman may call this — the server
  /// re-checks `meeting.foremanId == request.auth.uid`.
  Future<void> updateDailySafetyMeeting(
    String organizationId,
    String id, {
    List<String>? activityIds,
    List<String>? meetingPointIds,
    List<String>? concerns,
    List<String>? ahaIds,
  }) => _call<Object?>('updateDailySafetyMeeting', {
    'organizationId': organizationId,
    'id': id,
    'activityIds': ?activityIds,
    'meetingPointIds': ?meetingPointIds,
    'concerns': ?concerns,
    'ahaIds': ?ahaIds,
  });

  /// Completes the meeting: the server requires at least one activity and
  /// one meeting point (from the library or the Foreman's own) already
  /// recorded, then sets `status` to `completed`
  /// and records the Foreman's [crewOutcome] for the crew (with
  /// [crewOutcomeNote], required unless the outcome is GO). A crew STOP
  /// notifies the organization's Site Managers.
  Future<void> completeDailySafetyMeeting(
    String organizationId,
    String id, {
    PreStartOutcome? crewOutcome,
    String? crewOutcomeNote,
  }) => _call<Object?>('completeDailySafetyMeeting', {
    'organizationId': organizationId,
    'id': id,
    'crewOutcome': ?crewOutcome?.id,
    'crewOutcomeNote': ?crewOutcomeNote,
  });

  /// The calling Foreman's own outstanding "Needed today" lessons for a
  /// meeting at [siteId] covering [activityIds] — [meetingId] null before it
  /// is started. Exactly what Start/Complete will check server-side.
  Future<List<({String learningId, String title})>> getMyMeetingLearningGate({
    required String organizationId,
    required String siteId,
    required List<String> activityIds,
    String? meetingId,
  }) async {
    final result =
        await _call<Map<Object?, Object?>>('getMyMeetingLearningGate', {
          'organizationId': organizationId,
          'siteId': siteId,
          'activityIds': activityIds,
          'meetingId': ?meetingId,
        });
    final outstanding = result['outstanding'];
    return [
      if (outstanding is List)
        for (final entry in outstanding.whereType<Map<Object?, Object?>>())
          if (entry['learningId'] is String)
            (
              learningId: entry['learningId']! as String,
              title: entry['title'] is String
                  ? entry['title']! as String
                  : entry['learningId']! as String,
            ),
    ];
  }

  /// The meeting points suggested for a meeting at [siteId] covering
  /// [activityIds], best first, each with the reasons it is suggested —
  /// the same list `createDailySafetyMeeting` records on the meeting as its
  /// suggestion snapshot.
  Future<List<({String pointId, List<String> reasons})>>
  getMeetingPointSuggestions({
    required String organizationId,
    required String siteId,
    required List<String> activityIds,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getMeetingPointSuggestions',
      {
        'organizationId': organizationId,
        'siteId': siteId,
        'activityIds': activityIds,
      },
    );
    final suggestions = result['suggestions'];
    return [
      if (suggestions is List)
        for (final entry in suggestions.whereType<Map<Object?, Object?>>())
          if (entry['pointId'] is String)
            (
              pointId: entry['pointId']! as String,
              reasons: [
                if (entry['reasons'] is List)
                  for (final reason in entry['reasons']! as List)
                    if (reason is String) reason,
              ],
            ),
    ];
  }

  /// Sets (creates or overwrites) the discussion note for one meeting point
  /// on an in-progress meeting — what was actually explained/discussed
  /// about it, kept deliberately separate from Concerns (see
  /// [MeetingPointNote]'s doc comment). Refuses if [meetingPointId] is not
  /// currently on the meeting's own `meetingPointIds`, or once the meeting
  /// is completed.
  Future<void> setMeetingPointNote({
    required String organizationId,
    required String meetingId,
    required String meetingPointId,
    required String note,
  }) => _call<Object?>('setMeetingPointNote', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'meetingPointId': meetingPointId,
    'note': note,
  });

  /// Removes a meeting point's discussion note from an in-progress meeting.
  /// Succeeds even if the point itself was already removed from
  /// `meetingPointIds` — this is how the client cleans up a note when the
  /// point is removed from the meeting entirely, see
  /// `functions/src/daily_safety_meeting_callable.ts`'s doc comment on
  /// `removeMeetingPointNote`.
  Future<void> removeMeetingPointNote({
    required String organizationId,
    required String meetingId,
    required String meetingPointId,
  }) => _call<Object?>('removeMeetingPointNote', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'meetingPointId': meetingPointId,
  });

  /// A new id for one of the Foreman's own points — chosen on the phone so
  /// a point saved with no signal and sent twice is stored only once.
  static String newForemanPointId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(20, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  /// Adds or edits one of the Foreman's own points on [meetingId] — a
  /// [title], an optional [note] on what was discussed and an optional
  /// [activityId] from the meeting's activities. Adding works after the
  /// meeting is completed; editing does not. See [MeetingForemanPoint].
  ///
  /// With no signal the point is saved on this phone (throwing
  /// [SavedOfflineException]) and sent when the connection comes back.
  Future<void> saveMeetingForemanPoint({
    required String organizationId,
    required String meetingId,
    required String pointId,
    required String title,
    String? note,
    String? activityId,
  }) => _send('saveMeetingForemanPoint', "Meeting point - $title", {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'pointId': pointId,
    'title': title,
    'note': ?note,
    'activityId': ?activityId,
  });

  /// Removes one of the Foreman's own points from an in-progress meeting.
  /// With no signal the removal is saved on this phone and sent later.
  Future<void> removeMeetingForemanPoint({
    required String organizationId,
    required String meetingId,
    required String pointId,
  }) => _send('removeMeetingForemanPoint', 'Remove meeting point', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'pointId': pointId,
  });

  /// Sends [name] through the [Outbox], mirroring
  /// [MeetingAttendanceService.recordMeetingAttendance].
  Future<void> _send(
    String name,
    String label,
    Map<String, Object?> data,
  ) async {
    try {
      await (_outbox ?? Outbox.instance).send(
        callable: name,
        data: data,
        label: label,
        caller: (name, data) async =>
            (await _require().httpsCallable(name).call<Object?>(data)).data,
      );
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }

  /// Pre-allocates an evidence document id, without writing anything — the
  /// first step of [uploadMeetingEvidence], mirroring
  /// [HazardService.allocateHazardId]'s exact pattern. Exposed separately so
  /// a caller can start the Storage upload against a known path before
  /// calling the metadata callable.
  String allocateEvidenceId(String organizationId, String meetingId) {
    return _firestoreService.require
        .collection(
          FirestorePaths.meetingEvidenceCollection(organizationId, meetingId),
        )
        .doc()
        .id;
  }

  /// Uploads [bytes] to
  /// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/{evidenceId}/{fileName}`
  /// and returns its download URL, mirroring
  /// [HazardService.uploadHazardPhoto]'s exact pattern. Any org member may
  /// upload here — see `storage.rules`' org-scoped write grant — so this
  /// performs no separate authorization check of its own; `addMeetingEvidence`
  /// is what authorizes the metadata write that follows.
  Future<String> uploadEvidenceFile({
    required String organizationId,
    required String meetingId,
    required String evidenceId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    try {
      final ref = _storageService
          .orgRef(organizationId)
          .child('daily_safety_meetings/$meetingId/$evidenceId/$fileName');
      await ref.putData(bytes);
      return await ref.getDownloadURL();
    } on Object catch (e) {
      throw DataException('Failed to upload the evidence file.', cause: e);
    }
  }

  /// Records one piece of evidence end-to-end: pre-allocates the id,
  /// uploads [bytes] to a path scoped to that id, then calls
  /// `addMeetingEvidence` with the resulting `storagePath`/`downloadUrl` —
  /// mirroring [HazardService.reportHazard]'s exact sequencing. Unlike
  /// every other write on this meeting, this succeeds even once the
  /// meeting is `completed` — see [MeetingEvidence]'s doc comment.
  Future<String> uploadMeetingEvidence({
    required String organizationId,
    required String meetingId,
    required String fileName,
    required Uint8List bytes,
    required String fileType,
    required MeetingEvidenceType evidenceType,
    String? description,
  }) async {
    final evidenceId = allocateEvidenceId(organizationId, meetingId);
    // Matches the exact path StorageService.orgRef(...).child(...) builds in
    // uploadEvidenceFile below — kept as a single string built here (rather
    // than a shared helper) since it must exactly match what
    // addMeetingEvidence's own requireOwnMeeting-adjacent path-prefix check
    // expects: organizations/{orgId}/daily_safety_meetings/{meetingId}/...
    final storagePath =
        'organizations/$organizationId/daily_safety_meetings/$meetingId/'
        '$evidenceId/$fileName';
    final downloadUrl = await uploadEvidenceFile(
      organizationId: organizationId,
      meetingId: meetingId,
      evidenceId: evidenceId,
      fileName: fileName,
      bytes: bytes,
    );

    await _call<Object?>('addMeetingEvidence', {
      'organizationId': organizationId,
      'meetingId': meetingId,
      'evidenceId': evidenceId,
      'storagePath': storagePath,
      'downloadUrl': downloadUrl,
      'fileType': fileType,
      'evidenceType': evidenceType.id,
      'description': ?description,
    });

    return evidenceId;
  }

  /// Removes one piece of evidence from an in-progress meeting. Refuses
  /// once the meeting is completed — evidence may still be added
  /// afterward, but never removed, see [MeetingEvidence]'s doc comment.
  Future<void> removeMeetingEvidence({
    required String organizationId,
    required String meetingId,
    required String evidenceId,
  }) => _call<Object?>('removeMeetingEvidence', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'evidenceId': evidenceId,
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
