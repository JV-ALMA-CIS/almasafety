import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'meeting_evidence_type.dart';

/// One piece of supporting evidence for a [DailySafetyMeeting] — a photo of
/// the foreman's handwritten toolbox-talk book, a sign-in sheet, a
/// briefing/site photo, or another document — stored at
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/evidence/{id}`,
/// an auto-id subcollection mirroring [MeetingConcern]'s shape (many items,
/// no natural unique key).
///
/// This document is METADATA only — the actual file bytes live in Cloud
/// Storage at [storagePath]; [downloadUrl] is resolved once at upload time.
///
/// **Deliberately not frozen at meeting completion.** Unlike every other
/// record on a meeting (activities, meeting points, concerns, point notes),
/// evidence may still be ADDED after the meeting is `completed` — a foreman
/// may not have the physical safety book on hand at the exact moment they
/// complete the meeting on their phone. Removing evidence, however, is
/// still `inProgress`-only, mirroring `CorrectiveAction`'s "no delete once
/// permanent" rule. See `functions/src/daily_safety_meeting_callable.ts`'s
/// header note on EVIDENCE for the full rationale.
///
/// Created and edited exclusively through the `addMeetingEvidence`/
/// `removeMeetingEvidence` callables by the meeting's own foreman — see
/// `DailySafetyMeetingService.uploadMeetingEvidence`. Read-only client-side,
/// mirroring [MeetingConcern].
class MeetingEvidence {
  const MeetingEvidence({
    required this.id,
    required this.meetingId,
    required this.organizationId,
    required this.siteId,
    required this.evidenceType,
    required this.storagePath,
    required this.downloadUrl,
    required this.fileType,
    this.description,
    this.uploadedBy,
    this.createdAt,
  });

  final String id;
  final String meetingId;
  final String organizationId;
  final String siteId;
  final MeetingEvidenceType evidenceType;
  final String storagePath;
  final String downloadUrl;
  final String fileType;
  final String? description;
  final String? uploadedBy;
  final DateTime? createdAt;

  /// Whether [fileType] names an image the app can render inline (e.g. as a
  /// thumbnail), rather than a document that needs an external viewer.
  bool get isImage => fileType.startsWith('image/');

  /// Parses a meeting evidence document. Throws [DataException] on a
  /// missing or malformed document — see [MeetingConcern.fromFirestore] for
  /// why.
  factory MeetingEvidence.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That evidence could not be loaded.');
    }
    return MeetingEvidence.fromMap(doc.id, data);
  }

  factory MeetingEvidence.fromMap(String id, Map<String, dynamic> data) {
    final evidenceType = MeetingEvidenceType.tryFromId(
      data['evidenceType'] as String?,
    );
    if (evidenceType == null) {
      throw const DataException('That evidence has an unrecognised type.');
    }
    final meetingId = data['meetingId'] as String?;
    if (meetingId == null || meetingId.isEmpty) {
      throw const DataException('That evidence has no meeting.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That evidence has no organization.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That evidence has no site.');
    }
    final storagePath = data['storagePath'] as String?;
    if (storagePath == null || storagePath.isEmpty) {
      throw const DataException('That evidence has no storage path.');
    }
    final downloadUrl = data['downloadUrl'] as String?;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw const DataException('That evidence has no download URL.');
    }
    final fileType = data['fileType'] as String?;
    if (fileType == null || fileType.isEmpty) {
      throw const DataException('That evidence has no file type.');
    }
    return MeetingEvidence(
      id: id,
      meetingId: meetingId,
      organizationId: organizationId,
      siteId: siteId,
      evidenceType: evidenceType,
      storagePath: storagePath,
      downloadUrl: downloadUrl,
      fileType: fileType,
      description: data['description'] as String?,
      uploadedBy: data['uploadedBy'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
