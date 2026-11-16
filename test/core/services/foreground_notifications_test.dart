import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/foreground_notifications.dart';
import 'package:jva_safety/routing/app_routes.dart';

void main() {
  late StreamController<RemoteMessage> pushes;
  late List<String> opened;
  late List<Map<String, Object>> systemShown;
  late bool systemWorks;
  late GlobalKey<ScaffoldMessengerState> messengerKey;
  late ForegroundNotifications notifications;

  const alert = RemoteMessage(
    notification: RemoteNotification(
      title: 'CRITICAL SAFETY ALERT at Italian Embassy: Crane lift',
      body: 'Fred Otieno: Keep clear 10-12.',
    ),
    data: {'route': '/safety-alerts', 'urgent': '1'},
  );

  Future<void> pumpApp(WidgetTester tester) async {
    pushes = StreamController<RemoteMessage>();
    opened = [];
    systemShown = [];
    messengerKey = GlobalKey<ScaffoldMessengerState>();
    notifications = ForegroundNotifications(
      messengerKey: messengerKey,
      go: opened.add,
      messages: pushes.stream,
      showSystem:
          ({
            required String title,
            required String body,
            required String route,
            required bool urgent,
          }) async {
            systemShown.add({
              'title': title,
              'body': body,
              'route': route,
              'urgent': urgent,
            });
            return systemWorks;
          },
    );
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: Text('Dashboard')),
      ),
    );
    notifications.start();
  }

  tearDown(() async {
    notifications.dispose();
    await pushes.close();
  });

  testWidgets('on a computer: a system pop-up, urgent ones stay', (
    tester,
  ) async {
    systemWorks = true;
    await pumpApp(tester);
    pushes.add(alert);
    await tester.pumpAndSettle();

    expect(systemShown.single, {
      'title': 'CRITICAL SAFETY ALERT at Italian Embassy: Crane lift',
      'body': 'Fred Otieno: Keep clear 10-12.',
      'route': AppRoutes.safetyAlerts,
      'urgent': true,
    });
    // Not shown twice.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('in the Android app: a bar with the message and Open', (
    tester,
  ) async {
    systemWorks = false;
    await pumpApp(tester);
    pushes.add(alert);
    await tester.pumpAndSettle();

    expect(
      find.text('CRITICAL SAFETY ALERT at Italian Embassy: Crane lift'),
      findsOneWidget,
    );
    expect(find.text('Fred Otieno: Keep clear 10-12.'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, [AppRoutes.safetyAlerts]);
  });

  testWidgets('a push about nothing in particular opens Notifications', (
    tester,
  ) async {
    systemWorks = false;
    await pumpApp(tester);
    pushes.add(
      const RemoteMessage(
        notification: RemoteNotification(title: 'Hello', body: 'Hi'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    expect(opened, [AppRoutes.notifications]);
    expect(systemShown.single['urgent'], isFalse);
  });
}
