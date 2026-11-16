import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/notifications/data/notification_repository.dart';
import 'package:jva_safety/features/notifications/data/notification_service.dart';
import 'package:jva_safety/features/notifications/presentation/notifications_screen.dart';

class _Session extends SessionController {
  @override
  UserProfile? get profile => const UserProfile(
    uid: 'me',
    name: 'Eston',
    email: 'e@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  String? get activeOrganizationId => 'org';

  @override
  Membership? get activeMembership => const Membership(
    organizationId: 'org',
    role: AppRole.siteManager,
    siteIds: [],
    status: MembershipStatus.active,
  );
}

/// A server that answers only when told to — like a slow connection or a
/// function starting up.
class _SlowService extends NotificationService {
  final pending = <Completer<void>>[];
  final pendingAll = <Completer<void>>[];

  @override
  Future<void> markAllNotificationsRead({required String organizationId}) {
    final completer = Completer<void>();
    pendingAll.add(completer);
    return completer.future;
  }

  @override
  Future<void> markNotificationRead({
    required String organizationId,
    required String notificationId,
  }) {
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    await firestore.doc('organizations/org/notifications/n1').set({
      'organizationId': 'org',
      'recipientUid': 'me',
      'type': 'system',
      'title': 'Welcome',
      'message': 'Nothing to open',
      'isRead': false,
      'createdAt': Timestamp.now(),
    });
  });

  Future<_SlowService> open(WidgetTester tester) async {
    final service = _SlowService();
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionController>(
        create: (_) => _Session(),
        child: MaterialApp(
          home: NotificationsScreen(
            repository: NotificationRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org',
            ),
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('a tapped notification shows as read at once, without '
      'waiting for the server', (tester) async {
    final service = await open(tester);
    expect(find.text('1 unread'), findsOneWidget);

    await tester.tap(find.text('Welcome'));
    await tester.pump();

    // The server has not answered yet…
    expect(service.pending.single.isCompleted, isFalse);
    // …but the screen has already moved on.
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.text('New'), findsNothing);
    service.pending.single.complete();
  });

  testWidgets('if the server refuses, it shows as unread again', (
    tester,
  ) async {
    final service = await open(tester);
    await tester.tap(find.text('Welcome'));
    await tester.pump();
    service.pending.single.completeError(
      const DataException('Could not mark it read.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 unread'), findsOneWidget);
    expect(find.text('Could not mark it read.'), findsOneWidget);
  });

  testWidgets('notifications are grouped by day, each with its time', (
    tester,
  ) async {
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 9, 5);
    await firestore.doc('organizations/org/notifications/n2').set({
      'organizationId': 'org',
      'recipientUid': 'me',
      'type': 'safetyAlert',
      'title': 'Crane lift',
      'message': 'Keep clear',
      'isRead': true,
      'createdAt': Timestamp.fromDate(yesterday),
    });
    await open(tester);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('1 new'), findsOneWidget);
    expect(find.textContaining('09:05'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Today')).dy,
      lessThan(tester.getTopLeft(find.text('Yesterday')).dy),
    );
  });

  testWidgets('the Unread filter hides what has been read', (tester) async {
    await firestore.doc('organizations/org/notifications/n2').set({
      'organizationId': 'org',
      'recipientUid': 'me',
      'type': 'system',
      'title': 'Old news',
      'message': 'Already seen',
      'isRead': true,
      'createdAt': Timestamp.now(),
    });
    await open(tester);
    expect(find.text('Old news'), findsOneWidget);
    await tester.tap(find.text('Unread (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Old news'), findsNothing);
    expect(find.text('Welcome'), findsOneWidget);
  });

  testWidgets('Mark all read is instant, and undone if the server refuses', (
    tester,
  ) async {
    final service = await open(tester);
    await tester.tap(find.text('Mark all read'));
    await tester.pump();
    expect(service.pendingAll.single.isCompleted, isFalse);
    expect(find.text('All caught up'), findsOneWidget);

    service.pendingAll.single.completeError(
      const DataException('Could not mark them read.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 unread'), findsOneWidget);
    expect(find.text('Could not mark them read.'), findsOneWidget);
  });

  group('day labels', () {
    final now = DateTime(2026, 11, 16, 15); // a Monday
    test('today, yesterday, this week, then the date', () {
      expect(notificationDayLabel(DateTime(2026, 11, 16, 0, 1), now), 'Today');
      expect(notificationDayLabel(null, now), 'Today');
      expect(
        notificationDayLabel(DateTime(2026, 11, 15, 23), now),
        'Yesterday',
      );
      expect(notificationDayLabel(DateTime(2026, 11, 12), now), 'Thursday');
      expect(notificationDayLabel(DateTime(2026, 11, 9), now), 'Mon 9 Nov');
      expect(
        notificationDayLabel(DateTime(2025, 12, 31), now),
        'Wed 31 Dec 2025',
      );
    });
    test('time is 24-hour', () {
      expect(notificationTime(DateTime(2026, 11, 16, 7, 3)), '07:03');
      expect(notificationTime(null), 'now');
    });
  });
}
