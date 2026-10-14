import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/push_notification_service.dart';
import 'package:jva_safety/core/widgets/push_opt_in_card.dart';

class _FakePush extends PushNotificationService {
  _FakePush(this.current);

  PushPermission current;
  int enables = 0;
  int registrations = 0;

  @override
  Future<PushPermission> permission() async => current;

  @override
  Future<PushPermission> enable() async {
    enables++;
    return current = PushPermission.allowed;
  }

  @override
  Future<void> registerIfAllowed() async => registrations++;
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    _FakePush push, {
    bool iosBrowser = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PushOptInCard(service: push, isIosBrowser: iosBrowser),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('not asked yet: offers to turn them on, then disappears', (
    tester,
  ) async {
    final push = _FakePush(PushPermission.notAsked);
    await pump(tester, push);
    expect(find.text('Turn on notifications'), findsOneWidget);

    await tester.tap(find.text('Turn on notifications'));
    await tester.pumpAndSettle();
    expect(push.enables, 1);
    expect(find.text('Turn on notifications'), findsNothing);
  });

  testWidgets('already allowed: shows nothing, keeps the device registered', (
    tester,
  ) async {
    final push = _FakePush(PushPermission.allowed);
    await pump(tester, push);
    expect(find.byType(Container), findsNothing);
    expect(push.registrations, 1);
  });

  testWidgets('blocked: explains how to allow them again', (tester) async {
    await pump(tester, _FakePush(PushPermission.blocked));
    expect(find.textContaining('blocked on this device'), findsOneWidget);
    expect(find.text('Turn on notifications'), findsNothing);
  });

  testWidgets('an iPhone browser gets the Home Screen tip; others nothing', (
    tester,
  ) async {
    await pump(tester, _FakePush(PushPermission.unsupported), iosBrowser: true);
    expect(find.textContaining('Add to Home Screen'), findsOneWidget);

    await pump(tester, _FakePush(PushPermission.unsupported));
    expect(find.textContaining('Add to Home Screen'), findsNothing);
  });
}
