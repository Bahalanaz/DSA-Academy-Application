import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/auth_widgets.dart';
import '../../../core/services/auth_api.dart';
import '../../../core/utils/friendly_error.dart';

/// "Forgot Password?" in two steps:
///  1. their email or username -> the server emails a 6-digit code
///     (through Brevo);
///  2. the code and a new password -> changed, and every phone signed in to
///     the account is signed out. Back to log in.
///
/// The code works for 15 minutes and 5 tries; "Send a new code" is there
/// (after a short wait) if it doesn't arrive or runs out. At most 3 codes an
/// hour: the button counts down what's left, and after the 3rd the server
/// says how many minutes until they can ask again.
class ForgotPassword extends StatefulWidget {
  const ForgotPassword({super.key});

  @override
  State<ForgotPassword> createState() => _ForgotPasswordState();
}

class _ForgotPasswordState extends State<ForgotPassword> {
  final _identifier = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// Step 2: a code has been sent.
  bool _codeSent = false;
  bool _busy = false;

  /// Seconds before another code can be asked for.
  int _resendIn = 0;

  /// Codes they may still ask for this hour (the server's count).
  int _codesLeft = 3;
  Timer? _resendTimer;

  @override
  void dispose() {
    _identifier.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _startResendWait() {
    _resendTimer?.cancel();
    setState(() => _resendIn = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _resendIn--);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    final identifier = _identifier.text.trim();
    if (identifier.isEmpty) {
      _show("Please enter your email or username");
      return;
    }
    setState(() => _busy = true);
    try {
      final left = await AuthApi.forgotPassword(identifier: identifier);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _codesLeft = left;
      });
      if (left > 0) _startResendWait();
    } catch (e) {
      if (!mounted) return;
      // Asked 3 times this hour: no more until the hour is up.
      if (e.toString().contains('codes in the last hour')) {
        setState(() => _codesLeft = 0);
      }
      _show(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      _show("Enter the 6-digit code from the email");
      return;
    }
    if (_password.text.length < 6) {
      _show("Your new password must be at least 6 characters");
      return;
    }
    if (_password.text != _confirm.text) {
      _show("The two passwords don't match");
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthApi.resetPassword(
        identifier: _identifier.text.trim(),
        code: code,
        newPassword: _password.text,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Password changed. Log in with your new password."),
        ),
      );
    } catch (e) {
      if (mounted) _show(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Colors.white.withValues(alpha: 0.75),
      fontSize: 14,
      height: 1.4,
    );
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
                const SizedBox(height: 30),
                Text(
                  _codeSent ? "CHECK YOUR EMAIL" : "FORGOT PASSWORD?",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _codeSent
                      ? "If an account matches, we've emailed it a 6-digit "
                            "code. It works for 15 minutes. Check your spam "
                            "folder if you don't see it."
                      : "Enter your email or username and we'll email you a "
                            "code to reset your password.",
                  style: muted,
                ),
                const SizedBox(height: 20),
                if (!_codeSent) ...[
                  AuthTextField(
                    controller: _identifier,
                    hintText: "Email or Username",
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 24),
                  AuthButton(
                    label: _busy ? "SENDING..." : "SEND CODE",
                    onPressed: _sendCode,
                  ),
                ] else ...[
                  AuthTextField(
                    controller: _code,
                    hintText: "6-digit code",
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                  ),
                  const SizedBox(height: 16),
                  AuthTextField(
                    controller: _password,
                    hintText: "New password",
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  AuthTextField(
                    controller: _confirm,
                    hintText: "Confirm new password",
                    obscureText: true,
                  ),
                  const SizedBox(height: 24),
                  AuthButton(
                    label: _busy ? "SAVING..." : "RESET PASSWORD",
                    onPressed: _reset,
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _resendIn > 0 || _busy || _codesLeft <= 0
                          ? null
                          : _sendCode,
                      child: Text(
                        _codesLeft <= 0
                            ? "No more codes this hour. Use the newest one."
                            : _resendIn > 0
                            ? "Send a new code in ${_resendIn}s "
                                  "($_codesLeft left)"
                            : "Send a new code ($_codesLeft left)",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _resendIn > 0 || _codesLeft <= 0
                              ? Colors.white38
                              : Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      "Back to Log In",
                      style: TextStyle(
                        color: Colors.green,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
