import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/profile_photo.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../auth/screens/welcome_screen.dart';
import '../../../core/services/auth_api.dart';
import '../../../core/services/session.dart';
import '../../../core/widgets/change_password_dialog.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class AdminAccount extends StatefulWidget {
  const AdminAccount({super.key});

  @override
  State<AdminAccount> createState() => _AdminAccountState();
}

class _AdminAccountState extends State<AdminAccount> {
  bool _editing = false;

  // Seeded from whoever actually logged in, not a hardcoded name.
  final TextEditingController _nameController = TextEditingController(
    text: Session.current?.fullName ?? '',
  );
  final TextEditingController _emailController = TextEditingController(
    text: Session.current?.email ?? '',
  );
  // Started blank before, so saving the profile wiped the saved number.
  final TextEditingController _phoneController = TextEditingController(
    text: Session.current?.phone ?? '',
  );
  // What the admin logs in with (or the email). Same rules as signing up.
  final TextEditingController _usernameController = TextEditingController(
    text: Session.current?.username ?? '',
  );

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// The pencil turns into a checkmark while editing; tapping the
  /// checkmark is what actually saves, so leaving edit mode and
  /// persisting are the same action.
  Future<void> _toggleEditing() async {
    if (!_editing) {
      setState(() => _editing = true);
      return;
    }
    final oldUsername = Session.current?.username;
    final username = _usernameController.text.trim();
    try {
      await AuthApi.updateProfile(
        userId: Session.requireUserId,
        fullName: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        username: username,
      );
      if (mounted) setState(() => _editing = false);
      if (mounted && username != oldUsername) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Username changed. Log in with \"$username\" now."),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  /// Take Photo / Choose from Gallery / Remove photo for this account.
  Future<void> _showPhotoOptions() async {
    final url = await changePhoto(
      context,
      kind: 'user',
      id: Session.requireUserId,
      hasPhoto: Session.current?.photoUrl != null,
    );
    if (url == null) return;
    await AuthApi.setPhotoUrl(url);
    if (mounted) setState(() {});
  }

  void _logOut() {
    // Ends the session server-side too, so the token stops working.
    AuthApi.logOut();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const Default()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          children: [
            Row(
              children: [
                const SizedBox(width: 40),
                const Expanded(
                  child: Text(
                    "ADMIN ACCOUNT",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _toggleEditing,
                  icon: Icon(
                    _editing ? Icons.check : Icons.edit,
                    color: _accent,
                    size: 20,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_accent, Colors.green.shade900],
                      ),
                    ),
                    child: ProfilePhoto(
                      url: Session.current?.photoUrl,
                      radius: 44,
                    ),
                  ),
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: GestureDetector(
                      onTap: _showPhotoOptions,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: _bg, width: 2),
                        ),
                        child: const Icon(
                          Icons.add_a_photo,
                          color: Colors.white,
                          size: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            Center(
              child: Text(
                _nameController.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 2),
            const Center(
              child: Text(
                "Coach / Admin Account",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),

            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _AccountField(
                    icon: Icons.badge_outlined,
                    label: "Full Name",
                    controller: _nameController,
                    editing: _editing,
                    inputFormatters: [personNameChars],
                  ),
                  const SizedBox(height: 16),
                  _AccountField(
                    icon: Icons.alternate_email,
                    label: "Username",
                    controller: _usernameController,
                    editing: _editing,
                    // Letters, numbers, dots, dashes and underscores only,
                    // as when signing up.
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[A-Za-z0-9._-]'),
                      ),
                      LengthLimitingTextInputFormatter(60),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _AccountField(
                    icon: Icons.email_outlined,
                    label: "Email",
                    controller: _emailController,
                    editing: _editing,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16),
                  _AccountField(
                    icon: Icons.phone_outlined,
                    label: "Phone Number",
                    controller: _phoneController,
                    editing: _editing,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [phoneChars],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            _AccountAction(
              icon: Icons.lock_outline,
              label: "Change Password",
              onTap: () => showChangePasswordDialog(context),
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _logOut,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                label: const Text(
                  "LOG OUT",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _AccountField extends StatelessWidget {
  final IconData icon;
  final String label;
  final TextEditingController controller;
  final bool editing;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  const _AccountField({
    required this.icon,
    required this.label,
    required this.controller,
    required this.editing,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white54, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 3),
              if (editing)
                TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  inputFormatters: inputFormatters ?? [noEmoji],
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  cursorColor: _accent,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: _bg,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _accent, width: 1.5),
                    ),
                  ),
                )
              else
                Text(
                  controller.text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AccountAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
