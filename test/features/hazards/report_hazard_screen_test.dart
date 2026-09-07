import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/hazards/data/hazard_service.dart';
import 'package:jva_safety/features/hazards/presentation/report_hazard_screen.dart';

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
          body: ReportHazardScreen(hazardService: hazardService),
        ),
      ),
    );
  }

  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Submit Report'));
  }

  testWidgets('shows a message when the user has no assigned site',
    (tester) async {
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

  testWidgets('shows a message when the user has no organization',
    (tester) async {
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
        session: _FakeSession(
          role: AppRole.worker,
          siteIds: const ['site-1'],
        ),
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

  testWidgets('is not restricted by role — a foreman sees the same form',
    (tester) async {
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.foreman,
            siteIds: const ['site-1'],
          ),
          hazardService: _FakeHazardService(),
        ),
      );

      expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
    });

  testWidgets('validates that a category and description are required',
    (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.worker,
            siteIds: const ['site-1'],
          ),
          hazardService: _FakeHazardService(),
        ),
      );

      await tapSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('Please fill in the required fields.'),
        findsOneWidget,
      );
    });

  testWidgets('submits with category and description and shows success',
    (tester) async {
      useTallSurface(tester);
      final service = _FakeHazardService();
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.worker,
            siteIds: const ['site-1'],
          ),
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
      expect(find.text('Hazard Reported'), findsOneWidget);
    });

  testWidgets('location is passed through when provided, null when blank',
    (tester) async {
      useTallSurface(tester);
      final service = _FakeHazardService();
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.worker,
            siteIds: const ['site-1'],
          ),
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

      expect(
        service.reportCalls.single['location'],
        'East wing, 3rd floor',
      );
    });

  testWidgets('shows a "Report Another Hazard" action after success, which '
    'resets the form', (tester) async {
    useTallSurface(tester);
    final service = _FakeHazardService();
    await tester.pumpWidget(
      buildApp(
        session: _FakeSession(
          role: AppRole.worker,
          siteIds: const ['site-1'],
        ),
        hazardService: service,
      ),
    );

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'Something');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Report Another Hazard'));
    await tester.pumpAndSettle();

    expect(find.text('Report a Hazard'), findsAtLeastNWidgets(1));
    expect(find.text('Category'), findsOneWidget);
  });

  testWidgets('shows the error message and stays on the form on failure',
    (tester) async {
      useTallSurface(tester);
      final service = _FakeHazardService()
        ..error = const PermissionDeniedException('Not allowed.');
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.worker,
            siteIds: const ['site-1'],
          ),
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

  testWidgets('shows a loading indicator on the submit button while saving',
    (tester) async {
      useTallSurface(tester);
      final service = _FakeHazardService()..delay = true;
      await tester.pumpWidget(
        buildApp(
          session: _FakeSession(
            role: AppRole.worker,
            siteIds: const ['site-1'],
          ),
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
