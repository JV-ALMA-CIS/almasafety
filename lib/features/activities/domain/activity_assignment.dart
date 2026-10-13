import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// A worker's assignment to one activity, stored at
/// `organizations/{organizationId}/activities/{activityId}/assignments/{uid}`
/// — one document per worker per activity, keyed by the worker's own uid so
/// an assignment is idempotent to create and trivial to look up or remove.
///
/// [siteId] and [projectId] are denormalized from the parent activity at
/// assignment time purely for query convenience (they let a query filter
/// assignments by site or project without a join); neither carries any
/// authorization weight of its own. [projectId] is nullable — assignments
/// written before this field existed have none, and that is not an error;
/// see [SafetyRequirement]'s project-scope applicability, which simply
/// treats a null [projectId] as "no project-scoped requirement can match."
///
/// Created and removed exclusively through the `assignWorkerToActivity`/
/// `removeWorkerFromActivity` callables — see
/// `functions/src/activity_assignment_callable.ts` — which re-validate the
/// worker's site membership server-side before writing. This is therefore a
/// read-only model, mirroring [Activity].
class ActivityAssignment {
  const ActivityAssignment({
    required this.uid,
    required this.organizationId,
    required this.siteId,
    required this.activityId,
    this.projectId,
    this.assignedAt,
    this.assignedBy,
  });

  final String uid;
  final String organizationId;
  final String siteId;
  final String activityId;
  final String? projectId;
  final DateTime? assignedAt;
  final String? assignedBy;

  /// Parses an assignment document. Throws [DataException] on a missing or
  /// malformed document — see [Activity.fromFirestore] for why.
  factory ActivityAssignment.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That assignment could not be loaded.');
    }
    return ActivityAssignment.fromMap(doc.id, data);
  }

  factory ActivityAssignment.fromMap(String id, Map<String, dynamic> data) {
    final uid = data['uid'] as String? ?? id;
    final organizationId = data['organizationId'] as String?;
    final siteId = data['siteId'] as String?;
    final activityId = data['activityId'] as String?;
    if (uid.isEmpty) {
      throw const DataException('That assignment has no worker.');
    }
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That assignment has no organization.');
    }
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That assignment has no site.');
    }
    if (activityId == null || activityId.isEmpty) {
      throw const DataException('That assignment has no activity.');
    }
    return ActivityAssignment(
      uid: uid,
      organizationId: organizationId,
      siteId: siteId,
      activityId: activityId,
      projectId: data['projectId'] as String?,
      assignedAt: (data['assignedAt'] as Timestamp?)?.toDate(),
      assignedBy: data['assignedBy'] as String?,
    );
  }
}
