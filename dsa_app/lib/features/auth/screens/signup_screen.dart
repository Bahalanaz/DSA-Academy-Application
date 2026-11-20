import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../widgets/auth_widgets.dart';
import 'login_screen.dart';
import '../../../core/services/auth_api.dart';
import '../../../core/utils/text_rules.dart';

class Signup extends StatefulWidget {
  const Signup({super.key});

  @override
  State<Signup> createState() => _SignupState();
}

class _SignupState extends State<Signup> {
  final TextEditingController username = TextEditingController();
  final TextEditingController fullName = TextEditingController();
  final TextEditingController email = TextEditingController();
  final TextEditingController phoneNumber = TextEditingController();
  final TextEditingController password = TextEditingController();
  final TextEditingController confirmPassword = TextEditingController();

  bool _submitting = false;

  Future<void> signUp() async {
    if (_submitting) return;

    final usernameText = username.text.trim();
    final fullNameText = fullName.text.trim();
    final emailText = email.text.trim();
    // The name is what the admin sees as the child's guardian. Without this
    // field every new parent showed up under their username.
    if (fullNameText.isEmpty) {
      _showError("Please enter your full name");
      return;
    }
    final nameError = personNameError(fullNameText, label: "Full name");
    if (nameError != null) {
      _showError(nameError);
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9._-]{3,60}$').hasMatch(usernameText)) {
      _showError(
        "Username must be 3 to 60 letters, numbers, dots, dashes or underscores",
      );
      return;
    }
    if (usernameText.isEmpty || emailText.isEmpty) {
      _showError("Please enter a username and email");
      return;
    }
    if (password.text.isEmpty) {
      _showError("Please enter a password");
      return;
    }
    if (password.text != confirmPassword.text) {
      _showError("Passwords don't match");
      return;
    }

    setState(() => _submitting = true);
    try {
      await AuthApi.signUp(
        username: usernameText,
        fullName: fullNameText,
        email: emailText,
        phone: phoneNumber.text.trim(),
        password: password.text,
      );
      if (!mounted) return;
      // A signup never logs the user straight in — every new account
      // starts 'pending' until an admin approves it — so send them back
      // to Login with a clear explanation rather than into the app.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Account created. An admin needs to approve it before you can log in.",
          ),
          duration: Duration(seconds: 5),
        ),
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const Login()),
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
    fullName.dispose();
    email.dispose();
    phoneNumber.dispose();
    password.dispose();
    confirmPassword.dispose();
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
                const SizedBox(height: 10),

                const SizedBox(height: 20),

                const Text(
                  "JOIN THE ELITE.",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const Text(
                  "CREATE YOUR ACCOUNT.",
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 35),

                AuthTextField(
                  controller: fullName,
                  hintText: "Full Name (parent / guardian)",
                  inputFormatters: [personNameChars],
                ),

                const SizedBox(height: 16),

                AuthTextField(controller: username, hintText: "Username"),

                const SizedBox(height: 16),

                AuthTextField(
                  controller: email,
                  hintText: "Email",
                  keyboardType: TextInputType.emailAddress,
                ),

                const SizedBox(height: 16),

                AuthTextField(
                  controller: phoneNumber,
                  hintText: "Phone Number",
                  keyboardType: TextInputType.phone,
                  inputFormatters: [phoneChars],
                ),

                const SizedBox(height: 16),

                AuthTextField(
                  controller: password,
                  hintText: "Password",
                  obscureText: true,
                ),

                const SizedBox(height: 16),

                AuthTextField(
                  controller: confirmPassword,
                  hintText: "Confirm Password",
                  obscureText: true,
                ),

                const SizedBox(height: 30),

                AuthButton(
                  label: _submitting ? "CREATING ACCOUNT..." : "CREATE ACCOUNT",
                  onPressed: signUp,
                ),

                const SizedBox(height: 24),

                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Already have an account? ",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => const Login()),
                          );
                        },
                        child: const Text(
                          "Log In",
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
