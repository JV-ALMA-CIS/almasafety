import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../config/firebase_target.dart';
import 'notification_tap_handler.dart';
import 'system_notification_stub.dart'
    if (dart.library.js_interop) 'system_notification_web.dart'
    as system;

/// Shows a push that arrives while ALMASAFETY is OPEN — the device only
/// shows pushes by itself while the app is closed or hidden.
///
/// - On a computer/browser: a real system pop-up (bottom-right on Windows),
///   like Outlook's new-mail alert, even with ALMASAFETY in front. Urgent
///   ones (incidents, serious alerts) stay until clicked.
/// - In the Android app, or when the browser cannot: a bar at the bottom of
///   the app with the message and "Open".
///
/// Nothing here plays a sound of its own.
class ForegroundNotifications {
  ForegroundNotifications({
    required this.messengerKey,
    required this.go,
    this._messages,
    this._showSystem,
  });

  final GlobalKey<ScaffoldMessengerState> messengerKey;

  /// Navigates — `GoRouter.go` in the app.
  final void Function(String route) go;

  final Stream<RemoteMessage>? _messages;
  final Future<bool> Function({
    required String title,
    required String body,
    required String route,
    required bool urgent,
  })?
  _showSystem;

  StreamSubscription<RemoteMessage>? _subscription;

  /// Starts listening. Does nothing without Firebase or on the emulators.
  void start() {
    var messages = _messages;
    if (messages == null) {
      if (FirebaseTarget.useEmulators || Firebase.apps.isEmpty) return;
      messages = FirebaseMessaging.onMessage;
    }
    _subscription = messages.listen(show);
  }

  /// Shows [message].
  Future<void> show(RemoteMessage message) async {
    final title = message.notification?.title ?? 'ALMASAFETY';
    final body = message.notification?.body ?? '';
    final route = NotificationTapHandler.routeFor(message.data);
    final urgent = message.data['urgent'] == '1';

    final showSystem = _showSystem ?? system.showSystemNotification;
    if (await showSystem(
      title: title,
      body: body,
      route: route,
      urgent: urgent,
    )) {
      return;
    }

    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: urgent ? 30 : 8),
        showCloseIcon: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (body.isNotEmpty)
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        action: SnackBarAction(label: 'Open', onPressed: () => go(route)),
      ),
    );
  }

  void dispose() {
    _subscription?.cancel();
  }

  @visibleForTesting
  bool get isListening => _subscription != null;
}
