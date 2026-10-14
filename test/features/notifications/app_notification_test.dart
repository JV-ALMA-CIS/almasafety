import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/routing/app_routes.dart';
import 'package:jva_safety/features/notifications/presentation/notifications_screen.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/notifications/domain/app_notification.dart';
import 'package:jva_safety/features/notifications/domain/notification_type.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc('organizations/org-alpha/notifications/n1');
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'safetyAlert',
      'title': 'New safety alert',
      'message': 'Crane inspection overdue',
      'relatedEntityType': 'safetyAlert',
      'relatedEntityId': 'alert-1',
      'isRead': false,
      'createdAt': Timestamp.now(),
      'readAt': null,
    });

    final notification = AppNotification.fromFirestore(doc);

    expect(notification.id, 'n1');
    expect(notification.organizationId, 'org-alpha');
    expect(notification.recipientUid, 'worker-1');
    expect(notification.type, AppNotificationType.safetyAlert);
    expect(notification.title, 'New safety alert');
    expect(notification.message, 'Crane inspection overdue');
    expect(notification.relatedEntityType, 'safetyAlert');
    expect(notification.relatedEntityId, 'alert-1');
    expect(notification.isRead, isFalse);
    expect(notification.readAt, isNull);
  });

  test('relatedEntityType/relatedEntityId are null when absent', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'system',
      'title': 'Welcome',
      'message': 'Your account is active',
      'isRead': false,
    });

    final notification = AppNotification.fromFirestore(doc);

    expect(notification.relatedEntityType, isNull);
    expect(notification.relatedEntityId, isNull);
  });

  test('isRead defaults to false when absent', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'system',
      'title': 'x',
      'message': 'x',
    });

    final notification = AppNotification.fromFirestore(doc);

    expect(notification.isRead, isFalse);
  });

  test('parses a read notification with readAt set', () async {
    final readAt = Timestamp.now();
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'correctiveAction',
      'title': 'Action assigned',
      'message': 'You have a new corrective action',
      'isRead': true,
      'readAt': readAt,
    });

    final notification = AppNotification.fromFirestore(doc);

    expect(notification.isRead, isTrue);
    expect(notification.readAt, readAt.toDate());
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'recipientUid': 'worker-1',
      'type': 'system',
      'title': 'x',
      'message': 'x',
    });

    expect(
      () => AppNotification.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when recipientUid is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'type': 'system',
      'title': 'x',
      'message': 'x',
    });

    expect(
      () => AppNotification.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when title is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'system',
      'message': 'x',
    });

    expect(
      () => AppNotification.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when message is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'system',
      'title': 'x',
    });

    expect(
      () => AppNotification.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised type', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'recipientUid': 'worker-1',
      'type': 'weather',
      'title': 'x',
      'message': 'x',
    });

    expect(
      () => AppNotification.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every AppNotificationType round-trips through its stored id', () {
    for (final type in AppNotificationType.values) {
      expect(AppNotificationType.tryFromId(type.id), type);
    }
    expect(AppNotificationType.tryFromId('unknown'), isNull);
    expect(AppNotificationType.tryFromId(null), isNull);
  });

  test('the expected types exist — matching the server', () {
    expect(AppNotificationType.values.map((t) => t.id).toSet(), {
      'safetyAlert',
      'correctiveAction',
      'safetyMeeting',
      'safetyLearning',
      'hazard',
      'incident',
      'inspection',
      'riskAssessment',
      'system',
    });
  });

  test('a notification opens the page it is about', () {
    AppNotification about(String? type) => AppNotification.fromMap('n', {
      'organizationId': 'org',
      'recipientUid': 'u',
      'type': 'incident',
      'title': 't',
      'message': 'm',
      'isRead': false,
      'relatedEntityType': type,
    });
    expect(routeForNotification(about('incident')), AppRoutes.incidents);
    expect(
      routeForNotification(about('correctiveAction')),
      AppRoutes.correctiveActions,
    );
    expect(routeForNotification(about('inspection')), AppRoutes.inspections);
    expect(routeForNotification(about(null)), isNull);
  });
}
