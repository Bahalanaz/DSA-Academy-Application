import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_announcements.dart';
import '../models/mock_categories.dart';
import '../models/mock_roster.dart';
import '../models/mock_schedule.dart';
import '../models/mock_tournaments.dart';
import '../models/mock_trainings.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

const _everyone = everyoneAudience;

/// What the compose sheet hands back: the message plus every audience
/// picked, by kind. Trainings and tournaments travel as ids.
typedef _Draft = ({
  String title,
  String body,
  List<String> audiences,
  List<String> trainingIds,
  List<String> tournamentIds,
});

class AdminMessages extends StatefulWidget {
  const AdminMessages({super.key});

  @override
  State<AdminMessages> createState() => _AdminMessagesState();
}

class _AdminMessagesState extends State<AdminMessages>
    with LiveRefreshing<AdminMessages> {
  @override
  Future<void> reloadQuietly() async {
    await loadAnnouncements();
    await loadSchedule();
    await loadPlayers();
  }

  List<SentAnnouncement> get _sent => mockAnnouncements;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Trainings, tournaments, the schedule and the roster are all needed by
  /// the compose sheet: the first two to offer as audiences, the last two
  /// to warn when the picked audience has nobody in it yet.
  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadAnnouncements();
      await loadCategories();
      await loadTrainings();
      await loadTournaments();
      await loadSchedule();
      await loadPlayers();
    } catch (e) {
      _showError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  // "Everyone" is a broadcast option, not a real category; the rest come
  // from the same shared category list every other screen uses.
  List<String> get _audiences => [_everyone, ...mockCategories];

  /// By the message itself, not its position in the list: the list is
  /// re-sorted whenever it reloads, and a position could then point at a
  /// different message by the time EDIT or DELETE was tapped.
  void _openMessage(SentAnnouncement message) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _MessageDialog(
        message: message,
        onEdit: () {
          Navigator.pop(context);
          _compose(existing: message);
        },
        onDelete: () async {
          Navigator.pop(context);
          // Asked first: one tap used to delete it for every parent.
          final confirmed = await showConfirmDialog(
            this.context,
            title: "Delete this announcement?",
            message:
                "\"${message.title}\" will disappear for every parent it was "
                "sent to.",
            confirmLabel: "DELETE",
            confirmColor: Colors.redAccent,
          );
          if (!confirmed) return;
          try {
            await removeAnnouncement(message);
            if (mounted) setState(() {});
          } catch (e) {
            _showError(e);
          }
        },
      ),
    );
  }

  void _compose({SentAnnouncement? existing}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ComposeSheet(
        initial: existing,
        audiences: _audiences,
        onSend: (draft) async {
          try {
            if (existing == null) {
              await addAnnouncement(
                title: draft.title,
                body: draft.body,
                audiences: draft.audiences,
                trainingIds: draft.trainingIds,
                tournamentIds: draft.tournamentIds,
              );
            } else {
              await updateAnnouncement(
                existing,
                title: draft.title,
                body: draft.body,
                audiences: draft.audiences,
                trainingIds: draft.trainingIds,
                tournamentIds: draft.tournamentIds,
              );
            }
            if (mounted) setState(() {});
          } catch (e) {
            _showError(e);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(width: 40),
                  const Expanded(
                    child: Text(
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
                  IconButton(
                    onPressed: _compose,
                    icon: const Icon(
                      Icons.edit_note,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : _sent.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.campaign_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No announcements yet.\nTap the icon to send one.",
                            textAlign: TextAlign.center,
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
                      itemCount: _sent.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => FadeSlideIn(
                        index: index,
                        child: _SentMessageTile(
                          message: _sent[index],
                          onTap: () => _openMessage(_sent[index]),
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

class _SentMessageTile extends StatelessWidget {
  final SentAnnouncement message;
  final VoidCallback onTap;

  const _SentMessageTile({required this.message, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.campaign_outlined,
              color: Colors.white70,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: (message.isEveryone ? Colors.white : _accent)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          message.audienceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: message.isEveryone
                                ? Colors.white70
                                : _accent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      message.time,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onTap,
            icon: const Icon(Icons.chevron_right, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class _MessageDialog extends StatelessWidget {
  final SentAnnouncement message;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MessageDialog({
    required this.message,
    required this.onEdit,
    required this.onDelete,
  });

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
            Text(
              message.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "To: ${message.audienceLabel}",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message.body,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onEdit,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _accent, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.edit_outlined,
                      color: _accent,
                      size: 16,
                    ),
                    label: const Text(
                      "EDIT",
                      style: TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDelete,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(
                        color: Colors.redAccent,
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                      size: 16,
                    ),
                    label: const Text(
                      "DELETE",
                      style: TextStyle(
                        color: Colors.redAccent,
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

class _ComposeSheet extends StatefulWidget {
  final SentAnnouncement? initial;
  final List<String> audiences;
  final ValueChanged<_Draft> onSend;

  const _ComposeSheet({
    this.initial,
    required this.audiences,
    required this.onSend,
  });

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  late final Set<String> _selectedAudiences;
  late final Set<String> _trainingIds;
  late final Set<String> _tournamentIds;
  late final List<AudienceRef> _trainingOptions;
  late final List<AudienceRef> _tournamentOptions;
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  bool _sending = false;

  bool get _isEditing => widget.initial != null;

  bool get _isEveryone => _selectedAudiences.contains(_everyone);

  /// Editing a message already addressed to named players (an automatic
  /// notice) or to one family (Send message): who it goes to is fixed. Its
  /// audience chips used to show, so one tap could turn a private family
  /// message into one for the whole club.
  bool get _isNamed =>
      (widget.initial?.players.isNotEmpty ?? false) ||
      (widget.initial?.recipients.isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _selectedAudiences = {
      ...(initial?.audiences ?? [_everyone]),
    };
    _trainingIds = {...?initial?.trainings.map((t) => t.id)};
    _tournamentIds = {...?initial?.tournaments.map((t) => t.id)};

    // Active trainings/tournaments, plus any the message being edited was
    // already sent to that have since been deleted — otherwise that
    // audience would be selected but invisible, and saving would drop it.
    _trainingOptions = [
      for (final t in mockTrainings) (id: t.id, name: t.displayName),
      ...?initial?.trainings.where(
        (ref) => !mockTrainings.any((t) => t.id == ref.id),
      ),
    ];
    _tournamentOptions = [
      for (final t in mockTournaments) (id: t.id, name: t.name),
      ...?initial?.tournaments.where(
        (ref) => !mockTournaments.any((t) => t.id == ref.id),
      ),
    ];

    _titleController = TextEditingController(text: initial?.title);
    _bodyController = TextEditingController(text: initial?.body);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  /// "Everyone" and targeted audiences are mutually exclusive: picking
  /// Everyone clears the rest, picking anything specific clears Everyone,
  /// and un-picking the last specific one falls back to Everyone so the
  /// message is never addressed to nobody.
  void _toggle(Set<String> set, String value) {
    setState(() {
      if (set.contains(value)) {
        set.remove(value);
      } else {
        set.add(value);
      }
      _selectedAudiences.remove(_everyone);
      if (_selectedAudiences.isEmpty &&
          _trainingIds.isEmpty &&
          _tournamentIds.isEmpty) {
        _selectedAudiences.add(_everyone);
      }
    });
  }

  void _toggleAudience(String a) {
    if (a == _everyone) {
      setState(() {
        _selectedAudiences
          ..clear()
          ..add(_everyone);
        _trainingIds.clear();
        _tournamentIds.clear();
      });
      return;
    }
    _toggle(_selectedAudiences, a);
  }

  /// Whether anyone at all would receive this right now. Uses what the
  /// app already has loaded; the server resolves the real list on read.
  bool get _reachesAnyone {
    if (_isEveryone) return true;
    // An automatic notice already goes to the players who were on what
    // changed, and a direct message to its family.
    if (_isNamed) return true;
    if (mockRoster.any((p) => p.categories.any(_selectedAudiences.contains))) {
      return true;
    }
    if (mockSchedule.any(
      (s) => _trainingIds.contains(s.trainingId) && s.playerNames.isNotEmpty,
    )) {
      return true;
    }
    return mockTournaments.any(
      (t) => _tournamentIds.contains(t.id) && t.playerNames.isNotEmpty,
    );
  }

  Future<void> _send() async {
    if (_sending) return;
    if (_titleController.text.trim().isEmpty ||
        _bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in a title and message")),
      );
      return;
    }

    // Not a hard block: players added to that training or tournament later
    // will still see the message. But sending into an empty audience is
    // usually a mis-tap, so check first.
    if (!_reachesAnyone) {
      final proceed = await showConfirmDialog(
        context,
        title: "No one to receive this yet",
        message:
            "No players are assigned to what you picked, so nobody will see "
            "this right now. Anyone added to it later will still get it.",
        confirmLabel: "SEND ANYWAY",
      );
      if (!proceed || !mounted) return;
    }

    _sending = true;
    widget.onSend((
      title: _titleController.text.trim(),
      body: _bodyController.text.trim(),
      audiences: widget.audiences.where(_selectedAudiences.contains).toList(),
      trainingIds: _isEveryone ? const [] : _trainingIds.toList(),
      tournamentIds: _isEveryone ? const [] : _tournamentIds.toList(),
    ));
    Navigator.pop(context);
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: _bg,
      selectedColor: _accent,
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.white70,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      side: BorderSide(color: selected ? _accent : Colors.white24),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    // Scrollable and capped: categories, every training and every
    // tournament as chips, plus two text fields and the keyboard, will
    // not fit on one screen once the club has a few of each.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: media.viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditing ? "EDIT ANNOUNCEMENT" : "NEW ANNOUNCEMENT",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 16),
            _label(_isNamed ? "Sent to" : "Send to"),
            const SizedBox(height: 8),
            if (_isNamed)
              Text(
                widget.initial!.audienceLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in widget.audiences)
                    _chip(
                      a,
                      _selectedAudiences.contains(a),
                      () => _toggleAudience(a),
                    ),
                ],
              ),
            if (!_isNamed && _trainingOptions.isNotEmpty) ...[
              const SizedBox(height: 14),
              _label("Trainings"),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _trainingOptions)
                    _chip(
                      t.name,
                      _trainingIds.contains(t.id),
                      () => _toggle(_trainingIds, t.id),
                    ),
                ],
              ),
            ],
            if (!_isNamed && _tournamentOptions.isNotEmpty) ...[
              const SizedBox(height: 14),
              _label("Tournaments"),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _tournamentOptions)
                    _chip(
                      t.name,
                      _tournamentIds.contains(t.id),
                      () => _toggle(_tournamentIds, t.id),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _ComposeField(label: "Title", controller: _titleController),
            const SizedBox(height: 12),
            _ComposeField(
              label: "Message",
              controller: _bodyController,
              maxLines: 4,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  _isEditing ? "SAVE CHANGES" : "SEND ANNOUNCEMENT",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
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

class _ComposeField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;

  const _ComposeField({
    required this.label,
    required this.controller,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          inputFormatters: [noEmoji],
          maxLines: maxLines,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: _bg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
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
        ),
      ],
    );
  }
}
