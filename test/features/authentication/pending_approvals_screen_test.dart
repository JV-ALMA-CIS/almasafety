import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/pending_account.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/authentication/presentation/pending_approvals_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';

/// A fake approval service.
///
/// Subclasses the real service rather than introducing a mocking package,
/// following the repo's existing pattern of injectable services whose
/// Firebase dependency resolves lazily ([AuthService], [FirestoreService]).
/// The superclass constructor is invoked with no FirebaseFunctions, which is
/// safe precisely because that resolution is lazy — nothing here touches
/// Firebase.
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({
    this.accounts = const [],
    this.listError,
    this.decisionError,
  });

  List<PendingAccount> accounts;
  AppException? listError;
  AppException? decisionError;

  /// When set, the list call waits on this instead of returning at once, so
  /// a test can observe the in-flight frame.
  Completer<List<PendingAccount>>? listGate;

  final List<String> rejectedUids = [];
  final List<
    ({
      String uid,
      AppRole role,
      WorkerType? workerType,
      String? organizationId,
      List<String>? siteIds,
    })
  >
  approvedCalls = [];
  int listCallCount = 0;

  @override
  Future<List<PendingAccount>> listPendingApprovals() async {
    listCallCount++;
    final error = listError;
    if (error != null) throw error;
    final gate = listGate;
    if (gate != null) return gate.future;
    return accounts;
  }

  @override
  Future<void> approve(
    String uid, {
    required AppRole role,
    WorkerType? workerType,
    String? organizationId,
    List<String>? siteIds,
  }) async {
    final error = decisionError;
    if (error != null) throw error;
    approvedCalls.add((
      uid: uid,
      role: role,
      workerType: workerType,
      organizationId: organizationId,
      siteIds: siteIds,
    ));
  }

  @override
  Future<void> reject(String uid) async {
    final error = decisionError;
    if (error != null) throw error;
    rejectedUids.add(uid);
  }
}

/// A session controller reporting a fixed profile/membership, so the
/// screen's own capability check can be exercised without Firebase.
class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    bool noActiveOrganization = false,
    List<String>? extraOrganizationIds,
  }) : _profile = UserProfile(
         uid: 'approver-uid',
         name: 'Approver',
         email: 'approver@example.com',
         accountStatus: AccountStatus.active,
         // platformRole is admin-only now; every other role lives on the
         // active Membership instead — except a Site Manager approved with
         // no organization yet, signalled by this transient marker (see
         // account_approval.ts's approveAccount), which
         // [noActiveOrganization] simulates for a siteManager role.
         platformRole: role == AppRole.admin
             ? role
             : (noActiveOrganization && role == AppRole.siteManager
                   ? AppRole.siteManager
                   : null),
       ),
       // An Admin has no organization of its own — matching the real
       // bootstrap shape, and exercising that the screen does not assume
       // every reviewer has one. [noActiveOrganization] additionally forces
       // this for a non-Admin role, to exercise the "reviewer has a role
       // but genuinely no organization to act in yet" case.
       _memberships =
           role == null || role == AppRole.admin || noActiveOrganization
           ? const []
           : [
               Membership(
                 organizationId: 'jv-alma-cis',
                 role: role,
                 status: MembershipStatus.active,
               ),
               // Simulates a reviewer holding the same authorized role in a
               // second organization, for the org-picker's "which of my
               // organizations" case.
               for (final organizationId in extraOrganizationIds ?? const [])
                 Membership(
                   organizationId: organizationId,
                   role: role,
                   status: MembershipStatus.active,
                 ),
             ];

  final UserProfile _profile;
  final List<Membership> _memberships;

  Membership? get _membership =>
      _memberships.isEmpty ? null : _memberships.first;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;

  @override
  List<Membership> get memberships => _memberships;

  @override
  Membership? membershipFor(String organizationId) {
    for (final membership in _memberships) {
      if (membership.organizationId == organizationId) return membership;
    }
    return null;
  }
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  PendingAccount account(String uid, {String? name}) {
    return PendingAccount(
      uid: uid,
      name: name ?? 'Pending $uid',
      email: '$uid@example.com',
      phone: '+254700000000',
      submittedAt: DateTime(2026, 5, 4),
    );
  }

  Future<void> seedOrg(
    String id, {
    String name = 'Org',
    String code = 'CODE',
  }) async {
    await firestore.doc('organizations/$id').set({
      'name': name,
      'code': code,
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedSite(
    String organizationId,
    String id, {
    String name = 'Site',
    String projectId = 'project-1',
  }) async {
    await firestore.doc('organizations/$organizationId/sites/$id').set({
      'organizationId': organizationId,
      'projectId': projectId,
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap(
    AccountApprovalService service, {
    AppRole? reviewerRole = AppRole.siteManager,
    bool noActiveOrganization = false,
    List<String>? extraOrganizationIds,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: reviewerRole,
        noActiveOrganization: noActiveOrganization,
        extraOrganizationIds: extraOrganizationIds,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: PendingApprovalsScreen(
            service: service,
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
            siteRepositoryFor: (organizationId) => SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: organizationId,
            ),
          ),
        ),
      ),
    );
  }

  /// Taps Approve on the first matching card, then confirms the role dialog
  /// with its default selection (or picks [role] first if given).
  Future<void> approveViaDialog(WidgetTester tester, {AppRole? role}) async {
    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
    await tester.pumpAndSettle();

    if (role != null) {
      await tester.tap(find.byType(DropdownButtonFormField<AppRole>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(role.label).last);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
    await tester.pumpAndSettle();
  }

  group('PendingApprovalsScreen (no active organization)', () {
    testWidgets('a Site Manager with no active organization yet sees a clear '
        'message instead of a failed round-trip when attempting to '
        'approve — regression test for organizationId silently omitted '
        'from the request, surfacing only as a generic server error', (
      tester,
    ) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, noActiveOrganization: true));
      await tester.pumpAndSettle();

      // The transient-marker fallback lets them see the queue at all —
      // this is not the "no permission" case.
      expect(
        find.text('You do not have permission to review accounts.'),
        findsNothing,
      );
      expect(find.text('Pending Approvals'), findsOneWidget);

      await approveViaDialog(tester);

      expect(
        find.textContaining('not currently assigned to an organization'),
        findsOneWidget,
      );
      expect(service.approvedCalls, isEmpty);
    });
  });

  group('PendingApprovalsScreen (approver)', () {
    testWidgets('lists each pending account with the review details', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        accounts: [account('alice'), account('bob')],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Pending Approvals'), findsOneWidget);
      expect(find.text('Pending alice'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('Pending bob'), findsOneWidget);
      expect(find.textContaining('Submitted 2026-05-04'), findsNWidgets(2));
    });

    testWidgets('shows an empty state when nothing awaits review', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_FakeApprovalService()));
      await tester.pumpAndSettle();

      expect(find.text('No accounts are waiting for review.'), findsOneWidget);
    });

    testWidgets('shows a loading indicator while the queue loads', (
      tester,
    ) async {
      // Held open explicitly so the in-flight frame is observable; the other
      // fakes resolve immediately and would never render one.
      final gate = Completer<List<PendingAccount>>();
      final service = _FakeApprovalService()..listGate = gate;

      await tester.pumpWidget(wrap(service));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No accounts are waiting for review.'), findsNothing);

      gate.complete([account('alice')]);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Pending alice'), findsOneWidget);
    });

    testWidgets(
      'approving opens a role dialog, then calls the callable with that '
      "account's uid and the chosen role",
      (tester) async {
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(wrap(service));
        await tester.pumpAndSettle();

        await approveViaDialog(tester, role: AppRole.foreman);

        expect(service.approvedCalls, hasLength(1));
        expect(service.approvedCalls.single.uid, 'alice');
        expect(service.approvedCalls.single.role, AppRole.foreman);
        expect(service.rejectedUids, isEmpty);
        // The decided account leaves the queue.
        expect(find.text('Pending alice'), findsNothing);
      },
    );

    testWidgets('cancelling the role dialog leaves the account in the queue', (
      tester,
    ) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(service.approvedCalls, isEmpty);
      expect(find.text('Pending alice'), findsOneWidget);
    });

    testWidgets(
      'a Site Manager reviewer is only offered Foreman, never their own or '
      'a higher role',
      (tester) async {
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(
          wrap(service, reviewerRole: AppRole.siteManager),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<AppRole>));
        await tester.pumpAndSettle();

        expect(find.text(AppRole.admin.label), findsNothing);
        expect(find.text(AppRole.siteManager.label), findsNothing);
        expect(find.text(AppRole.worker.label), findsNothing);
        expect(find.text(AppRole.foreman.label), findsWidgets);
      },
    );

    testWidgets(
      'a Site Manager approving a Foreman is offered a site picker, and '
      'the checked site(s) are sent alongside the approval — regression '
      'test for a Foreman approved with no site, who could never open '
      'Daily Safety Meetings (DailySafetyMeetingScreen requires a '
      'non-empty membership.siteIds)',
      (tester) async {
        await seedOrg('jv-alma-cis', name: 'JV Alma CIS', code: 'JV-1');
        await seedSite('jv-alma-cis', 'site-1', name: 'North Yard');
        await seedSite('jv-alma-cis', 'site-2', name: 'South Yard');
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(
          wrap(service, reviewerRole: AppRole.siteManager),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();

        // The role dropdown already defaults to the only grantable role
        // (Foreman) for a Site Manager, so the site picker should already
        // be showing without any extra interaction.
        expect(find.text('North Yard'), findsOneWidget);
        expect(find.text('South Yard'), findsOneWidget);

        await tester.tap(find.text('North Yard'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
        await tester.pumpAndSettle();

        expect(service.approvedCalls.single.siteIds, ['site-1']);
      },
    );

    testWidgets('the site picker is not shown when approving a role other than '
        'Foreman', (tester) async {
      await seedSite('jv-alma-cis', 'site-1', name: 'North Yard');
      final service = _FakeApprovalService(accounts: [account('alice')]);

      // An Admin approving Site Manager never needs a site picker — only
      // a Foreman grant does.
      await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();

      expect(find.text('North Yard'), findsNothing);
    });

    testWidgets('rejecting calls the callable with that account\'s uid', (
      tester,
    ) async {
      final service = _FakeApprovalService(accounts: [account('bob')]);

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
      await tester.pumpAndSettle();

      expect(service.rejectedUids, ['bob']);
      expect(service.approvedCalls, isEmpty);
    });

    testWidgets('approving one row leaves the others alone', (tester) async {
      final service = _FakeApprovalService(
        accounts: [account('alice'), account('bob')],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await approveViaDialog(tester);

      expect(service.approvedCalls.map((c) => c.uid), ['alice']);
      expect(find.text('Pending bob'), findsOneWidget);
    });

    testWidgets('surfaces a load failure without crashing', (tester) async {
      final service = _FakeApprovalService(
        listError: const NetworkException('Network error. Try again.'),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Network error. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces a refused decision and keeps the row', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        accounts: [account('alice')],
        decisionError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      await approveViaDialog(tester);

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
      // A refused approval must not optimistically remove the account.
      expect(find.text('Pending alice'), findsOneWidget);
    });

    testWidgets('refresh re-queries the queue', (tester) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();
      expect(service.listCallCount, 1);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(service.listCallCount, 2);
    });

    testWidgets('action buttons meet the 48px field touch target', (
      tester,
    ) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.widgetWithText(ElevatedButton, 'Approve')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(OutlinedButton, 'Reject')).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('lays out without overflow on a small mobile viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = _FakeApprovalService(
        accounts: [account('alice'), account('bob')],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('PendingApprovalsScreen (Admin reviewer)', () {
    testWidgets(
      'is prompted for an organization, unlike an org-scoped reviewer',
      (tester) async {
        await seedOrg('org-1', name: 'Test Org', code: '12345');
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();

        expect(find.text('Organization (optional)'), findsOneWidget);
        expect(find.text('Organization ID'), findsNothing);
      },
    );

    testWidgets('an org-scoped reviewer sees a required organization field, '
        'pre-selected from their own membership — not the Admin\'s optional '
        'picker over every organization', (tester) async {
      await seedOrg('jv-alma-cis', name: 'JV Alma CIS', code: 'JV-1');
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, reviewerRole: AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();

      expect(find.text('Organization (optional)'), findsNothing);
      expect(find.text('Organization'), findsOneWidget);
      expect(find.text('JV Alma CIS'), findsOneWidget);
    });

    testWidgets(
      'a Site Manager of two organizations can pick either one, and the '
      'chosen organization id — not whichever happened to be active — is '
      'what gets sent to the callable',
      (tester) async {
        await seedOrg('jv-alma-cis', name: 'JV Alma CIS', code: 'JV-1');
        await seedOrg('jv-second-site', name: 'JV Second Site', code: 'JV-2');
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(
          wrap(
            service,
            reviewerRole: AppRole.siteManager,
            extraOrganizationIds: const ['jv-second-site'],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();

        // Defaults to the first (here, also the "active") organization.
        expect(find.text('JV Alma CIS'), findsOneWidget);

        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        expect(find.text('JV Second Site'), findsOneWidget);
        await tester.tap(find.text('JV Second Site').last);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
        await tester.pumpAndSettle();

        expect(service.approvedCalls.single.organizationId, 'jv-second-site');
      },
    );

    testWidgets('the dropdown shows organization name and code, never a '
        'raw Firestore document id', (tester) async {
      await seedOrg('aImNf59EoZ99hNQms2YR', name: 'Test Org', code: '12345');
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();

      // The default selection is "none yet," so the organization's own
      // name/code only appears once the dropdown is opened.
      await tester.tap(find.byType(DropdownButtonFormField<Organization?>));
      await tester.pumpAndSettle();

      expect(find.text('Test Org (12345)'), findsOneWidget);
      expect(find.text('aImNf59EoZ99hNQms2YR'), findsNothing);
    });

    testWidgets('approving with no organization selected leaves organizationId '
        'unset — the common case for an Admin who does not know which '
        'organization a Site Manager belongs to', (tester) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();

      // No organization picked; submitting still succeeds.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
      await tester.pumpAndSettle();

      expect(service.approvedCalls, hasLength(1));
      expect(service.approvedCalls.single.organizationId, isNull);
    });

    testWidgets(
      'approving supplies the selected organization\'s Firestore document '
      'id, never its code or name',
      (tester) async {
        await seedOrg('aImNf59EoZ99hNQms2YR', name: 'Test Org', code: '12345');
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButtonFormField<Organization?>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test Org (12345)').last);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
        await tester.pumpAndSettle();

        expect(service.approvedCalls, hasLength(1));
        expect(
          service.approvedCalls.single.organizationId,
          'aImNf59EoZ99hNQms2YR',
        );
        expect(service.approvedCalls.single.organizationId, isNot('12345'));
      },
    );

    testWidgets(
      'choosing a different organization from the dropdown sends that '
      "organization's document id",
      (tester) async {
        await seedOrg('org-alpha', name: 'Alpha Org', code: 'ALPHA');
        await seedOrg('org-beta', name: 'Beta Org', code: 'BETA');
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButtonFormField<Organization?>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Beta Org (BETA)').last);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').last);
        await tester.pumpAndSettle();

        expect(service.approvedCalls, hasLength(1));
        expect(service.approvedCalls.single.organizationId, 'org-beta');
      },
    );

    testWidgets('may grant Site Manager, but never Admin itself', (
      tester,
    ) async {
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, reviewerRole: AppRole.admin));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Approve').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<AppRole>));
      await tester.pumpAndSettle();

      expect(find.text(AppRole.siteManager.label), findsWidgets);
      expect(find.text(AppRole.foreman.label), findsNothing);
      expect(find.text(AppRole.worker.label), findsNothing);
      expect(find.text(AppRole.admin.label), findsNothing);
    });
  });

  group('PendingApprovalsScreen (non-reviewer)', () {
    testWidgets('renders no queue and never calls the callable', (
      tester,
    ) async {
      // Defence in depth behind the router guard: even if an unauthorized
      // user somehow renders this widget, it must not fetch or display the
      // queue.
      final service = _FakeApprovalService(accounts: [account('alice')]);

      await tester.pumpWidget(wrap(service, reviewerRole: null));
      await tester.pumpAndSettle();

      expect(find.text('Pending alice'), findsNothing);
      expect(find.text('Pending Approvals'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
      expect(
        find.text('You do not have permission to review accounts.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a Worker role renders no queue either — role alone must be authorized',
      (tester) async {
        final service = _FakeApprovalService(accounts: [account('alice')]);

        await tester.pumpWidget(wrap(service, reviewerRole: AppRole.worker));
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to review accounts.'),
          findsOneWidget,
        );
      },
    );
  });
}
