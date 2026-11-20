import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/push_notifications.dart';
import '../theme/app_colors.dart';

/// The web version only (iPhone Home Screen app, laptops): "Turn on
/// notifications" at the top of the parent's Home until they've answered.
/// The Android app asks by itself after signing in; a browser only asks
/// straight from a tap, so without this an iPhone family would never be
/// asked. On iPhone Safari before "Add to Home Screen" it says how to get
/// them instead. Nothing on Android, and nothing once answered.
class WebPushBanner extends StatefulWidget {
  const WebPushBanner({super.key});

  @override
  State<WebPushBanner> createState() => _WebPushBannerState();
}

class _WebPushBannerState extends State<WebPushBanner> {
  NotificationStatus? _status;

  /// The Home Screen tip can be closed; it comes back next time the app
  /// opens, until the app is added.
  bool _tipClosed = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) _load();
  }

  Future<void> _load() async {
    final status = await PushNotifications.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _turnOn() async {
    // First thing in the tap: Safari only asks while it's still the tap.
    final asked = await PushNotifications.askOnWeb();
    if (!mounted) return;
    if (!asked) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(webNoPushHelp)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    return switch (_status) {
      NotificationStatus.notAsked => _Banner(
        icon: Icons.notifications_active_outlined,
        title: "Turn on notifications",
        text:
            "Get new messages, bills and tournament invitations straight "
            "away.",
        action: "TURN ON",
        onTap: _turnOn,
      ),
      NotificationStatus.unavailable when !_tipClosed => _Banner(
        icon: Icons.add_to_home_screen_outlined,
        title: "Add DSA Elite to your Home Screen",
        text:
            "On iPhone: tap Share, then Add to Home Screen, and open the "
            "app from there to get notifications.",
        action: "CLOSE",
        onTap: () => setState(() => _tipClosed = true),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final String action;
  final VoidCallback onTap;

  const _Banner({
    required this.icon,
    required this.title,
    required this.text,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        text,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  action,
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
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
