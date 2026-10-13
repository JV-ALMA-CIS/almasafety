import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/incidents/data/incident_repository.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_repository.dart';
import 'package:jva_safety/features/dashboard/presentation/worker_dashboard_screen.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/todays_safety_readiness.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';
import 'package:jva_safety/routing/app_routes.dart';

class _FakeSession extends SessionController {
  _FakeSession({List<String> siteIds = const []})
    : _profile = const UserProfile(
        uid: 'worker-1',
        name: 'Test Worker',
        email: 'worker@example.com',
        accountStatus: AccountStatus.active,
      ),
      _membership = Membership(
        organizationId: 'org-alpha',
        role: AppRole.worker,
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

ReadinessItem _item(String id) => ReadinessItem(
  learningId: id,
  title: 'Learning $id',
  status: ReadinessItemStatus.notStarted,
  canStart: true,
);

void main() {
  late FakeFirebaseFirestore firestore;
  late List<String> openedAllLearning;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    openedAllLearning = [];
  });

  Widget wrap({
    List<String> siteIds = const ['site-1'],
    TodaysSafetyReadiness readiness = const TodaysSafetyReadiness(
      gatingSource: ReadinessGatingSource.assignments,
    ),
  }) {
    final firestoreService = FirestoreService(firestore: firestore);
    final router = GoRouter(
      initialLocation: AppRoutes.dashboard,
      routes: [
        GoRoute(
          path: AppRoutes.dashboard,
          builder: (context, state) => WorkerDashboardScreen(
            safetyRequirementRepository: SafetyRequirementRepository(
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
            meetingAttendanceRepositoryFor: (meetingId) =>
                MeetingAttendanceRepository(
                  firestoreService: firestoreService,
                  organizationId: 'org-alpha',
                  meetingId: meetingId,
                ),
            workerLearningService: _FakeWorkerLearningService(readiness),
            onOpenAllLearning: (_) async => openedAllLearning.add('all'),
            workerLearningRepository: WorkerLearningRepository(
              firestoreService: firestoreService,
              organizationId: 'org-alpha',
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.safetyLearning,
          builder: (context, state) =>
              const Scaffold(body: Text('Safety Learning screen')),
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
      ],
    );

    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(siteIds: siteIds),
      child: MaterialApp.router(routerConfig: router),
    );
  }

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

  Future<void> seedCorrectiveAction(String id, {String status = 'open'}) async {
    await firestore.doc('organizations/org-alpha/corrective_actions/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
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

  testWidgets('renders the dashboard heading and section titles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Ready for Today'), findsOneWidget);
    expect(find.text("Today's Meeting"), findsOneWidget);
    await tester.scrollUntilVisible(find.text('All My Learning'), 200);
    expect(find.text('All My Learning'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('My Safety Reports'), 200);
    expect(find.text('My Safety Reports'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('My Corrective Actions'), 200);
    expect(find.text('My Corrective Actions'), findsOneWidget);
    expect(find.text('Report a Safety Issue'), findsOneWidget);
  });

  testWidgets('shows a message when the worker has no assigned site', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(siteIds: const []));
    await tester.pumpAndSettle();

    expect(find.text('You are not yet assigned to a site.'), findsOneWidget);
  });

  testWidgets('shows no meeting recorded when none exists today', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(
      find.text('No meeting recorded at your site today.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the open hazard count from watchReportedBy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedHazard('h1', status: 'reported');
    await seedHazard('h2', status: 'closed');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('open hazard'), 200);

    // One still open (the closed one doesn't count).
    expect(find.text('open hazard'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
  });

  testWidgets('shows the open corrective action count from watchForAssignee', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedCorrectiveAction('ca1', status: 'open');
    await seedCorrectiveAction('ca2', status: 'completed');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('action open'), 200);
    expect(find.text('action open'), findsOneWidget);
  });

  testWidgets("Ready for Today leads the dashboard with only today's "
      'before-meeting and before-work counts', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        readiness: TodaysSafetyReadiness(
          gatingSource: ReadinessGatingSource.assignments,
          projects: const [ReadinessScopeRef(id: 'p', name: 'Rosslyn Project')],
          beforeMeeting: [_item('g1'), _item('g2')],
          beforeWork: [_item('p1')],
          additional: [_item('x1'), _item('x2'), _item('x3')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rosslyn Project'), findsOneWidget);
    expect(find.text('2 items remaining'), findsOneWidget);
    expect(find.text('1 item remaining'), findsOneWidget);
    expect(find.text('Continue Learning'), findsOneWidget);
    expect(find.text('Learning x1'), findsNothing);
  });

  testWidgets('tapping "See all" under All My Learning opens the full '
      'learning list on its own page', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // The Pre-Start Check card sits above this section; bring the section
    // heading into view first so its "See all" button is built at all.
    await tester.scrollUntilVisible(find.text('All My Learning'), 200);
    final seeAll = find.widgetWithText(TextButton, 'See all').first;
    await tester.ensureVisible(seeAll);
    await tester.pumpAndSettle();
    await tester.tap(seeAll);
    await tester.pumpAndSettle();

    expect(openedAllLearning, ['all']);
  });

  testWidgets('Report a Safety Issue opens the chooser, which opens the '
      'right form', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report a Safety Issue'));
    await tester.pumpAndSettle();

    expect(find.text('Something COULD happen'), findsOneWidget);
    expect(find.text('Something NEARLY happened'), findsOneWidget);
    expect(find.text('Something ACTUALLY happened'), findsOneWidget);

    await tester.tap(find.text('Something COULD happen'));
    await tester.pumpAndSettle();
    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
  });
}
