import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/crew_readiness.dart';
import 'package:jva_safety/features/dashboard/presentation/foreman_dashboard_screen.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/domain/activity_compliance_summary.dart';
import 'package:jva_safety/routing/app_routes.dart';

class _FakeSession extends SessionController {
  _FakeSession({List<String> siteIds = const ['site-1']})
    : _profile = const UserProfile(
        uid: 'foreman-1',
        name: 'Test Foreman',
        email: 'foreman@example.com',
        accountStatus: AccountStatus.active,
      ),
      _membership = Membership(
        organizationId: 'org-alpha',
        role: AppRole.foreman,
        siteIds: siteIds,
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

class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService(this.users);

  final List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async => users;
}

class _FakeComplianceRepository extends SafetyComplianceRepository {
  _FakeComplianceRepository(
    this.summariesBySite, {
    required super.firestoreService,
    required super.organizationId,
  });

  final Map<String, List<ActivityComplianceSummary>> summariesBySite;

  @override
  Future<List<ActivityComplianceSummary>> buildSiteCompliance(
    String siteId,
  ) async => summariesBySite[siteId] ?? const [];
}

class _FakeAttendanceService extends MeetingAttendanceService {
  _FakeAttendanceService(this.readiness);

  final CrewReadiness readiness;

  @override
  Future<CrewReadiness> getSiteCrewReadiness({
    required String organizationId,
    required String siteId,
  }) async => readiness;
}

class _FakeWorkerLearningService extends WorkerLearningService {
  _FakeWorkerLearningService(this.readiness);

  final TodaysSafetyReadiness readiness;

  @override
  Future<void> getMyRequiredLearning({required String organizationId}) async {}

  @override
  Future<TodaysSafetyReadiness> getMyTodaysSafetyReadiness({
    required String organizationId,
  }) async => readiness;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedSite(String id) async {
    await firestore.doc('organizations/org-alpha/sites/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'name': 'Site $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedHazard(
    String id, {
    required String siteId,
    String status = 'reported',
  }) async {
    await firestore.doc('organizations/org-alpha/hazards/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': siteId,
      'reportedByUid': 'worker-1',
      'category': 'electrical',
      'description': 'A hazard',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedCorrectiveAction(
    String id, {
    required String siteId,
    String status = 'open',
  }) async {
    await firestore.doc('organizations/org-alpha/corrective_actions/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': siteId,
      'meetingId': 'meeting-1',
      'concernId': null,
      'title': 'Action $id',
      'description': 'Description',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': status,
      'evidenceRequired': false,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({
    List<String> siteIds = const ['site-1'],
    List<OrganizationUser> users = const [],
    Map<String, List<ActivityComplianceSummary>> compliance = const {},
    CrewReadiness crew = const CrewReadiness(outstandingByWorker: {}),
    TodaysSafetyReadiness myReadiness = const TodaysSafetyReadiness(
      gatingSource: ReadinessGatingSource.assignments,
      isForeman: true,
    ),
  }) {
    final firestoreService = FirestoreService(firestore: firestore);
    final router = GoRouter(
      initialLocation: AppRoutes.dashboard,
      routes: [
        GoRoute(
          path: AppRoutes.dashboard,
          builder: (context, state) => ForemanDashboardScreen(
            siteRepository: SiteRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            dailySafetyMeetingRepository: DailySafetyMeetingRepository(
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
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            safetyComplianceRepository: _FakeComplianceRepository(
              compliance,
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
            approvalService: _FakeApprovalService(users),
            meetingAttendanceService: _FakeAttendanceService(crew),
            workerLearningService: _FakeWorkerLearningService(myReadiness),
            workerLearningRepository: WorkerLearningRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.workers,
          builder: (context, state) =>
              const Scaffold(body: Text('My Workers screen')),
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
              const Scaffold(body: Text('Meeting workspace')),
        ),
        GoRoute(
          path: AppRoutes.safetyLearningCompliance,
          builder: (context, state) =>
              const Scaffold(body: Text('Learning Compliance screen')),
        ),
      ],
    );

    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(siteIds: siteIds),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('renders section titles', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text("Today's Meeting"), findsOneWidget);
    await tester.scrollUntilVisible(find.text('My Readiness'), 200);
    expect(find.text('My Readiness'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Crew Readiness'), 200);
    expect(find.text('Crew Readiness'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Site Workers'), 200);
    expect(find.text('Site Workers'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Safety Reports'), 200);
    expect(find.text('Safety Reports'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('open incidents'), 200);
    expect(find.text('open incidents'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Corrective Actions'), 200);
    expect(find.text('Corrective Actions'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Quick Actions'), 200);
    expect(find.text('Quick Actions'), findsOneWidget);
  });

  testWidgets('shows a message when not assigned to a site', (tester) async {
    await tester.pumpWidget(wrap(siteIds: const []));
    await tester.pumpAndSettle();

    expect(
      find.text('You have not been assigned to a site yet.'),
      findsOneWidget,
    );
  });

  testWidgets('shows no meeting started when none exists today', (
    tester,
  ) async {
    await seedSite('site-1');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('No meeting started today.'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('counts only workers at the assigned site(s)', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(
      wrap(
        users: [
          const OrganizationUser(
            uid: 'w1',
            name: 'Worker One',
            email: 'w1@example.com',
            accountStatus: AccountStatus.active,
            role: AppRole.worker,
            siteIds: ['site-1'],
          ),
          const OrganizationUser(
            uid: 'w2',
            name: 'Worker Two',
            email: 'w2@example.com',
            accountStatus: AccountStatus.active,
            role: AppRole.worker,
            siteIds: ['site-2'],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('worker'), 200);
    expect(find.text('1'), findsWidgets);
    expect(find.text('worker'), findsOneWidget);
  });

  testWidgets("Crew Readiness shows today's gating readiness by worker "
      'name before the meeting starts', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(
      wrap(
        users: [
          const OrganizationUser(
            uid: 'w1',
            name: 'Worker One',
            email: 'w1@example.com',
            accountStatus: AccountStatus.active,
            role: AppRole.worker,
            siteIds: ['site-1'],
          ),
        ],
        crew: const CrewReadiness(
          activityNames: ['Roofing'],
          outstandingByWorker: {
            'w1': ['Site Induction'],
            'w2': [],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('1 Need attention'), 200);

    expect(find.text("Before today's meeting"), findsOneWidget);
    expect(find.text('2 workers'), findsOneWidget);
    expect(find.text('1 Ready'), findsOneWidget);
    expect(find.text('1 Need attention'), findsOneWidget);
    expect(find.text('Worker One'), findsOneWidget);
    expect(find.text('Must complete: Site Induction'), findsOneWidget);
  });

  testWidgets('My Readiness shows the Foreman the learning they must '
      'complete before they can start the meeting', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(
      wrap(
        myReadiness: const TodaysSafetyReadiness(
          gatingSource: ReadinessGatingSource.assignments,
          isForeman: true,
          sites: [ReadinessScopeRef(id: 'site-1', name: 'Site A')],
          beforeMeeting: [
            ReadinessItem(
              learningId: 'l1',
              title: 'Site Induction',
              status: ReadinessItemStatus.notStarted,
              canStart: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Readiness'), findsOneWidget);
    expect(find.text('Needed today'), findsOneWidget);
    expect(find.text('1 item remaining'), findsOneWidget);
    expect(find.text('Continue Learning'), findsOneWidget);
  });

  testWidgets('tapping Full compliance navigates to the compliance '
      'screen', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Full compliance'), 200);
    await tester.tap(find.text('Full compliance'));
    await tester.pumpAndSettle();

    expect(find.text('Learning Compliance screen'), findsOneWidget);
  });

  testWidgets('shows the open hazard count scoped to the assigned site', (
    tester,
  ) async {
    await seedSite('site-1');
    await seedHazard('h1', siteId: 'site-1', status: 'reported');
    await seedHazard('h2', siteId: 'site-2', status: 'reported');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('open hazard'), 200);
    expect(find.text('open hazard'), findsOneWidget);
  });

  testWidgets(
    'shows the open corrective action count scoped to the assigned site',
    (tester) async {
      await seedSite('site-1');
      await seedCorrectiveAction('ca1', siteId: 'site-1', status: 'open');
      await seedCorrectiveAction('ca2', siteId: 'site-2', status: 'open');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('open on your sites'), 200);
      // Only site-1's action counts; site-2 is not this Foreman's site.
      expect(
        find.ancestor(
          of: find.text('open on your sites'),
          matching: find.byType(Card),
        ),
        findsWidgets,
      );
      expect(find.text('1'), findsWidgets);
    },
  );

  testWidgets('tapping See all under Site Workers navigates to My Workers', (
    tester,
  ) async {
    await seedSite('site-1');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // The Site Workers header row carries its own See all button.
    await tester.scrollUntilVisible(find.text('Site Workers'), 200);
    await tester.ensureVisible(find.text('Site Workers'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'See all').first);
    await tester.pumpAndSettle();

    expect(find.text('My Workers screen'), findsOneWidget);
  });

  testWidgets('Report a Safety Issue opens the chooser', (tester) async {
    await seedSite('site-1');
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report a Safety Issue'));
    await tester.pumpAndSettle();

    expect(find.text('Something NEARLY happened'), findsOneWidget);
    await tester.tap(find.text('Something NEARLY happened'));
    await tester.pumpAndSettle();
    expect(find.text('What nearly happened?'), findsOneWidget);
  });
}
