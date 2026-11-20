import 'package:flutter/material.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/push_notifications.dart';
import '../../../core/services/saved_login.dart';
import '../../../core/services/session.dart';
import '../../../core/services/warm_up.dart';
import '../../../core/theme/app_colors.dart';
import '../../admin/screens/admin_home_screen.dart';
import '../../parent/screens/parent_home_screen.dart';
import 'welcome_screen.dart';

/// The first screen. If this phone remembers a login ("Keep me signed in"),
/// it checks with the server that it still works and goes straight to Home;
/// otherwise it shows the welcome screen. Shows the logo while it checks.
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  void _go(Widget screen) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, _, _) => screen,
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  Future<void> _decide() async {
    final user = await SavedLogin.read();
    if (user == null) return _go(const Default());

    Session.current = user;
    try {
      // Any cheap request every account may make: it only has to prove the
      // token still works.
      await ApiClient.getList('/categories');
    } on ApiException catch (e) {
      // 401: the login ended (logged out elsewhere, the password was changed on
      // another phone, the account was deactivated). ApiClient has already
      // cleared it and sent the app back to the start screen with the
      // reason, so there is nothing more to do here.
      if (e.statusCode == 401) return;
    } catch (_) {
      // The server can't be reached (no signal, or it's down). Keep the
      // saved login for the next launch, but don't open Home onto a screen
      // full of errors.
      Session.current = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Connection lost. Please check your internet connection and "
            "reopen the app to sign in automatically.",
          ),
        ),
      );
      _go(const Default());
      return;
    }
    warmUp();
    PushNotifications.register();
    _go(user.isAdmin ? const AdminHome() : const HomeParents());
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image(image: AssetImage("assets/LOGO.png"), width: 160),
            SizedBox(height: 28),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
