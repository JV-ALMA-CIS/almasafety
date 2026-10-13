import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'incident_enums.dart';

/// Something that ACTUALLY happened on site — someone hurt, something
/// damaged, a spill, a dangerous event — stored flat at
/// `organizations/{organizationId}/incidents/{id}`. See
/// `FIRESTORE_DATA_MODEL.md` §7a and `functions/src/incident_callable.ts`.
///
/// The original report ([type], [description], [occurredAt], [location],
/// [injuredPersonName], [immediateAction], [photoUrl]) is never edited after
/// creation. A reviewer then classifies [severity] and starts the
/// investigation, raises any number of corrective actions
/// ([correctiveActionIds]), and closes it with a [rootCause] once every
/// action is complete.
///
/// Readable only by the reporter and reviewer roles — `firestore.rules`.
/// Read-only client-side; never deletable.
class Incident {
  const Incident({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.reportedByUid,
    required this.type,
    required this.description,
    required this.occurredAt,
    required this.status,
    this.location,
    this.injuredPersonName,
    this.immediateAction,
    this.photoUrl,
    this.severity,
    this.investigationStartedBy,
    this.investigationStartedAt,
    this.correctiveActionIds = const [],
    this.rootCause,
    this.closingNotes,
    this.closedBy,
    this.closedAt,
    this.createdAt,
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;
  final String reportedByUid;
  final IncidentType type;
  final String description;

  /// When it happened — often earlier than [createdAt], when it was
  /// reported.
  final DateTime occurredAt;
  final IncidentStatus status;
  final String? location;

  /// Only ever set for [IncidentType.injury].
  final String? injuredPersonName;

  /// What was done straight away (first aid, area made safe…).
  final String? immediateAction;
  final String? photoUrl;

  /// Null until a reviewer starts the investigation.
  final IncidentSeverity? severity;
  final String? investigationStartedBy;
  final DateTime? investigationStartedAt;
  final List<String> correctiveActionIds;
  final String? rootCause;
  final String? closingNotes;
  final String? closedBy;
  final DateTime? closedAt;
  final DateTime? createdAt;

  bool get isClosed => status.isTerminal;

  factory Incident.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That incident could not be loaded.');
    }
    return Incident.fromMap(doc.id, data);
  }

  factory Incident.fromMap(String id, Map<String, dynamic> data) {
    final status = IncidentStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException('That incident has an unrecognised status.');
    }
    final type = IncidentType.tryFromId(data['type'] as String?);
    if (type == null) {
      throw const DataException('That incident has an unrecognised type.');
    }
    String required(String field) {
      final value = data[field] as String?;
      if (value == null || value.isEmpty) {
        throw DataException('That incident has no $field.');
      }
      return value;
    }

    final occurredAt = (data['occurredAt'] as Timestamp?)?.toDate();
    if (occurredAt == null) {
      throw const DataException('That incident has no occurrence time.');
    }
    final rawSeverity = data['severity'] as String?;
    final severity = IncidentSeverity.tryFromId(rawSeverity);
    if (rawSeverity != null && severity == null) {
      throw const DataException('That incident has an unrecognised severity.');
    }
    return Incident(
      id: id,
      organizationId: required('organizationId'),
      projectId: required('projectId'),
      siteId: required('siteId'),
      reportedByUid: required('reportedByUid'),
      type: type,
      description: required('description'),
      occurredAt: occurredAt,
      status: status,
      location: data['location'] as String?,
      injuredPersonName: data['injuredPersonName'] as String?,
      immediateAction: data['immediateAction'] as String?,
      photoUrl: data['photoUrl'] as String?,
      severity: severity,
      investigationStartedBy: data['investigationStartedBy'] as String?,
      investigationStartedAt: (data['investigationStartedAt'] as Timestamp?)
          ?.toDate(),
      correctiveActionIds: [
        for (final value in (data['correctiveActionIds'] as List?) ?? const [])
          if (value is String) value,
      ],
      rootCause: data['rootCause'] as String?,
      closingNotes: data['closingNotes'] as String?,
      closedBy: data['closedBy'] as String?,
      closedAt: (data['closedAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
