import 'package:firebase_core/firebase_core.dart';

/// Firebase for the web version (iPhone "Add to Home Screen", laptops):
/// your Firebase project's web app (fill in the placeholders). These are
/// public by design (every web page that uses Firebase sends them), unlike
/// the server's service-account key. Android reads its own from
/// android/app/google-services.json instead.
const firebaseWebOptions = FirebaseOptions(
  apiKey: 'YOUR_FIREBASE_WEB_API_KEY',
  authDomain: 'your-project.firebaseapp.com',
  projectId: 'your-project',
  storageBucket: 'your-project.firebasestorage.app',
  messagingSenderId: 'YOUR_SENDER_ID',
  appId: 'YOUR_FIREBASE_WEB_APP_ID',
);

/// The project's Web Push certificate (public half), so browsers accept
/// notifications sent on the academy's behalf. Firebase console > Project
/// settings > Cloud Messaging > Web Push certificates.
const webPushKey = 'YOUR_WEB_PUSH_PUBLIC_KEY';

/// The helper that shows notifications while the web app is closed,
/// web/firebase-messaging-sw.js. Relative, so it lives next to the app
/// (…/app/firebase-messaging-sw.js) wherever the app is hosted.
const webPushWorker = 'firebase-messaging-sw.js';
