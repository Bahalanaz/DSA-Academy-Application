import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/firebase_web.dart';
import 'api_client.dart';
import 'live_refresh.dart';
import 'session.dart';

/// Whether this phone shows the club's notifications, for the Account
/// screen's Notification Settings row.
enum NotificationStatus {
  /// Allowed.
  on,

  /// Refused (in the "Allow?" question or the phone's settings).
  off,

  /// Never asked yet.
  notAsked,

  /// Not on this device: Firebase isn't set up, or a browser that can't
  /// show them (on iPhone: Safari itself, before "Add to Home Screen").
  unavailable,
}

/// The web version on a browser that can't show notifications: on iPhone,
/// that's Safari until the app is added to the Home Screen.
const webNoPushHelp =
    "To get notifications on iPhone, add DSA Elite to your Home Screen "
    "(Share, then Add to Home Screen) and open it from there.";

/// The web version after notifications were refused.
const webPushBlockedHelp =
    "Notifications are turned off. On iPhone: Settings > Notifications > "
    "DSA Elite > Allow Notifications.";

/// Push notifications (Firebase Cloud Messaging): a new message from the
/// club, a schedule change or a cancellation buzzes the phone even when the
/// app is closed.
///
/// After every sign-in (and on start-up with a remembered login) this asks
/// once for permission to show notifications, then tells the server where
/// to send them (POST /devices). The server files that under the login, so
/// logging out stops them. The server decides who gets what: the same
/// people who'd see the message in Messages.
///
/// Until Firebase is configured (android/app/google-services.json) every
/// call quietly does nothing and the app works as before.
class PushNotifications {
  PushNotifications._();

  /// Set by main.dart: shows a notification that arrives while the app is
  /// open (Android and iOS don't show those themselves).
  static void Function(String title, String body)? onForegroundMessage;

  static Future<bool>? _starting;
  static bool _available = false;
  static StreamSubscription<String>? _tokenRefresh;

  /// Starts Firebase once. Everyone asking while it's still starting waits
  /// for that same start: a second caller used to get "not available"
  /// straight away (right after signing in, Home asked while sign-in was
  /// still starting it).
  static Future<bool> _start() => _starting ??= _init();

  static Future<bool> _init() async {
    try {
      await Firebase.initializeApp(options: kIsWeb ? firebaseWebOptions : null);
      // A browser without web push (on iPhone: Safari before "Add to Home
      // Screen", or iOS older than 16.4) simply has no notifications.
      if (kIsWeb && !await FirebaseMessaging.instance.isSupported()) {
        return false;
      }
      _available = true;
      FirebaseMessaging.onMessage.listen((message) {
        final note = message.notification;
        if (note != null) {
          onForegroundMessage?.call(note.title ?? '', note.body ?? '');
        }
        // The new message (and the unread badge) shows straight away.
        LiveRefresh.now();
      });
      // Tapping a notification opens the app: bring its screens up to date.
      // (On the web, firebase-messaging-sw.js opens the app instead.)
      if (!kIsWeb) {
        FirebaseMessaging.onMessageOpenedApp.listen((_) => LiveRefresh.now());
      }
    } catch (e) {
      debugPrint('Push notifications unavailable: $e');
    }
    return _available;
  }

  /// Call after signing in. Never throws and never blocks sign-in.
  static Future<void> register() async {
    if (!await _start()) return;
    try {
      final messaging = FirebaseMessaging.instance;
      if (kIsWeb) {
        // A browser only asks "Allow notifications?" straight from a tap
        // (askOrOpenSettings), never after a sign-in finishes. Here: just
        // keep an already-allowed browser's address up to date.
        final settings = await messaging.getNotificationSettings();
        if (settings.authorizationStatus != AuthorizationStatus.authorized) {
          return;
        }
      } else {
        final settings = await messaging.requestPermission();
        if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      }
      final token = kIsWeb
          ? await messaging.getToken(
              vapidKey: webPushKey,
              serviceWorkerScriptPath: webPushWorker,
            )
          : await messaging.getToken();
      if (token != null) await _send(token);
      // Browsers don't report a new address; every sign-in and start-up
      // sends the current one instead.
      if (!kIsWeb) _tokenRefresh ??= messaging.onTokenRefresh.listen(_send);
    } catch (e) {
      debugPrint('Could not register for notifications: $e');
    }
  }

  static Future<NotificationStatus> status() async {
    if (!await _start()) return NotificationStatus.unavailable;
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => NotificationStatus.on,
        AuthorizationStatus.notDetermined => NotificationStatus.notAsked,
        // Permanently: Android won't show the question again, only the
        // phone's settings can turn them back on.
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently => NotificationStatus.off,
      };
    } catch (_) {
      return NotificationStatus.unavailable;
    }
  }

  /// The Notification Settings row: never asked yet -> the phone's "Allow
  /// notifications?" question; otherwise -> this app's notification settings
  /// on the phone (to turn them back on after refusing — Android stops
  /// asking after a couple of refusals — or to turn them off). Returns false
  /// when there was nothing to open.
  static Future<bool> askOrOpenSettings() async {
    if (kIsWeb) return askOnWeb();
    final now = await status();
    if (now == NotificationStatus.unavailable) return false;
    if (now == NotificationStatus.notAsked) {
      await register();
      return true;
    }
    return openPhoneSettings();
  }

  /// The web version's "Allow notifications?" question. Call it straight
  /// from a tap, before anything else is awaited: Safari on iPhone only
  /// shows the question while it still counts as the person's own tap.
  /// Returns false where the browser can't show notifications at all.
  static Future<bool> askOnWeb() async {
    if (!_available) return false;
    try {
      final answer = await FirebaseMessaging.instance.requestPermission();
      if (answer.authorizationStatus == AuthorizationStatus.authorized) {
        await register();
      }
      return true;
    } catch (e) {
      debugPrint('Could not ask for notifications: $e');
      return false;
    }
  }

  /// Opens this app's notification settings on the phone (Android; see
  /// MainActivity.kt). False where that isn't possible.
  static Future<bool> openPhoneSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await const MethodChannel('dsa/settings')
              .invokeMethod<bool>('openNotificationSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _send(String token) async {
    if (!Session.isLoggedIn) return;
    try {
      await ApiClient.post('/devices', {
        'token': token,
        'platform': kIsWeb
            ? 'web'
            : defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
      });
    } catch (e) {
      debugPrint('Could not register this phone for notifications: $e');
    }
  }
}
