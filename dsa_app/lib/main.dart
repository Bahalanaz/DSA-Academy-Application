import 'package:flutter/material.dart';

import 'package:dsa_app/features/auth/screens/startup_gate.dart';
import 'package:dsa_app/features/auth/screens/welcome_screen.dart';
import 'package:dsa_app/core/services/api_client.dart';
import 'package:dsa_app/core/services/live_refresh.dart';
import 'package:dsa_app/core/services/push_notifications.dart';
import 'package:dsa_app/core/theme/app_theme.dart';

final _navigatorKey = GlobalKey<NavigatorState>();
final _messengerKey = GlobalKey<ScaffoldMessengerState>();

// Data loading starts after login (see core/services/warm_up.dart): every
// server call needs the session token, which doesn't exist until then.
void main() {
  // When the server says the login has ended, go back to the start screen
  // and say why, from wherever the user happens to be.
  ApiClient.onSessionEnded = (message) {
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const Default()),
      (route) => false,
    );
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  };
  // A notification that arrives while the app is open shows as a message
  // at the bottom of the screen (the phone only shows them when it's not).
  PushNotifications.onForegroundMessage = (title, body) {
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(body.isEmpty ? title : '$title\n$body', maxLines: 4),
        duration: const Duration(seconds: 6),
      ),
    );
  };
  runApp(const MyApp());
  // Screens reload by themselves, so two phones on the same account (or
  // two admins) see each other's changes without leaving the screen.
  LiveRefresh.start();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      // Dark, green-accented, one look for every shared component: see
      // core/theme/app_theme.dart.
      theme: AppTheme.dark,
      // The phone's text-size setting is honoured, up to 130%. Beyond that
      // card rows and buttons built for normal text start to overflow.
      builder: (context, child) =>
          MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child!),
      home: const StartupGate(),
    );
  }
}
