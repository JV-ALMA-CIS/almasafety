import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_repository.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/daily_safety_meeting_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_meeting_points/data/safety_meeting_point_repository.dart';

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
  String? get activeOrganizationId => _membership?.organizationId ?? 'org-alpha';

  @override
  Membership? get activeMembership => _membership;
}

class _FakeMeetingService extends DailySafetyMeetingService {
  final List<Map<String, Object?>> createCalls = [];
  final List<({String id, List<String>? activityIds, List<String>? meetingPointIds})>
      updateCalls = [];
  final List<String> completeCalls = [];
  AppException? completeError;

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
  }) async {
    updateCalls.add(
      (id: id, activityIds: activityIds, meetingPointIds: meetingPointIds),
    );
  }

  @override
  Future<void> completeDailySafetyMeeting(
    String organizationId,
    String id,
  ) async {
    final error = completeError;
    if (error != null) throw error;
    completeCalls.add(id);
  }
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

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
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
    await firestore.doc('organizations/org-alpha/safety_meeting_points/$id').set({
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
    final resolvedDate = date ??
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
            '${today.day.toString().padLeft(2, '0')}';
    await firestore.doc('organizations/org-alpha/daily_safety_meetings/$id').set({
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

  Widget wrap({
    required AppRole? role,
    List<String> siteIds = const ['site-1'],
    _FakeMeetingService? meetingService,
    _FakeConcernService? concernService,
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
            activityRepository: ActivityRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
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
            attendanceService: MeetingAttendanceService(),
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

    testWidgets('a worker (non-foreman) is refused regardless of site '
        'assignment', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.worker));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Daily Safety Meetings are available to a foreman assigned to '
          'a site.',
        ),
        findsOneWidget,
      );
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

    testWidgets('starting the meeting sends the recommended points and '
        "today's activities to the existing callable", (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeetingPoint('point-1');
      final service = _FakeMeetingService();

      await tester.pumpWidget(wrap(role: AppRole.foreman, meetingService: service));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, "Start Today's Meeting"));
      await tester.pumpAndSettle();

      expect(service.createCalls, hasLength(1));
      expect(service.createCalls.single['siteId'], 'site-1');
      expect(service.createCalls.single['activityIds'], ['activity-1']);
      expect(service.createCalls.single['meetingPointIds'], ['point-1']);
    });

    testWidgets(
      'a point scoped to Roofing by its real activity document id is '
      "recommended for today's Roofing meeting, and a point scoped to a "
      'different activity is not',
      (tester) async {
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
        await seedMeetingPoint(
          'point-3',
          title: 'PPE',
        );

        await tester.pumpWidget(wrap(role: AppRole.foreman));
        await tester.pumpAndSettle();

        expect(find.text('Working at Height'), findsOneWidget);
        expect(find.text('PPE'), findsOneWidget);
        expect(find.text('Electrical Safety'), findsNothing);
      },
    );
  });

  group('DailySafetyMeetingScreen (in-progress workspace — meeting points)', () {
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

      final checkbox = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'Working at Height'),
      );
      expect(checkbox.value, isTrue);
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

      await tester.pumpWidget(wrap(role: AppRole.foreman, meetingService: service));
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

      await tester.pumpWidget(wrap(role: AppRole.foreman, meetingService: service));
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
        200,
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

  group('DailySafetyMeetingScreen (completion gate)', () {
    testWidgets('cannot complete without at least one activity and one '
        'meeting point', (tester) async {
      await seedSite('site-1');
      await seedActivity('activity-1');
      await seedMeeting('meeting-1', activityIds: const [], meetingPointIds: const []);

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        200,
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

      await tester.pumpWidget(wrap(role: AppRole.foreman, meetingService: service));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Complete Meeting'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Complete Meeting'));
      await tester.pumpAndSettle();

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
}
