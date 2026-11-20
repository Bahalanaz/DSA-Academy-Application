import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/training_fee.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/dialog_body.dart';
import '../models/admin_player.dart';
import '../models/mock_roster.dart';
import '../models/mock_schedule.dart';
import 'add_players_screen.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class TrainingSession {
  /// The `sessions` row this attendance belongs to. Everything the roster
  /// screen saves is keyed to it.
  final String id;
  final String category;
  // The training program's full category list — a training can span
  // more than one (e.g. "B2012" and "B2013" together). Used to scope the
  // "add players" picker; [category] stays the display label.
  final List<String> categories;
  final String time;
  final String date;
  final String location;
  // Exactly who showed up to this specific session — set manually by the
  // admin from this screen, since attendance isn't the same group every
  // time a recurring training happens. Mutating this list (it's the same
  // instance the schedule holds) is what persists the roster.
  final List<String> playerNames;

  /// The roster by player ID — what everything here matches on, since two
  /// players can share a name. Lines up with [playerNames] index for index,
  /// and is the same list instance the schedule holds.
  final List<int> playerIds;

  /// The session's actual calendar day ([date] is only its display text).
  final DateTime? sessionDate;

  const TrainingSession({
    this.id = '',
    required this.category,
    this.categories = const [],
    required this.time,
    required this.date,
    required this.location,
    this.playerNames = const [],
    this.playerIds = const [],
    this.sessionDate,
  });

  /// Whether the session's day is still ahead. Nobody can be present or
  /// absent at something that hasn't happened, so those marks are locked
  /// until the day (the server enforces the same rule).
  /// Whether the session is in a month that has already ended, and so has
  /// already been billed.
  bool get isInBilledMonth {
    final d = sessionDate;
    if (d == null) return false;
    final now = serverNow();
    return DateTime(d.year, d.month).isBefore(DateTime(now.year, now.month));
  }

  bool get isUpcoming {
    final d = sessionDate;
    if (d == null) return false;
    final now = serverNow();
    return DateTime(
      d.year,
      d.month,
      d.day,
    ).isAfter(DateTime(now.year, now.month, now.day));
  }
}

class AttendanceRosterScreen extends StatefulWidget {
  final TrainingSession session;

  const AttendanceRosterScreen({super.key, required this.session});

  @override
  State<AttendanceRosterScreen> createState() => _AttendanceRosterScreenState();
}

enum AttendanceStatus { unmarked, present, absent, exempt }

class _AttendanceRosterScreenState extends State<AttendanceRosterScreen> {
  // Keyed by player id, never by name.
  final Map<int, AttendanceStatus> _statuses = {};
  Map<int, AttendanceStatus>? _draftStatuses;

  bool get _editMode => _draftStatuses != null;

  // Exactly the players the admin has added to THIS session — recomputed
  // live off the session's own list so it reflects additions immediately.
  List<AdminPlayer> get _roster =>
      mockRoster.where((p) => widget.session.playerIds.contains(p.id)).toList();

  @override
  void initState() {
    super.initState();
    _loadMarks();
  }

  /// Marks already saved for this session come back from the server, so
  /// reopening the screen shows what was actually recorded rather than
  /// resetting everyone to unmarked.
  Future<void> _loadMarks() async {
    for (final p in _roster) {
      _statuses[p.id] = AttendanceStatus.unmarked;
    }
    try {
      final saved = await loadAttendance(widget.session.id);
      saved.forEach((playerId, status) {
        _statuses[playerId] = _statusFromName(status);
      });
    } catch (e) {
      _showError(e);
    }
    if (mounted) setState(() {});
  }

  AttendanceStatus _statusFromName(String name) => switch (name) {
    'present' => AttendanceStatus.present,
    'absent' => AttendanceStatus.absent,
    'exempt' => AttendanceStatus.exempt,
    _ => AttendanceStatus.unmarked,
  };

  String _statusToName(AttendanceStatus status) => switch (status) {
    AttendanceStatus.present => 'present',
    AttendanceStatus.absent => 'absent',
    AttendanceStatus.exempt => 'exempt',
    AttendanceStatus.unmarked => 'unmarked',
  };

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  /// The month this session counts towards.
  DateTime get _month {
    final d = widget.session.sessionDate;
    return d == null ? kCurrentMonth : DateTime(d.year, d.month);
  }

  /// Each player's saved totals for [_month] (every training that month,
  /// the same figures as their stats window), fetched when editing starts.
  /// Null until loaded.
  Map<int, MonthFees>? _monthTotals;

  Future<void> _loadMonthTotals() async {
    try {
      await loadMonthAttendance(_month);
      if (!mounted) return;
      setState(() {
        _monthTotals = {
          for (final p in _roster) p.id: monthlyAttendanceCounts(p, _month),
        };
      });
    } catch (_) {
      // The counts just don't show; marking still works.
    }
  }

  /// A player's month while editing: the saved totals with this session's
  /// saved mark taken out and the one being picked put in, so the numbers
  /// move as each button is tapped. Present and absent only count once
  /// the day has come, as on the server.
  ({int present, int absent, int exempt})? _liveTotals(int playerId) {
    final saved = _monthTotals?[playerId];
    if (saved == null) return null;
    var present = saved.present, absent = saved.absent, exempt = saved.exempt;
    void count(AttendanceStatus? status, int by) {
      switch (status) {
        case AttendanceStatus.present when !widget.session.isUpcoming:
          present += by;
        case AttendanceStatus.absent when !widget.session.isUpcoming:
          absent += by;
        case AttendanceStatus.exempt:
          exempt += by;
        default:
      }
    }

    count(_statuses[playerId], -1);
    count(_draftStatuses?[playerId], 1);
    return (
      present: present < 0 ? 0 : present,
      absent: absent < 0 ? 0 : absent,
      exempt: exempt < 0 ? 0 : exempt,
    );
  }

  void _enterEditMode() {
    setState(() => _draftStatuses = Map.of(_statuses));
    _loadMonthTotals();
  }

  void _cancelEdit() {
    setState(() => _draftStatuses = null);
  }

  /// Saves every mark for this session in one call, then reloads the
  /// roster so the monthly counts come back derived from the attendance
  /// table.
  ///
  /// This is also what fixes the old double-counting problem: the counts
  /// are no longer nudged up and down by hand here, so re-confirming the
  /// same session twice just writes the same rows again instead of
  /// inflating anyone's totals.
  Future<void> _confirmEdit() async {
    final draft = _draftStatuses!;
    try {
      await saveAttendance(widget.session.id, {
        for (final entry in draft.entries)
          entry.key: _statusToName(entry.value),
      });
      await loadPlayers();
      if (!mounted) return;
      setState(() {
        _statuses
          ..clear()
          ..addAll(draft);
        _draftStatuses = null;
      });
    } catch (e) {
      _showError(e);
    }
  }

  /// Tapping the mark a player already has clears it (back to unmarked).
  /// Without this, EXEMPT set on an upcoming session could never be taken
  /// off: it's the only button open before the day.
  void _setDraftStatus(int playerId, AttendanceStatus status) {
    setState(() {
      final current = _draftStatuses![playerId];
      _draftStatuses![playerId] = current == status
          ? AttendanceStatus.unmarked
          : status;
    });
  }

  Future<void> _addPlayers() async {
    final added = await Navigator.push<List<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddPlayersScreen(
          categoryLabel: widget.session.category,
          categories: widget.session.categories.isEmpty
              ? [widget.session.category]
              : widget.session.categories,
          alreadyAdded: widget.session.playerIds,
        ),
      ),
    );
    if (added == null || added.isEmpty) return;
    try {
      await addPlayersToSessionById(widget.session.id, added);
      if (!mounted) return;
      setState(() {
        for (final playerId in added) {
          if (!widget.session.playerIds.contains(playerId)) {
            widget.session.playerIds.add(playerId);
            widget.session.playerNames.add(playerNameFor(playerId));
          }
          _statuses[playerId] = AttendanceStatus.unmarked;
          _draftStatuses?[playerId] = AttendanceStatus.unmarked;
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  /// One tap on the X used to take a player off with no prompt.
  Future<void> _removePlayer(int playerId) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove ${playerNameFor(playerId)}?",
      message:
          "They'll be taken off this session's roster and any attendance "
          "mark for it is cleared, so they aren't charged for this session.",
      confirmLabel: "REMOVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    try {
      await removePlayerFromSessionById(widget.session.id, playerId);
      if (!mounted) return;
      setState(() {
        final index = widget.session.playerIds.indexOf(playerId);
        if (index >= 0) {
          widget.session.playerIds.removeAt(index);
          if (index < widget.session.playerNames.length) {
            widget.session.playerNames.removeAt(index);
          }
        }
        _statuses.remove(playerId);
        _draftStatuses?.remove(playerId);
      });
    } catch (e) {
      _showError(e);
    }
  }

  void _showPlayerStats(AdminPlayer player) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _PlayerStatsDialog(
        player: player,
        sessionStatus: _statuses[player.id] ?? AttendanceStatus.unmarked,
        trainingLabel: widget.session.category,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roster = _roster;
    final markedCount = _statuses.values
        .where((s) => s != AttendanceStatus.unmarked)
        .length;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: Text(
          "${widget.session.category} ROSTER",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addPlayers,
        backgroundColor: _accent,
        shape: const CircleBorder(),
        child: const Icon(Icons.person_add_alt_1, color: Colors.white),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  if (_editMode)
                    IconButton(
                      onPressed: _cancelEdit,
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white54,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  Expanded(
                    child: Text(
                      "$markedCount/${roster.length} marked",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: _accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _editMode ? _confirmEdit : _enterEditMode,
                    icon: Icon(
                      _editMode ? Icons.check : Icons.edit_outlined,
                      color: _editMode ? _accent : Colors.white54,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // Editing an old month re-prices bills families may already have
            // paid, which happened with no hint that it would.
            if (widget.session.isInBilledMonth)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.lightBlueAccent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.lightBlueAccent.withValues(alpha: 0.35),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      color: Colors.lightBlueAccent,
                      size: 18,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "This month has already been billed. Changing marks "
                        "updates those bills, so a family may end up owing "
                        "more or be due a refund.",
                        style: TextStyle(
                          color: Colors.lightBlueAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.session.isUpcoming)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, color: Colors.amber, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "This session is on ${widget.session.date}. Present "
                        "and absent open on the day; you can mark players "
                        "exempt now.",
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: roster.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          "No players added to this training yet.\n"
                          "Tap + to add players.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 84),
                      itemCount: roster.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final player = roster[index];
                        final status =
                            (_editMode
                                ? _draftStatuses![player.id]
                                : _statuses[player.id]) ??
                            AttendanceStatus.unmarked;
                        return _RosterRow(
                          player: player,
                          status: status,
                          editMode: _editMode,
                          lockPresence: widget.session.isUpcoming,
                          monthLabel: _monthNames[_month.month - 1],
                          monthTotals: _editMode
                              ? _liveTotals(player.id)
                              : null,
                          onChanged: (s) => _setDraftStatus(player.id, s),
                          onRemove: () => _removePlayer(player.id),
                          onTap: () => _showPlayerStats(player),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RosterRow extends StatelessWidget {
  final AdminPlayer player;
  final AttendanceStatus status;
  final bool editMode;

  /// True for a session that hasn't happened yet: PRESENT and ABSENT are
  /// disabled, EXEMPT (excused in advance) still works.
  final bool lockPresence;
  final ValueChanged<AttendanceStatus> onChanged;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  /// While editing: the player's present / absent / exempt for the month,
  /// as they'll be once saved. Null hides them.
  final ({int present, int absent, int exempt})? monthTotals;
  final String monthLabel;

  const _RosterRow({
    required this.player,
    required this.status,
    required this.editMode,
    this.lockPresence = false,
    this.monthTotals,
    this.monthLabel = '',
    required this.onChanged,
    required this.onRemove,
    required this.onTap,
  });

  static const _colors = {
    AttendanceStatus.present: _accent,
    AttendanceStatus.absent: Colors.redAccent,
    AttendanceStatus.exempt: Colors.amber,
  };

  static const _icons = {
    AttendanceStatus.present: Icons.check_circle,
    AttendanceStatus.absent: Icons.cancel,
    AttendanceStatus.exempt: Icons.event_busy,
  };

  @override
  Widget build(BuildContext context) {
    final statusColor = _colors[status];
    final showStatus = statusColor != null && !editMode;

    return Pressable(
      enabled: !editMode,
      child: InkWell(
        onTap: editMode ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: showStatus ? statusColor.withValues(alpha: 0.08) : _card,
            borderRadius: BorderRadius.circular(14),
            border: showStatus
                ? Border.all(color: statusColor.withValues(alpha: 0.35))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 36,
                    decoration: BoxDecoration(
                      color: showStatus ? statusColor : Colors.white12,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ProfilePhoto(url: player.photoUrl, radius: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      player.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showStatus)
                    Icon(_icons[status], color: statusColor, size: 20),
                  if (editMode)
                    IconButton(
                      onPressed: onRemove,
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white38,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
              if (editMode) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _StatusButton(
                        label: "PRESENT",
                        color: _accent,
                        selected: status == AttendanceStatus.present,
                        onTap: lockPresence
                            ? null
                            : () => onChanged(AttendanceStatus.present),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _StatusButton(
                        label: "ABSENT",
                        color: Colors.redAccent,
                        selected: status == AttendanceStatus.absent,
                        onTap: lockPresence
                            ? null
                            : () => onChanged(AttendanceStatus.absent),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _StatusButton(
                        label: "EXEMPT",
                        color: Colors.amber,
                        selected: status == AttendanceStatus.exempt,
                        onTap: () => onChanged(AttendanceStatus.exempt),
                      ),
                    ),
                  ],
                ),
                if (monthTotals case final totals?) ...[
                  const SizedBox(height: 8),
                  _MonthTotalsStrip(label: monthLabel, totals: totals),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

const _monthNames = [
  "JANUARY",
  "FEBRUARY",
  "MARCH",
  "APRIL",
  "MAY",
  "JUNE",
  "JULY",
  "AUGUST",
  "SEPTEMBER",
  "OCTOBER",
  "NOVEMBER",
  "DECEMBER",
];

/// Under a player's buttons while editing: their month so far, the same
/// three numbers as their stats window, changing as each mark is tapped.
class _MonthTotalsStrip extends StatelessWidget {
  final String label;
  final ({int present, int absent, int exempt}) totals;

  const _MonthTotalsStrip({required this.label, required this.totals});

  @override
  Widget build(BuildContext context) {
    Widget stat(String name, int count, Color color) => Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            name,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          // The number pops when it changes, so the update is noticed.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Text(
              "$count",
              key: ValueKey(count),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            "$label SO FAR",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              stat("PRESENT", totals.present, _accent),
              stat("ABSENT", totals.absent, Colors.redAccent),
              stat("EXEMPT", totals.exempt, Colors.amber),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;

  /// Null disables the button (drawn faded).
  final VoidCallback? onTap;

  const _StatusButton({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(opacity: onTap == null ? 0.35 : 1, child: _buildButton());
  }

  Widget _buildButton() {
    return Pressable(
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? color : Colors.white24),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? color : Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerStatsDialog extends StatefulWidget {
  final AdminPlayer player;
  final AttendanceStatus sessionStatus;
  final String trainingLabel;

  const _PlayerStatsDialog({
    required this.player,
    required this.sessionStatus,
    required this.trainingLabel,
  });

  @override
  State<_PlayerStatsDialog> createState() => _PlayerStatsDialogState();
}

class _PlayerStatsDialogState extends State<_PlayerStatsDialog> {
  late DateTime _selectedMonth = kCurrentMonth;
  bool _loadingMonth = false;

  /// Fetches the chosen month's attendance. Changing month used to only
  /// relabel the header — any month but this one showed all zeros and an
  /// AED 0.00 fee, whatever the player had actually attended.
  Future<void> _showMonth(DateTime month) async {
    setState(() {
      _selectedMonth = month;
      _loadingMonth = true;
    });
    try {
      final current = kCurrentMonth;
      if (month.year != current.year || month.month != current.month) {
        await loadMonthAttendance(month);
      }
    } catch (_) {
      // The figures fall back to zero; the header still names the month.
    }
    if (mounted) setState(() => _loadingMonth = false);
  }

  void _goToPreviousMonth() {
    _showMonth(DateTime(_selectedMonth.year, _selectedMonth.month - 1));
  }

  void _goToNextMonth() {
    _showMonth(DateTime(_selectedMonth.year, _selectedMonth.month + 1));
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _accent,
              onPrimary: Colors.white,
              surface: _card,
              onSurface: Colors.white,
            ),
            dialogTheme: const DialogThemeData(backgroundColor: _bg),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      await _showMonth(DateTime(picked.year, picked.month));
    }
  }

  String get _statusLabel {
    switch (widget.sessionStatus) {
      case AttendanceStatus.present:
        return "Present";
      case AttendanceStatus.absent:
        return "Absent";
      case AttendanceStatus.exempt:
        return "Exempt";
      case AttendanceStatus.unmarked:
        return "Not marked yet";
    }
  }

  Color get _statusColor {
    switch (widget.sessionStatus) {
      case AttendanceStatus.present:
        return _accent;
      case AttendanceStatus.absent:
        return Colors.redAccent;
      case AttendanceStatus.exempt:
        return Colors.amber;
      case AttendanceStatus.unmarked:
        return Colors.white38;
    }
  }

  IconData get _statusIcon {
    switch (widget.sessionStatus) {
      case AttendanceStatus.present:
        return Icons.check_circle;
      case AttendanceStatus.absent:
        return Icons.cancel;
      case AttendanceStatus.exempt:
        return Icons.event_busy;
      case AttendanceStatus.unmarked:
        return Icons.help_outline;
    }
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
            Row(
              children: [
                ProfilePhoto(url: widget.player.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.player.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              "THIS TRAINING",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _statusColor.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(_statusIcon, color: _statusColor, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    _statusLabel,
                    style: TextStyle(
                      color: _statusColor,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // A multi-category program's label is long ("B2013,
                  // B2014, B2015 Training"), so it takes the rest of the row
                  // right-aligned and ellipsises rather than overflowing.
                  Expanded(
                    child: Text(
                      widget.trainingLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "OVERALL",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _goToPreviousMonth,
                  icon: const Icon(
                    Icons.chevron_left,
                    color: Colors.white54,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    "${_monthNames[_selectedMonth.month - 1]} "
                    "${_selectedMonth.year}",
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _pickMonth,
                  icon: const Icon(
                    Icons.calendar_today_outlined,
                    color: Colors.white54,
                    size: 15,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _goToNextMonth,
                  icon: const Icon(
                    Icons.chevron_right,
                    color: Colors.white54,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (_loadingMonth)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(color: _accent)),
              )
            else
              Builder(
                builder: (context) {
                  final counts = monthlyAttendanceCounts(
                    widget.player,
                    _selectedMonth,
                  );
                  final owed = trainingFeeOwed(counts);
                  return Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _MonthlyStat(
                                label: "PRESENT",
                                count: counts.present,
                                color: _accent,
                              ),
                            ),
                            Expanded(
                              child: _MonthlyStat(
                                label: "ABSENT",
                                count: counts.absent,
                                color: Colors.redAccent,
                              ),
                            ),
                            Expanded(
                              child: _MonthlyStat(
                                label: "EXEMPT",
                                count: counts.exempt,
                                color: Colors.amber,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            // The month's whole fee, before anything paid —
                            // "owed" read as what's still outstanding.
                            const Text(
                              "Month's training fee",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                "AED ${owed.toStringAsFixed(2)}",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                  color: _accent,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
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

class _MonthlyStat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _MonthlyStat({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "$count",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
