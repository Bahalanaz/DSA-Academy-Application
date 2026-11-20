import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/mock_announcements.dart';
import '../../admin/models/mock_roster.dart';
import '../models/mock_parent_players.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// A parent-facing view of one announcement (see mock_announcements.dart
/// for the stored shape).
///
/// Deliberately carries no "who it was addressed to": a parent only needs
/// the message itself, not that it happened to go to B2013.
class MessageThread {
  final String title;
  final String preview;
  final String body;
  final String time;
  final SentAnnouncement announcement;

  const MessageThread({
    required this.announcement,
    this.title = '',
    required this.preview,
    required this.body,
    required this.time,
  });
}

class ParentMessages extends StatefulWidget {
  /// Called when the messages reload or one is read, so the unread badge on
  /// the bottom bar keeps up.
  final VoidCallback? onChanged;

  const ParentMessages({super.key, this.onChanged});

  @override
  State<ParentMessages> createState() => _ParentMessagesState();
}

class _ParentMessagesState extends State<ParentMessages>
    with LiveRefreshing<ParentMessages> {
  @override
  Future<void> reloadQuietly() async {
    await loadAnnouncements();
    await loadPlayers();
    widget.onChanged?.call();
  }

  // The categories this parent's players actually belong to, derived from
  // the shared roster — so an admin reassigning a player's category
  // immediately changes which announcements reach this parent.
  List<String> get _myCategories =>
      myPlayers.expand((p) => p.categories).toSet().toList();

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadAnnouncements();
      await loadPlayers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
    widget.onChanged?.call();
  }

  /// The announcements this parent should actually see: club-wide ones,
  /// plus any aimed at a category, training or tournament one of their
  /// players is in (matched by player id, never by name).
  List<MessageThread> get _visibleThreads => mockAnnouncements
      .where(
        (a) => a.isVisibleTo(
          categories: _myCategories.toSet(),
          playerIds: myAllPlayerIds,
        ),
      )
      .map(
        (a) => MessageThread(
          announcement: a,
          preview: a.body,
          body: a.body,
          time: a.time,
          title: a.title,
        ),
      )
      .toList();

  void _openMessage(MessageThread thread) {
    if (!thread.announcement.isRead) {
      markAnnouncementRead(thread.announcement);
      setState(() {});
      widget.onChanged?.call();
    }
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _MessageDialog(thread: thread),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threads = _visibleThreads;

    return Container(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: const Text(
                "MESSAGES",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : threads.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.forum_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No messages yet.",
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: threads.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => FadeSlideIn(
                        index: index,
                        child: _MessageTile(
                          thread: threads[index],
                          onOpen: () => _openMessage(threads[index]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final MessageThread thread;
  final VoidCallback onOpen;

  const _MessageTile({required this.thread, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    // The whole tile opens the message. There is no arrow: it added nothing
    // to aim at, and the tile itself is the target.
    return Pressable(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // What kind of message it is, before reading a word: the club's
              // own messages, a change to a session, or a cancellation.
              CircleAvatar(
                radius: 24,
                backgroundColor: _kindOf(thread).color.withValues(alpha: 0.15),
                child: Icon(
                  _kindOf(thread).icon,
                  color: _kindOf(thread).color,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title, preview, date. Nothing about who it was addressed to:
                    // that is the admin's concern, not the parent's.
                    Text(
                      thread.title.isEmpty ? "Announcement" : thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      thread.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      thread.time,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // Not opened yet. Nothing told a parent which messages were
              // new, and with no notifications this list is where they look.
              if (!thread.announcement.isRead)
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Kind = ({IconData icon, Color color, String? tag});

_Kind _kindOf(MessageThread thread) => switch (thread.announcement.autoKind) {
  'session_changed' => (
    icon: Icons.update,
    color: Colors.amber,
    tag: "SCHEDULE CHANGE",
  ),
  'sessions_added' => (
    icon: Icons.event_available,
    color: _accent,
    tag: "NEW SESSION",
  ),
  'sessions_cancelled' || 'tournament_cancelled' => (
    icon: Icons.event_busy,
    color: Colors.redAccent,
    tag: "CANCELLED",
  ),
  // A jersey number the family asked for was approved or declined.
  'jersey_number' => (icon: Icons.numbers, color: _accent, tag: "JERSEY"),
  // The academy marked a bill (training, tournament, order...) as paid.
  'payment_paid' => (icon: Icons.verified, color: _accent, tag: "PAID"),
  // The academy is waiting for the family to answer a tournament invite.
  'tournament_reminder' => (
    icon: Icons.emoji_events_outlined,
    color: Colors.amber,
    tag: "REMINDER",
  ),
  // Sent by the server on the child's birthday.
  'birthday' => (icon: Icons.cake, color: Colors.pinkAccent, tag: "BIRTHDAY"),
  _ => (icon: Icons.groups, color: Colors.white54, tag: null),
};

/// A message's text, easier to scan: paragraphs spaced apart, and a line
/// like "New time: 4:00 PM to 6:00 PM" shown as a quiet label with the
/// value in bold, so the new time or place is what the eye lands on.
/// Anything else reads exactly as written.
class _MessageBody extends StatelessWidget {
  final String text;

  const _MessageBody({required this.text});

  static final _labelled = RegExp(r"^([A-Z][A-Za-z' ]{1,18}):\s+(.+)$");

  @override
  Widget build(BuildContext context) {
    final paragraphs = text.trim().split(RegExp(r'\n\s*\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in paragraphs[i].split('\n'))
                  _line(line, first: i == 0),
              ],
            ),
          ),
      ],
    );
  }

  Widget _line(String line, {required bool first}) {
    final match = _labelled.firstMatch(line.trim());
    if (match == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          line,
          style: TextStyle(
            color: Colors.white,
            fontSize: first ? 15 : 14,
            height: 1.4,
          ),
        ),
      );
    }
    final label = match.group(1)!;
    // "Was:" is the old value: shown quieter, so the new one stands out.
    final isOld = label == "Was";
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: "$label  ",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: match.group(2),
              style: TextStyle(
                color: isOld
                    ? Colors.white.withValues(alpha: 0.5)
                    : Colors.white,
                fontSize: 14,
                fontWeight: isOld ? FontWeight.normal : FontWeight.bold,
                decoration: isOld ? TextDecoration.lineThrough : null,
                decorationColor: Colors.white38,
              ),
            ),
          ],
        ),
        style: const TextStyle(height: 1.4),
      ),
    );
  }
}

/// A schedule change (or a new session) is one message to every family on that session, so
/// it can't name anyone's child in its text. The server sends each family
/// only its own children on it; they're added here, first, so the family
/// sees straight away which child the change is about.
String _withPlayers(MessageThread thread) {
  final players = thread.announcement.players;
  const aboutSessions = {'session_changed', 'sessions_added'};
  if (!aboutSessions.contains(thread.announcement.autoKind) ||
      players.isEmpty) {
    return thread.body;
  }
  final label = players.length == 1 ? "Player" : "Players";
  return "$label: ${players.map((p) => p.name).join(", ")}\n\n${thread.body}";
}

class _MessageDialog extends StatelessWidget {
  final MessageThread thread;

  const _MessageDialog({required this.thread});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      // A long announcement would otherwise run off the screen.
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_kindOf(thread).tag != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _kindOf(thread).color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _kindOf(thread).tag!,
                  style: TextStyle(
                    color: _kindOf(thread).color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              thread.title.isEmpty ? "Announcement" : thread.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              thread.time,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            _MessageBody(text: _withPlayers(thread)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accent, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  "CLOSE",
                  style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
