import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// A worker's assignment to one activity, stored at
/// `organizations/{organizationId}/activities/{activityId}/assignments/{uid}`
/// — one document per worker per activity, keyed by the worker's own uid so
/// an assignment is idempotent to create and trivial to look up or remove.
///
/// [siteId] is denormalized from the parent activity at assignment time
/// purely for query convenience (it lets a query filter assignments by site
/// without a join); it carries no authorization weight of its own.
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
    this.assignedAt,
    this.assignedBy,
  });

  final String uid;
  final String organizationId;
  final String siteId;
  final String activityId;
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
      assignedAt: (data['assignedAt'] as Timestamp?)?.toDate(),
      assignedBy: data['assignedBy'] as String?,
    );
  }
}
