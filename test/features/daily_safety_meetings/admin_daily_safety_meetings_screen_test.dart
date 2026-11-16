import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting.dart';
import 'package:jva_safety/features/daily_safety_meetings/presentation/admin_daily_safety_meetings_screen.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';

/// Forces `watchAll()` to emit a stream error — reproduces the scenario
/// where one malformed document (or a permission/index failure) throws
/// inside the real repository's Firestore stream, which the admin screen
/// must surface rather than silently render as "no meetings."
class _ErroringMeetingRepository extends DailySafetyMeetingRepository {
  _ErroringMeetingRepository({required super.firestoreService})
    : super(organizationId: 'org-alpha');

  @override
  Stream<List<DailySafetyMeeting>> watchCompleted() =>
      Stream.error(Exception('simulated Firestore failure'));
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

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'admin-uid',
        name: 'Admin',
        email: 'admin@example.com',
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

  @override
  Membership? membershipFor(String organizationId) =>
      _membership?.organizationId == organizationId ? _membership : null;
}

void main() {
  late FakeFirebaseFirestore firestore;

  const organization = Organization(
    id: 'org-alpha',
    name: 'JV Alma CIS',
    code: 'JV-ALMA-CIS',
    status: OrganizationRecordStatus.active,
  );

  const tomas = OrganizationUser(
    uid: 'O9755kUSpMUZcJWARnsmuCzo8d72',
    name: 'Tomas',
    email: 'tom@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.foreman,
    workerType: WorkerType.contractor,
    organizationId: 'org-alpha',
    siteIds: ['site-1'],
  );

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

  Future<void> seedProject(String id, {String name = 'Test Project'}) async {
    await firestore.doc('organizations/org-alpha/projects/$id').set({
      'organizationId': 'org-alpha',
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedMeeting(
    String id, {
    String foremanId = 'O9755kUSpMUZcJWARnsmuCzo8d72',
    String siteId = 'site-1',
    String projectId = 'project-1',
    List<String> activityIds = const ['activity-1'],
    List<String> meetingPointIds = const ['point-1'],
    List<String> concerns = const [],
    String status = 'completed',
    String date = '2026-08-21',
  }) async {
    await firestore
        .doc('organizations/org-alpha/daily_safety_meetings/$id')
        .set({
          'organizationId': 'org-alpha',
          'projectId': projectId,
          'siteId': siteId,
          'date': date,
          'foremanId': foremanId,
          'activityIds': activityIds,
          'meetingPointIds': meetingPointIds,
          'status': status,
          'concerns': concerns,
          'correctiveActionIds': <String>[],
          'createdAt': Timestamp.now(),
        });
  }

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    List<OrganizationUser> users = const [],
    DailySafetyMeetingRepository? meetingRepository,
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: AdminDailySafetyMeetingsScreen(
            organization: organization,
            firestoreService: FirestoreService(firestore: firestore),
            meetingRepository:
                meetingRepository ??
                DailySafetyMeetingRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: 'org-alpha',
                ),
            projectRepository: ProjectRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
            approvalService: _FakeApprovalService(users: users),
          ),
        ),
      ),
    );
  }

  group('AdminDailySafetyMeetingsScreen (authorization)', () {
    testWidgets('an Admin can view the list', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view daily safety meetings.'),
        findsNothing,
      );
    });

    testWidgets('a Site Manager of the matching organization can view', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Site · 2026-08-21'), findsOneWidget);
    });

    testWidgets('a Site Manager of a different organization is refused', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'org-beta'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view daily safety meetings.'),
        findsOneWidget,
      );
    });

    testWidgets('a foreman of the matching organization does not receive '
        'administrative review access — reviewing other Foremen\'s meetings '
        'is a Site Manager/Admin authority (PROJECT_CONTEXT.md Â§22A); a '
        'Foreman sees their own meetings through the Meeting Workspace '
        'instead', (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.foreman, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view daily safety meetings.'),
        findsOneWidget,
      );
      // Crucially, no "Start Today's Meeting" or other operational control
      // exists on this screen — the administrator gets review only.
      expect(find.text("Start Today's Meeting"), findsNothing);
    });
  });

  group('AdminDailySafetyMeetingsScreen (list content)', () {
    testWidgets('shows the meeting card with site, date, foreman and '
        'counts', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting(
        'meeting-1',
        activityIds: ['activity-1', 'activity-2'],
        meetingPointIds: ['point-1'],
      );

      await tester.pumpWidget(wrap(role: AppRole.admin, users: [tomas]));
      await tester.pumpAndSettle();

      expect(find.text('Test Site · 2026-08-21'), findsOneWidget);
      expect(find.textContaining('Tomas'), findsOneWidget);
      expect(find.textContaining('2 activities'), findsOneWidget);
      expect(find.textContaining('1 safety points'), findsOneWidget);
    });

    testWidgets('falls back to the foreman uid when no name is available', (
      tester,
    ) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('O9755kUSpMUZcJWARnsmuCzo8d72'),
        findsOneWidget,
      );
    });

    testWidgets('shows an empty state when there are no meetings', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(
        find.text('No daily safety meetings recorded yet.'),
        findsOneWidget,
      );
      // An error state must not appear alongside a genuinely empty stream.
      expect(
        find.text('Unable to load daily safety meetings. Please try again.'),
        findsNothing,
      );
    });

    testWidgets(
      'shows an error state, not the empty state, when the meetings stream '
      'fails — a regression test for a completed meeting silently '
      'disappearing behind an unhandled stream error',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            role: AppRole.admin,
            meetingRepository: _ErroringMeetingRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Unable to load daily safety meetings. Please try again.'),
          findsOneWidget,
        );
        expect(
          find.text('No daily safety meetings recorded yet.'),
          findsNothing,
        );
      },
    );

    testWidgets('a completed meeting still displays normally when the stream '
        'succeeds', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1', status: 'completed');

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.text('Test Site · 2026-08-21'), findsOneWidget);
      expect(
        find.text('Unable to load daily safety meetings. Please try again.'),
        findsNothing,
      );
    });
  });

  group('AdminDailySafetyMeetingsScreen (opening a summary)', () {
    testWidgets('tapping a meeting opens the read-only summary, not the '
        "foreman's operational workspace", (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await firestore.doc('organizations/org-alpha/activities/activity-1').set({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'name': 'Roofing',
        'code': 'ROOF-01',
        'status': 'active',
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });
      await firestore
          .doc('organizations/org-alpha/safety_meeting_points/point-1')
          .set({
            'organizationId': 'org-alpha',
            'title': 'Working at Height',
            'category': 'safety',
            'status': 'active',
            'applicableActivities': <String>[],
            'applicableRisks': <String>[],
            'createdAt': Timestamp.now(),
            'updatedAt': Timestamp.now(),
          });
      await seedMeeting('meeting-1', activityIds: ['activity-1']);

      await tester.pumpWidget(wrap(role: AppRole.admin, users: [tomas]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Test Site · 2026-08-21'));
      await tester.pumpAndSettle();

      // The summary's banner is its title (the top bar has none).
      expect(find.text('DAILY SAFETY MEETING'), findsOneWidget);
      expect(find.text('Roofing'), findsOneWidget);
      // The summary is a list of colored section cards; scroll to the
      // safety points section.
      await tester.scrollUntilVisible(
        find.text('Working at Height'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Working at Height'), findsOneWidget);
      // No operational controls (Start/Complete/Assign worker etc.) exist
      // on the summary screen.
      expect(find.text("Start Today's Meeting"), findsNothing);
      expect(find.text('Complete Meeting'), findsNothing);
      expect(find.byIcon(Icons.person_add_alt_1_outlined), findsNothing);
    });

    testWidgets('the summary shows organization, project, site, date and '
        'foreman', (tester) async {
      await seedSite('site-1', name: 'Test Site');
      await seedProject('project-1', name: 'Test Project');
      await seedMeeting('meeting-1');

      await tester.pumpWidget(wrap(role: AppRole.admin, users: [tomas]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Test Site · 2026-08-21'));
      await tester.pumpAndSettle();

      expect(find.text('JV Alma CIS'), findsOneWidget);
      expect(find.text('Test Project'), findsOneWidget);
      expect(find.text('Test Site'), findsOneWidget);
      expect(find.text('2026-08-21'), findsOneWidget);
      expect(find.text('Tomas'), findsOneWidget);
    });

    testWidgets('the summary shows attendance by name, concerns and '
        'corrective actions', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');
      await firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/meeting-1/'
            'attendance/worker-2',
          )
          .set({
            'meetingId': 'meeting-1',
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'workerId': 'worker-2',
            'status': 'present',
            'recordedAt': Timestamp.now(),
            'recordedBy': tomas.uid,
          });
      await firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/meeting-1/'
            'concerns/concern-1',
          )
          .set({
            'meetingId': 'meeting-1',
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'description': 'Unstable ladder at east wing.',
            'category': 'safety',
            'reportedBy': tomas.uid,
            'status': 'open',
            'createdAt': Timestamp.now(),
          });
      await firestore
          .doc('organizations/org-alpha/corrective_actions/action-1')
          .set({
            'organizationId': 'org-alpha',
            'projectId': 'project-1',
            'siteId': 'site-1',
            'meetingId': 'meeting-1',
            'concernId': 'concern-1',
            'title': 'Replace ladder',
            'description': 'Remove and replace before use.',
            'assignedTo': 'worker-2',
            'assignedBy': tomas.uid,
            'dueDate': Timestamp.fromDate(DateTime(2026, 8, 25)),
            'status': 'open',
            'evidenceRequired': false,
            'createdAt': Timestamp.now(),
            'updatedAt': Timestamp.now(),
          });

      const worker2 = OrganizationUser(
        uid: 'worker-2',
        name: 'Peter',
        email: 'peter@example.com',
        accountStatus: AccountStatus.active,
        role: AppRole.worker,
        organizationId: 'org-alpha',
        siteIds: ['site-1'],
      );

      await tester.pumpWidget(
        wrap(role: AppRole.admin, users: [tomas, worker2]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Test Site · 2026-08-21'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.textContaining('Peter'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Peter'), findsWidgets);
      expect(find.text(worker2.uid), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('Unstable ladder at east wing.'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Unstable ladder at east wing.'),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.textContaining('Replace ladder'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Replace ladder'), findsOneWidget);
    });
  });

  group('AdminDailySafetyMeetingsScreen (concern counts)', () {
    Future<void> seedConcernDoc(String meetingId, String id) {
      return firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/$meetingId/'
            'concerns/$id',
          )
          .set({
            'meetingId': meetingId,
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'description': 'Loose sheet $id',
            'category': 'safety',
            'reportedBy': 'O9755kUSpMUZcJWARnsmuCzo8d72',
            'status': 'open',
            'createdAt': Timestamp.now(),
          });
    }

    testWidgets('the card uses the stored concernCount', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');
      await firestore
          .doc('organizations/org-alpha/daily_safety_meetings/meeting-1')
          .update({'concernCount': 4});

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.textContaining('4 concerns'), findsOneWidget);
    });

    testWidgets('an older meeting without a stored count counts its concerns '
        'instead of reading the unused text list as 0', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1');
      await seedConcernDoc('meeting-1', 'c1');
      await seedConcernDoc('meeting-1', 'c2');

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 concerns'), findsOneWidget);
      expect(find.textContaining('0 concerns'), findsNothing);
    });

    testWidgets('the summary counts its concerns and shows what was '
        'suggested next to what was kept', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await seedMeeting('meeting-1', meetingPointIds: ['point-1', 'point-3']);
      await firestore
          .doc('organizations/org-alpha/daily_safety_meetings/meeting-1')
          .update({
            'suggestedPointIds': ['point-1', 'point-2'],
            'suggestionReasons': {
              'point-1': ["Today's work: Roofing"],
              'point-2': ['General safety point for any work'],
            },
          });
      for (final (id, title) in [
        ('point-1', 'Working at Height'),
        ('point-2', 'PPE'),
        ('point-3', 'Ladders'),
      ]) {
        await firestore
            .doc('organizations/org-alpha/safety_meeting_points/$id')
            .set({
              'organizationId': 'org-alpha',
              'title': title,
              'category': 'safety',
              'status': 'active',
              'applicableActivities': <String>[],
              'applicableRisks': <String>[],
            });
      }
      await seedConcernDoc('meeting-1', 'c1');

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Site · 2026-08-21'));
      await tester.pumpAndSettle();

      expect(find.text('1 concern'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('suggested at the start'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(
          '2 suggested at the start, 1 kept. Not covered: PPE. '
          'Added: Ladders.',
        ),
        findsOneWidget,
      );
    });
    testWidgets("the card and summary count the Foreman's own points and "
        'show them, marked, with what was discussed', (tester) async {
      await seedSite('site-1');
      await seedProject('project-1');
      await firestore.doc('organizations/org-alpha/activities/activity-1').set({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'name': 'Roofing',
        'code': 'ROOF-01',
        'status': 'active',
      });
      await seedMeeting('meeting-1', meetingPointIds: const []);
      await firestore
          .doc('organizations/org-alpha/daily_safety_meetings/meeting-1')
          .update({'foremanPointCount': 1});
      await firestore
          .doc(
            'organizations/org-alpha/daily_safety_meetings/meeting-1/'
            'foreman_points/pointAbc12345',
          )
          .set({
            'meetingId': 'meeting-1',
            'organizationId': 'org-alpha',
            'siteId': 'site-1',
            'title': 'Wet roof sheets',
            'note': 'No walking on wet sheets.',
            'activityId': 'activity-1',
            'createdAt': Timestamp.now(),
          });

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 safety points'), findsOneWidget);

      await tester.tap(find.text('Test Site · 2026-08-21'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Wet roof sheets (added by Foreman, about Roofing)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('No walking on wet sheets.'), findsOneWidget);
      expect(find.text('No safety points recorded.'), findsNothing);
    });
  });
}
