import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/safety_reporting/presentation/report_safety_issue_screen.dart';

class _WorkerSession extends SessionController {
  @override
  UserProfile? get profile => const UserProfile(
    uid: 'worker-1',
    name: 'Test Worker',
    email: 'worker@example.com',
    accountStatus: AccountStatus.active,
  );

  @override
  String? get activeOrganizationId => 'org-alpha';

  @override
  Membership? get activeMembership => const Membership(
    organizationId: 'org-alpha',
    role: AppRole.worker,
    siteIds: ['site-1'],
    status: MembershipStatus.active,
  );
}

void main() {
  Widget app() => ChangeNotifierProvider<SessionController>(
    create: (_) => _WorkerSession(),
    child: MaterialApp(
      home: Builder(
        builder: (context) => const Scaffold(body: ReportSafetyIssueButton()),
      ),
    ),
  );

  Future<void> openChooser(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.tap(find.text('Report a Safety Issue'));
    await tester.pumpAndSettle();
  }

  testWidgets('the button reads as an action, with what it covers', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    expect(find.text('Report a Safety Issue'), findsOneWidget);
    expect(
      find.text('Something wrong, nearly happened, or happened'),
      findsOneWidget,
    );
  });

  testWidgets('"could happen" opens the hazard form', (tester) async {
    await openChooser(tester);
    await tester.tap(find.text('Something COULD happen'));
    await tester.pumpAndSettle();
    expect(find.text('What is the hazard?'), findsOneWidget);
  });

  testWidgets('"nearly happened" opens the hazard form as a near-miss', (
    tester,
  ) async {
    await openChooser(tester);
    await tester.tap(find.text('Something NEARLY happened'));
    await tester.pumpAndSettle();
    expect(find.text('What nearly happened?'), findsOneWidget);
  });

  testWidgets('"actually happened" opens the incident form', (tester) async {
    await openChooser(tester);
    await tester.tap(find.text('Something ACTUALLY happened'));
    await tester.pumpAndSettle();
    expect(find.text('Report an Incident'), findsWidgets);
    expect(find.text('Submit Incident'), findsOneWidget);
  });

  testWidgets('back from the chosen form returns to where the person started', (
    tester,
  ) async {
    await openChooser(tester);
    await tester.tap(find.text('Something COULD happen'));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Something COULD happen'), findsNothing);
    expect(find.text('Report a Safety Issue'), findsOneWidget);
  });
}
