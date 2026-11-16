// Receives push notifications for the JVA Safety web app while it is closed
// or in the background, and shows them on the device. Notifications sent by
// the server (functions/src/push_callable.ts) carry a title, a body and a
// link to the page they are about; tapping one opens that page.
//
// Must live at the site root as `firebase-messaging-sw.js` — that is where
// the Firebase Messaging SDK looks for it.

// Clicking a notification opens its page — registered BEFORE the Firebase
// SDK's own click listener so it runs first. Handles both kinds:
// - shown by the SDK for a push while the app is closed/hidden (the page is
//   in the push data, `FCM_MSG.data.route`);
// - shown by the app itself while it is open (`data.route`, see
//   lib/core/services/foreground_notifications.dart).
// The page opens on THIS address (whichever one the app is used from): an
// open app window is brought forward and told which page to show
// (web/index.html listens); otherwise a new window opens on that page.
self.addEventListener("notificationclick", (event) => {
  const data = event.notification.data || {};
  const fcm = data.FCM_MSG;
  const route = (fcm && fcm.data && fcm.data.route) || data.route;
  if (!route) return;
  event.stopImmediatePropagation();
  event.notification.close();
  event.waitUntil(openPage(route));
});

/**
 * Brings the app forward on [route] ("/hazards"), or opens it there.
 *
 * @param {string} route the page.
 * @return {Promise<void>} when done.
 */
async function openPage(route) {
  const page = /^\/[a-z-]+$/.test(route) ? route : "/notifications";
  const windows = await self.clients.matchAll({
    type: "window",
    includeUncontrolled: true,
  });
  const app = windows.find(
    (w) => new URL(w.url).origin === self.location.origin
  );
  if (app) {
    await app.focus();
    app.postMessage({type: "almasafety-open", route: page});
    return;
  }
  await self.clients.openWindow(self.location.origin + "/#" + page);
}

importScripts(
  "https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js"
);
importScripts(
  "https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js"
);

firebase.initializeApp({
  apiKey: "AIzaSyC2f4auPrNQIWYpHtoOPV1UafOBmXElsd8",
  appId: "1:585202248724:web:eb90e7f2fa5ea19b6d8b01",
  messagingSenderId: "585202248724",
  projectId: "jva-safety",
  authDomain: "jva-safety.firebaseapp.com",
  storageBucket: "jva-safety.firebasestorage.app",
});

// Messages with a `notification` part are shown automatically, and the
// webpush link opens the right page when tapped.
firebase.messaging();
