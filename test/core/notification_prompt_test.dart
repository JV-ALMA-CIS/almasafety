import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  setUp(() {
    NotificationPrompt.closedThisSession = false;
    SharedPreferences.setMockInitialValues({});
  });

  /// Opens the dashboard (a fresh prompt each time, like coming back to it).
  Future<void> openDashboard(
    WidgetTester tester,
    _FakePush push, {
    bool iosBrowser = false,
    bool desktop = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationPrompt(
            key: UniqueKey(),
            service: push,
            isIosBrowser: iosBrowser,
            isDesktop: desktop,
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

  group('on a computer', () {
    final tip = find.text('Get alerts on this computer');

    testWidgets('once allowed, offers the how-to; Got it hides it for good', (
      tester,
    ) async {
      final push = _FakePush(PushPermission.allowed);
      await openDashboard(tester, push, desktop: true);
      expect(tip, findsOneWidget);
      expect(dashboard, findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(tip, findsNothing);

      // A new session on this computer: still hidden.
      NotificationPrompt.closedThisSession = false;
      await openDashboard(tester, push, desktop: true);
      expect(tip, findsNothing);
    });

    testWidgets('Show me how opens the steps', (tester) async {
      await openDashboard(
        tester,
        _FakePush(PushPermission.allowed),
        desktop: true,
      );
      await tester.tap(find.text('Show me how'));
      await tester.pumpAndSettle();
      expect(
        find.text('Let the browser run in the background'),
        findsOneWidget,
      );
      expect(find.text('Let Windows show the pop-ups'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tip, findsNothing);
    });

    testWidgets('not allowed yet: asks to turn them on first', (tester) async {
      await openDashboard(
        tester,
        _FakePush(PushPermission.notAsked),
        desktop: true,
      );
      expect(turnOn, findsOneWidget);
      expect(tip, findsNothing);
    });

    testWidgets('never on a phone or tablet', (tester) async {
      await openDashboard(tester, _FakePush(PushPermission.allowed));
      expect(tip, findsNothing);
    });
  });
}
