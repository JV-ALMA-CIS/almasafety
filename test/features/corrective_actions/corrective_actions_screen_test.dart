import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/widgets/choice_list.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_service.dart';
import 'package:jva_safety/features/corrective_actions/presentation/corrective_actions_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        // platformRole is admin-only now; every other role lives on the
        // active Membership instead.
        platformRole: role == AppRole.admin ? role : null,
      ),
      _membership =
          role == null || role == AppRole.admin || organizationId == null
          ? null
          : Membership(
              organizationId: organizationId,
              role: role,
              status: MembershipStatus.active,
            );

  final UserProfile _profile;
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrg(String id) async {
    await firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedAction(
    String orgId,
    String id, {
    String status = 'open',
    String? hazardId,
    String assignedTo = 'worker-1',
  }) async {
    await firestore.doc('organizations/$orgId/corrective_actions/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': 'site-1',
      'meetingId': hazardId == null ? 'meeting-1' : null,
      'concernId': null,
      'hazardId': hazardId,
      'title': 'Action $id',
      'description': 'Description $id',
      'assignedTo': assignedTo,
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': status,
      'evidenceRequired': false,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    // Built even when `organizationId` starts null (an Admin with no
    // membership): OrganizationScopeSelector now auto-selects a sole
    // seeded organization rather than leaving the picker showing forever,
    // so the screen may resolve an organization id itself once the fake
    // Firestore stream settles — these repositories must be fake-backed
    // for that case too, not only when the caller already knows the id.
    const fallbackOrganizationId = 'alpha';
    final resolvedOrganizationId = organizationId ?? fallbackOrganizationId;
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: CorrectiveActionsScreen(
            repository: CorrectiveActionRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            service: CorrectiveActionService(),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
          ),
        ),
      ),
    );
  }

  group('CorrectiveActionsScreen (Admin)', () {
    testWidgets('an Admin with one organization is taken straight to content — '
        'nothing to pick', (tester) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Corrective Actions are available to Organization '
          'Administrators, Safety Managers and Site Superintendents.',
        ),
        findsNothing,
      );
      // The sole organization is auto-selected — see
      // OrganizationScopeSelector's own doc comment — so the picker never
      // appears and the Admin lands directly on the content.
      expect(find.text('Organization'), findsNothing);
      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Action action-1'), findsOneWidget);
    });

    testWidgets('shows an organization picker instead of being blocked', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedOrg('beta');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Corrective Actions are available to Organization '
          'Administrators, Safety Managers and Site Superintendents.',
        ),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
      expect(find.byType(ChoiceList<String>), findsOneWidget);
    });

    testWidgets('a reviewer with an organization sees content directly', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Action action-1'), findsOneWidget);
      expect(find.text('Organization'), findsNothing);
    });

    testWidgets('a foreman with an organization also sees content directly '
        '(reviewer authority includes Foreman)', (tester) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Action action-1'), findsOneWidget);
    });
  });

  group('CorrectiveActionsScreen (non-reviewer)', () {
    testWidgets('a worker is refused regardless of organization', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Corrective Actions are available to Organization '
          'Administrators, Safety Managers and Site Superintendents.',
        ),
        findsOneWidget,
      );
    });
  });

  group('CorrectiveActionsScreen (row content)', () {
    testWidgets('shows the description and origin for a meeting-originated '
        'action', (tester) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Description action-1'), findsOneWidget);
      expect(find.text('Origin: daily safety meeting'), findsOneWidget);
    });

    testWidgets('shows the origin for a hazard-originated action', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-2', hazardId: 'hazard-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Origin: reported hazard'), findsOneWidget);
    });

    testWidgets('an open action does not offer Completed — completion requires '
        'submittedForReview first', (tester) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-3');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Completed'), findsNothing);
    });

    testWidgets('a submittedForReview action is reviewed on its own screen — '
        'approve or send back — never completed with one blind tap', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAction('alpha', 'action-4', status: 'submittedForReview');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Completed'), findsNothing);
      expect(find.text('Review submission'), findsOneWidget);

      await tester.tap(find.text('Review submission'));
      await tester.pumpAndSettle();

      expect(
        find.text('Approve & complete', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Send back', skipOffstage: false), findsOneWidget);
    });
  });

  group(
    'CorrectiveActionsScreen (work assigned to the reviewer themselves)',
    () {
      testWidgets('a Foreman sees their own action under "Assigned to you" '
          'with Complete & Submit — regression test for having no way to '
          'submit evidence from the reviewer list', (tester) async {
        tester.view.physicalSize = const Size(800, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await seedOrg('alpha');
        await seedAction(
          'alpha',
          'mine',
          hazardId: 'hazard-1',
          assignedTo: 'uid-1',
        );
        await seedAction('alpha', 'theirs');

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, organizationId: 'alpha'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Assigned to you'), findsWidgets);
        expect(find.text('Complete & Submit'), findsWidgets);

        await tester.tap(find.text('Complete & Submit').first);
        await tester.pumpAndSettle();
        expect(find.text('Submit for Review'), findsOneWidget);
        expect(find.text('Action mine'), findsOneWidget);
      });

      testWidgets('opening your own action offers Complete & Submit, not '
          '"nothing submitted" alone', (tester) async {
        tester.view.physicalSize = const Size(800, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await seedOrg('alpha');
        await seedAction('alpha', 'mine', assignedTo: 'uid-1');

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, organizationId: 'alpha'),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Action mine').first);
        await tester.pumpAndSettle();

        expect(find.textContaining('This is assigned to you'), findsOneWidget);
        expect(find.text('Complete & Submit'), findsOneWidget);
        expect(find.text('Approve & complete'), findsNothing);
      });

      testWidgets('your own submitted work cannot be approved by you', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(800, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await seedOrg('alpha');
        await seedAction(
          'alpha',
          'mine',
          assignedTo: 'uid-1',
          status: 'submittedForReview',
        );

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, organizationId: 'alpha'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Review submission'), findsNothing);
        await tester.tap(find.text('Action mine').first);
        await tester.pumpAndSettle();
        expect(find.text('Approve & complete'), findsNothing);
        expect(
          find.textContaining('Another reviewer must approve'),
          findsOneWidget,
        );
      });
    },
  );
}
