import 'package:flutter/material.dart';

import '../../core/utils/friendly_error.dart';

import '../services/auth_api.dart';
import '../theme/app_colors.dart';
import 'dialog_body.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Asks for the current password and a new one, then saves it. Shared by the
/// admin and parent Account screens.
Future<void> showChangePasswordDialog(BuildContext context) async {
  final changed = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const _ChangePasswordDialog(),
  );
  if (changed == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Password changed. Other devices have been signed out."),
      ),
    );
  }
}

/// Right after logging in with a temporary password the admin gave them.
/// The temporary one is already known (they just typed it), so only the new
/// one is asked for, and the dialog can't be dismissed: backing out logs
/// them out instead. Returns whether the password was changed.
Future<bool> showForcedPasswordChange(
  BuildContext context, {
  required String temporaryPassword,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (_) => PopScope(
      canPop: false,
      child: _ChangePasswordDialog(knownCurrent: temporaryPassword),
    ),
  );
  return changed == true;
}

class _ChangePasswordDialog extends StatefulWidget {
  /// Set in the forced flow: the current password isn't asked for.
  final String? knownCurrent;

  const _ChangePasswordDialog({this.knownCurrent});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;

  /// Shown inside the dialog: a SnackBar would sit behind it.
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final current = widget.knownCurrent ?? _current.text;
    final next = _next.text;
    String? problem;
    if (current.isEmpty) {
      problem = "Enter your current password";
    } else if (next.length < 6) {
      problem = "The new password must be at least 6 characters";
    } else if (next != _confirm.text) {
      problem = "The new passwords don't match";
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AuthApi.changePassword(currentPassword: current, newPassword: next);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e);
      });
    }
  }

  Widget _field(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: true,
        enabled: !_saving,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        cursorColor: _accent,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
          isDense: true,
          filled: true,
          fillColor: _bg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent, width: 1.5),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.knownCurrent == null
                  ? "CHANGE PASSWORD"
                  : "CHOOSE A NEW PASSWORD",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (widget.knownCurrent != null) ...[
              const SizedBox(height: 8),
              Text(
                "The academy reset your password. Choose your own to continue.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (widget.knownCurrent == null)
              _field(_current, "Current password"),
            _field(_next, "New password"),
            _field(_confirm, "Confirm new password"),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      widget.knownCurrent == null ? "CANCEL" : "LOG OUT",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      _saving ? "SAVING..." : "SAVE",
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
    );
  }
}
