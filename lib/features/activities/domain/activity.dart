import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/domain/organization_record_status.dart';

/// An activity within a site, stored at
/// `organizations/{organizationId}/activities/{id}` — a flat sibling of
/// `sites`, not nested under it; [projectId] and [siteId] are fields, not
/// path segments, so an activity is addressable by organization alone
/// without knowing its project or site. Mirrors [Site]'s doc comment.
///
/// Created and edited exclusively through the `createActivity`/
/// `updateActivity` callables by a System Administrator or an Organization
/// Administrator of the activity's own organization — see
/// `functions/src/activity_callable.ts`. The callable enforces
/// `activity.organizationId == site.organizationId` and
/// `activity.projectId == site.projectId` server-side before writing, so
/// every [Activity] this class ever parses is guaranteed to belong to the
/// site it names.
class Activity {
  const Activity({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.name,
    required this.code,
    required this.status,
    this.description,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;
  final String name;
  final String code;
  final String? description;
  final OrganizationRecordStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses an activity document. Throws [DataException] on a missing or
  /// malformed document — see [Site.fromFirestore] for why.
  factory Activity.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That activity could not be loaded.');
    }
    return Activity.fromMap(doc.id, data);
  }

  factory Activity.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException('That activity has an unrecognised status.');
    }
    final organizationId = data['organizationId'] as String?;
    final projectId = data['projectId'] as String?;
    final siteId = data['siteId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That activity has no organization.');
    }
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That activity has no project.');
    }
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That activity has no site.');
    }
    return Activity(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      siteId: siteId,
      name: data['name'] as String? ?? '',
      code: data['code'] as String? ?? '',
      description: data['description'] as String?,
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
