import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'corrective_action_evidence.dart';
import 'corrective_action_status.dart';

/// A corrective action raised from a Daily Safety Meeting OR a Hazard report,
/// stored flat at `organizations/{organizationId}/corrective_actions/{id}` —
/// a sibling of `daily_safety_meetings` and `hazards`, not a subcollection of
/// either, matching `FirestorePaths.correctiveActions`'s already-reserved
/// top-level shape. Flat so an authorized supervisor's Corrective Actions
/// list can query every action across every meeting/hazard/site in one
/// collection, exactly like `WorkerLearningRepository.watchForOrganization`
/// queries every worker's records in one collection rather than fanning out
/// per learning item.
///
/// **Concern → Corrective Action → Assigned Person → Due Date →
/// Completion**, OR **Hazard → Corrective Action → Assigned Person → Due
/// Date → Completion.** Every corrective action traces back to exactly one
/// origin — [meetingId] (and, usually, the specific [concernId]), [hazardId]
/// OR [incidentId], never more than one — see `FIRESTORE_DATA_MODEL.md` §7 and
/// `functions/src/corrective_action_callable.ts`'s "exactly one of meetingId
/// or hazardId" validation.
///
/// **Evidence upload is explicitly out of scope for this stage** —
/// [evidenceRequired] only flags whether completing this action will
/// eventually need to attach evidence; there is no evidence field or upload
/// path here yet.
///
/// Created exclusively through `createCorrectiveAction` (by the meeting's
/// own foreman for a meeting-originated action, or an authorized reviewer
/// for a hazard-originated one — also reachable via
/// `linkHazardCorrectiveAction`); status is transitioned exclusively through
/// `updateCorrectiveActionStatus` by an authorized supervisor/manager role —
/// see `functions/src/corrective_action_callable.ts`. Read-only client-side,
/// mirroring [MeetingConcern]. **Never deletable** — a corrective action is
/// part of the permanent safety record once created, exactly like a
/// completed [DailySafetyMeeting]'s own concerns.
class CorrectiveAction {
  const CorrectiveAction({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.title,
    required this.description,
    required this.assignedTo,
    required this.assignedBy,
    required this.dueDate,
    required this.status,
    required this.evidenceRequired,
    this.meetingId,
    this.concernId,
    this.hazardId,
    this.incidentId,
    this.createdAt,
    this.updatedAt,
    this.completedAt,
    this.assignedToName,
    this.assignedByName,
    this.completedByName,
    this.evidenceKinds = const [],
    this.evidenceInstructions,
    this.completionNote,
    this.evidencePhotos = const [],
    this.submittedAt,
    this.reviewFeedback,
  });

  /// Names stored when the action was created/completed, so every screen
  /// shows a person, never a uid. Null on actions created before names were
  /// stored — screens then look the name up, or say "a supervisor".
  final String? assignedToName;
  final String? assignedByName;
  final String? completedByName;

  /// What evidence completing this needs — see [requiredEvidence].
  final List<CorrectiveActionEvidenceKind> evidenceKinds;

  /// Optional detail from the creator, e.g. "Photo of the new guard rail".
  final String? evidenceInstructions;

  /// The assignee's own account of what was done, sent with their evidence.
  final String? completionNote;
  final List<EvidencePhoto> evidencePhotos;
  final DateTime? submittedAt;

  /// Why a reviewer sent the work back, shown to the assignee until they
  /// resubmit.
  final String? reviewFeedback;

  /// The evidence the assignee must attach — [evidenceKinds], or a photo
  /// for an action created before kinds existed with only
  /// [evidenceRequired] set (what that flag always meant on screen).
  List<CorrectiveActionEvidenceKind> get requiredEvidence {
    if (evidenceKinds.isNotEmpty) return evidenceKinds;
    return evidenceRequired
        ? const [CorrectiveActionEvidenceKind.photo]
        : const [];
  }

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;

  /// The meeting this action was raised from, when meeting-originated. Null
  /// for a hazard-originated action — see this class's doc comment.
  final String? meetingId;

  /// The specific [MeetingConcern] this action addresses, when raised from
  /// one. Null when raised directly from the meeting without pointing at a
  /// single recorded concern, and always null for a hazard-originated
  /// action.
  final String? concernId;

  /// The hazard this action was raised from, when hazard-originated. Null
  /// for a meeting-originated action — see this class's doc comment.
  final String? hazardId;

  /// The incident this action was raised from during its investigation, when
  /// incident-originated. An incident may have several actions.
  final String? incidentId;

  final String title;
  final String description;

  /// The uid of the worker/supervisor responsible for completing this
  /// action.
  final String assignedTo;

  /// The uid of the foreman who created this action.
  final String assignedBy;
  final DateTime dueDate;
  final CorrectiveActionStatus status;

  /// Whether completing this action will require evidence to be attached —
  /// a flag only; there is no evidence upload path yet (see this class's
  /// doc comment).
  final bool evidenceRequired;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? completedAt;

  bool get isCompleted => status.isTerminal;

  /// Parses a corrective action document. Throws [DataException] on a
  /// missing or malformed document — see [MeetingConcern.fromFirestore] for
  /// why.
  factory CorrectiveAction.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That corrective action could not be loaded.');
    }
    return CorrectiveAction.fromMap(doc.id, data);
  }

  factory CorrectiveAction.fromMap(String id, Map<String, dynamic> data) {
    final status = CorrectiveActionStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException(
        'That corrective action has an unrecognised status.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That corrective action has no organization.');
    }
    final projectId = data['projectId'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That corrective action has no project.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That corrective action has no site.');
    }
    final rawMeetingId = data['meetingId'] as String?;
    final meetingId = (rawMeetingId != null && rawMeetingId.isNotEmpty)
        ? rawMeetingId
        : null;
    final rawHazardId = data['hazardId'] as String?;
    final hazardId = (rawHazardId != null && rawHazardId.isNotEmpty)
        ? rawHazardId
        : null;
    final rawIncidentId = data['incidentId'] as String?;
    final incidentId = (rawIncidentId != null && rawIncidentId.isNotEmpty)
        ? rawIncidentId
        : null;
    if ([meetingId, hazardId, incidentId].nonNulls.length != 1) {
      throw const DataException('That corrective action has no valid origin.');
    }
    final title = data['title'] as String?;
    if (title == null || title.isEmpty) {
      throw const DataException('That corrective action has no title.');
    }
    final description = data['description'] as String?;
    if (description == null || description.isEmpty) {
      throw const DataException('That corrective action has no description.');
    }
    final assignedTo = data['assignedTo'] as String?;
    if (assignedTo == null || assignedTo.isEmpty) {
      throw const DataException('That corrective action has no assignee.');
    }
    final assignedBy = data['assignedBy'] as String?;
    if (assignedBy == null || assignedBy.isEmpty) {
      throw const DataException(
        'That corrective action has no assigning foreman.',
      );
    }
    final dueDate = (data['dueDate'] as Timestamp?)?.toDate();
    if (dueDate == null) {
      throw const DataException('That corrective action has no due date.');
    }
    final rawConcernId = data['concernId'] as String?;
    return CorrectiveAction(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      siteId: siteId,
      meetingId: meetingId,
      concernId: (rawConcernId != null && rawConcernId.isNotEmpty)
          ? rawConcernId
          : null,
      hazardId: hazardId,
      incidentId: incidentId,
      title: title,
      description: description,
      assignedTo: assignedTo,
      assignedBy: assignedBy,
      dueDate: dueDate,
      status: status,
      evidenceRequired: data['evidenceRequired'] as bool? ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      assignedToName: _nonEmpty(data['assignedToName']),
      assignedByName: _nonEmpty(data['assignedByName']),
      completedByName: _nonEmpty(data['completedByName']),
      evidenceKinds: [
        for (final raw in (data['evidenceKinds'] as List?) ?? const [])
          ?CorrectiveActionEvidenceKind.tryFromId(raw as String?),
      ],
      evidenceInstructions: _nonEmpty(data['evidenceInstructions']),
      completionNote: _nonEmpty(data['completionNote']),
      evidencePhotos: [
        for (final raw in (data['evidencePhotos'] as List?) ?? const [])
          ?EvidencePhoto.tryFromMap(raw),
      ],
      submittedAt: (data['submittedAt'] as Timestamp?)?.toDate(),
      reviewFeedback: _nonEmpty(data['reviewFeedback']),
    );
  }
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
