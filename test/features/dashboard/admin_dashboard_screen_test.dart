import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/core/widgets/choice_list.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/analytics/data/analytics_repository.dart';
import 'package:jva_safety/features/analytics/domain/analytics_dashboard.dart';
import 'package:jva_safety/features/analytics/domain/attendance_metrics.dart';
import 'package:jva_safety/features/analytics/domain/concern_metrics.dart';
import 'package:jva_safety/features/analytics/domain/corrective_action_metrics.dart';
import 'package:jva_safety/features/analytics/domain/safety_alert_metrics.dart';
import 'package:jva_safety/features/analytics/domain/safety_learning_metrics.dart';
import 'package:jva_safety/features/analytics/domain/safety_meeting_metrics.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/dashboard/presentation/admin_dashboard_screen.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/domain/activity_compliance_summary.dart';
import 'package:jva_safety/routing/app_routes.dart';

class _FakeSession extends SessionController {
  _FakeSession()
    : _profile = const UserProfile(
        uid: 'admin-1',
        name: 'Test Admin',
        email: 'admin@example.com',
        accountStatus: AccountStatus.active,
        platformRole: AppRole.admin,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => null;
}

class _FakeAnalyticsRepository extends AnalyticsRepository {
  _FakeAnalyticsRepository(
    this.dashboard, {
    required super.firestoreService,
    required super.organizationId,
  });

  final AnalyticsDashboard dashboard;

  @override
  Future<AnalyticsDashboard> build({
    String? projectId,
    String? siteId,
    DateTime? from,
    DateTime? to,
    bool includeSafetyLearning = true,
  }) async => dashboard;
}

class _FakeComplianceRepository extends SafetyComplianceRepository {
  _FakeComplianceRepository({
    required super.firestoreService,
    required super.organizationId,
  });

  @override
  Future<List<ActivityComplianceSummary>> buildSiteCompliance(
    String siteId,
  ) async => const [];
}

AnalyticsDashboard _emptyDashboard({
  int overdueActions = 0,
  double learningCompletion = 0,
}) {
  return AnalyticsDashboard(
    meetings: const SafetyMeetingMetrics(
      completedCount: 0,
      inProgressCount: 0,
      bySite: {},
      byDate: {},
    ),
    attendance: const AttendanceMetrics(presentCount: 0, absentCount: 0),
    concerns: const ConcernMetrics(totalCount: 0, openCount: 0, byCategory: {}),
    correctiveActions: CorrectiveActionMetrics(
      totalCount: overdueActions,
      openCount: 0,
      inProgressCount: 0,
      completedCount: 0,
      overdueCount: overdueActions,
    ),
    safetyAlerts: const SafetyAlertMetrics(
      activeCount: 0,
      acknowledgedCount: 0,
      resolvedCount: 0,
      bySeverity: {},
      byCategory: {},
    ),
    safetyLearning: SafetyLearningMetrics(
      assignedCount: 100,
      completedCount: learningCompletion.round(),
      inProgressCount: 0,
      outstandingCount: 100 - learningCompletion.round(),
    ),
  );
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

  Future<void> seedHazard(String id, {String status = 'reported'}) async {
    await firestore.doc('organizations/alpha/hazards/$id').set({
      'organizationId': 'alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'reportedByUid': 'worker-1',
      'category': 'electrical',
      'description': 'A hazard',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({AnalyticsDashboard? dashboard}) {
    final firestoreService = FirestoreService(firestore: firestore);
    final router = GoRouter(
      initialLocation: AppRoutes.dashboard,
      routes: [
        GoRoute(
          path: AppRoutes.dashboard,
          builder: (context, state) => Scaffold(
            body: AdminDashboardScreen(
              analyticsRepository: _FakeAnalyticsRepository(
                dashboard ?? _emptyDashboard(),
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              hazardRepository: HazardRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              incidentRepository: IncidentRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              correctiveActionRepository: CorrectiveActionRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              siteRepository: SiteRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              projectRepository: ProjectRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
              organizationRepository: OrganizationRepository(
                firestoreService: firestoreService,
              ),
              safetyComplianceRepository: _FakeComplianceRepository(
                firestoreService: firestoreService,
                organizationId: 'alpha',
              ),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.hazards,
          builder: (context, state) =>
              const Scaffold(body: Text('Hazards screen')),
        ),
        GoRoute(
          path: AppRoutes.correctiveActions,
          builder: (context, state) =>
              const Scaffold(body: Text('Corrective Actions screen')),
        ),
        GoRoute(
          path: AppRoutes.safetyLearningCompliance,
          builder: (context, state) =>
              const Scaffold(body: Text('Learning Compliance screen')),
        ),
      ],
    );

    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets(
    'an Admin never sees an organization picker — the sole organization '
    'is resolved silently',
    (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Organization'), findsNothing);
      expect(find.byType(ChoiceList<String>), findsNothing);
      expect(find.text('Dashboard'), findsOneWidget);
    },
  );

  testWidgets('shows a setup message instead of a picker when more than one '
      'organization exists', (tester) async {
    await seedOrg('alpha');
    await seedOrg('beta');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Organization'), findsNothing);
    expect(find.byType(ChoiceList<String>), findsNothing);
    expect(find.text('JV ALMA CIS has not been set up yet.'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);
  });

  testWidgets('renders section titles once loaded', (tester) async {
    await seedOrg('alpha');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Organization KPIs'), findsOneWidget);
    expect(find.text('Learning Compliance'), findsOneWidget);
    expect(find.text('View site learning readiness'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Safety Reports'), 200);
    expect(find.text('Safety Reports'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Corrective Actions'), 200);
    expect(find.text('Corrective Actions'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Recent Activity'), 200);
    expect(find.text('Recent Activity'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Attention Required'), 200);
    expect(find.text('Attention Required'), findsOneWidget);
  });

  testWidgets('shows the open hazard count from watchForOrganization', (
    tester,
  ) async {
    await seedOrg('alpha');
    await seedHazard('h1', status: 'reported');
    await seedHazard('h2', status: 'closed');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('open hazard'), 200);
    expect(find.text('open hazard'), findsOneWidget);
  });

  testWidgets('Recent Activity shows a reported hazard', (tester) async {
    await seedOrg('alpha');
    await seedHazard('h1', status: 'reported');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Hazard reported: Electrical'),
      200,
    );
    expect(find.text('Hazard reported: Electrical'), findsOneWidget);
  });

  testWidgets('Recent Activity shows a message when there is nothing yet', (
    tester,
  ) async {
    await seedOrg('alpha');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('No recent activity yet.'), 200);
    expect(find.text('No recent activity yet.'), findsOneWidget);
  });

  testWidgets('Attention Required flags overdue corrective actions', (
    tester,
  ) async {
    await seedOrg('alpha');

    await tester.pumpWidget(
      wrap(dashboard: _emptyDashboard(overdueActions: 4)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('4 corrective actions are overdue.'),
      200,
    );
    expect(find.text('4 corrective actions are overdue.'), findsOneWidget);
  });

  testWidgets('Attention Required shows nothing when there is nothing to '
      'flag', (tester) async {
    await seedOrg('alpha');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Nothing needs attention right now.'),
      200,
    );
    expect(find.text('Nothing needs attention right now.'), findsOneWidget);
  });

  testWidgets('tapping See all under Hazards & Corrective Actions '
      'navigates to Hazards', (tester) async {
    await seedOrg('alpha');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final openHazardsTile = find.text('open hazards');
    await tester.scrollUntilVisible(openHazardsTile, 200);
    await tester.ensureVisible(openHazardsTile);
    await tester.pumpAndSettle();
    await tester.tap(openHazardsTile);
    await tester.pumpAndSettle();

    expect(find.text('Hazards screen'), findsOneWidget);
  });
}
