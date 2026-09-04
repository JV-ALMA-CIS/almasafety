import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/domain/organization_record_status.dart';
import 'safety_requirement_risk.dart';

/// A safety requirement, stored at
/// `organizations/{organizationId}/safety_requirements/{id}` — a flat
/// sibling of `safety_learning`, matching [Activity]'s doc comment's shape.
///
/// [requiredLearningIds] names the [SafetyLearning] items this requirement
/// mandates. This stage applies a requirement organization-wide — there is
/// deliberately no per-site/per-activity/per-role targeting field yet (see
/// `RequiredLearningResolver`'s doc comment for the resolution rule this
/// enables, and for why a narrower future scoping model is not precluded).
///
/// Created and edited exclusively through the `createSafetyRequirement`/
/// `updateSafetyRequirement` callables by a System Administrator or an
/// Organization Administrator of the requirement's own organization — see
/// `functions/src/safety_learning_callable.ts`. `updateSafetyRequirement`
/// validates every id in `requiredLearningIds` refers to an existing
/// `SafetyLearning` document in the same organization before writing.
/// Read-only client-side, mirroring [Activity].
class SafetyRequirement {
  const SafetyRequirement({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.category,
    required this.risk,
    required this.status,
    this.description,
    this.requiredLearningIds = const [],
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String name;
  final String? description;

  /// Free text for now — no enum, per this feature's "do not invent complex
  /// permissions/systems" guidance.
  final String category;
  final SafetyRequirementRisk risk;
  final List<String> requiredLearningIds;
  final OrganizationRecordStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  /// Parses a safety requirement document. Throws [DataException] on a
  /// missing or malformed document — see [Activity.fromFirestore] for why.
  factory SafetyRequirement.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException(
        'That safety requirement could not be loaded.',
      );
    }
    return SafetyRequirement.fromMap(doc.id, data);
  }

  factory SafetyRequirement.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That safety requirement has an unrecognised status.',
      );
    }
    final risk = SafetyRequirementRisk.tryFromId(data['risk'] as String?);
    if (risk == null) {
      throw const DataException(
        'That safety requirement has an unrecognised risk level.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That safety requirement has no '
          'organization.');
    }
    return SafetyRequirement(
      id: id,
      organizationId: organizationId,
      name: data['name'] as String? ?? '',
      description: data['description'] as String?,
      category: data['category'] as String? ?? '',
      risk: risk,
      requiredLearningIds:
          (data['requiredLearningIds'] as List<dynamic>?)?.cast<String>() ??
              const [],
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
