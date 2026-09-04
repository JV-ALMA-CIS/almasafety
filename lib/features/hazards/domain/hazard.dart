import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'hazard_category.dart';
import 'hazard_status.dart';

/// A worker-reported hazard, stored flat at
/// `organizations/{organizationId}/hazards/{id}` — a sibling of
/// `corrective_actions` and `daily_safety_meetings`, matching
/// `FirestorePaths.hazardsCollection`'s shape. See
/// `FIRESTORE_DATA_MODEL.md` §7 for the full field/lifecycle rationale.
///
/// **This is a report, not the remediation.** [category], [description],
/// [location] and [photoUrl] are the ORIGINAL report content and are never
/// client-editable after creation — see
/// `functions/src/hazard_callable.ts`'s header note. Only the
/// status-transition fields ([status], [correctiveActionId],
/// [acknowledgedBy]/[acknowledgedAt], [closedBy]/[closedAt]) are ever written
/// after creation, and only by an authorized reviewer.
///
/// Created exclusively through `createHazard` by the reporting worker (any
/// active org member with the hazard's own site in their `siteIds` — not
/// role-restricted); triaged/linked/closed exclusively through
/// `acknowledgeHazard`/`linkHazardCorrectiveAction`/`closeHazard` by an
/// authorized reviewer role — see `functions/src/hazard_callable.ts`.
/// Read-only client-side, mirroring [CorrectiveAction]. **Never deletable** —
/// a hazard is part of the permanent safety record once created.
class Hazard {
  const Hazard({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.reportedByUid,
    required this.category,
    required this.description,
    required this.status,
    this.location,
    this.photoUrl,
    this.correctiveActionId,
    this.acknowledgedBy,
    this.acknowledgedAt,
    this.closedBy,
    this.closedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;

  /// The uid of the worker who filed this report — always the caller's own
  /// uid at creation time server-side, never a request argument.
  final String reportedByUid;

  final HazardCategory category;
  final String description;

  /// Free-text location (e.g. "East wing, 3rd floor"). A geopoint is
  /// deferred — see `FIRESTORE_DATA_MODEL.md` §7.
  final String? location;

  /// Storage path/URL for the evidence photo, optional per the MVP
  /// requirement. Uploaded to a path scoped to [id] before this document is
  /// created — see `FIRESTORE_DATA_MODEL.md` §7's "Photo-upload sequencing"
  /// note and [HazardService.createHazard].
  final String? photoUrl;

  final HazardStatus status;

  /// Set once a corrective action has been raised from this hazard — see
  /// [HazardStatus.correctiveActionCreated].
  final String? correctiveActionId;
  final String? acknowledgedBy;
  final DateTime? acknowledgedAt;
  final String? closedBy;
  final DateTime? closedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isClosed => status.isTerminal;

  /// Whether this hazard can still be closed directly (no remediation
  /// needed) — mirrors `closeHazard`'s own server-side check: only from
  /// [HazardStatus.reported] or [HazardStatus.acknowledged], never once a
  /// corrective action already exists or it is already closed.
  bool get canCloseDirectly =>
      status == HazardStatus.reported || status == HazardStatus.acknowledged;

  /// Parses a hazard document. Throws [DataException] on a missing or
  /// malformed document — see [CorrectiveAction.fromFirestore] for why.
  factory Hazard.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That hazard could not be loaded.');
    }
    return Hazard.fromMap(doc.id, data);
  }

  factory Hazard.fromMap(String id, Map<String, dynamic> data) {
    final status = HazardStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException('That hazard has an unrecognised status.');
    }
    final category = HazardCategory.tryFromId(data['category'] as String?);
    if (category == null) {
      throw const DataException('That hazard has an unrecognised category.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That hazard has no organization.');
    }
    final projectId = data['projectId'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That hazard has no project.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That hazard has no site.');
    }
    final reportedByUid = data['reportedByUid'] as String?;
    if (reportedByUid == null || reportedByUid.isEmpty) {
      throw const DataException('That hazard has no reporter.');
    }
    final description = data['description'] as String?;
    if (description == null || description.isEmpty) {
      throw const DataException('That hazard has no description.');
    }
    final rawCorrectiveActionId = data['correctiveActionId'] as String?;
    return Hazard(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      siteId: siteId,
      reportedByUid: reportedByUid,
      category: category,
      description: description,
      location: data['location'] as String?,
      photoUrl: data['photoUrl'] as String?,
      status: status,
      correctiveActionId:
          (rawCorrectiveActionId != null && rawCorrectiveActionId.isNotEmpty)
              ? rawCorrectiveActionId
              : null,
      acknowledgedBy: data['acknowledgedBy'] as String?,
      acknowledgedAt: (data['acknowledgedAt'] as Timestamp?)?.toDate(),
      closedBy: data['closedBy'] as String?,
      closedAt: (data['closedAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
