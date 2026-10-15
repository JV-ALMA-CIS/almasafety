import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Whether this device can show push notifications, and whether the person
/// has allowed them.
enum PushPermission {
  /// This browser/device cannot receive push (e.g. Safari on an iPhone
  /// unless the app is added to the Home Screen).
  unsupported,

  /// Not asked yet.
  notAsked,
  allowed,

  /// The person said no — only their browser/phone settings can undo it.
  blocked,
}

/// Push notifications on this device (Firebase Cloud Messaging): asks
/// permission, and registers / removes this device's token on the signed-in
/// account (`registerPushToken` / `unregisterPushToken` in
/// `functions/src/push_callable.ts`). The server then pushes every in-app
/// notification to the person's devices too.
class PushNotificationService {
  PushNotificationService({this._messaging, this._functions});

  /// The project's public Web Push key (Firebase console → Cloud Messaging →
  /// Web Push certificates). Public by design — it identifies the sender.
  static const vapidKey =
      'BC8ZU2xYbYU5feu6Vb2Agpwj89GHYoTCsJaAl9B6lPPIQ87Rw2bqHsbxM4I-BORBUKVe'
      'G_jR0ULEXBSH2LxIgso';

  final FirebaseMessaging? _messaging;
  final FirebaseFunctions? _functions;

  /// The token registered from this device in this session, if any.
  static String? _registeredToken;
  static bool _listening = false;

  FirebaseMessaging? get _instance {
    if (_messaging != null) return _messaging;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseMessaging.instance;
  }

  FirebaseFunctions? get _callables {
    if (_functions != null) return _functions;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFunctions.instance;
  }

  /// Where this device stands.
  Future<PushPermission> permission() async {
    final messaging = _instance;
    if (messaging == null) return PushPermission.unsupported;
    try {
      if (!await messaging.isSupported()) return PushPermission.unsupported;
      final settings = await messaging.getNotificationSettings();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.allowed,
        AuthorizationStatus.denied => PushPermission.blocked,
        AuthorizationStatus.notDetermined => PushPermission.notAsked,
      };
    } on Object {
      return PushPermission.unsupported;
    }
  }

  /// Asks permission — the browser/phone shows its own Allow prompt
  /// straight away, with nothing awaited before it — and returns the answer
  /// as soon as it is given. If allowed, this device is registered in the
  /// background; the caller never waits for that.
  Future<PushPermission> enable() async {
    final messaging = _instance;
    if (messaging == null) return PushPermission.unsupported;
    final PushPermission result;
    try {
      final settings = await messaging.requestPermission();
      result = switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.allowed,
        AuthorizationStatus.denied => PushPermission.blocked,
        AuthorizationStatus.notDetermined => PushPermission.notAsked,
      };
    } on Object {
      return PushPermission.unsupported;
    }
    if (result == PushPermission.allowed) {
      unawaited(registerIfAllowed(alreadyAllowed: true));
    }
    return result;
  }

  /// Registers this device if notifications are already allowed — called
  /// on opening the app, so a refreshed token is never missed.
  ///
  /// [alreadyAllowed] skips checking permission again when the caller has
  /// just been told it is allowed.
  Future<void> registerIfAllowed({bool alreadyAllowed = false}) async {
    final messaging = _instance;
    final functions = _callables;
    if (messaging == null || functions == null) return;
    if (!alreadyAllowed && await permission() != PushPermission.allowed) {
      return;
    }
    try {
      final token = await messaging.getToken(
        vapidKey: kIsWeb ? vapidKey : null,
      );
      if (token == null || token == _registeredToken) return;
      await _register(functions, token);
      if (!_listening) {
        _listening = true;
        messaging.onTokenRefresh.listen((fresh) => _register(functions, fresh));
      }
    } on Object catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  Future<void> _register(FirebaseFunctions functions, String token) async {
    await functions.httpsCallable('registerPushToken').call<Object?>({
      'token': token,
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    });
    _registeredToken = token;
  }

  /// Removes this device from the account — on sign-out, so the next
  /// person on this phone does not get the previous person's notifications.
  Future<void> unregister() async {
    final token = _registeredToken;
    final functions = _callables;
    if (token == null || functions == null) return;
    try {
      await functions.httpsCallable('unregisterPushToken').call<Object?>({
        'token': token,
      });
    } on Object catch (e) {
      debugPrint('Push unregistration failed: $e');
    }
    _registeredToken = null;
  }
}
