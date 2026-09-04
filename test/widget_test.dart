import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jva_safety/app.dart';

void main() {
  testWidgets(
    'App boots to the session-loading screen when Firebase is unavailable',
    (WidgetTester tester) async {
      // In this test environment Firebase is not initialized, so
      // AuthService.authStateChanges() never emits and the session stays in
      // AuthStatus.loading — this asserts the app renders the loading gate
      // rather than crashing or showing a feature screen prematurely.
      await tester.pumpWidget(const JvaSafetyApp());
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );
}
