import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/push_notification_service.dart';
import 'package:jva_safety/core/widgets/notification_prompt.dart';

class _FakePush extends PushNotificationService {
  _FakePush(this.current);

  PushPermission current;
  int enables = 0;
  int registrations = 0;

  /// When set, the Allow prompt stays open until this completes.
  Completer<PushPermission>? prompt;

  @override
  Future<PushPermission> permission() async => current;

  @override
  Future<PushPermission> enable() async {
    enables++;
    final answer =
        await (prompt?.future ?? Future.value(PushPermission.allowed));
    return current = answer;
  }

  @override
  Future<void> registerIfAllowed({bool alreadyAllowed = false}) async =>
      registrations++;
}

void main() {
  setUp(() => NotificationPrompt.closedThisSession = false);

  /// Opens the dashboard (a fresh prompt each time, like coming back to it).
  Future<void> openDashboard(
    WidgetTester tester,
    _FakePush push, {
    bool iosBrowser = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationPrompt(
            key: UniqueKey(),
            service: push,
            isIosBrowser: iosBrowser,
            child: const Center(child: Text('Dashboard')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final turnOn = find.text('Turn on notifications');
  final dashboard = find.text('Dashboard');

  testWidgets('floats over the dashboard, which stays usable', (tester) async {
    await openDashboard(tester, _FakePush(PushPermission.notAsked));
    expect(turnOn, findsOneWidget);
    expect(dashboard, findsOneWidget);
  });

  testWidgets('Turn on → the Allow prompt → the card disappears', (
    tester,
  ) async {
    final push = _FakePush(PushPermission.notAsked);
    await openDashboard(tester, push);
    await tester.tap(turnOn);
    await tester.pumpAndSettle();
    expect(push.enables, 1);
    expect(turnOn, findsNothing);
    expect(push.registrations, 0); // enable() registers the device itself

    // Allowed: never again, and the device is kept registered.
    await openDashboard(tester, push);
    expect(turnOn, findsNothing);
    expect(push.registrations, 1);
  });

  testWidgets('✕ closes it for the rest of the session', (tester) async {
    final push = _FakePush(PushPermission.notAsked);
    await openDashboard(tester, push);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(turnOn, findsNothing);

    await openDashboard(tester, push); // back to the dashboard later
    expect(turnOn, findsNothing);

    NotificationPrompt.closedThisSession = false; // a new session
    await openDashboard(tester, push);
    expect(turnOn, findsOneWidget);
  });

  testWidgets('blocked: how to allow them again, no Turn on button', (
    tester,
  ) async {
    await openDashboard(tester, _FakePush(PushPermission.blocked));
    expect(find.textContaining('blocked on this device'), findsOneWidget);
    expect(turnOn, findsNothing);
  });

  testWidgets('iPhone browser: the Home Screen tip; desktop: nothing', (
    tester,
  ) async {
    await openDashboard(
      tester,
      _FakePush(PushPermission.unsupported),
      iosBrowser: true,
    );
    expect(find.textContaining('Add to Home Screen'), findsOneWidget);

    await openDashboard(tester, _FakePush(PushPermission.unsupported));
    expect(find.textContaining('Add to Home Screen'), findsNothing);
  });

  testWidgets('the card leaves the moment it is tapped — before the Allow '
      'prompt is even answered', (tester) async {
    final push = _FakePush(PushPermission.notAsked)
      ..prompt = Completer<PushPermission>();
    await openDashboard(tester, push);
    await tester.tap(turnOn);
    await tester.pumpAndSettle();
    expect(push.enables, 1);
    expect(turnOn, findsNothing);
    push.prompt!.complete(PushPermission.allowed);
    await tester.pumpAndSettle();
    expect(turnOn, findsNothing);
  });

  testWidgets('choosing Block brings the card back with the how-to', (
    tester,
  ) async {
    final push = _FakePush(PushPermission.notAsked)
      ..prompt = Completer<PushPermission>();
    await openDashboard(tester, push);
    await tester.tap(turnOn);
    await tester.pumpAndSettle();
    push.prompt!.complete(PushPermission.blocked);
    await tester.pumpAndSettle();
    expect(find.textContaining('blocked on this device'), findsOneWidget);
  });
}
