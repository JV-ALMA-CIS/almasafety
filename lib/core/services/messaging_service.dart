import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Thin wrapper around FirebaseMessaging.
///
/// Foundation only: requests permission and exposes the device token /
/// message streams needed later by the notifications and safety_alerts
/// features. No topic subscription or notification-handling logic is wired
/// up yet — that belongs to those features.
///
/// Resolves [FirebaseMessaging.instance] lazily, mirroring [AuthService].
class MessagingService {
  MessagingService({FirebaseMessaging? messaging}) : _injected = messaging;

  final FirebaseMessaging? _injected;

  FirebaseMessaging? get instance {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseMessaging.instance;
  }

  /// Requests notification permission. Returns null if Firebase is not
  /// available (e.g. unconfigured platform, tests).
  Future<NotificationSettings?> requestPermission() {
    final messaging = instance;
    if (messaging == null) return Future.value(null);
    return messaging.requestPermission();
  }

  /// The device's FCM registration token, or null if messaging is
  /// unavailable. Storing this against the user's profile (for targeted
  /// safety alerts) is left to the notifications feature.
  Future<String?> getToken() {
    final messaging = instance;
    if (messaging == null) return Future.value(null);
    return messaging.getToken();
  }

  /// Foreground message stream. Empty if messaging is unavailable.
  Stream<RemoteMessage> onMessage() =>
      instance != null ? FirebaseMessaging.onMessage : const Stream.empty();
}
