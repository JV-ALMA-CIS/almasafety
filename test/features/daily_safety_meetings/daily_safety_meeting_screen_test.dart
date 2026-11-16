import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/reports/pdf_report.dart';
import 'package:jva_safety/core/reports/print_report_button.dart';
import 'package:jva_safety/core/widgets/choice_list.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_admin_service.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_repository.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_evidence_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_foreman_point_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_point_note_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/daily_safety_meeting_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/risk_assessments/data/risk_assessment_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';
import 'package:jva_safety/features/safety_meeting_points/data/safety_meeting_point_repository.dart';
import 'package:jva_safety/features/pre_start_checks/domain/pre_start_outcome.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, List<String> siteIds = const []})
    : _profile = UserProfile(
        uid: 'O9755kUSpMUZcJWARnsmuCzo8d72',
        name: 'Tomas',
        email: 'tom@example.com',
        accountStatus: AccountStatus.active,
        // platformRole is admin-only now; every other role (including
        // foreman, which this screen requires) lives on the active
        // Membership instead.
        platformRole: role == AppRole.admin ? role : null,
      ),
      _membership = role == null || role == AppRole.admin
          ? null
          : Membership(
              organizationId: 'org-alpha',
              role: role,
              siteIds: siteIds,
              status: MembershipStatus.active,
            );

  final UserProfile _profile;
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId =>
      _membership?.organizationId ?? 'org-alpha';

  @override
  Membership? get activeMembership => _membership;
}

class _FakeMeetingService extends DailySafetyMeetingService {
  final List<Map<String, Object?>> createCalls = [];
  final List<
    ({String id, List<String>? activityIds, List<String>? meetingPointIds})
  >
  updateCalls = [];
  final List<String> completeCalls = [];
  final List<List<String>> ahaCalls = [];
  final List<({PreStartOutcome? outcome, String? note})> crewOutcomes = [];
  AppException? completeError;

  /// Every `saveMeetingForemanPoint` / `removeMeetingForemanPoint` call.
  final List<Map<String, String?>> foremanPointSaves = [];
  final List<String> foremanPointRemovals = [];

  @override
  Future<void> saveMeetingForemanPoint({
    required String organizationId,
    required String meetingId,
    required String pointId,
    required String title,
    String? note,
    String? activityId,
  }) async {
    foremanPointSaves.add({
      'meetingId': meetingId,
      'pointId': pointId,
      'title': title,
      'note': note,
      'activityId': activityId,
    });
  }

  @override
  Future<void> removeMeetingForemanPoint({
    required String organizationId,
    required String meetingId,
    required String pointId,
  }) async {
    foremanPointRemovals.add(pointId);
  }

  /// What `getMyMeetingLearningGate` reports as the Foreman's own
  /// outstanding "Needed today" lessons.
  List<({String learningId, String title})> gateOutstanding = const [];

  /// What `getMeetingPointSuggestions` returns. Null (the default) behaves
  /// as if the server could not be reached, so the screen falls back to
  /// matching today's activities only.
  List<({String pointId, List<String> reasons})>? suggestions;
  final List<String> suggestionSites = [];

  @override
  Future<List<({String pointId, List<String> reasons})>>
  getMeetingPointSuggestions({
    required String organizationId,
    required String siteId,
    required List<String> activityIds,
  }) async {
    suggestionSites.add(siteId);
    final result = suggestions;
    if (result == null) {
      throw const DataException('Cannot reach the safety service.');
    }
    return result;
  }

  @override
  Future<List<({String learningId, String title})>> getMyMeetingLearningGate({
    required String organizationId,
    required String siteId,
    required List<String> activityIds,
    String? meetingId,
  }) async => gateOutstanding;

  @override
  Future<String> createDailySafetyMeeting({
    required String organizationId,
    required String projectId,
    required String siteId,
    List<String> activityIds = const [],
    List<String> meetingPointIds = const [],
  }) async {
    createCalls.add({
      'organizationId': organizationId,
      'projectId': projectId,
      'siteId': siteId,
      'activityIds': activityIds,
      'meetingPointIds': meetingPointIds,
    });
    return 'meeting-1';
  }

  @override
  Future<void> updateDailySafetyMeeting(
    String organizationId,
    String id, {
    List<String>? activityIds,
    List<String>? meetingPointIds,
    List<String>? concerns,
    List<String>? ahaIds,
  }) async {
    if (ahaIds != null) ahaCalls.add(ahaIds);
    updateCalls.add((
      id: id,
      activityIds: activityIds,
      meetingPointIds: meetingPointIds,
    ));
  }

  @override
  Future<void> completeDailySafetyMeeting(
    String organizationId,
    String id, {
    PreStartOutcome? crewOutcome,
    String? crewOutcomeNote,
  }) async {
    final error = completeError;
    if (error != null) throw error;
    completeCalls.add(id);
    crewOutcomes.add((outcome: crewOutcome, note: crewOutcomeNote));
  }
}

class _FakeAttendanceService extends MeetingAttendanceService {
  _FakeAttendanceService({this.learningStatus = const {}});

  final Map<String, List<String>> learningStatus;
  final List<String> recordCalls = [];
  final List<String> briefedCalls = [];

  @override
  Future<void> recordMeetingAttendance({
    required String organizationId,
    required String meetingId,
    required String workerId,
    required String status,
    bool briefedInPerson = false,
  }) async {
    recordCalls.add(workerId);
    if (briefedInPerson) briefedCalls.add(workerId);
  }

  @override
  Future<Map<String, List<String>>> getMeetingAttendeeLearningStatus({
    required String organizationId,
    required String meetingId,
  }) async => learningStatus;
}

class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({this.users = const []});

  List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async => users;
}

/// Stands in for the `getSiteActivities` callable — reads through the same
/// fake Firestore via [ActivityRepository.watchBySite], which is fine in
/// tests since `FakeFirebaseFirestore` does not enforce security rules at
/// all (the rules restriction this callable exists to work around is a
/// production-only concern).
class _FakeActivityAdminService extends ActivityAdminService {
  _FakeActivityAdminService(this._repository);

  final ActivityRepository _repository;

  @override
  Future<List<Activity>> getSiteActivities({
    required String organizationId,
    required String siteId,
  }) => _repository.watchBySite(siteId).first;
}

class _FakeConcernService extends MeetingConcernService {
  final List<({String description, String category})> addCalls = [];

  @override
  Future<String> addMeetingConcern({
    required String organizationId,
    required String meetingId,
    required String description,
    required String category,
  }) async {
    addCalls.add((description: description, category: category));
    return 'concern-1';
  }
}

/// Scrolls the screen until [finder] is built and fully on screen, then
/// taps it — for buttons the colored layout pushes below the test viewport.
Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tapVisible(tester, finder);
}

/// Scrolls [finder] fully into view before tapping it — the colored
/// meeting header pushes some buttons to the bottom edge of the test screen.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  // A lazily built list only builds what is near the screen — scroll down
  // to it first when it is further away.
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

/// Picks [label] ("GO", "GO corrected" or "STOP") in the crew-result
/// dialog that Complete Meeting opens, adds [note] if given, and confirms.
Future<void> chooseCrewResult(
  WidgetTester tester,
  String label, {
  String? note,
}) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  if (note != null) {
    await tester.enterText(find.byType(TextField).last, note);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.widgetWithText(TextButton, 'Complete Meeting'));
  await tester.pumpAndSettle();
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    // A tall screen, so the whole meeting (which now also lists what is
    // still open from earlier) is built without scrolling in most tests.
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1;
    addTearDown(view.reset);
  });

  Future<void> seedSite(String id, {String name = 'Test Site'}) async {
    await firestore.doc('organizations/org-alpha/sites/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedActivity(
    String id, {
    String siteId = 'site-1',
    String name = 'Roofing',
  }) async {
    await firestore.doc('organizations/org-alpha/activities/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': siteId,
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedMeetingPoint(
    String id, {
    String title = 'Working at Height',
    String category = 'safety',
    List<String> applicableActivities = const [],
  }) async {
    await firestore
        .doc('organizations/org-alpha/safety_meeting_points/$id')
        .set({
          'organizationId': 'org-alpha',
          'title': title,
          'category': category,
          'status': 'active',
          'applicableActivities': applicableActivities,
          'applicableRisks': <String>[],
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        });
  }

  Future<void> seedMeeting(
    String id, {
    String foremanId = 'O9755kUSpMUZcJWARnsmuCzo8d72',
    String siteId = 'site-1',
    List<String> activityIds = const [],
    List<String> meetingPointIds = const [],
    String status = 'inProgress',
    String? date,
  }) async {
    final today = DateTime.now();
    final resolvedDate =
        date ??
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
            '${today.day.toString().padLeft(2, '0')}';
    await firestore
        .doc('organizations/org-alpha/daily_safety_meetings/$id')
        .set({
          'organizationId': 'org-alpha',
          'projectId': 'project-1',
          'siteId': siteId,
          'date': resolvedDate,
          'foremanId': foremanId,
          'activityIds': activityIds,
          'meetingPointIds': meetingPointIds,
          'status': status,
          'concerns': <String>[],
          'correctiveActionIds': <String>[],
          'createdAt': Timestamp.now(),
        });
  }

  Future<void> seedAssignment(String activityId, String uid) {
    return firestore
        .doc('organizations/org-alpha/activities/$activityId/assignments/$uid')
        .set({
          'uid': uid,
          'organizationId': 'org-alpha',
          'siteId': 'site-1',
          'activityId': activityId,
          'assignedAt': Timestamp.now(),
          'assignedBy': 'foreman-a',
        });
  }

  Future<void> seedWorkerLearningRecord(
    String workerUid,
    String learningId, {
    required String status,
  }) {
    return firestore
        .doc(
          'organizations/org-alpha/worker_learning_records/'
          '${workerUid}_$learningId',
        )
        .set({
          'workerUid': workerUid,
          'organizationId': 'org-alpha',
          'learningId': learningId,
          'status': status,
          'assignedAt': Timestamp.now(),
        });
  }

  Widget wrap({
    required AppRole? role,
    List<String> siteIds = const ['site-1'],
    _FakeMeetingService? meetingService,
    _FakeConcernService? concernService,
    _FakeAttendanceService? attendanceService,
    _FakeApprovalService? approvalService,
    ReportPrinter? printReport,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, siteIds: siteIds),
      child: MaterialApp(
        home: Scaffold(
          body: DailySafetyMeetingScreen(
            meetingRepository: DailySafetyMeetingRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            meetingService: meetingService ?? _FakeMeetingService(),
            activityAdminService: _FakeActivityAdminService(
              ActivityRepository(
                firestoreService: FirestoreService(firestore: firestore),
                organizationId: 'org-alpha',
              ),
            ),
            meetingPointRepository: SafetyMeetingPointRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            activityAssignmentRepository: ActivityAssignmentRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            attendanceService: attendanceService ?? _FakeAttendanceService(),
            attendanceRepositoryBuilder: (meetingId) =>
                MeetingAttendanceRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: 'org-alpha',
                  meetingId: meetingId,
                ),
            concernService: concernService ?? _FakeConcernService(),
            concernRepositoryBuilder: (meetingId) => MeetingConcernRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
              meetingId: meetingId,
            ),
            correctiveActionService: CorrectiveActionService(),
            correctiveActionRepository: CorrectiveActionRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            pointNoteRepositoryBuilder: (meetingId) =>
                MeetingPointNoteRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: 'org-alpha',
                  meetingId: meetingId,
                ),
            foremanPointRepositoryBuilder: (meetingId) =>
                MeetingForemanPointRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: 'org-alpha',
                  meetingId: meetingId,
                ),
            evidenceRepositoryBuilder: (meetingId) => MeetingEvidenceRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
              meetingId: meetingId,
            ),
            workerLearningRepository: WorkerLearningRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            riskAssessmentRepository: RiskAssessmentRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            approvalService: approvalService ?? _FakeApprovalService(),
            printReport: printReport,
          ),
        ),
      ),
    );
  }

  group('DailySafetyMeetingScreen (access)', () {
    testWidgets('a foreman assigned to a site can open the screen', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Daily Safety Meetings are available to a foreman assigned to '
          'a site.',
        ),
        findsNothing,
      );
    });

    testWidgets('a foreman with no assigned site is refused', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.foreman, siteIds: const []));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Daily Safety Meetings are available to a foreman assigned to '
          'a site.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'a worker (non-foreman) sees their own site\'s Today\'s Meeting '
      'card, not the foreman workspace',
      (tester) async {
        await tester.pumpWidget(wrap(role: AppRole.worker));
        await tester.pumpAndSettle();

        expect(find.text("Today's Meeting"), findsOneWidget);
        // The foreman-only "Start Today's Meeting" flow must never render
        // for a worker.
        expect(find.text("Start Today's Meeting"), findsNothing);
      },
    );

    testWidgets('a worker with no assigned site sees a clear message via '
        "the shared Today's Meeting card", (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.worker, siteIds: const []));
      await tester.pumpAndSettle();

      expect(find.text('You are not yet assigned to a site.'), findsOneWidget);
    });
  });

  group('DailySafetyMeetingScreen (start view — site and activities)', () {
    testWidgets('shows the correct assigned site', (tester) async {
      await seedSite('site-1', name: 'Test Site');
      await seedActivity('activity-1');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Test Site'), findsOneWidget);
    });

    testWidgets('shows the site\'s active activity', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1', name: 'Roofing');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Roofing'), findsOneWidget);
    });

    testWidgets('shows recommended meeting points', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1', title: 'Working at Height');
      await seedMeetingPoint('point-2', title: 'PPE');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Working at Height'), findsOneWidget);
      expect(find.text('PPE'), findsOneWidget);
    });

    testWidgets('meeting points are unchecked by default — the foreman '
        "must actively select which apply today's meeting", (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await scrollAndTap(
        tester,
        find.widgetWithText(ElevatedButton, "Start Today's Meeting"),
      );
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single['siteId'], 'site-1');
      expect(service.createCalls.single['activityIds'], ['activity-1']);
      expect(service.createCalls.single['meetingPointIds'], <String>[]);
    });

    testWidgets('ticking a point far down the list keeps the page where it '
        'is — regression test for every tick jumping back to the top', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      // Enough points to run well past the bottom of the (tall) test screen.
      for (var i = 1; i <= 60; i++) {
        await seedMeetingPoint('point-$i', title: 'Point $i');
      }

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      final point = find.widgetWithText(ChoiceTile, 'Point 55');
      await tester.scrollUntilVisible(
        point,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scrollable.position.pixels;
      expect(before, greaterThan(0));

      await tester.tap(point);
      await tester.pumpAndSettle();

      expect(scrollable.position.pixels, before);
      expect(tester.widget<ChoiceTile>(point).selected, isTrue);
    });

    testWidgets('checking a meeting point includes it when starting the '
        'meeting', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1', title: 'Working at Height');
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceTile, 'Working at Height'));
      await tester.pumpAndSettle();

      final tile = tester.widget<ChoiceTile>(
        find.widgetWithText(ChoiceTile, 'Working at Height'),
      );
      expect(tile.selected, isTrue, reason: 'point should be ticked after tap');

      await scrollAndTap(
        tester,
        find.widgetWithText(ElevatedButton, "Start Today's Meeting"),
      );
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single['meetingPointIds'], ['point-1']);
    });

    testWidgets('a point scoped to Roofing by its real activity document id is '
        "recommended for today's Roofing meeting, and a point scoped to a "
        'different activity is not', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1', name: 'Roofing');
      // Scoped correctly to the real activity id — must be recommended.
      await seedMeetingPoint(
        'point-1',
        title: 'Working at Height',
        applicableActivities: ['activity-1'],
      );
      // Scoped to an activity that isn't at this site today — must not be
      // recommended for this meeting.
      await seedMeetingPoint(
        'point-2',
        title: 'Electrical Safety',
        applicableActivities: ['activity-other'],
      );
      // Universal (empty list) — always recommended, matching every other
      // test in this file.
      await seedMeetingPoint('point-3', title: 'PPE');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Working at Height'), findsOneWidget);
      expect(find.text('PPE'), findsOneWidget);
      expect(find.text('Electrical Safety'), findsNothing);
    });
  });

  group(
    'DailySafetyMeetingScreen (in-progress workspace — meeting points)',
    () {
      testWidgets('recommended points seeded on the meeting are shown as '
          'covered/checked', (tester) async {
        await seedSite('site-1');
        await seedActivity('activity-1');
        await seedMeetingPoint('point-1', title: 'Working at Height');
        await seedMeeting(
          'meeting-1',
          activityIds: ['activity-1'],
          meetingPointIds: ['point-1'],
        );

        await tester.pumpWidget(wrap(role: AppRole.foreman));
        await tester.pumpAndSettle();

        final tile = tester.widget<ChoiceTile>(
          find.widgetWithText(ChoiceTile, 'Working at Height'),
        );
        expect(tile.selected, isTrue);
      });

      testWidgets('removing a recommended point calls updateDailySafetyMeeting '
          'without it', (tester) async {
        await seedSite('site-1');
        await seedActivity('activity-1');
        await seedMeetingPoint('point-1', title: 'Working at Height');
        await seedMeetingPoint('point-2', title: 'PPE');
        await seedMeeting(
          'meeting-1',
          activityIds: ['activity-1'],
          meetingPointIds: ['point-1', 'point-2'],
        );
        final service = _FakeMeetingService();

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, meetingService: service),
        );
        await tester.pumpAndSettle();

        final removeButtons = find.byTooltip('Remove');
        await tester.tap(removeButtons.first);
        await tester.pumpAndSettle();

        expect(service.updateCalls, isNotEmpty);
        expect(service.updateCalls.last.meetingPointIds, hasLength(1));
      });

      testWidgets('adding a safety point from the library adds it to the '
          'meeting', (tester) async {
        await seedSite('site-1');
        await seedActivity('activity-1');
        await seedMeetingPoint('point-1', title: 'Working at Height');
        await seedMeetingPoint('point-2', title: 'Ladder Safety');
        await seedMeeting(
          'meeting-1',
          activityIds: ['activity-1'],
          meetingPointIds: ['point-1'],
        );
        final service = _FakeMeetingService();

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, meetingService: service),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Add Safety Point'));
        await tester.pumpAndSettle();

        // "Ladder Safety" is offered since it's not yet on the meeting;
        // "Working at Height" is already recommended, so the picker's
        // candidate list must exclude it even though the underlying page
        // still shows it in the Recommended section behind the dialog.
        expect(find.text('Ladder Safety'), findsOneWidget);
        await tester.tap(find.text('Ladder Safety'));
        await tester.pumpAndSettle();

        expect(service.updateCalls, isNotEmpty);
        expect(
          service.updateCalls.last.meetingPointIds,
          containsAll(['point-1', 'point-2']),
        );
      });

      testWidgets('no audio-recording or speech-to-text control exists '
          'anywhere on the meeting workspace', (tester) async {
        await seedSite('site-1');
        await seedActivity('activity-1');
        await seedMeeting('meeting-1', activityIds: ['activity-1']);

        await tester.pumpWidget(wrap(role: AppRole.foreman));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.mic), findsNothing);
        expect(find.byIcon(Icons.mic_none), findsNothing);
        expect(find.textContaining('Record'), findsNothing);
        expect(find.textContaining('Transcri'), findsNothing);
        expect(find.textContaining('Translat'), findsNothing);
      });
    },
  );

  group('DailySafetyMeetingScreen (attendance — learning visibility)', () {
    testWidgets('shows an assigned worker by name, resolved from the '
        'organization roster', (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          approvalService: _FakeApprovalService(
            users: const [
              OrganizationUser(
                uid: 'worker-a',
                name: 'Alex Worker',
                email: 'alex@example.com',
                accountStatus: AccountStatus.active,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alex Worker'), findsOneWidget);
      expect(find.text('worker-a'), findsNothing);
    });

    testWidgets('falls back to the raw uid when no name could be resolved', (
      tester,
    ) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('worker-a'), findsOneWidget);
    });

    testWidgets('a worker with lessons outstanding can be marked present as '
        '"Briefed in person", after confirming', (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      final attendance = _FakeAttendanceService(
        learningStatus: const {
          'worker-a': ['Working at Height'],
        },
      );

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, attendanceService: attendance),
      );
      await tester.pumpAndSettle();

      final briefed = find.widgetWithText(OutlinedButton, 'Briefed in person');
      await tapVisible(tester, briefed);
      await tester.pumpAndSettle();
      expect(find.text('Briefed in person?'), findsOneWidget);
      expect(find.textContaining('• Working at Height'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Mark present'));
      await tester.pumpAndSettle();

      expect(attendance.briefedCalls, ['worker-a']);
    });

    testWidgets('a worker with nothing outstanding is never offered '
        '"Briefed in person"', (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          attendanceService: _FakeAttendanceService(
            learningStatus: const {'worker-a': []},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Briefed in person'), findsNothing);
    });

    testWidgets(
      'shows an attendee\'s outstanding required learning, informationally',
      (tester) async {
        await seedActivity('activity-1');
        await seedAssignment('activity-1', 'worker-a');
        await seedMeeting('meeting-1', activityIds: ['activity-1']);

        await tester.pumpWidget(
          wrap(
            role: AppRole.foreman,
            attendanceService: _FakeAttendanceService(
              learningStatus: const {
                'worker-a': ['Working at Height'],
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Outstanding: Working at Height'), findsOneWidget);
      },
    );

    testWidgets(
      'shows nothing extra for an attendee with no outstanding learning',
      (tester) async {
        await seedActivity('activity-1');
        await seedAssignment('activity-1', 'worker-a');
        await seedMeeting('meeting-1', activityIds: ['activity-1']);

        await tester.pumpWidget(
          wrap(
            role: AppRole.foreman,
            attendanceService: _FakeAttendanceService(
              learningStatus: const {'worker-a': []},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Outstanding:'), findsNothing);
      },
    );

    testWidgets('marking attendance is never blocked by outstanding learning — '
        'informational only', (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final attendanceService = _FakeAttendanceService(
        learningStatus: const {
          'worker-a': ['Working at Height'],
        },
      );

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, attendanceService: attendanceService),
      );
      await tester.pumpAndSettle();

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Present'));
      await tester.pumpAndSettle();

      expect(attendanceService.recordCalls, ['worker-a']);
    });
  });

  group('DailySafetyMeetingScreen (concerns)', () {
    testWidgets('a concern can be recorded', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      final concernService = _FakeConcernService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, concernService: concernService),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Describe the concern'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Describe the concern'),
        'Unstable ladder at east wing.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add Concern'));
      await tester.pumpAndSettle();

      expect(concernService.addCalls, hasLength(1));
      expect(
        concernService.addCalls.single.description,
        'Unstable ladder at east wing.',
      );
    });
  });

  group('DailySafetyMeetingScreen (risk assessments)', () {
    Future<void> seedAha(
      String id, {
      String status = 'accepted',
      String siteId = 'site-1',
      List<String> activityIds = const [],
    }) {
      return firestore.doc('organizations/org-alpha/risk_assessments/$id').set({
        'organizationId': 'org-alpha',
        'siteId': siteId,
        'featureOfWork': 'Removals',
        'revision': 1,
        'status': status,
        'steps': <Object>[],
        'activityIds': activityIds,
      });
    }

    Future<void> readyMeeting() async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
    }

    Future<void> scrollTo(WidgetTester tester, String text) async {
      await tester.scrollUntilVisible(
        find.text(text),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      // Rows rebuilt by scrolling (the learning check) settle first.
      await tester.pumpAndSettle();
    }

    ElevatedButton completeButton(WidgetTester tester) =>
        tester.widget(find.widgetWithText(ElevatedButton, 'Complete Meeting'));

    testWidgets("the site's accepted AHA must be ticked before Complete", (
      tester,
    ) async {
      await readyMeeting();
      await seedAha('aha-1');
      await seedAha('draft', status: 'draft');
      await seedAha('other', siteId: 'site-2');
      final service = _FakeMeetingService();
      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await scrollTo(tester, 'Read "Removals"');
      // Only the accepted AHA for this site is offered.
      expect(find.text('Read "Removals"'), findsOneWidget);
      await tapVisible(tester, find.text('Removals'));
      await tester.pumpAndSettle();
      expect(service.ahaCalls, [
        ['aha-1'],
      ]);

      // Not ticked yet (this fake does not save it), so Complete waits.
      await scrollTo(tester, 'Complete Meeting');
      expect(completeButton(tester).onPressed, isNull);
      expect(
        find.textContaining('Cover the risk assessment (AHA)'),
        findsOneWidget,
      );
    });

    testWidgets('once covered, the meeting can be completed', (tester) async {
      await readyMeeting();
      await seedAha('aha-1');
      await firestore
          .doc('organizations/org-alpha/daily_safety_meetings/meeting-1')
          .update({
            'ahaIds': ['aha-1'],
          });
      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('1 AHA covered'), findsOneWidget);
      await scrollTo(tester, 'Complete Meeting');
      expect(completeButton(tester).onPressed, isNotNull);
    });

    testWidgets("an AHA for an activity not worked today is not offered "
        'and does not hold the meeting up', (tester) async {
      await readyMeeting();
      await seedAha('aha-1', activityIds: const ['activity-other']);
      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();
      await scrollTo(
        tester,
        "None of today's activities has a risk assessment.",
      );
      expect(find.text('Read "Removals"'), findsNothing);
      await scrollTo(tester, 'Complete Meeting');
      expect(completeButton(tester).onPressed, isNotNull);
    });

    testWidgets('a site without an accepted AHA is not held up', (
      tester,
    ) async {
      await readyMeeting();
      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();
      await scrollTo(tester, 'This site has no accepted risk assessment yet.');
      await scrollTo(tester, 'Complete Meeting');
      expect(completeButton(tester).onPressed, isNotNull);
    });
  });

  group('DailySafetyMeetingScreen (completion gate)', () {
    testWidgets('cannot complete without at least one activity and one '
        'meeting point', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting(
        'meeting-1',
        activityIds: const [],
        meetingPointIds: const [],
      );

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );

      final completeButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      expect(completeButton.onPressed, isNull);
      expect(
        find.text(
          'At least one activity and one meeting point must be '
          'recorded before completing.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('can complete once an activity and a meeting point are '
        'recorded', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      await tester.pumpAndSettle();

      await chooseCrewResult(tester, 'GO');
      expect(service.completeCalls, ['meeting-1']);
      expect(service.crewOutcomes.single.outcome, PreStartOutcome.go);
      expect(service.crewOutcomes.single.note, isNull);
    });

    testWidgets('cancelling the crew result leaves the meeting in progress', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      await tester.pumpAndSettle();

      expect(find.text("Today's crew result"), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(service.completeCalls, isEmpty);
    });

    testWidgets('a crew STOP needs a note, and sends it with the result', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('STOP'));
      await tester.pumpAndSettle();
      final confirm = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Complete Meeting'),
      );
      expect(confirm.onPressed, isNull);

      await tester.enterText(
        find.byType(TextField).last,
        'Scaffold failed inspection',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Complete Meeting'));
      await tester.pumpAndSettle();

      expect(service.crewOutcomes.single.outcome, PreStartOutcome.stop);
      expect(service.crewOutcomes.single.note, 'Scaffold failed inspection');
    });

    const foremanUid = 'O9755kUSpMUZcJWARnsmuCzo8d72';

    testWidgets('is blocked, with the outstanding item named, when the foreman '
        'has not completed a required learning item for this meeting', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final service = _FakeMeetingService()
        ..gateOutstanding = const [
          (learningId: 'l1', title: 'Working at Height Training'),
        ];

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('• Working at Height Training'), findsOneWidget);
      final completeButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      expect(completeButton.onPressed, isNull);
    });

    testWidgets(
      'unblocks once the foreman completes the required learning item',
      (tester) async {
        await seedSite('site-1');
        await seedActivity('activity-1');
        // Titled apart from the lesson, which is what must disappear.
        await seedMeetingPoint('point-1', title: 'PPE');
        // The server still lists l1 (fetched before completion); the
        // Foreman's completed record drops it live.
        await seedWorkerLearningRecord(foremanUid, 'l1', status: 'completed');
        await seedMeeting(
          'meeting-1',
          activityIds: ['activity-1'],
          meetingPointIds: ['point-1'],
        );
        final service = _FakeMeetingService()
          ..gateOutstanding = const [
            (learningId: 'l1', title: 'Working at Height'),
          ];

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, meetingService: service),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.text('Complete Meeting'),
          1000,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        expect(find.text('Working at Height'), findsNothing);
        await tapVisible(
          tester,
          find.widgetWithText(ElevatedButton, 'Complete Meeting'),
        );
        await tester.pumpAndSettle();

        await chooseCrewResult(tester, 'GO');
        expect(service.completeCalls, ['meeting-1']);
      },
    );

    testWidgets('nothing outstanding on the server means Complete is '
        'available', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      await tester.pumpAndSettle();

      await chooseCrewResult(tester, 'GO');
      expect(service.completeCalls, ['meeting-1']);
    });
  });

  group('DailySafetyMeetingScreen (organization/site isolation)', () {
    testWidgets('a meeting from another organization never surfaces here', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      // A meeting under a different organization path is never visible to
      // this repository, which is scoped to organizations/org-alpha at
      // construction — matching every other org-scoped repository in this
      // codebase.
      await firestore
          .doc('organizations/org-other/daily_safety_meetings/meeting-x')
          .set({
            'organizationId': 'org-other',
            'projectId': 'project-1',
            'siteId': 'site-1',
            'date': '2026-01-01',
            'foremanId': 'O9755kUSpMUZcJWARnsmuCzo8d72',
            'activityIds': <String>[],
            'meetingPointIds': <String>[],
            'status': 'inProgress',
            'concerns': <String>[],
            'correctiveActionIds': <String>[],
            'createdAt': Timestamp.now(),
          });

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      // No in-progress meeting workspace should render for the org-alpha
      // foreman — they should still see the Start view.
      expect(find.text("Start Today's Meeting"), findsOneWidget);
    });
  });

  // ---- Milestone 1: a meeting record you can trust ----

  Future<void> seedConcern(String meetingId, String id, String text) {
    return firestore
        .doc(
          'organizations/org-alpha/daily_safety_meetings/$meetingId/'
          'concerns/$id',
        )
        .set({
          'meetingId': meetingId,
          'organizationId': 'org-alpha',
          'siteId': 'site-1',
          'description': text,
          'category': 'equipment',
          'reportedBy': 'O9755kUSpMUZcJWARnsmuCzo8d72',
          'status': 'open',
          'createdAt': Timestamp.now(),
        });
  }

  Future<void> seedCorrectiveAction(
    String id, {
    required String title,
    String status = 'open',
    String siteId = 'site-1',
  }) {
    return firestore.doc('organizations/org-alpha/corrective_actions/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': siteId,
      'meetingId': 'old-meeting',
      'concernId': null,
      'hazardId': null,
      'incidentId': null,
      'title': title,
      'description': 'Fix it',
      'assignedTo': 'worker-a',
      'assignedBy': 'O9755kUSpMUZcJWARnsmuCzo8d72',
      'dueDate': Timestamp.fromDate(DateTime(2026, 11, 2)),
      'status': status,
      'createdAt': Timestamp.now(),
    });
  }

  group('DailySafetyMeetingScreen (site picker)', () {
    testWidgets('a foreman at one site sees no site picker', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.textContaining('tap to change'), findsNothing);
    });

    testWidgets('a foreman at several sites picks which site the meeting is '
        'for, and starts it there', (tester) async {
      await seedSite('site-1', name: 'Rosslyn Ridge');
      await seedSite('site-2', name: 'Gigiri Residence');
      await seedActivity('activity-1', name: 'Roofing');
      await seedActivity('activity-2', siteId: 'site-2', name: 'Plastering');
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          siteIds: const ['site-1', 'site-2'],
          meetingService: service,
        ),
      );
      await tester.pumpAndSettle();

      // Starts on the first site.
      expect(find.text('Roofing'), findsOneWidget);
      expect(find.text('Plastering'), findsNothing);

      await tester.tap(find.textContaining('tap to change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gigiri Residence'));
      await tester.pumpAndSettle();

      expect(find.text('Plastering'), findsOneWidget);
      expect(find.text('Roofing'), findsNothing);

      await scrollAndTap(tester, find.text("Start Today's Meeting"));
      await tester.pumpAndSettle();
      expect(service.createCalls.single['siteId'], 'site-2');
      expect(service.createCalls.single['activityIds'], ['activity-2']);
      expect(service.suggestionSites.last, 'site-2');
    });
  });

  group('DailySafetyMeetingScreen (suggested points)', () {
    testWidgets("shows the server's suggestions in its order, with the "
        'reasons, and leaves out points it did not suggest', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-ppe', title: 'PPE');
      await seedMeetingPoint('point-height', title: 'Working at Height');
      await seedMeetingPoint('point-dig', title: 'Excavation');
      final service = _FakeMeetingService()
        ..suggestions = const [
          (pointId: 'point-height', reasons: ["Today's work: Roofing"]),
          (
            pointId: 'point-ppe',
            reasons: ['General safety point for any work'],
          ),
        ];

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Today's work: Roofing"), findsOneWidget);
      expect(
        find.textContaining('General safety point for any work'),
        findsOneWidget,
      );
      expect(find.text('Excavation'), findsNothing);
      final height = tester.getTopLeft(find.text('Working at Height')).dy;
      final ppe = tester.getTopLeft(find.text('PPE')).dy;
      expect(height, lessThan(ppe));
    });
  });

  group('DailySafetyMeetingScreen (attendance — adding a site worker)', () {
    testWidgets("a worker from the same site who is not on today's "
        'activities can be added to the roster', (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          approvalService: _FakeApprovalService(
            users: const [
              OrganizationUser(
                uid: 'worker-a',
                name: 'Alex Worker',
                email: 'a@example.com',
                accountStatus: AccountStatus.active,
                role: AppRole.worker,
                siteIds: ['site-1'],
              ),
              OrganizationUser(
                uid: 'worker-b',
                name: 'Baraka Mason',
                email: 'b@example.com',
                accountStatus: AccountStatus.active,
                role: AppRole.worker,
                siteIds: ['site-1'],
              ),
              // Another site: never offered.
              OrganizationUser(
                uid: 'worker-c',
                name: 'Chebet Elsewhere',
                email: 'c@example.com',
                accountStatus: AccountStatus.active,
                role: AppRole.worker,
                siteIds: ['site-2'],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Baraka Mason'), findsNothing);
      await scrollAndTap(
        tester,
        find.text('Add another worker from this site'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chebet Elsewhere'), findsNothing);
      // Alex is already on the roster, so only Baraka is offered.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Alex Worker'),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Baraka Mason'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Baraka Mason'), findsOneWidget);
      expect(find.text('0 of 2 recorded'), findsOneWidget);
    });

    testWidgets('a site worker already marked stays on the roster after a '
        "reload, though not assigned to today's activities", (tester) async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      await firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/meeting-1/'
            'attendance/worker-b',
          )
          .set({
            'meetingId': 'meeting-1',
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'workerId': 'worker-b',
            'status': 'present',
            'recordedAt': Timestamp.now(),
          });

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('worker-b'), findsOneWidget);
      expect(find.text('1 of 2 recorded'), findsOneWidget);
    });
  });

  group('DailySafetyMeetingScreen (completed meeting)', () {
    testWidgets('a concern on a completed meeting can still get a corrective '
        'action, but cannot be edited or removed', (tester) async {
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        status: 'completed',
      );
      await seedConcern('meeting-1', 'c1', 'Ladder feet worn');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Ladder feet worn'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Create Corrective Action'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Remove'), findsNothing);
    });

    testWidgets('the Foreman can print their own completed meeting', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        status: 'completed',
      );
      String? printedName;

      await tester.pumpWidget(
        wrap(
          role: AppRole.foreman,
          printReport: ({required name, required build}) async {
            printedName = name;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Print / PDF'));
      await tester.pumpAndSettle();

      expect(printedName, startsWith('Daily safety meeting - Test Site'));
    });

    testWidgets('an in-progress meeting has no print button', (tester) async {
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.byType(PrintReportButton), findsNothing);
    });
  });

  group('DailySafetyMeetingScreen (still open from earlier)', () {
    testWidgets("lists open concerns from the Foreman's earlier meetings at "
        "the site and the site's unfinished corrective actions", (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting(
        'old-meeting',
        activityIds: ['activity-1'],
        status: 'completed',
        date: '2026-10-20',
      );
      await seedConcern('old-meeting', 'c1', 'Scaffold tag missing');
      // Another site's meeting never counts.
      await seedMeeting(
        'other-site',
        siteId: 'site-2',
        status: 'completed',
        date: '2026-10-21',
      );
      await seedConcern('other-site', 'c2', 'Elsewhere issue');
      await seedCorrectiveAction('ca-open', title: 'Replace ladder');
      await seedCorrectiveAction(
        'ca-done',
        title: 'Old finished job',
        status: 'completed',
      );
      await seedCorrectiveAction(
        'ca-far',
        title: 'Other site job',
        siteId: 'site-2',
      );

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Still open from earlier (2)'), findsOneWidget);
      await tester.tap(find.text('Still open from earlier (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Equipment: Scaffold tag missing'), findsOneWidget);
      expect(find.text('Raised at your meeting on 2026-10-20'), findsOneWidget);
      expect(find.text('Replace ladder'), findsOneWidget);
      expect(find.textContaining('Elsewhere issue'), findsNothing);
      expect(find.text('Old finished job'), findsNothing);
      expect(find.text('Other site job'), findsNothing);
    });

    testWidgets('says so when nothing is open', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(
        find.text('Nothing open from earlier meetings at this site.'),
        findsOneWidget,
      );
    });
  });
  group("DailySafetyMeetingScreen (the Foreman's own points)", () {
    Future<void> seedForemanPoint(
      String id, {
      String title = 'Wet roof sheets',
      String? note = 'No walking on wet sheets.',
      String? activityId = 'activity-1',
    }) {
      return firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/meeting-1/'
            'foreman_points/$id',
          )
          .set({
            'meetingId': 'meeting-1',
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'title': title,
            'note': note,
            'activityId': activityId,
            'recordedBy': 'O9755kUSpMUZcJWARnsmuCzo8d72',
            'createdAt': Timestamp.now(),
          });
    }

    testWidgets('the Foreman types a point of their own with what was '
        'discussed, about one of today\'s activities', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Type your own point'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Safety point'),
        '  Wet roof sheets after rain  ',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What was discussed (optional)'),
        'Crew waits until the sheets are dry.',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Roofing'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save point'));
      await tester.pumpAndSettle();

      final saved = service.foremanPointSaves.single;
      expect(saved['meetingId'], 'meeting-1');
      expect(saved['title'], 'Wet roof sheets after rain');
      expect(saved['note'], 'Crew waits until the sheets are dry.');
      expect(saved['activityId'], 'activity-1');
      // A fresh id chosen on the phone, safe to send twice.
      expect(saved['pointId'], matches(RegExp(r'^[A-Za-z0-9]{20}$')));
    });

    testWidgets('the point needs a title; what was discussed is optional', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Type your own point'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save point'));
      await tester.pumpAndSettle();
      expect(find.text('Type the safety point.'), findsOneWidget);
      expect(service.foremanPointSaves, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Safety point'),
        'Housekeeping',
      );
      await tester.tap(find.text('Save point'));
      await tester.pumpAndSettle();
      expect(service.foremanPointSaves.single['note'], isNull);
      expect(service.foremanPointSaves.single['activityId'], isNull);
    });

    testWidgets('shows the point with its activity and note, counts it, and '
        'lets the meeting complete with no library point', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      await seedForemanPoint('pointAbc12345');
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      expect(find.text('Wet roof sheets'), findsOneWidget);
      expect(find.text('Your own point · Roofing'), findsOneWidget);
      expect(find.text('No walking on wet sheets.'), findsOneWidget);
      expect(find.text('1 meeting point'), findsOneWidget);
      expect(
        find.textContaining('1 point of your own is about this'),
        findsOneWidget,
      );
      expect(
        find.textContaining('At least one activity and one meeting point'),
        findsNothing,
      );

      await tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Complete Meeting'),
      );
      await tester.pumpAndSettle();
      await chooseCrewResult(tester, 'GO');
      expect(service.completeCalls, ['meeting-1']);
    });

    testWidgets('editing keeps the same point; removing sends its id', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: ['activity-1']);
      await seedForemanPoint('pointAbc12345');
      final service = _FakeMeetingService();

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, meetingService: service),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit your point'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What was discussed (optional)'),
        'Sheets checked dry at 10:00.',
      );
      await tester.tap(find.text('Save point'));
      await tester.pumpAndSettle();
      expect(service.foremanPointSaves.single, {
        'meetingId': 'meeting-1',
        'pointId': 'pointAbc12345',
        'title': 'Wet roof sheets',
        'note': 'Sheets checked dry at 10:00.',
        'activityId': 'activity-1',
      });

      final remove = find.descendant(
        of: find.ancestor(
          of: find.text('Wet roof sheets'),
          matching: find.byType(Card),
        ),
        matching: find.byTooltip('Remove'),
      );
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(service.foremanPointRemovals, ['pointAbc12345']);
    });

    testWidgets('once completed, the point is read-only but a new one can '
        'still be added', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        status: 'completed',
      );
      await seedForemanPoint('pointAbc12345');

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      expect(find.text('Wet roof sheets'), findsOneWidget);
      expect(find.byTooltip('Edit'), findsNothing);
      expect(find.text('Type your own point'), findsOneWidget);
    });

    testWidgets('a library point shows an obvious box for what was '
        'discussed', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1'],
        meetingPointIds: ['point-1'],
      );

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add what was discussed'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'What was discussed'),
        findsOneWidget,
      );
    });
  });
}
