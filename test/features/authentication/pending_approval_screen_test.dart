import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/presentation/access_denied_screen.dart';
import 'package:jva_safety/features/authentication/presentation/pending_approval_screen.dart';

void main() {
  Widget wrap(Widget child) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => SessionController(),
      child: MaterialApp(home: child),
    );
  }

  group('PendingApprovalScreen', () {
    testWidgets('explains that the account is awaiting review', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const PendingApprovalScreen()));

      expect(find.text('Account Pending Approval'), findsOneWidget);
      expect(find.textContaining('waiting for review'), findsOneWidget);
    });

    testWidgets('tells the user access arrives without re-signing in', (
      tester,
    ) async {
      // The profile is streamed, so approval takes effect live; the copy
      // must match that behaviour or users will pointlessly re-login.
      await tester.pumpWidget(wrap(const PendingApprovalScreen()));

      expect(find.textContaining('automatically once that happens'), findsOne);
    });

    testWidgets('offers sign-out and nothing that advances the account', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const PendingApprovalScreen()));

      expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);

      // No affordance that could approve, retry approval, or self-assign.
      for (final forbidden in ['Approve', 'Activate', 'Retry', 'Continue']) {
        expect(
          find.textContaining(forbidden),
          findsNothing,
          reason: 'a pending user must not be offered "$forbidden"',
        );
      }
    });

    testWidgets('sign-out meets the 48px field touch target', (tester) async {
      await tester.pumpWidget(wrap(const PendingApprovalScreen()));

      final button = tester.getSize(
        find.widgetWithText(OutlinedButton, 'Sign out'),
      );

      expect(button.height, greaterThanOrEqualTo(48));
    });

    testWidgets('lays out without overflow on a small mobile viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const PendingApprovalScreen()));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('AccessDeniedScreen', () {
    testWidgets('renders without crashing and offers sign-out', (
      tester,
    ) async {
      // With Firebase unavailable the session sits in `loading`, which maps
      // to the generic fallback copy — the screen must still render.
      await tester.pumpWidget(wrap(const AccessDeniedScreen()));

      expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);
    });

    testWidgets('never tells a user their account is merely pending', (
      tester,
    ) async {
      // Pending users are routed to PendingApprovalScreen instead; this
      // screen is only for suspended, rejected and profile-missing states.
      await tester.pumpWidget(wrap(const AccessDeniedScreen()));

      expect(find.text('Account Pending Approval'), findsNothing);
    });
  });
}
