import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'safety_alert_category.dart';
import 'safety_alert_severity.dart';
import 'safety_alert_status.dart';

/// A safety alert, stored flat at
/// `organizations/{organizationId}/safety_alerts/{id}` — a sibling of
/// `corrective_actions` and `daily_safety_meetings`, matching
/// `FirestorePaths.safetyAlerts`'s already-reserved top-level shape. Flat
/// (not nested under a site) so an authorized user's Safety Alerts screen
/// can query every alert across every site in one collection, exactly like
/// [CorrectiveAction] does for its own organization-wide list.
///
/// **Record-keeping only, like every other feature in this stage.** There is
/// no automated alert generation, no push notification and no Gemini
/// involvement anywhere in this class or the callables that write it — see
/// `functions/src/safety_alert_callable.ts`'s header note. An alert exists
/// because an authorized human created it.
///
/// `active` -> `acknowledged` -> `resolved` is the intended lifecycle.
/// Created exclusively through `createSafetyAlert`; acknowledged/resolved
/// exclusively through `acknowledgeSafetyAlert`/`resolveSafetyAlert` — all
/// three restricted to the same reviewer role set (`admin`/`siteManager`)
/// [CorrectiveAction] status transitions already use.
/// Read-only client-side, mirroring [CorrectiveAction]. **Never deletable —
/// a resolved alert is a permanent part of the safety record**, exactly like
/// a completed meeting's concerns or a corrective action once created.
class SafetyAlert {
  const SafetyAlert({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.title,
    required this.description,
    required this.severity,
    required this.category,
    required this.status,
    required this.createdBy,
    this.createdAt,
    this.acknowledgedAt,
    this.acknowledgedBy,
    this.resolvedAt,
    this.resolvedBy,
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;
  final String title;
  final String description;
  final SafetyAlertSeverity severity;
  final SafetyAlertCategory category;
  final SafetyAlertStatus status;

  /// The uid of the authorized user who created this alert.
  final String createdBy;
  final DateTime? createdAt;
  final DateTime? acknowledgedAt;
  final String? acknowledgedBy;
  final DateTime? resolvedAt;
  final String? resolvedBy;

  bool get isActive => status == SafetyAlertStatus.active;
  bool get isResolved => status.isTerminal;

  /// Parses a safety alert document. Throws [DataException] on a missing or
  /// malformed document — see [CorrectiveAction.fromFirestore] for why.
  factory SafetyAlert.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That safety alert could not be loaded.');
    }
    return SafetyAlert.fromMap(doc.id, data);
  }

  factory SafetyAlert.fromMap(String id, Map<String, dynamic> data) {
    final status = SafetyAlertStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException(
        'That safety alert has an unrecognised status.',
      );
    }
    final severity = SafetyAlertSeverity.tryFromId(data['severity'] as String?);
    if (severity == null) {
      throw const DataException(
        'That safety alert has an unrecognised severity.',
      );
    }
    final category = SafetyAlertCategory.tryFromId(data['category'] as String?);
    if (category == null) {
      throw const DataException(
        'That safety alert has an unrecognised category.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That safety alert has no organization.');
    }
    final projectId = data['projectId'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That safety alert has no project.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That safety alert has no site.');
    }
    final title = data['title'] as String?;
    if (title == null || title.isEmpty) {
      throw const DataException('That safety alert has no title.');
    }
    final description = data['description'] as String?;
    if (description == null || description.isEmpty) {
      throw const DataException('That safety alert has no description.');
    }
    final createdBy = data['createdBy'] as String?;
    if (createdBy == null || createdBy.isEmpty) {
      throw const DataException('That safety alert has no creator.');
    }
    return SafetyAlert(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      siteId: siteId,
      title: title,
      description: description,
      severity: severity,
      category: category,
      status: status,
      createdBy: createdBy,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      acknowledgedAt: (data['acknowledgedAt'] as Timestamp?)?.toDate(),
      acknowledgedBy: data['acknowledgedBy'] as String?,
      resolvedAt: (data['resolvedAt'] as Timestamp?)?.toDate(),
      resolvedBy: data['resolvedBy'] as String?,
    );
  }
}
