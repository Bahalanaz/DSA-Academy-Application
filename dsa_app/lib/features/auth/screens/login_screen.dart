import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../widgets/auth_widgets.dart';
import 'signup_screen.dart';
import 'forgot_password_screen.dart';
import '../../parent/screens/parent_home_screen.dart';
import '../../admin/screens/admin_home_screen.dart';
import '../../../core/services/auth_api.dart';
import '../../../core/services/push_notifications.dart';
import '../../../core/services/saved_login.dart';
import '../../../core/services/session.dart';
import '../../../core/services/warm_up.dart';
import '../../../core/widgets/change_password_dialog.dart';

class Login extends StatefulWidget {
  const Login({super.key});

  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final TextEditingController username = TextEditingController();
  final TextEditingController password = TextEditingController();

  bool _submitting = false;

  /// "Keep me signed in": remember this login on this phone. On by default;
  /// turn it off on a shared or borrowed phone.
  bool _keepSignedIn = true;

  Future<void> logIn() async {
    if (_submitting) return;

    if (username.text.trim().isEmpty || password.text.isEmpty) {
      _showError("Please enter your username/email and password");
      return;
    }

    setState(() => _submitting = true);
    try {
      final user = await AuthApi.logIn(
        identifier: username.text.trim(),
        password: password.text,
      );
      // Everything downstream that needs "who is logged in" reads this —
      // notably players.parent_id when a parent adds a player.
      Session.current = user;
      // A temporary password from the admin: the server refuses everything
      // else until a new one is chosen, so ask now. Backing out signs out.
      if (user.mustChangePassword) {
        if (!mounted) return;
        final changed = await showForcedPasswordChange(
          context,
          temporaryPassword: password.text,
        );
        if (!changed) {
          await AuthApi.logOut();
          return;
        }
        password.clear();
      }
      if (_keepSignedIn) await SavedLogin.save(user);
      // Now that there's a token, fill the shared lists in the background.
      warmUp();
      // Ask once for notifications and tell the server where to send them.
      PushNotifications.register();
      if (!mounted) return;
      // Home with nothing underneath: the phone's Back button must never
      // land on the welcome or login screen. Only Log out goes back there.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) =>
              user.isAdmin ? const AdminHome() : const HomeParents(),
        ),
        (route) => false,
      );
    } catch (e) {
      _showError(friendlyError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuthBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom -
                  40,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 20),

                const Text(
                  "WELCOME BACK.",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const Text(
                  "LOG IN TO CONTINUE.",
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 35),

                AuthTextField(
                  controller: username,
                  hintText: "Username or Email",
                  keyboardType: TextInputType.emailAddress,
                ),

                const SizedBox(height: 16),

                AuthTextField(
                  controller: password,
                  hintText: "Password",
                  obscureText: true,
                ),

                const SizedBox(height: 8),

                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            setState(() => _keepSignedIn = !_keepSignedIn),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: _keepSignedIn,
                                  onChanged: (v) =>
                                      setState(() => _keepSignedIn = v ?? true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Flexible(
                                child: Text(
                                  "Keep me signed in",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ForgotPassword(),
                          ),
                        );
                      },
                      child: const Text(
                        "Forgot Password?",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                AuthButton(
                  label: _submitting ? "LOGGING IN..." : "LOG IN",
                  onPressed: logIn,
                ),

                const SizedBox(height: 24),

                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Don't have an account? ",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => const Signup()),
                          );
                        },
                        child: const Text(
                          "Create Account",
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
