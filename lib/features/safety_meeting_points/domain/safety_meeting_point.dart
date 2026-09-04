import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/domain/organization_record_status.dart';

/// A safety meeting point — a reusable topic/location entry a foreman or
/// worker can draw on when running a meeting — stored at
/// `organizations/{organizationId}/safety_meeting_points/{id}`, a flat
/// sibling of `safety_learning` and `activities`, matching
/// [SafetyLearning]'s doc comment's shape.
///
/// [applicableActivities] and [applicableRisks] are free-form id/label lists
/// rather than validated references: this stage only stores them so a future
/// Daily Safety Meetings feature can filter meeting points by an activity or
/// risk without a data migration. Nothing in this stage reads or enforces
/// them beyond storing and returning what was written.
///
/// Created and edited exclusively through the `createSafetyMeetingPoint`/
/// `updateSafetyMeetingPoint`/`activateSafetyMeetingPoint`/
/// `deactivateSafetyMeetingPoint` callables by a System Administrator or an
/// Organization Administrator of the item's own organization — see
/// `functions/src/safety_meeting_point_callable.ts`. Read-only client-side,
/// mirroring [SafetyLearning].
class SafetyMeetingPoint {
  const SafetyMeetingPoint({
    required this.id,
    required this.organizationId,
    required this.title,
    required this.category,
    required this.status,
    this.description,
    this.applicableActivities = const [],
    this.applicableRisks = const [],
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.updatedBy,
  });

  final String id;
  final String organizationId;
  final String title;
  final String? description;
  final String category;
  final List<String> applicableActivities;
  final List<String> applicableRisks;
  final OrganizationRecordStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdBy;
  final String? updatedBy;

  bool get isActive => status == OrganizationRecordStatus.active;

  /// Parses a safety meeting point document. Throws [DataException] on a
  /// missing or malformed document — see [SafetyLearning.fromFirestore] for
  /// why.
  factory SafetyMeetingPoint.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException(
        'That safety meeting point could not be loaded.',
      );
    }
    return SafetyMeetingPoint.fromMap(doc.id, data);
  }

  factory SafetyMeetingPoint.fromMap(String id, Map<String, dynamic> data) {
    final status = OrganizationRecordStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That safety meeting point has an unrecognised status.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That safety meeting point has no organization.',
      );
    }
    return SafetyMeetingPoint(
      id: id,
      organizationId: organizationId,
      title: data['title'] as String? ?? '',
      description: data['description'] as String?,
      category: data['category'] as String? ?? '',
      applicableActivities:
          (data['applicableActivities'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          const [],
      applicableRisks:
          (data['applicableRisks'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          const [],
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}
