import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'notification_type.dart';

/// One notification for one user, stored flat at
/// `organizations/{organizationId}/notifications/{id}` — a sibling of
/// `safety_alerts`/`corrective_actions`, matching
/// `FirestorePaths.notifications`'s already-reserved top-level shape.
///
/// **Personal data, unlike every other collection in this stage.** A
/// notification belongs to exactly one [recipientUid] and is readable only
/// by that user (plus a System Administrator) — see `firestore.rules`'s
/// treatment of this collection, which is scoped narrower than the usual
/// "any org member" grant, mirroring `worker_learning_records`'s own
/// "owning worker only" read boundary.
///
/// **This is a data/service foundation only.** Nothing in this codebase yet
/// calls `createNotification` (the internal helper in
/// `functions/src/notification_callable.ts`) from any other feature —
/// Safety Alerts, Corrective Actions, Daily Safety Meetings and Safety
/// Learning do not automatically generate notifications yet. That wiring is
/// deliberately out of scope for this stage; what exists here is the model,
/// the read/mark-as-read callables, and the server-side helper future
/// features can call safely once that wiring is built.
///
/// [relatedEntityType]/[relatedEntityId] are a loose, optional pointer back
/// to whatever raised the notification (e.g. `relatedEntityType:
/// "safetyAlert"`, `relatedEntityId` set to that alert's own id) — carried
/// as plain strings
/// rather than a typed reference, since a notification may eventually point
/// at any one of several unrelated collections and this model does not need
/// to resolve or validate that link itself.
///
/// Created exclusively server-side (see `createNotification` in
/// `notification_callable.ts`); marked read exclusively through
/// `markNotificationRead`/`markAllNotificationsRead`, both scoped to the
/// caller's own [recipientUid] — see
/// `functions/src/notification_callable.ts`. Read-only client-side,
/// mirroring [SafetyAlert].
class AppNotification {
  const AppNotification({
    required this.id,
    required this.organizationId,
    required this.recipientUid,
    required this.type,
    required this.title,
    required this.message,
    required this.isRead,
    this.relatedEntityType,
    this.relatedEntityId,
    this.createdAt,
    this.readAt,
  });

  final String id;
  final String organizationId;
  final String recipientUid;
  final AppNotificationType type;
  final String title;
  final String message;

  /// A loose pointer to the entity this notification relates to (e.g.
  /// `"safetyAlert"`), when there is one. Carried as a plain string, not a
  /// typed reference — see this class's doc comment.
  final String? relatedEntityType;

  /// The id of the entity named by [relatedEntityType], when there is one.
  final String? relatedEntityId;
  final bool isRead;
  final DateTime? createdAt;
  final DateTime? readAt;

  /// Parses a notification document. Throws [DataException] on a missing or
  /// malformed document — see [SafetyAlert.fromFirestore] for why.
  factory AppNotification.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That notification could not be loaded.');
    }
    return AppNotification.fromMap(doc.id, data);
  }

  factory AppNotification.fromMap(String id, Map<String, dynamic> data) {
    final type = AppNotificationType.tryFromId(data['type'] as String?);
    if (type == null) {
      throw const DataException(
        'That notification has an unrecognised type.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That notification has no organization.');
    }
    final recipientUid = data['recipientUid'] as String?;
    if (recipientUid == null || recipientUid.isEmpty) {
      throw const DataException('That notification has no recipient.');
    }
    final title = data['title'] as String?;
    if (title == null || title.isEmpty) {
      throw const DataException('That notification has no title.');
    }
    final message = data['message'] as String?;
    if (message == null || message.isEmpty) {
      throw const DataException('That notification has no message.');
    }
    final relatedEntityType = data['relatedEntityType'] as String?;
    final relatedEntityId = data['relatedEntityId'] as String?;
    return AppNotification(
      id: id,
      organizationId: organizationId,
      recipientUid: recipientUid,
      type: type,
      title: title,
      message: message,
      relatedEntityType: (relatedEntityType != null && relatedEntityType.isNotEmpty)
          ? relatedEntityType
          : null,
      relatedEntityId: (relatedEntityId != null && relatedEntityId.isNotEmpty)
          ? relatedEntityId
          : null,
      isRead: data['isRead'] as bool? ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      readAt: (data['readAt'] as Timestamp?)?.toDate(),
    );
  }
}
