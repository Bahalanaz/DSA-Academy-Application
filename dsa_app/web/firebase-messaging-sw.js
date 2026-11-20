// Shows the academy's notifications while the web app is closed (iPhone
// Home Screen app, laptop browser). Firebase displays each message's title
// and body itself; tapping one opens (or brings back) the app.
//
// The SDK version matches what the Flutter plugin uses (firebase_core_web's
// supportedFirebaseJsSdkVersion). The config is the public "DSA Web" app
// config, the same as lib/core/config/firebase_web.dart.
importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-messaging-compat.js');

// Registered before Firebase's own listener, so a tap always opens the app
// (the server's messages carry no web link of their own).
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const appUrl = new URL('./', self.registration.scope).href;
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      for (const w of windows) {
        if (w.url.startsWith(appUrl) && 'focus' in w) return w.focus();
      }
      return clients.openWindow(appUrl);
    }),
  );
});

firebase.initializeApp({
  apiKey: 'YOUR_FIREBASE_WEB_API_KEY',
  authDomain: 'your-project.firebaseapp.com',
  projectId: 'your-project',
  storageBucket: 'your-project.firebasestorage.app',
  messagingSenderId: 'YOUR_SENDER_ID',
  appId: 'YOUR_FIREBASE_WEB_APP_ID',
});

firebase.messaging();
