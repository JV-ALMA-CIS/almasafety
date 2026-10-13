import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
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
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/dashboard/presentation/site_manager_dashboard_screen.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/domain/activity_compliance_summary.dart';
import 'package:jva_safety/routing/app_routes.dart';

class _FakeSession extends SessionController {
  _FakeSession()
    : _profile = const UserProfile(
        uid: 'sm-1',
        name: 'Test Site Manager',
        email: 'sm@example.com',
        accountStatus: AccountStatus.active,
      ),
      _membership = const Membership(
        organizationId: 'org-alpha',
        role: AppRole.siteManager,
        status: MembershipStatus.active,
      );

  final UserProfile _profile;
  final Membership _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => 'org-alpha';

  @override
  Membership? get activeMembership => _membership;
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

AnalyticsDashboard _dashboard({
  int completedMeetings = 0,
  int inProgressMeetings = 0,
  int present = 0,
  int absent = 0,
  int openConcerns = 0,
  int openActions = 0,
  int overdueActions = 0,
  int completedActions = 0,
  int assignedLearning = 0,
  int completedLearning = 0,
}) {
  return AnalyticsDashboard(
    meetings: SafetyMeetingMetrics(
      completedCount: completedMeetings,
      inProgressCount: inProgressMeetings,
      bySite: const {},
      byDate: const {},
    ),
    attendance: AttendanceMetrics(presentCount: present, absentCount: absent),
    concerns: ConcernMetrics(
      totalCount: openConcerns,
      openCount: openConcerns,
      byCategory: const {},
    ),
    correctiveActions: CorrectiveActionMetrics(
      totalCount: openActions + overdueActions + completedActions,
      openCount: openActions,
      inProgressCount: 0,
      completedCount: completedActions,
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
      assignedCount: assignedLearning,
      completedCount: completedLearning,
      inProgressCount: 0,
      outstandingCount: assignedLearning - completedLearning,
    ),
  );
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedHazard(String id, {String status = 'reported'}) async {
    await firestore.doc('organizations/org-alpha/hazards/$id').set({
      'organizationId': 'org-alpha',
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
          builder: (context, state) => SiteManagerDashboardScreen(
            analyticsRepository: _FakeAnalyticsRepository(
              dashboard ?? _dashboard(),
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            hazardRepository: HazardRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            incidentRepository: IncidentRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            siteRepository: SiteRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            safetyComplianceRepository: _FakeComplianceRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
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
          path: AppRoutes.dailySafetyMeetings,
          builder: (context, state) =>
              const Scaffold(body: Text('Meetings screen')),
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

  testWidgets('renders section titles once loaded', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Site KPIs'), findsOneWidget);
    expect(find.text('Learning Compliance'), findsOneWidget);
    expect(find.text('View site learning readiness'), findsOneWidget);
    expect(find.text('Safety Reports'), findsOneWidget);
    expect(find.text('to investigate'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Corrective Actions'), 200);
    expect(find.text('Corrective Actions'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Meetings'), 200);
    expect(find.text('Meetings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Attention Required'), 200);
    expect(find.text('Attention Required'), findsOneWidget);
  });

  testWidgets('shows open and overdue corrective action counts', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(dashboard: _dashboard(openActions: 3, overdueActions: 2)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('overdue'), 200);
    expect(find.text('2'), findsWidgets);
    expect(find.text('overdue'), findsOneWidget);
  });

  testWidgets('shows the open hazard count from watchForOrganization', (
    tester,
  ) async {
    await seedHazard('h1', status: 'reported');
    await seedHazard('h2', status: 'closed');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('open hazard'), findsOneWidget);
  });

  testWidgets('Attention Required shows nothing when there is nothing to '
      'flag', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Nothing needs attention right now.'),
      200,
    );
    expect(find.text('Nothing needs attention right now.'), findsOneWidget);
  });

  testWidgets('Attention Required flags overdue corrective actions', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(dashboard: _dashboard(overdueActions: 3)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('3 corrective actions are overdue.'),
      200,
    );
    expect(find.text('3 corrective actions are overdue.'), findsOneWidget);
  });

  testWidgets('Attention Required flags open hazards', (tester) async {
    await seedHazard('h1', status: 'reported');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('1 hazard is still open.'), 200);
    expect(find.text('1 hazard is still open.'), findsOneWidget);
  });

  testWidgets('tapping the open hazards count navigates to Hazards', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('open hazards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open hazards'));
    await tester.pumpAndSettle();

    expect(find.text('Hazards screen'), findsOneWidget);
  });

  testWidgets('pull to refresh re-runs the load', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.fling(find.text('Dashboard'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Site KPIs'), findsOneWidget);
  });
}
