import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_alerts/data/safety_alert_repository.dart';
import 'package:jva_safety/features/safety_alerts/data/safety_alert_service.dart';
import 'package:jva_safety/features/safety_alerts/presentation/safety_alerts_screen.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';

class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    String? organizationId,
    List<String> siteIds = const [],
  }) : _profile = UserProfile(
         uid: 'uid-1',
         name: 'Test User',
         email: 'user@example.com',
         accountStatus: AccountStatus.active,
         platformRole: role == AppRole.admin ? role : null,
       ),
       _membership =
           role == null || role == AppRole.admin || organizationId == null
           ? null
           : Membership(
               organizationId: organizationId,
               role: role,
               status: MembershipStatus.active,
               siteIds: siteIds,
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

  Future<void> seedSite(String orgId, String id) async {
    await firestore.doc('organizations/$orgId/sites/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'name': 'Site $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedAlert(
    String orgId,
    String id, {
    String siteId = 'site-1',
  }) async {
    await firestore.doc('organizations/$orgId/safety_alerts/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'title': 'Alert $id',
      'description': 'Description $id',
      'severity': 'high',
      'category': 'safety',
      'status': 'active',
      'createdBy': 'uid-1',
      'createdAt': Timestamp.now(),
      'acknowledgedAt': null,
      'acknowledgedBy': null,
      'resolvedAt': null,
      'resolvedBy': null,
    });
  }

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    List<String> siteIds = const [],
    String? todaysMeetingSiteId,
  }) {
    // Built even when `organizationId` starts null (an Admin with no
    // membership): OrganizationScopeSelector now auto-selects a sole
    // seeded organization rather than leaving the picker showing forever,
    // so the screen may resolve an organization id itself once the fake
    // Firestore stream settles — these repositories must be fake-backed
    // for that case too, not only when the caller already knows the id.
    const fallbackOrganizationId = 'alpha';
    final resolvedOrganizationId = organizationId ?? fallbackOrganizationId;
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: role,
        organizationId: organizationId,
        siteIds: siteIds,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyAlertsScreen(
            repository: SafetyAlertRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            service: SafetyAlertService(),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
            todaysMeetingSiteLookup: (_, _) async => todaysMeetingSiteId,
          ),
        ),
      ),
    );
  }

  group('SafetyAlertsScreen (Admin)', () {
    testWidgets('an Admin with one organization is taken straight to content — '
        'nothing to pick', (tester) async {
      await seedOrg('alpha');
      await seedAlert('alpha', 'alert-1');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Safety Alerts are available once your account has an '
          'organization.',
        ),
        findsNothing,
      );
      // The sole organization is auto-selected — see
      // OrganizationScopeSelector's own doc comment — so the picker never
      // appears and the Admin lands directly on the content.
      expect(find.text('Organization'), findsNothing);
      expect(find.text('Safety Alerts'), findsOneWidget);
      expect(find.text('Alert alert-1'), findsOneWidget);
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
          'Safety Alerts are available once your account has an '
          'organization.',
        ),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
    });

    testWidgets('a reviewer with an organization sees content directly', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedAlert('alpha', 'alert-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Safety Alerts'), findsOneWidget);
      expect(find.text('Alert alert-1'), findsOneWidget);
    });
  });

  group('SafetyAlertsScreen (Foreman)', () {
    Future<void> openNewAlert(WidgetTester tester) async {
      await tester.tap(find.text('New Alert'));
      await tester.pumpAndSettle();
    }

    testWidgets('a Foreman sees only their own sites\' alerts', (tester) async {
      await seedSite('alpha', 'site-1');
      await seedAlert('alpha', 'mine', siteId: 'site-1');
      await seedAlert('alpha', 'theirs', siteId: 'site-2');

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          organizationId: 'alpha',
          siteIds: const ['site-1'],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alert mine'), findsOneWidget);
      expect(find.text('Alert theirs'), findsNothing);
      expect(find.text('1 for your site(s)'), findsOneWidget);
    });

    testWidgets('with one site, New Alert opens with that site set', (
      tester,
    ) async {
      await seedSite('alpha', 'site-1');

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          organizationId: 'alpha',
          siteIds: const ['site-1'],
        ),
      );
      await tester.pumpAndSettle();
      await openNewAlert(tester);

      expect(find.text('Your site'), findsOneWidget);
      expect(find.text('Site site-1'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<Site>), findsNothing);
    });

    testWidgets('with several sites and no meeting today, the Foreman must '
        'choose the site before sending', (tester) async {
      await seedSite('alpha', 'site-1');
      await seedSite('alpha', 'site-2');

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          organizationId: 'alpha',
          siteIds: const ['site-1', 'site-2'],
        ),
      );
      await tester.pumpAndSettle();
      await openNewAlert(tester);

      expect(find.text('Choose the site you are at.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), 'High winds');
      await tester.enterText(find.byType(TextField).at(1), 'Stop lifts');
      await tester.pump();
      final send = find.widgetWithText(ElevatedButton, 'Send Alert');
      await tester.scrollUntilVisible(
        send,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.widget<ElevatedButton>(send).onPressed, isNull);
    });

    testWidgets("with several sites, today's meeting site is pre-selected", (
      tester,
    ) async {
      await seedSite('alpha', 'site-1');
      await seedSite('alpha', 'site-2');

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          organizationId: 'alpha',
          siteIds: const ['site-1', 'site-2'],
          todaysMeetingSiteId: 'site-2',
        ),
      );
      await tester.pumpAndSettle();
      await openNewAlert(tester);

      expect(
        find.text('Everyone at Site site-2 will see this alert.'),
        findsOneWidget,
      );
    });

    testWidgets('with no site, New Alert explains why instead of doing '
        'nothing', (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.foreman, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();
      await openNewAlert(tester);

      expect(
        find.textContaining('You are not assigned to a site yet'),
        findsOneWidget,
      );
    });
  });
}
