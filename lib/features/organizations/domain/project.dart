import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'organization_record_status.dart';

/// A project within an organization, stored at
/// `organizations/{organizationId}/projects/{id}` (FIRESTORE_DATA_MODEL.md
/// §3).
///
/// Created and edited exclusively by a System Administrator through the
/// `createProject`/`updateProject` callables — see [Organization]'s doc
/// comment for why this is a read model, not a write-payload builder.
/// [organizationId] is carried as a field as well as being the parent path
/// segment, matching FIRESTORE_DATA_MODEL.md §1's "redundant with path, kept
/// for defense-in-depth and collectionGroup queries" convention.
class Project {
  const Project({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.code,
    required this.status,
    this.description,
    this.startDate,
    this.endDate,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String name;
  final String code;
  final String? description;
  final OrganizationRecordStatus status;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses a project document. Throws [DataException] on a missing or
  /// malformed document — see [Organization.fromFirestore] for why.
  factory Project.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That project could not be loaded.');
    }
    return Project.fromMap(doc.id, data);
  }

  factory Project.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException('That project has an unrecognised status.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That project has no organization.');
    }
    return Project(
      id: id,
      organizationId: organizationId,
      name: data['name'] as String? ?? '',
      code: data['code'] as String? ?? '',
      description: data['description'] as String?,
      status: status,
      startDate: (data['startDate'] as Timestamp?)?.toDate(),
      endDate: (data['endDate'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
