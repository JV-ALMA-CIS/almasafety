import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/authentication/presentation/organization_users_screen.dart';

/// A fake approval service.
///
/// Subclasses the real service rather than introducing a mocking package,
/// following the repo's existing pattern (see pending_approvals_screen_test).
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({
    this.usersByStatus = const {},
    this.listError,
    this.decisionError,
  });

  /// Users returned for each requested status.
  Map<AccountStatus, List<OrganizationUser>> usersByStatus;
  AppException? listError;
  AppException? decisionError;

  /// When set, the first list call waits on this instead of returning at
  /// once, so a test can observe the in-flight frame.
  Completer<List<OrganizationUser>>? listGate;

  final List<String> suspendedUids = [];
  final List<String> reinstatedUids = [];
  int listCallCount = 0;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
  }) async {
    listCallCount++;
    final error = listError;
    if (error != null) throw error;
    final gate = listGate;
    if (gate != null && listCallCount == 1) return gate.future;
    return usersByStatus[status] ?? const [];
  }

  @override
  Future<void> suspend(String uid) async {
    final error = decisionError;
    if (error != null) throw error;
    suspendedUids.add(uid);
  }

  @override
  Future<void> reinstate(String uid) async {
    final error = decisionError;
    if (error != null) throw error;
    reinstatedUids.add(uid);
  }
}

/// A session controller reporting a fixed profile, so the screen's own
/// capability check can be exercised without Firebase.
class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role})
    : _profile = UserProfile(
        uid: 'approver-uid',
        name: 'Approver',
        email: 'approver@example.com',
        accountStatus: AccountStatus.active,
        organizationId:
            role == AppRole.admin ? null : 'jv-alma-cis',
        platformRole: role,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;
}

void main() {
  OrganizationUser user(
    String uid, {
    AccountStatus status = AccountStatus.active,
    String? name,
  }) {
    return OrganizationUser(
      uid: uid,
      name: name ?? 'User $uid',
      email: '$uid@example.com',
      phone: '+254700000000',
      accountStatus: status,
      role: AppRole.worker,
      workerType: WorkerType.contractor,
      organizationId: 'jv-alma-cis',
      registeredAt: DateTime(2026, 5, 4),
    );
  }

  Widget wrap(
    AccountApprovalService service, {
    required List<AccountStatus> statuses,
    String title = 'Active Users',
    AppRole? reviewerRole = AppRole.siteManager,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: reviewerRole),
      child: MaterialApp(
        home: Scaffold(
          body: OrganizationUsersScreen(
            statuses: statuses,
            title: title,
            service: service,
          ),
        ),
      ),
    );
  }

  group('OrganizationUsersScreen (Active Users)', () {
    testWidgets('lists each active user with a Suspend action', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice'), user('bob')],
        },
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active Users'), findsOneWidget);
      expect(find.text('User alice'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('User bob'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Suspend'), findsNWidgets(2));
      expect(find.widgetWithText(ElevatedButton, 'Reinstate'), findsNothing);
    });

    testWidgets('shows an empty state when there are no active users', (
      tester,
    ) async {
      final service = _FakeApprovalService();

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      expect(find.text('No users to show.'), findsOneWidget);
    });

    testWidgets('shows a loading indicator while the list loads', (
      tester,
    ) async {
      final gate = Completer<List<OrganizationUser>>();
      final service = _FakeApprovalService()..listGate = gate;

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete([user('alice')]);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('User alice'), findsOneWidget);
    });

    testWidgets('suspending calls the callable with that user\'s uid', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(service.suspendedUids, ['alice']);
      // The suspended row leaves the list.
      expect(find.text('User alice'), findsNothing);
    });

    testWidgets('surfaces a load failure without crashing', (tester) async {
      final service = _FakeApprovalService(
        listError: const NetworkException('Network error. Try again.'),
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Network error. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces a refused suspend and keeps the row', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
        decisionError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
      expect(find.text('User alice'), findsOneWidget);
    });

    testWidgets('refresh re-queries the list', (tester) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();
      expect(service.listCallCount, 1);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(service.listCallCount, 2);
    });

    testWidgets('the Suspend action meets the 48px field touch target', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
      );

      await tester.pumpWidget(
        wrap(service, statuses: const [AccountStatus.active]),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Suspend'))
            .height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('OrganizationUsersScreen (Suspended/Rejected Users)', () {
    testWidgets(
      'combines suspended and rejected users from two separate calls',
      (tester) async {
        final service = _FakeApprovalService(
          usersByStatus: {
            AccountStatus.suspended: [
              user('carol', status: AccountStatus.suspended),
            ],
            AccountStatus.rejected: [
              user('dave', status: AccountStatus.rejected),
            ],
          },
        );

        await tester.pumpWidget(
          wrap(
            service,
            statuses: const [AccountStatus.suspended, AccountStatus.rejected],
            title: 'Suspended / Rejected Users',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Suspended / Rejected Users'), findsOneWidget);
        expect(find.text('User carol'), findsOneWidget);
        expect(find.text('User dave'), findsOneWidget);
      },
    );

    testWidgets('offers Reinstate for a suspended user but not a rejected one',
        (tester) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.suspended: [
            user('carol', status: AccountStatus.suspended),
          ],
          AccountStatus.rejected: [
            user('dave', status: AccountStatus.rejected),
          ],
        },
      );

      await tester.pumpWidget(
        wrap(
          service,
          statuses: const [AccountStatus.suspended, AccountStatus.rejected],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ElevatedButton, 'Reinstate'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Suspend'), findsNothing);
    });

    testWidgets('reinstating calls the callable with that user\'s uid', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.suspended: [
            user('carol', status: AccountStatus.suspended),
          ],
          AccountStatus.rejected: [],
        },
      );

      await tester.pumpWidget(
        wrap(
          service,
          statuses: const [AccountStatus.suspended, AccountStatus.rejected],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Reinstate'));
      await tester.pumpAndSettle();

      expect(service.reinstatedUids, ['carol']);
      expect(find.text('User carol'), findsNothing);
    });
  });

  group('OrganizationUsersScreen (non-reviewer)', () {
    testWidgets('renders no list content', (
      tester,
    ) async {
      // Defence in depth behind the router guard: even if an unauthorized
      // user somehow renders this widget, it must not display the list.
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
      );

      await tester.pumpWidget(
        wrap(
          service,
          statuses: const [AccountStatus.active],
          reviewerRole: null,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('User alice'), findsNothing);
      expect(find.text('Active Users'), findsNothing);
      expect(
        find.text('You do not have permission to view this list.'),
        findsOneWidget,
      );
    });

    testWidgets('a Worker role renders no list either', (tester) async {
      final service = _FakeApprovalService(
        usersByStatus: {
          AccountStatus.active: [user('alice')],
        },
      );

      await tester.pumpWidget(
        wrap(
          service,
          statuses: const [AccountStatus.active],
          reviewerRole: AppRole.worker,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view this list.'),
        findsOneWidget,
      );
    });
  });
}
