import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/presentation/register_screen.dart';
import 'package:jva_safety/routing/app_routes.dart';

void main() {
  Widget wrap(Widget child) {
    // Firebase is not initialized in the test environment, so the session's
    // AuthService resolves to no FirebaseAuth — exactly the "backend
    // unavailable" path the screen must handle without crashing.
    final router = GoRouter(
      initialLocation: AppRoutes.register,
      routes: [
        GoRoute(path: AppRoutes.register, builder: (_, _) => child),
        GoRoute(
          path: AppRoutes.login,
          builder: (_, _) => const Scaffold(body: Text('login screen')),
        ),
      ],
    );
    return ChangeNotifierProvider<SessionController>(
      create: (_) => SessionController(),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// The registration form has six fields and does not fit the default
  /// 800x600 test viewport, which puts the submit button and the validation
  /// messages below it off-screen. Tests that interact with the whole form
  /// use a taller surface; the small-viewport layout test below deliberately
  /// does not, since scrolling is the intended behaviour there.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> fillValidForm(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Full name'),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'ada@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone number'),
      '+254700000000',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password123',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password'),
      'password123',
    );
  }

  group('registration form fields', () {
    testWidgets('collects exactly name, email, phone and password', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      expect(find.widgetWithText(TextFormField, 'Full name'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Phone number'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    });

    testWidgets('offers no role, trade, organization, site or activity', (
      tester,
    ) async {
      // The security guarantee stated as a UI assertion: a registering user
      // has no control on screen that could confer authority.
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      for (final forbidden in [
        'Role',
        'Worker type',
        'Trade',
        'Contractor',
        'Organization',
        'Site',
        'Activity',
        'Administrator',
        'Safety Manager',
        'Foreman',
        'Supervisor',
      ]) {
        expect(
          find.textContaining(forbidden),
          findsNothing,
          reason: 'registration must not offer "$forbidden"',
        );
      }
    });

    testWidgets('offers no dropdown at all — only text fields', (
      tester,
    ) async {
      // Role, trade and site assignment are decided by a foreman or
      // superintendent at approval time, never chosen by the registrant.
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      expect(find.byType(DropdownButtonFormField<Object?>), findsNothing);
    });

    testWidgets('explains that approval is required before access', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      expect(
        find.textContaining('reviewed and approved'),
        findsOneWidget,
      );
    });
  });

  group('validation', () {
    testWidgets('rejects an empty form field by field', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );
      await tester.pump();

      expect(find.text('Enter your full name.'), findsOneWidget);
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your phone number.'), findsOneWidget);
      expect(find.text('Choose a password.'), findsOneWidget);
    });

    testWidgets('rejects a malformed email', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await fillValidForm(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'not-an-email',
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );
      await tester.pump();

      expect(find.text('Enter a valid email address.'), findsOneWidget);
    });

    testWidgets('rejects a short password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await fillValidForm(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'short',
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );
      await tester.pump();

      expect(find.text('Use at least 8 characters.'), findsOneWidget);
    });

    testWidgets('rejects mismatched password confirmation', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await fillValidForm(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'different123',
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );
      await tester.pump();

      expect(find.text('Passwords do not match.'), findsOneWidget);
    });
  });

  group('submission', () {
    testWidgets('surfaces a backend-unavailable error instead of crashing', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await fillValidForm(tester);
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Registration is unavailable right now. Please try again later.',
        ),
        findsOneWidget,
      );
    });
  });

  group('navigation and layout', () {
    testWidgets('offers a route back to sign-in', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      await tester.tap(
        find.widgetWithText(TextButton, 'Already have an account? Sign in'),
      );
      await tester.pumpAndSettle();

      expect(find.text('login screen'), findsOneWidget);
    });

    testWidgets('primary action meets the 48px field touch target', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(const RegisterScreen()));

      final button = tester.getSize(
        find.widgetWithText(ElevatedButton, 'Create account'),
      );

      expect(button.height, greaterThanOrEqualTo(48));
    });

    testWidgets('lays out without overflow on a small mobile viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const RegisterScreen()));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
