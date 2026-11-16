import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/core/services/notification_tap_handler.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/routing/app_routes.dart';

class _Session extends SessionController {
  AuthStatus current = AuthStatus.loading;

  @override
  AuthStatus get status => current;

  void become(AuthStatus status) {
    current = status;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late _Session session;
  late List<String> opened;
  late StreamController<RemoteMessage> taps;

  setUp(() {
    session = _Session();
    opened = [];
    taps = StreamController<RemoteMessage>.broadcast();
  });

  tearDown(() => taps.close());

  NotificationTapHandler handler({RemoteMessage? startedBy}) =>
      NotificationTapHandler(
        session: session,
        go: opened.add,
        initialMessage: () async => startedBy,
        openedApp: taps.stream,
      );

  test(
    'a tap that started the app waits for sign-in, then opens the page',
    () async {
      final h = handler(
        startedBy: const RemoteMessage(data: {'route': '/safety-alerts'}),
      );
      await h.start();
      expect(opened, isEmpty);

      session.become(AuthStatus.loadingProfile);
      expect(opened, isEmpty);
      session.become(AuthStatus.authenticated);
      expect(opened, [AppRoutes.safetyAlerts]);

      // Opened once only — later session changes do not reopen it.
      session.become(AuthStatus.authenticated);
      expect(opened, [AppRoutes.safetyAlerts]);
      h.dispose();
    },
  );

  test(
    'a tap while the app is in the background opens the page at once',
    () async {
      session.current = AuthStatus.authenticated;
      final h = handler();
      await h.start();
      taps.add(const RemoteMessage(data: {'route': '/hazards'}));
      await Future<void>.delayed(Duration.zero);
      expect(opened, [AppRoutes.hazards]);
      h.dispose();
    },
  );

  test('an unknown or missing page opens Notifications', () {
    expect(
      NotificationTapHandler.routeFor({'route': '/administration'}),
      AppRoutes.notifications,
    );
    expect(NotificationTapHandler.routeFor({}), AppRoutes.notifications);
    expect(
      NotificationTapHandler.routeFor({'route': '/incidents'}),
      AppRoutes.incidents,
    );
  });
}
