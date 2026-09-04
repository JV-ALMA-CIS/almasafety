import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/presentation/login_screen.dart';
import 'package:jva_safety/routing/app_routes.dart';

void main() {
  Widget wrap(Widget child) {
    // Firebase is not initialized in the test environment, so the session's
    // AuthService resolves to no FirebaseAuth and its auth-state stream
    // stays empty — exactly the "backend unavailable" path the screen must
    // handle without crashing.
    //
    // A real (if minimal) GoRouter is used rather than a bare MaterialApp
    // because the screen navigates to /register via context.go.
    final router = GoRouter(
      initialLocation: AppRoutes.login,
      routes: [
        GoRoute(path: AppRoutes.login, builder: (_, _) => child),
        GoRoute(
          path: AppRoutes.register,
          builder: (_, _) =>
              const Scaffold(body: Text('registration screen')),
        ),
      ],
    );
    return ChangeNotifierProvider<SessionController>(
      create: (_) => SessionController(),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('shows validation errors for empty email/password', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginScreen()));

    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
  });

  testWidgets('shows validation error for malformed email', (tester) async {
    await tester.pumpWidget(wrap(const LoginScreen()));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'not-an-email',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password123',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
  });

  testWidgets('offers a route to self-registration', (tester) async {
    // Self-registration is now the entry path; it grants no access, only a
    // pending account.
    await tester.pumpWidget(wrap(const LoginScreen()));

    expect(find.widgetWithText(TextButton, 'Create account'), findsOneWidget);
  });

  testWidgets('the create-account action navigates to /register', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginScreen()));

    await tester.tap(find.widgetWithText(TextButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(find.text('registration screen'), findsOneWidget);
  });

  testWidgets('surfaces a backend-unavailable error instead of crashing', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginScreen()));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'user@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password123',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sign-in is unavailable right now. Please try again later.'),
      findsOneWidget,
    );
  });

  testWidgets('primary action meets the 48px field touch target', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginScreen()));

    final button = tester.getSize(
      find.widgetWithText(ElevatedButton, 'Sign in'),
    );

    expect(button.height, greaterThanOrEqualTo(48));
  });

  testWidgets('lays out without overflow on a small mobile viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const LoginScreen()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ElevatedButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('lays out without overflow on a desktop viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const LoginScreen()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ElevatedButton, 'Sign in'), findsOneWidget);
  });
}
