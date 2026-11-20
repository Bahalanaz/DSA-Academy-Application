import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/profile_photo.dart';

import '../../auth/screens/welcome_screen.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../models/mock_parent_players.dart';
import '../../../core/services/auth_api.dart';
import '../../../core/services/push_notifications.dart';
import '../../../core/services/session.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class ParentProfile extends StatefulWidget {
  const ParentProfile({super.key});

  @override
  State<ParentProfile> createState() => _ParentProfileState();
}

class _ParentProfileState extends State<ParentProfile>
    with WidgetsBindingObserver {
  bool _editing = false;

  /// Shown on the Notification Settings row. Null until checked.
  NotificationStatus? _notifications;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
  }

  /// Back from the phone's settings: show what they chose, and if they
  /// turned notifications on, tell the server where to send them.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNotifications();
  }

  Future<void> _checkNotifications() async {
    final before = _notifications;
    final now = await PushNotifications.status();
    if (!mounted) return;
    setState(() => _notifications = now);
    if (now == NotificationStatus.on && before != NotificationStatus.on) {
      PushNotifications.register();
    }
  }

  Future<void> _notificationSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    if (kIsWeb) {
      // The browser's question has to come straight from this tap.
      final asked = await PushNotifications.askOrOpenSettings();
      if (!asked) {
        messenger.showSnackBar(const SnackBar(content: Text(webNoPushHelp)));
      } else if (await PushNotifications.status() == NotificationStatus.off) {
        messenger.showSnackBar(
          const SnackBar(content: Text(webPushBlockedHelp)),
        );
      }
      await _checkNotifications();
      return;
    }
    if (_notifications == NotificationStatus.off) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Turn on \"Allow notifications\", then come back."),
        ),
      );
    }
    final opened = await PushNotifications.askOrOpenSettings();
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Notifications aren't available on this device."),
        ),
      );
    }
    await _checkNotifications();
  }

  // Seeded from the signed-in account, falling back to the shared parent
  // identity constants when there's no session (e.g. hot reload).
  final TextEditingController _nameController = TextEditingController(
    text: Session.current?.fullName ?? currentParentName,
  );
  final TextEditingController _emailController = TextEditingController(
    text: Session.current?.email ?? currentParentEmail,
  );
  // From the account itself. It used to be borrowed from the first child's
  // record, which was blank until players had loaded (and always blank for a
  // parent with no players) — and saving the profile then wiped the number.
  final TextEditingController _phoneController = TextEditingController(
    text: Session.current?.phone ?? '',
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// Tapping the checkmark both leaves edit mode and saves.
  Future<void> _toggleEditing() async {
    if (!_editing) {
      setState(() => _editing = true);
      return;
    }
    try {
      await AuthApi.updateProfile(
        userId: Session.requireUserId,
        fullName: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
      );
      if (mounted) setState(() => _editing = false);
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

  Future<void> _deleteAccount() async {
    final messenger = ScaffoldMessenger.of(context);
    final deleted = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (deleted != true || !mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const Default()),
      (route) => false,
    );
    messenger.showSnackBar(
      const SnackBar(content: Text("Your account has been deleted.")),
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
                    "MY ACCOUNT",
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
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
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
                "Parent / Guardian Account",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),

            const SizedBox(height: 24),

            FadeSlideIn(
              index: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
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
            ),

            const SizedBox(height: 16),

            // No "Change Password" here: parents use "Forgot Password?" on the
            // log-in screen (a code by email), at the club's request.
            FadeSlideIn(
              index: 1,
              child: _AccountAction(
                icon: Icons.notifications_none,
                label: "Notification Settings",
                // Never asked: the phone's "Allow notifications?" question.
                // Otherwise: this app's notification settings on the phone.
                onTap: _notificationSettings,
              ),
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

            const SizedBox(height: 14),

            // A solid red box: stronger than Log out's outline, because
            // this one can't be undone (it asks first).
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _deleteAccount,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.white,
                ),
                label: const Text(
                  "DELETE MY ACCOUNT",
                  style: TextStyle(
                    color: Colors.white,
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

/// Deleting the account, with the password asked again. Says plainly what
/// happens: the account and its details go, the children come off the
/// club's lists, and payment records stay with the club.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_password.text.isEmpty) {
      setState(() => _error = "Enter your password to confirm.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthApi.deleteAccount(password: _password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Delete your account?",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Your name, username, email and phone number are removed, "
                "you're signed out everywhere, and your children come off "
                "the academy's lists and upcoming trainings.\n\nPayment records "
                "stay with the academy for its accounts. Anything still owed, "
                "or credit the academy is holding, has to be settled first.\n\n"
                "This can't be undone.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.redAccent,
                decoration: InputDecoration(
                  hintText: "Your password",
                  hintStyle: const TextStyle(color: Colors.white38),
                  isDense: true,
                  filled: true,
                  fillColor: _bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        "KEEP IT",
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _busy ? null : _delete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        _busy ? "DELETING..." : "DELETE",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
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
