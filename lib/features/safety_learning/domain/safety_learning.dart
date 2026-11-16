import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/domain/organization_record_status.dart';
import 'safety_learning_type.dart';

/// A piece of safety learning content, stored at
/// `organizations/{organizationId}/safety_learning/{id}` — a flat sibling of
/// `activities`, matching [Activity]'s doc comment's shape.
///
/// [contentReference] is a single opaque string (a URL or document
/// reference) — deliberately not a rich content-block model or a file-upload
/// pipeline; this stage keeps content management minimal.
///
/// [minimumWatchSeconds] applies to ANY [SafetyLearningType] — not just
/// [SafetyLearningType.video] — see `completeLearning`'s doc comment
/// (`functions/src/worker_learning_callable.ts`) for the honest verification
/// this enables and its limitation: it enforces elapsed real time since the
/// worker's own `startLearning` call (a genuine server timestamp), NOT
/// verified watch position/percentage or reading completion, which nothing
/// in this architecture (a direct-URL player or an externally-opened
/// content link, no hosting/DRM/analytics service) can trust from the
/// client. Null/zero means no minimum is enforced, matching every
/// pre-existing item's behavior unchanged.
///
/// [passingScorePercent] governs the KNOWLEDGE-CHECK GATE — deliberately
/// NOT confined to [SafetyLearningType.knowledgeCheck] items. Any item
/// (including a [SafetyLearningType.video] one) that has at least one
/// `knowledge_check_questions` document configured is gated on this
/// threshold; an item with zero configured questions has no knowledge-check
/// gate at all, regardless of this value — see `completeLearning`'s
/// "ZERO QUESTIONS -> NO GATE" doc comment
/// (`functions/src/worker_learning_callable.ts`). This lets a single video
/// item require BOTH `minimumWatchSeconds` AND a passing quiz score. The
/// questions themselves (and their correct answers) are never readable
/// client-side — see `KnowledgeCheckQuestion`'s doc comment.
///
/// Created and edited exclusively through the `createSafetyLearning`/
/// `updateSafetyLearning` callables by a System Administrator or an
/// Organization Administrator of the item's own organization — see
/// `functions/src/safety_learning_callable.ts`. Read-only client-side,
/// mirroring [Activity].
class SafetyLearning {
  const SafetyLearning({
    required this.id,
    required this.organizationId,
    required this.title,
    required this.type,
    required this.contentReference,
    required this.status,
    this.description,
    this.minimumWatchSeconds,
    this.passingScorePercent,
    this.deletionPending = false,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String title;
  final String? description;
  final SafetyLearningType type;
  final String contentReference;
  final OrganizationRecordStatus status;

  /// The minimum number of seconds that must elapse between `startLearning`
  /// and `completeLearning` before a video item can be completed. Only
  /// meaningful when [type] is [SafetyLearningType.video]; null/zero means
  /// no minimum. See this class's doc comment for what this does and does
  /// not verify.
  final int? minimumWatchSeconds;

  /// The minimum percentage score (0-100) required to pass this item's
  /// knowledge check. Only meaningful when at least one question is
  /// configured — see this class's doc comment.
  final int? passingScorePercent;

  /// A deletion was started but could not finish (its uploaded file or
  /// documents could not be removed yet) — see `deleteSafetyLearning`. The
  /// item is hidden (inactive) and cannot be edited; choosing Delete again
  /// finishes it, and the server also retries on a schedule.
  final bool deletionPending;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses a safety learning document. Throws [DataException] on a missing
  /// or malformed document — see [Activity.fromFirestore] for why.
  factory SafetyLearning.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException(
        'That safety learning item could not be '
        'loaded.',
      );
    }
    return SafetyLearning.fromMap(doc.id, data);
  }

  factory SafetyLearning.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That safety learning item has an unrecognised status.',
      );
    }
    final type = SafetyLearningType.tryFromId(data['type'] as String?);
    if (type == null) {
      throw const DataException(
        'That safety learning item has an unrecognised type.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That safety learning item has no organization.',
      );
    }
    return SafetyLearning(
      id: id,
      organizationId: organizationId,
      title: data['title'] as String? ?? '',
      description: data['description'] as String?,
      type: type,
      contentReference: data['contentReference'] as String? ?? '',
      status: status,
      minimumWatchSeconds: (data['minimumWatchSeconds'] as num?)?.toInt(),
      passingScorePercent: (data['passingScorePercent'] as num?)?.toInt(),
      deletionPending:
          data['deletion'] is Map &&
          (data['deletion'] as Map)['pending'] == true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
