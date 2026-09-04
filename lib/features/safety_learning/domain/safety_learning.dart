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
      throw const DataException('That safety learning item could not be '
          'loaded.');
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
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
