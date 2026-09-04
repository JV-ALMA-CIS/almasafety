import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'organization_record_status.dart';

/// A JVA Safety client organization, stored at `organizations/{id}`.
///
/// Created and edited exclusively by a System Administrator through the
/// `createOrganization`/`updateOrganization` Cloud Functions callables
/// (`functions/src/organization_callable.ts`) — `firestore.rules` denies
/// every client write to this collection, mirroring how `users/{uid}`
/// approval fields are Admin-SDK-only. This class is therefore a read
/// model: the client never constructs a payload the server would reject,
/// because it never constructs a write payload at all.
class Organization {
  const Organization({
    required this.id,
    required this.name,
    required this.code,
    required this.status,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String name;

  /// Short, unique-per-organization identifier (e.g. "JV-ALMA-CIS"), distinct
  /// from [id] (a Firestore auto-ID). Chosen by the System Administrator at
  /// creation; human-meaningful in a way an auto-ID is not.
  final String code;

  final OrganizationRecordStatus status;

  /// Server-assigned. Null only in the brief window between a local write
  /// and the server acknowledging it.
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// uid of the System Administrator who created/last updated this record.
  final String? createdBy;
  final String? updatedBy;

  /// Parses an organization document.
  ///
  /// Throws [DataException] on a missing or malformed document — unlike
  /// [OrganizationRecordStatus.tryFromId] elsewhere, there is no safe
  /// "denied" reading to fall back to for a whole organization record, so a
  /// malformed one must fail loudly rather than render with blank fields.
  factory Organization.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That organization could not be loaded.');
    }
    return Organization.fromMap(doc.id, data);
  }

  factory Organization.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That organization has an unrecognised status.',
      );
    }
    return Organization(
      id: id,
      name: data['name'] as String? ?? '',
      code: data['code'] as String? ?? '',
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
