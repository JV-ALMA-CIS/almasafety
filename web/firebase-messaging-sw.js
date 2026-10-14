// Receives push notifications for the JVA Safety web app while it is closed
// or in the background, and shows them on the device. Notifications sent by
// the server (functions/src/push_callable.ts) carry a title, a body and a
// link to the page they are about; tapping one opens that page.
//
// Must live at the site root as `firebase-messaging-sw.js` — that is where
// the Firebase Messaging SDK looks for it.

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
