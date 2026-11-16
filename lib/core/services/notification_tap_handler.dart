import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../../routing/app_routes.dart';
import '../config/firebase_target.dart';
import 'session_controller.dart';

/// Opens the page a push notification is about when it is tapped in the
/// phone's notification shade — in the installed app (APK). The web app
/// does not need this: there the notification's link opens the page.
///
/// - App closed: the tap starts the app; the page opens as soon as sign-in
///   has finished (not on top of the loading screen, which would send it
///   straight back to the dashboard).
/// - App in the background: the tap brings it forward on that page.
///
/// The page comes from the push's `route` (`functions/src/push_callable.ts`)
/// and must be one of [allowedRoutes]; anything else opens Notifications.
class NotificationTapHandler {
  NotificationTapHandler({
    required this.session,
    required this.go,
    this._initialMessage,
    this._openedApp,
  });

  final SessionController session;

  /// Navigates — `GoRouter.go` in the app.
  final void Function(String route) go;

  final Future<RemoteMessage?> Function()? _initialMessage;
  final Stream<RemoteMessage>? _openedApp;

  /// The pages a notification may open.
  static const allowedRoutes = {
    AppRoutes.correctiveActions,
    AppRoutes.hazards,
    AppRoutes.incidents,
    AppRoutes.inspections,
    AppRoutes.riskAssessments,
    AppRoutes.dailySafetyMeetings,
    AppRoutes.safetyAlerts,
    AppRoutes.notifications,
  };

  /// The page for a push's [data].
  static String routeFor(Map<String, dynamic> data) {
    final route = data['route'];
    return route is String && allowedRoutes.contains(route)
        ? route
        : AppRoutes.notifications;
  }

  String? _pending;
  StreamSubscription<RemoteMessage>? _subscription;
  bool _listeningToSession = false;

  /// Starts listening for taps. Does nothing on the web, in tests without
  /// Firebase, or against the emulators.
  Future<void> start() async {
    Future<RemoteMessage?> Function()? initial = _initialMessage;
    Stream<RemoteMessage>? opened = _openedApp;
    if (initial == null || opened == null) {
      if (kIsWeb || FirebaseTarget.useEmulators || Firebase.apps.isEmpty) {
        return;
      }
      initial ??= FirebaseMessaging.instance.getInitialMessage;
      opened ??= FirebaseMessaging.onMessageOpenedApp;
    }
    _subscription = opened.listen(_handle);
    try {
      final message = await initial();
      if (message != null) _handle(message);
    } on Object catch (e) {
      debugPrint('Could not read the notification that opened the app: $e');
    }
  }

  void _handle(RemoteMessage message) {
    _pending = routeFor(message.data);
    _openWhenSignedIn();
  }

  void _openWhenSignedIn() {
    final route = _pending;
    if (route == null) return;
    if (session.status == AuthStatus.authenticated) {
      _pending = null;
      _stopListeningToSession();
      go(route);
    } else if (!_listeningToSession) {
      _listeningToSession = true;
      session.addListener(_openWhenSignedIn);
    }
  }

  void _stopListeningToSession() {
    if (!_listeningToSession) return;
    _listeningToSession = false;
    session.removeListener(_openWhenSignedIn);
  }

  void dispose() {
    _subscription?.cancel();
    _stopListeningToSession();
  }
}
