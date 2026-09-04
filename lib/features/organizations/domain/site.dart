import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'organization_record_status.dart';

/// A site within a project, stored at
/// `organizations/{organizationId}/sites/{id}` (FIRESTORE_DATA_MODEL.md §3)
/// — a flat sibling of `projects`, not nested under it; [projectId] is a
/// field, not a path segment, so a site is addressable by organization alone
/// without knowing its project.
///
/// Created and edited exclusively by a System Administrator through the
/// `createSite`/`updateSite` callables — see [Organization]'s doc comment
/// for why this is a read model. The callable enforces
/// `site.organizationId == project.organizationId` server-side before
/// writing, so every [Site] this class ever parses is guaranteed to belong
/// to the project it names.
class Site {
  const Site({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.name,
    required this.code,
    required this.status,
    this.location,
    this.description,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String name;
  final String code;
  final String? location;
  final String? description;
  final OrganizationRecordStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses a site document. Throws [DataException] on a missing or
  /// malformed document — see [Organization.fromFirestore] for why.
  factory Site.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That site could not be loaded.');
    }
    return Site.fromMap(doc.id, data);
  }

  factory Site.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException('That site has an unrecognised status.');
    }
    final organizationId = data['organizationId'] as String?;
    final projectId = data['projectId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That site has no organization.');
    }
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That site has no project.');
    }
    return Site(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      name: data['name'] as String? ?? '',
      code: data['code'] as String? ?? '',
      location: data['location'] as String?,
      description: data['description'] as String?,
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
