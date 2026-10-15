// Renders the newer screens with the REAL app theme and scrolls through
// them — the theme makes Outlined/Elevated buttons full width, which breaks
// layout when such a button sits in a Row; feature tests that use a plain
// MaterialApp never see that. Any layout error fails the test.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/push_notification_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/core/theme/app_theme.dart';
import 'package:jva_safety/core/widgets/notification_prompt.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/features/organizations/presentation/site_emergency_contacts.dart';
import 'package:jva_safety/features/risk_assessments/domain/standard_ahas.dart';
import 'package:jva_safety/features/risk_assessments/presentation/risk_assessment_editor_screen.dart';
import 'package:jva_safety/features/safety_meetings/domain/safety_meeting.dart';
import 'package:jva_safety/features/safety_meetings/presentation/record_safety_meeting_screen.dart';

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
    siteIds: ['site-1'],
    status: MembershipStatus.active,
  );
}

class _Push extends PushNotificationService {
  _Push(this.value);

  final PushPermission value;

  @override
  Future<PushPermission> permission() async => value;
}

void main() {
  late FakeFirebaseFirestore firestore;
  late SiteRepository sites;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    firestore = FakeFirebaseFirestore();
    sites = SiteRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org',
    );
    await firestore.doc('organizations/org/sites/site-1').set({
      'organizationId': 'org',
      'projectId': 'p',
      'name': 'Italian Embassy',
      'code': 'EMB',
      'status': 'active',
    });
  });

  /// Pumps [screen] in a phone-sized window with the app's real theme
  /// (light and dark), then scrolls to the very bottom and back.
  Future<void> renderAndScroll(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(
        ChangeNotifierProvider<SessionController>(
          create: (_) => _Session(),
          child: MaterialApp(theme: theme, home: screen),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 20; i++) {
        await tester.drag(scrollable, const Offset(0, -600));
        await tester.pumpAndSettle();
      }
      await tester.drag(scrollable, const Offset(0, 20000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  }

  testWidgets('recording a weekly meeting', (tester) async {
    await renderAndScroll(
      tester,
      RecordSafetyMeetingScreen(
        organizationId: 'org',
        kind: SafetyMeetingKind.weeklyEmployee,
        siteRepository: sites,
        loadPeople: (_) async => [
          const OrganizationUser(
            uid: 'w1',
            name: 'Wanjiru',
            email: 'w@example.com',
            accountStatus: AccountStatus.active,
            role: AppRole.worker,
            organizationId: 'org',
            membershipStatus: MembershipStatus.active,
            siteIds: ['site-1'],
          ),
        ],
      ),
    );
  });

  testWidgets('recording a monthly meeting', (tester) async {
    await renderAndScroll(
      tester,
      RecordSafetyMeetingScreen(
        organizationId: 'org',
        kind: SafetyMeetingKind.monthlySupervisory,
        siteRepository: sites,
        loadPeople: (_) async => const [],
      ),
    );
  });

  testWidgets('preparing an AHA from a library draft', (tester) async {
    await renderAndScroll(
      tester,
      RiskAssessmentEditorScreen(
        organizationId: 'org',
        initial: standardAhas.first.content,
        siteRepository: sites,
        loadActivities: (_, _) async => const [
          Activity(
            id: 'a1',
            organizationId: 'org',
            projectId: 'p',
            siteId: 'site-1',
            name: 'Painting',
            code: 'PNT',
            status: OrganizationRecordStatus.active,
          ),
        ],
      ),
    );
  });

  testWidgets('editing emergency contacts', (tester) async {
    await renderAndScroll(
      tester,
      const SiteEmergencyEditorScreen(
        organizationId: 'org',
        site: Site(
          id: 'site-1',
          organizationId: 'org',
          projectId: 'p',
          name: 'Italian Embassy',
          code: 'EMB',
          status: OrganizationRecordStatus.active,
        ),
      ),
    );
  });

  for (final permission in [
    PushPermission.notAsked,
    PushPermission.blocked,
    PushPermission.unsupported,
  ]) {
    testWidgets('the notifications card (${permission.name})', (tester) async {
      NotificationPrompt.closedThisSession = false;
      await renderAndScroll(
        tester,
        Scaffold(
          body: NotificationPrompt(
            service: _Push(permission),
            isIosBrowser: true,
            child: ListView(
              children: [for (var i = 0; i < 40; i++) Text('Row $i')],
            ),
          ),
        ),
      );
      expect(find.byTooltip('Close'), findsOneWidget);
    });
  }
}
