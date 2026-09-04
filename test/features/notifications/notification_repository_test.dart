import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/notifications/data/notification_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedNotification(
    String orgId,
    String id, {
    required String recipientUid,
    bool isRead = false,
    DateTime? createdAt,
  }) async {
    await firestore.doc('organizations/$orgId/notifications/$id').set({
      'organizationId': orgId,
      'recipientUid': recipientUid,
      'type': 'system',
      'title': 'Notification $id',
      'message': 'Message $id',
      'isRead': isRead,
      'createdAt': Timestamp.fromDate(createdAt ?? DateTime(2026, 1, 1)),
      'readAt': null,
    });
  }

  test('watchForRecipient returns only notifications for that user',
      () async {
    await seedNotification('org-alpha', 'n1', recipientUid: 'worker-1');
    await seedNotification('org-alpha', 'n2', recipientUid: 'worker-1');
    await seedNotification('org-alpha', 'n3', recipientUid: 'worker-2');

    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final notifications = await repository.watchForRecipient('worker-1').first;

    expect(notifications.map((n) => n.id).toSet(), {'n1', 'n2'});
  });

  test('watchForRecipient orders most recent first', () async {
    await seedNotification(
      'org-alpha',
      'older',
      recipientUid: 'worker-1',
      createdAt: DateTime(2026, 1, 1),
    );
    await seedNotification(
      'org-alpha',
      'newer',
      recipientUid: 'worker-1',
      createdAt: DateTime(2026, 2, 1),
    );

    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final notifications = await repository.watchForRecipient('worker-1').first;

    expect(notifications.map((n) => n.id).toList(), ['newer', 'older']);
  });

  test("watchForRecipient excludes another organization's notifications",
      () async {
    await seedNotification('org-alpha', 'n1', recipientUid: 'worker-1');
    await seedNotification('org-beta', 'n1', recipientUid: 'worker-1');

    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final notifications = await repository.watchForRecipient('worker-1').first;

    expect(notifications, hasLength(1));
    expect(notifications.single.organizationId, 'org-alpha');
  });

  test('watchUnreadForRecipient returns only unread notifications for that '
      'user', () async {
    await seedNotification(
      'org-alpha',
      'n1',
      recipientUid: 'worker-1',
      isRead: false,
    );
    await seedNotification(
      'org-alpha',
      'n2',
      recipientUid: 'worker-1',
      isRead: true,
    );
    await seedNotification(
      'org-alpha',
      'n3',
      recipientUid: 'worker-2',
      isRead: false,
    );

    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final unread = await repository.watchUnreadForRecipient('worker-1').first;

    expect(unread.map((n) => n.id).toList(), ['n1']);
  });

  test('watchUnreadForRecipient is empty once everything is read', () async {
    await seedNotification(
      'org-alpha',
      'n1',
      recipientUid: 'worker-1',
      isRead: true,
    );

    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final unread = await repository.watchUnreadForRecipient('worker-1').first;

    expect(unread, isEmpty);
  });

  test('getById returns null for a missing document', () async {
    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = NotificationRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
