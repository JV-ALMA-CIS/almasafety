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
}
