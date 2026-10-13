import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_meetings/data/safety_meeting_repository.dart';
import 'package:jva_safety/features/safety_meetings/data/safety_meeting_service.dart';
import 'package:jva_safety/features/safety_meetings/domain/safety_meeting.dart';
import 'package:jva_safety/features/safety_meetings/presentation/record_safety_meeting_screen.dart';
import 'package:jva_safety/features/safety_meetings/presentation/safety_meetings_screen.dart';

class _Session extends SessionController {
  _Session(this.role);

  final AppRole role;

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
  Membership? get activeMembership => Membership(
    organizationId: 'org',
    role: role,
    siteIds: const ['site-1'],
    status: MembershipStatus.active,
  );
}

/// Records what would be sent to `recordSafetyMeeting`.
class _FakeService extends SafetyMeetingService {
  final calls = <Map<String, Object?>>[];

  @override
  Future<String> record({
    required String organizationId,
    required SafetyMeetingKind kind,
    required String? siteId,
    required DateTime date,
    required List<String> topics,
    required List<String> attendeeUids,
    List<String> otherAttendees = const [],
    List<String> concerns = const [],
    String? notes,
  }) async {
    calls.add({
      'kind': kind,
      'siteId': siteId,
      'date': meetingDateId(date),
      'topics': topics,
      'attendeeUids': attendeeUids,
      'otherAttendees': otherAttendees,
    });
    return 'new-id';
  }
}

OrganizationUser _person(
  String uid,
  String name,
  AppRole role, {
  List<String> siteIds = const [],
}) => OrganizationUser(
  uid: uid,
  name: name,
  email: '$uid@example.com',
  accountStatus: AccountStatus.active,
  role: role,
  organizationId: 'org',
  membershipStatus: MembershipStatus.active,
  siteIds: siteIds,
);

final _people = [
  _person('me', 'Eston', AppRole.siteManager),
  _person('foreman-1', 'Fred Foreman', AppRole.foreman, siteIds: ['site-1']),
  _person('worker-1', 'Wanjiru Worker', AppRole.worker, siteIds: ['site-1']),
  _person('worker-2', 'Other Site Otieno', AppRole.worker, siteIds: ['site-2']),
];

/// Thursday 15 October 2026.
final _now = DateTime(2026, 10, 15, 9);

void main() {
  late FakeFirebaseFirestore firestore;
  late SafetyMeetingRepository repository;
  late SiteRepository siteRepository;
  late _FakeService service;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    final firestoreService = FirestoreService(firestore: firestore);
    repository = SafetyMeetingRepository(
      firestoreService: firestoreService,
      organizationId: 'org',
    );
    siteRepository = SiteRepository(
      firestoreService: firestoreService,
      organizationId: 'org',
    );
    service = _FakeService();
    await firestore.doc('organizations/org/sites/site-1').set({
      'organizationId': 'org',
      'projectId': 'project-1',
      'name': 'Rosslyn Ridge',
      'code': 'RR',
      'status': 'active',
    });
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> seedMeeting(
    String id,
    SafetyMeetingKind kind,
    String date, {
    String? siteId = 'site-1',
  }) {
    return firestore.doc('organizations/org/safety_meetings/$id').set({
      'organizationId': 'org',
      'kind': kind.id,
      'date': date,
      'siteId': siteId,
      'siteName': siteId == null ? null : 'Rosslyn Ridge',
      'topics': ['PPE'],
      'attendeeUids': ['worker-1'],
      'attendeeNames': {'worker-1': 'Wanjiru Worker'},
      'otherAttendees': <String>[],
      'concerns': <String>[],
      'facilitatorUid': 'foreman-1',
      'facilitatorName': 'Fred Foreman',
    });
  }

  Widget page(AppRole role) => ChangeNotifierProvider<SessionController>(
    create: (_) => _Session(role),
    child: MaterialApp(
      home: Scaffold(
        body: SafetyMeetingsScreen(
          repository: repository,
          service: service,
          siteRepository: siteRepository,
          loadPeople: (_) async => _people,
          now: () => _now,
        ),
      ),
    ),
  );

  group('current period', () {
    SafetyMeeting meeting(SafetyMeetingKind kind, String date) =>
        SafetyMeeting.fromMap('m', {
          'kind': kind.id,
          'date': date,
          'facilitatorUid': 'x',
        });

    test('weekly counts Monday to Sunday of this week', () {
      const weekly = SafetyMeetingKind.weeklyEmployee;
      expect(isInCurrentPeriod(meeting(weekly, '2026-10-12'), _now), isTrue);
      expect(isInCurrentPeriod(meeting(weekly, '2026-10-18'), _now), isTrue);
      expect(isInCurrentPeriod(meeting(weekly, '2026-10-11'), _now), isFalse);
    });

    test('monthly counts the calendar month', () {
      const monthly = SafetyMeetingKind.monthlySupervisory;
      expect(isInCurrentPeriod(meeting(monthly, '2026-10-01'), _now), isTrue);
      expect(isInCurrentPeriod(meeting(monthly, '2026-09-30'), _now), isFalse);
    });
  });

  group('the page', () {
    testWidgets('a Site Manager sees both meetings due and can record both', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();

      expect(find.text('Not recorded this week'), findsOneWidget);
      expect(find.text('Not recorded this month'), findsOneWidget);
      expect(find.text('Record meeting'), findsNWidgets(2));
      expect(find.text('No meetings recorded yet.'), findsOneWidget);
    });

    testWidgets("a meeting this week is shown as held; last week's is only "
        'history', (tester) async {
      tall(tester);
      await seedMeeting('m1', SafetyMeetingKind.weeklyEmployee, '2026-10-05');
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      expect(find.text('Not recorded this week'), findsOneWidget);

      await seedMeeting('m2', SafetyMeetingKind.weeklyEmployee, '2026-10-15');
      await tester.pumpAndSettle();
      expect(find.text('Held this week'), findsOneWidget);
      expect(find.text('Run by Fred Foreman'), findsNWidgets(2));
    });

    testWidgets('a Foreman can record only the weekly meeting', (tester) async {
      tall(tester);
      await tester.pumpWidget(page(AppRole.foreman));
      await tester.pumpAndSettle();
      expect(find.text('Record meeting'), findsOneWidget);
    });

    testWidgets('a Worker cannot use the page', (tester) async {
      await tester.pumpWidget(page(AppRole.worker));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('recorded by Foremen and Site Managers'),
        findsOneWidget,
      );
    });

    testWidgets('a past meeting opens with its subjects and attendees', (
      tester,
    ) async {
      tall(tester);
      await seedMeeting('m1', SafetyMeetingKind.weeklyEmployee, '2026-10-05');
      await tester.pumpWidget(page(AppRole.siteManager));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run by Fred Foreman'));
      await tester.pumpAndSettle();
      expect(find.text('PPE'), findsOneWidget);
      expect(find.text('Wanjiru Worker'), findsOneWidget);
    });
  });

  group('recording', () {
    Future<void> openForm(
      WidgetTester tester,
      AppRole role,
      SafetyMeetingKind kind,
    ) async {
      tall(tester);
      await tester.pumpWidget(page(role));
      await tester.pumpAndSettle();
      final buttons = find.text('Record meeting');
      await tester.tap(
        kind == SafetyMeetingKind.weeklyEmployee ? buttons.first : buttons.last,
      );
      await tester.pumpAndSettle();
    }

    FilledButton recordButton(WidgetTester tester) =>
        tester.widget(find.widgetWithText(FilledButton, 'Record meeting'));

    testWidgets('monthly: all sites by default, supervisors listed, sent '
        'once confirmed', (tester) async {
      await openForm(
        tester,
        AppRole.siteManager,
        SafetyMeetingKind.monthlySupervisory,
      );

      // Supervisors only; the person recording is not listed.
      expect(find.text('Fred Foreman'), findsOneWidget);
      expect(find.text('Wanjiru Worker'), findsNothing);
      expect(recordButton(tester).onPressed, isNull);
      expect(find.textContaining('tick at least one subject'), findsOneWidget);

      await tester.tap(
        find.text(
          'Open deficiencies and overdue corrective '
          'actions',
        ),
      );
      await tester.tap(find.text('Fred Foreman'));
      await tester.pumpAndSettle();
      expect(recordButton(tester).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilledButton, 'Record meeting'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Record'));
      await tester.pumpAndSettle();

      expect(service.calls, [
        {
          'kind': SafetyMeetingKind.monthlySupervisory,
          'siteId': null,
          'date': '2026-10-15',
          'topics': ['Open deficiencies and overdue corrective actions'],
          'attendeeUids': ['foreman-1'],
          'otherAttendees': <String>[],
        },
      ]);
      expect(
        find.text('Monthly supervisory meeting recorded.'),
        findsOneWidget,
      );
    });

    testWidgets("weekly: the site's people, 'everyone attended', extra "
        'subjects and visitors', (tester) async {
      await openForm(tester, AppRole.foreman, SafetyMeetingKind.weeklyEmployee);

      // A Foreman with one site has it chosen for them.
      await tester.pumpAndSettle();
      expect(find.text('Wanjiru Worker'), findsOneWidget);
      expect(find.text('Other Site Otieno'), findsNothing);

      await tester.tap(find.text('Everyone listed attended'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Another subject'),
        'Heat stress',
      );
      await tester.tap(find.text('Add subject'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Visiting electrician',
      );
      await tester.tap(find.text('Add person'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Record meeting'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Record'));
      await tester.pumpAndSettle();

      final call = service.calls.single;
      expect(call['siteId'], 'site-1');
      expect(call['topics'], ['Heat stress']);
      expect((call['attendeeUids']! as List).toSet(), {
        'foreman-1',
        'worker-1',
      });
      expect(call['otherAttendees'], ['Visiting electrician']);
    });
  });

  testWidgets("a weekly meeting lists the chosen site's people", (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionController>(
        create: (_) => _Session(AppRole.siteManager),
        child: MaterialApp(
          home: RecordSafetyMeetingScreen(
            organizationId: 'org',
            kind: SafetyMeetingKind.weeklyEmployee,
            service: service,
            siteRepository: siteRepository,
            loadPeople: (_) async => _people,
            now: () => _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // With only one site, it is chosen automatically.
    expect(find.text('Rosslyn Ridge'), findsOneWidget);
    expect(find.text('Wanjiru Worker'), findsOneWidget);
    expect(find.text('Other Site Otieno'), findsNothing);
  });
}
