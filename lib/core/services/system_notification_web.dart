import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Shows a real computer/phone notification from the open web app — a
/// Windows/Mac pop-up like Outlook's — through the push service worker
/// (web/firebase-messaging-sw.js), so clicking it opens [route] there.
///
/// Returns false when it cannot (notifications not allowed, no service
/// worker yet); the caller then shows its in-app notice instead.
Future<bool> showSystemNotification({
  required String title,
  required String body,
  required String route,
  required bool urgent,
}) async {
  try {
    if (web.Notification.permission != 'granted') return false;
    final registration = await web.window.navigator.serviceWorker
        .getRegistration('/firebase-cloud-messaging-push-scope')
        .toDart;
    if (registration == null) return false;
    await registration
        .showNotification(
          title,
          web.NotificationOptions(
            body: body,
            icon: '/icons/Icon-192.png',
            badge: '/favicon.png',
            requireInteraction: urgent,
            data: {'route': route}.jsify(),
          ),
        )
        .toDart;
    return true;
  } on Object {
    return false;
  }
}
