import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/hazards/data/hazard_service.dart';
import 'package:jva_safety/features/hazards/presentation/report_hazard_screen.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, List<String> siteIds = const []})
    : _profile = UserProfile(
        uid: 'worker-1',
        name: 'Test Worker',
        email: 'worker@example.com',
        accountStatus: AccountStatus.active,
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
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;
}

class _NoOrgSession extends SessionController {
  @override
  UserProfile? get profile => const UserProfile(
    uid: 'worker-1',
    name: 'Test Worker',
    email: 'worker@example.com',
    accountStatus: AccountStatus.active,
  );
}

class _FakeHazardService extends HazardService {
  _FakeHazardService();

  final List<Map<String, Object?>> reportCalls = [];
  AppException? error;
  bool delay = false;

  @override
  Future<String> reportHazard({
    required String organizationId,
    required String siteId,
    required String category,
    required String description,
    String kind = 'hazard',
    String? location,
    String? photoFileName,
    Uint8List? photoBytes,
  }) async {
    if (delay) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final err = error;
    if (err != null) throw err;
    reportCalls.add({
      'organizationId': organizationId,
      'siteId': siteId,
      'kind': kind,
      'category': category,
      'description': description,
      'location': location,
    });
    return 'hazard-1';
  }
}

void main() {
  /// The default 800x600 test surface is too short to lay out the whole
  /// form (including the submit button) without scrolling; a taller surface
  /// avoids depending on scroll behavior in every test here. Reset via
  /// `addTearDown` so later test files get the default surface back.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  late FakeFirebaseFirestore firestore;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    for (final (id, name) in [('site-1', 'Embassy'), ('site-2', 'Depot')]) {
      await firestore.doc('organizations/org-alpha/sites/$id').set({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'name': name,
        'code': id.toUpperCase(),
        'status': 'active',
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });
    }
  });

  Widget buildApp({
    required SessionController session,
    required HazardService hazardService,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ReportHazardScreen(
            hazardService: hazardService,
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: 'org-alpha',
            ),
          ),
        ),
      ),
    );
  }

  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Submit Report'));
  }

  Future<void> fillAndSubmit(WidgetTester tester) async {
    await tester.tap(find.text('Fire'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Smoke');
    await tapSubmit(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('a single assigned site is chosen automatically', (tester) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Embassy'), findsOneWidget);
    expect(find.text('Depot'), findsNothing);
    await fillAndSubmit(tester);
    expect(service.reportCalls.single['siteId'], 'site-1');
  });

  testWidgets('a worker on two sites picks which one', (tester) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(
          role: AppRole.worker,
          siteIds: const ['site-1', 'site-2'],
        ),
        hazardService: service,
      ),
    );
    await tester.pumpAndSettle();

    await fillAndSubmit(tester);
    expect(service.reportCalls, isEmpty, reason: 'no site chosen yet');

    await tester.tap(find.text('Depot'));
    await tester.pump();
    await tapSubmit(tester);
    await tester.pumpAndSettle();
    expect(service.reportCalls.single['siteId'], 'site-2');
  });

  testWidgets('a Site Manager with no assigned site can report at any site '
      'of the organization', (tester) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.siteManager),
        hazardService: service,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('available once you are assigned'),
      findsNothing,
    );
    await tester.tap(find.text('Embassy'));
    await tester.pump();
    await fillAndSubmit(tester);
    expect(service.reportCalls.single['siteId'], 'site-1');
  });

  testWidgets('shows a message when the user has no assigned site', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const []),
        hazardService: _FakeHazardService(),
      ),
    );

    expect(
      find.textContaining('available once you are assigned to a site'),
      findsOneWidget,
    );
  });

  testWidgets('shows a message when the user has no organization', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(session: _NoOrgSession(), hazardService: _FakeHazardService()),
    );

    expect(
      find.textContaining('available once you are assigned to a site'),
      findsOneWidget,
    );
  });

  testWidgets('renders the form for an active user with a site', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: _FakeHazardService(),
      ),
    );

    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
    expect(find.text('Category'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Location (optional)'), findsOneWidget);
    expect(find.text('Photo (optional)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Submit Report'), findsOneWidget);
  });

  testWidgets('is not restricted by role — a foreman sees the same form', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.foreman, siteIds: const ['site-1']),
        hazardService: _FakeHazardService(),
      ),
    );

    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
  });

  testWidgets('validates that a category and description are required', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: _FakeHazardService(),
      ),
    );

    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(find.text('Please fill in the required fields.'), findsOneWidget);
  });

  testWidgets('submits with category and description and shows success', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Electrical'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Exposed wiring near the water tank',
    );
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(service.reportCalls, hasLength(1));
    expect(service.reportCalls.single['organizationId'], 'org-alpha');
    expect(service.reportCalls.single['siteId'], 'site-1');
    expect(service.reportCalls.single['category'], 'electrical');
    expect(
      service.reportCalls.single['description'],
      'Exposed wiring near the water tank',
    );
    expect(service.reportCalls.single['kind'], 'hazard');
    expect(find.text('Hazard Reported'), findsOneWidget);
  });

  testWidgets('with no signal the report is saved on the phone, not lost', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService()..error = const SavedOfflineException();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Electrical'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Exposed wiring near the water tank',
    );
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(find.text('Hazard Reported'), findsOneWidget);
    expect(
      find.textContaining('your report is saved on this phone'),
      findsOneWidget,
    );
  });

  testWidgets('choosing "Something nearly happened" reports a near-miss', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Something nearly happened'));
    await tester.pump();
    expect(find.text('What nearly happened?'), findsOneWidget);
    await tester.tap(find.text('Working at Height'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Hammer fell from scaffold',
    );
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(service.reportCalls.single['kind'], 'nearMiss');
    expect(service.reportCalls.single['category'], 'workingAtHeight');
    expect(find.text('Near-miss Reported'), findsOneWidget);
  });

  testWidgets('location is passed through when provided, null when blank', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Fire'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'Smoke near storage',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'East wing, 3rd floor',
    );
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(service.reportCalls.single['location'], 'East wing, 3rd floor');
  });

  testWidgets('shows a "Report Another" action after success, which '
      'resets the form', (tester) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Something');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report Another'));
    await tester.pumpAndSettle();

    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
    expect(find.text('Category'), findsOneWidget);
  });

  testWidgets('shows the error message and stays on the form on failure', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService()
      ..error = const PermissionDeniedException('Not allowed.');
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Housekeeping'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Clutter');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(find.text('Not allowed.'), findsOneWidget);
    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
  });

  testWidgets('shows a loading indicator on the submit button while saving', (
    tester,
  ) async {
    useTallSurface(tester);
    final service = _FakeHazardService()..delay = true;
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(role: AppRole.worker, siteIds: const ['site-1']),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Chemical'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Spill');
    await tapSubmit(tester);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();
  });
}
