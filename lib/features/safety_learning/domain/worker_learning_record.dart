import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'knowledge_check_result.dart';
import 'worker_learning_status.dart';

/// One worker's progress record for one [SafetyLearning] item, stored at
/// `organizations/{organizationId}/worker_learning_records/{recordId}`
/// where `recordId` is the deterministic composite
/// `${workerUid}_${learningId}` — mirroring how [ActivityAssignment] uses
/// `uid` as its own document id for idempotency/uniqueness.
///
/// A deterministic id (not an auto-id) is used because a worker must have
/// at most one record per learning item: re-deriving the same id from
/// `(workerUid, learningId)` makes "create or update" trivially idempotent
/// server-side (`doc(id).set(..., {merge: true})`-style) without needing a
/// query to check for an existing record first, and makes the record
/// trivially addressable from either direction (a worker's own view, or an
/// admin's compliance view for one learning item).
///
/// **Server-authoritative, write-once-per-transition.** Created and
/// transitioned exclusively through the `getMyRequiredLearning` (lazy
/// `assigned` materialization), `startLearning` and `completeLearning`
/// callables in `functions/src/worker_learning_callable.ts`. None of those
/// callables accept a `workerUid` argument — every one derives it from
/// `request.auth.uid`, which is what makes it structurally impossible for a
/// worker to create or modify another worker's record. `firestore.rules`
/// denies every client write to this collection outright; read access is
/// scoped to the record's own `workerUid` or an organization/system
/// administrator. Read-only client-side, mirroring [Activity].
class WorkerLearningRecord {
  const WorkerLearningRecord({
    required this.id,
    required this.workerUid,
    required this.organizationId,
    required this.learningId,
    required this.status,
    this.assignedAt,
    this.startedAt,
    this.completedAt,
    this.contentCompletedAt,
    this.knowledgeCheckResult,
    this.contentCompletedFlag = false,
  });

  final String id;
  final String workerUid;
  final String organizationId;
  final String learningId;
  final WorkerLearningStatus status;
  final DateTime? assignedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  /// When the content step — watching the video, reading the document —
  /// was recorded as done (the minimum engagement time had passed). Set
  /// before [completedAt] when the item also has a mandatory quiz, so
  /// "video watched, quiz outstanding" is a real, persisted state. Absent
  /// on records written before this existed.
  final DateTime? contentCompletedAt;

  /// Whether the content step is done: recorded, or the whole item is.
  bool get contentCompleted =>
      contentCompletedAt != null ||
      contentCompletedFlag ||
      status == WorkerLearningStatus.completed;

  /// Set for a crew row, where the server reports only a yes/no instead of
  /// [contentCompletedAt].
  final bool contentCompletedFlag;

  /// Only present when the associated [SafetyLearning.type] is
  /// [SafetyLearningType.knowledgeCheck] and the worker has completed it.
  final KnowledgeCheckResult? knowledgeCheckResult;

  /// Parses a worker learning record document. Throws [DataException] on a
  /// missing or malformed document — see [Activity.fromFirestore] for why.
  factory WorkerLearningRecord.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That learning record could not be loaded.');
    }
    return WorkerLearningRecord.fromMap(doc.id, data);
  }

  factory WorkerLearningRecord.fromMap(String id, Map<String, dynamic> data) {
    final status = WorkerLearningStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException(
        'That learning record has an unrecognised status.',
      );
    }
    final workerUid = data['workerUid'] as String?;
    if (workerUid == null || workerUid.isEmpty) {
      throw const DataException('That learning record has no worker.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That learning record has no organization.');
    }
    final learningId = data['learningId'] as String?;
    if (learningId == null || learningId.isEmpty) {
      throw const DataException(
        'That learning record has no learning '
        'item.',
      );
    }
    final rawKnowledgeCheckResult = data['knowledgeCheckResult'];
    return WorkerLearningRecord(
      id: id,
      workerUid: workerUid,
      organizationId: organizationId,
      learningId: learningId,
      status: status,
      assignedAt: (data['assignedAt'] as Timestamp?)?.toDate(),
      startedAt: (data['startedAt'] as Timestamp?)?.toDate(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      contentCompletedAt: (data['contentCompletedAt'] as Timestamp?)?.toDate(),
      contentCompletedFlag: data['contentCompleted'] == true,
      knowledgeCheckResult: rawKnowledgeCheckResult is Map<String, dynamic>
          ? KnowledgeCheckResult.fromMap(rawKnowledgeCheckResult)
          : null,
    );
  }
}
