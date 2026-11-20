import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart' show serverNow;
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/date_picker_field.dart';
import '../../../core/widgets/option_sheet.dart';
import '../../../core/services/live_refresh.dart';
import 'tournament_standings_screen.dart' show OpponentPickerField;
import '../models/mock_roster.dart';
import '../models/mock_schedule.dart';
import '../models/mock_tournaments.dart';
import '../models/mock_trainings.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class AdminSchedule extends StatefulWidget {
  const AdminSchedule({super.key});

  @override
  State<AdminSchedule> createState() => _AdminScheduleState();
}

class _AdminScheduleState extends State<AdminSchedule>
    with LiveRefreshing<AdminSchedule> {
  @override
  Future<void> reloadQuietly() async {
    await loadSchedule();
    await loadTrainings();
    await loadTournaments();
  }

  DateTime _selectedDate = serverNow();
  bool _loading = true;
  bool _multiMode = false;
  final Set<DateTime> _multiDates = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadSchedule();
      await loadTrainings();
      // Tournaments too: the Add Session sheet picks a fixture's
      // tournament from this list, and without it the picker would come up
      // empty for an admin who hadn't happened to open the Tournaments
      // screen first this session.
      await loadTournaments();
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

  Map<DateTime, List<ScheduledSession>> get _grouped {
    final map = <DateTime, List<ScheduledSession>>{};
    for (final s in mockSchedule) {
      final key = dateOnly(s.date);
      map.putIfAbsent(key, () => []).add(s);
    }
    return map;
  }

  List<ScheduledSession> get _entriesForSelectedDate =>
      _grouped[dateOnly(_selectedDate)] ?? [];

  List<DateTime> get _weekDays {
    final startOfWeek = _selectedDate.subtract(
      Duration(days: _selectedDate.weekday - 1),
    );
    return List.generate(
      7,
      (i) => dateOnly(startOfWeek.add(Duration(days: i))),
    );
  }

  void _goToNextWeek() {
    setState(() => _selectedDate = _selectedDate.add(const Duration(days: 7)));
  }

  void _goToPreviousWeek() {
    setState(
      () => _selectedDate = _selectedDate.subtract(const Duration(days: 7)),
    );
  }

  void _onHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < 0) {
      _goToNextWeek();
    } else if (velocity > 0) {
      _goToPreviousWeek();
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
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
      setState(() => _selectedDate = picked);
    }
  }

  void _toggleMultiMode() {
    setState(() {
      _multiMode = !_multiMode;
      _multiDates.clear();
      if (_multiMode) _multiDates.add(dateOnly(_selectedDate));
    });
  }

  void _toggleDateSelection(DateTime day) {
    setState(() {
      final key = dateOnly(day);
      if (_multiDates.contains(key)) {
        _multiDates.remove(key);
      } else {
        _multiDates.add(key);
      }
    });
  }

  void _addSession() {
    if (_multiMode && _multiDates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Select at least one day first")),
      );
      return;
    }
    final dates = _multiMode ? (_multiDates.toList()..sort()) : [_selectedDate];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) =>
          _AddSessionSheet(dates: dates, onAdd: _onSessionsAdded),
    );
  }

  /// Tapping a session: change it, or cancel it. One that has already taken
  /// place can only be cancelled (if it didn't happen) — its day, time and
  /// place are what attendance and fees were worked out on.
  Future<void> _sessionActions(ScheduledSession session) async {
    final alreadyHappened = dateOnly(session.date)
        .isBefore(dateOnly(serverNow()));
    if (alreadyHappened) {
      await _cancelSession(session);
      return;
    }
    const edit = "Edit session";
    const cancel = "Cancel session";
    final picked = await showOptionSheet(
      context,
      title:
          "${session.type.toUpperCase()} · "
          "${formatAdminDate(session.date).toUpperCase()}",
      options: const [edit, cancel],
    );
    if (picked == null || !mounted) return;
    if (picked == edit) {
      await _editSession(session);
    } else {
      await _cancelSession(session);
    }
  }

  Future<void> _editSession(ScheduledSession session) async {
    final saved = await showModalBottomSheet<({DateTime date, bool notified})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _EditSessionSheet(session: session),
    );
    if (saved == null || !mounted) return;
    setState(() => _selectedDate = saved.date);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved.notified
              ? "Session updated. The families on it were sent a message."
              : "Session updated.",
        ),
      ),
    );
  }

  /// There was no way to take a session off the schedule, so one added by
  /// mistake stayed — and anyone rostered on it could still be billed.
  Future<void> _cancelSession(ScheduledSession session) async {
    // A session that already happened was charged for. Cancelling it takes
    // that charge off the month, which can leave families overpaid; the
    // prompt didn't say so.
    final alreadyHappened = dateOnly(session.date)
        .isBefore(dateOnly(serverNow()));
    final confirmed = await showConfirmDialog(
      context,
      title: "Cancel this session?",
      message:
          "${session.type} on ${formatAdminDate(session.date)} at "
          "${session.time} will be removed from the schedule for everyone. "
          "A cancelled session is never charged; any attendance already "
          "marked is kept on record."
          "${!alreadyHappened && session.playerIds.isNotEmpty ? "\n\nThe families of the ${session.playerIds.length} player${session.playerIds.length == 1 ? '' : 's'} on it will get a message. Cancel more sessions in the next few minutes and they're added to the same message." : ""}"
          "${alreadyHappened ? "\n\nThis session has already taken place. "
                    "Only cancel it if it didn't happen: that month's training "
                    "fees will be recalculated without it, and anything already "
                    "paid for it can be refunded from Training Fees." : ""}",
      confirmLabel: "CANCEL SESSION",
      cancelLabel: "KEEP IT",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await removeSession(session);
      // Fees depend on which sessions exist, so the roster's totals move.
      await loadPlayers();
      if (mounted) setState(() {});
      // A slip is one tap to undo. There was no way back: the session had
      // to be added again from scratch, and its roster and attendance
      // re-entered.
      messenger.showSnackBar(
        SnackBar(
          content: const Text("Session cancelled."),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: "UNDO",
            onPressed: () => _undoCancel(session),
          ),
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  /// Puts a just-cancelled session back, roster and attendance included.
  Future<void> _undoCancel(ScheduledSession session) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await restoreSession(session);
      await loadPlayers();
      if (!mounted) return;
      setState(() => _selectedDate = session.date);
      messenger.showSnackBar(
        const SnackBar(content: Text("Session put back on the schedule.")),
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _onSessionsAdded(List<ScheduledSession> entries) async {
    var failed = 0;
    String? firstError;
    for (final entry in entries) {
      try {
        await addSession(
          type: entry.type,
          trainingId: entry.trainingId,
          tournamentId: entry.tournamentId,
          categoryLabel: entry.category,
          date: entry.date,
          startTime: entry.time,
          endTime: entry.timeEnd,
          location: entry.location,
          opponent: entry.opponent,
        );
      } catch (e) {
        failed++;
        firstError ??= friendlyError(e);
      }
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _selectedDate = entries.last.date;
      _multiMode = false;
      _multiDates.clear();
    });
    if (failed > 0) {
      // The reason, not just the count — "already on the schedule" and
      // "that training was deleted" need different fixes.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            entries.length == 1
                ? firstError!
                : "$failed of ${entries.length} sessions couldn't be added: "
                      "$firstError",
          ),
        ),
      );
    } else if (entries.length > 1) {
      messenger.showSnackBar(
        SnackBar(content: Text("Added to ${entries.length} days.")),
      );
    }
  }

  static const _monthNames = [
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
  static const _weekdayLabels = [
    "MON",
    "TUE",
    "WED",
    "THU",
    "FRI",
    "SAT",
    "SUN",
  ];

  @override
  Widget build(BuildContext context) {
    final monthLabel =
        "${_monthNames[_selectedDate.month - 1]} ${_selectedDate.year}";
    final grouped = _grouped;
    final entries = _entriesForSelectedDate;

    return Container(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _pickDate,
                    icon: const Icon(
                      Icons.calendar_today_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _multiMode
                          ? "${_multiDates.length} DAY"
                                "${_multiDates.length == 1 ? '' : 'S'} SELECTED"
                          : "SCHEDULE",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleMultiMode,
                    tooltip: "Select multiple days",
                    icon: Icon(
                      _multiMode ? Icons.close : Icons.event_repeat,
                      color: _multiMode ? _accent : Colors.white,
                      size: 20,
                    ),
                  ),
                  IconButton(
                    onPressed: _addSession,
                    icon: const Icon(Icons.add, color: Colors.white, size: 24),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.event_note, color: _accent, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    monthLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _goToNextWeek,
                    icon: const Icon(
                      Icons.chevron_right,
                      color: Colors.white70,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            GestureDetector(
              onHorizontalDragEnd: _onHorizontalSwipe,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: _weekDays.map((day) {
                    final isMultiSelected =
                        _multiMode && _multiDates.contains(dateOnly(day));
                    final isSelected = _multiMode
                        ? isMultiSelected
                        : dateOnly(day) == dateOnly(_selectedDate);
                    final hasEvent =
                        (grouped[dateOnly(day)] ?? const []).isNotEmpty;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => _multiMode
                            ? _toggleDateSelection(day)
                            : setState(() => _selectedDate = day),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              width: double.infinity,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? _accent
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: _multiMode && !isSelected
                                    ? Border.all(color: Colors.white24)
                                    : null,
                                boxShadow: isSelected
                                    ? [
                                        BoxShadow(
                                          color: _accent.withValues(
                                            alpha: 0.35,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    _weekdayLabels[day.weekday - 1],
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white38,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "${day.day}",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (hasEvent)
                              Positioned(
                                top: -1,
                                right: 6,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.amber,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: _bg, width: 1.5),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_available_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 40,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "Nothing scheduled.\nTap + to add a session.",
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
                      key: ValueKey(_selectedDate),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) => _AdminScheduleCard(
                        entry: entries[index],
                        onTap: () => _sessionActions(entries[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminScheduleCard extends StatelessWidget {
  final ScheduledSession entry;

  /// Offers to cancel the session.
  final VoidCallback onTap;

  const _AdminScheduleCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isTournament = entry.type == "Tournament";

    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: isTournament ? _accent : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 78,
                child: entry.timeEnd == null
                    ? Text(
                        entry.time,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.time,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            "to",
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            entry.timeEnd!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.type,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.category,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    if (entry.opponent != null)
                      Text(
                        entry.opponent!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    Text(
                      entry.location,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddSessionSheet extends StatefulWidget {
  final List<DateTime> dates;
  final ValueChanged<List<ScheduledSession>> onAdd;

  const _AddSessionSheet({required this.dates, required this.onAdd});

  @override
  State<_AddSessionSheet> createState() => _AddSessionSheetState();
}

class _AddSessionSheetState extends State<_AddSessionSheet> {
  String _type = "Training";
  late DateTime _selectedDate;
  TrainingProgram? _selectedTraining;

  // A tournament fixture is a game IN a tournament, so it's picked from
  // the tournaments that already exist rather than typed as a birth-year
  // category — same as a training session picks its program. The category
  // then comes from the tournament itself, which is the only place it was
  // ever really decided.
  Tournament? _selectedTournament;
  final _timeController = TextEditingController(text: "5:00 PM");
  final _timeEndController = TextEditingController(text: "6:00 PM");
  final _locationController = TextEditingController(text: "DSA Gym");

  /// "vs. Lakers", picked from the tournament's Standings teams, or null.
  String? _opponent;

  static const _types = ["Training", "Tournament"];

  bool get _isMultiDate => widget.dates.length > 1;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.dates.first;
    if (mockTrainings.isNotEmpty) {
      _selectedTraining = mockTrainings.first;
    }
    if (mockTournaments.isNotEmpty) {
      _selectedTournament = mockTournaments.first;
    }
  }

  Future<void> _pickSessionDate() async {
    final picked = await showAdminDatePicker(
      context,
      initialDate: _selectedDate,
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _pickTraining() async {
    final picked = await showModalBottomSheet<TrainingProgram>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Capped and scrollable: the club can have any number of trainings,
      // and a plain Column would burst the sheet once they stop fitting.
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "SELECT TRAINING",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              if (mockTrainings.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    "No trainings yet. Create one first from "
                    "Home > Trainings.",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                )
              else
                ...mockTrainings.map(
                  (t) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => Navigator.pop(context, t),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: t.id == _selectedTraining?.id
                                ? _accent
                                : Colors.white12,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.sports_basketball_outlined,
                                color: _accent,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    t.categoryLabel,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 11,
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
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() => _selectedTraining = picked);
    }
  }

  Future<void> _pickTournament() async {
    final picked = await showModalBottomSheet<Tournament>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Capped and scrollable for the same reason as the training picker:
      // however many tournaments the club runs, the sheet has to hold.
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "SELECT TOURNAMENT",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              if (mockTournaments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    "No tournaments yet. Create one first from "
                    "Home > Tournaments.",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                )
              else
                ...mockTournaments.map(
                  (t) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => Navigator.pop(context, t),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: t.id == _selectedTournament?.id
                                ? _accent
                                : Colors.white12,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.emoji_events_outlined,
                                color: _accent,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    t.category,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 11,
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
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        // The teams are per tournament, so another one's opponent can't stay.
        if (picked.id != _selectedTournament?.id) _opponent = null;
        _selectedTournament = picked;
      });
    }
  }

  @override
  void dispose() {
    _timeController.dispose();
    _timeEndController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_type == "Training" && _selectedTraining == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Please select a training")));
      return;
    }
    // Not optional: the database rejects a tournament session with no
    // tournament behind it, so catching it here beats a failed save.
    if (_type == "Tournament" && _selectedTournament == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a tournament")),
      );
      return;
    }
    final start = parseDisplayTime(_timeController.text);
    final end = _type == "Training"
        ? parseDisplayTime(_timeEndController.text)
        : null;
    if (start == null || (_type == "Training" && end == null)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Enter times like 5:00 PM")));
      return;
    }
    if (end != null && end <= start) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("The end time must be after the start time"),
        ),
      );
      return;
    }
    final dates = _isMultiDate ? widget.dates : [_selectedDate];
    widget.onAdd(
      dates
          .map(
            (date) => ScheduledSession(
              date: date,
              time: _timeController.text.trim(),
              timeEnd: _type == "Training"
                  ? _timeEndController.text.trim()
                  : null,
              type: _type,
              // Either way the category comes from the thing being
              // scheduled, never typed separately — one source of truth.
              category: _type == "Training"
                  ? _selectedTraining!.categoryLabel
                  : _selectedTournament!.category,
              location: _locationController.text.trim(),
              opponent: _type == "Tournament" ? _opponent : null,
              trainingId: _type == "Training" ? _selectedTraining!.id : null,
              tournamentId: _type == "Tournament"
                  ? _selectedTournament!.id
                  : null,
            ),
          )
          .toList(),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "ADD SESSION",
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 18),
          _FieldLabel("Type"),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: _types.map((t) {
              final isSelected = _type == t;
              return ChoiceChip(
                label: Text(t),
                selected: isSelected,
                onSelected: (_) => setState(() => _type = t),
                backgroundColor: _bg,
                selectedColor: _accent,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(color: isSelected ? _accent : Colors.white24),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          if (_isMultiDate)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.event_repeat, color: _accent, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "${widget.dates.length} days selected — this will be "
                      "added to each one",
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            )
          else
            DatePickerField(
              label: "Date",
              value: _selectedDate,
              onTap: _pickSessionDate,
            ),
          const SizedBox(height: 16),
          if (_type == "Training") ...[
            _FieldLabel("Training"),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickTraining,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.sports_basketball_outlined,
                      color: _selectedTraining == null
                          ? Colors.white38
                          : _accent,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    // Expanded + ellipsis: a program covering several
                    // categories reads "B2013, B2014, B2015 Training",
                    // which is already wider than the field on a small
                    // phone — unbounded it would overflow the sheet.
                    Expanded(
                      child: Text(
                        _selectedTraining == null
                            ? "Select a training"
                            : _selectedTraining!.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedTraining == null
                              ? Colors.white38
                              : Colors.white,
                          fontSize: 14,
                          fontWeight: _selectedTraining == null
                              ? FontWeight.normal
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            _FieldLabel("Tournament"),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickTournament,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.emoji_events_outlined,
                      color: _selectedTournament == null
                          ? Colors.white38
                          : _accent,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    // Expanded so a long tournament name ellipsises rather
                    // than overflowing the sheet.
                    Expanded(
                      child: Text(
                        _selectedTournament == null
                            ? "Select a tournament"
                            : _selectedTournament!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _selectedTournament == null
                              ? Colors.white38
                              : Colors.white,
                          fontSize: 14,
                          fontWeight: _selectedTournament == null
                              ? FontWeight.normal
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_selectedTournament != null)
                      Text(
                        _selectedTournament!.category,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (_type == "Training")
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: "Time Start",
                    controller: _timeController,
                    endController: _timeEndController,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimeField(
                    label: "Time End",
                    controller: _timeEndController,
                  ),
                ),
              ],
            )
          else
            _TimeField(label: "Time", controller: _timeController),
          const SizedBox(height: 14),
          _SheetField(label: "Location", controller: _locationController),
          if (_type == "Tournament") ...[
            const SizedBox(height: 14),
            OpponentPickerField(
              tournamentId: _selectedTournament?.id,
              value: _opponent,
              onChanged: (value) => setState(() => _opponent = value),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                "ADD TO SCHEDULE",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Changes one session's day, times and place (and opponent, for a game).
/// Which training or tournament it belongs to, and so who is on it, stays.
class _EditSessionSheet extends StatefulWidget {
  final ScheduledSession session;

  const _EditSessionSheet({required this.session});

  @override
  State<_EditSessionSheet> createState() => _EditSessionSheetState();
}

class _EditSessionSheetState extends State<_EditSessionSheet> {
  late DateTime _date = widget.session.date;
  late final _timeController = TextEditingController(text: widget.session.time);
  late final _timeEndController = TextEditingController(
    text: widget.session.timeEnd ?? "",
  );
  late final _locationController = TextEditingController(
    text: widget.session.location,
  );

  /// "vs. Lakers", picked from the tournament's Standings teams, or null.
  /// An older game may still have one that was typed in; it stays until
  /// another is picked.
  late String? _opponent = _cleanOpponent(widget.session.opponent);
  bool _saving = false;

  static String? _cleanOpponent(String? raw) {
    final text = raw?.trim() ?? "";
    return text.isEmpty ? null : text;
  }

  bool get _isTraining => widget.session.type == "Training";

  @override
  void dispose() {
    _timeController.dispose();
    _timeEndController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showAdminDatePicker(context, initialDate: _date);
    if (picked != null) setState(() => _date = picked);
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final session = widget.session;
    final start = parseDisplayTime(_timeController.text);
    final end = _isTraining ? parseDisplayTime(_timeEndController.text) : null;
    if (start == null || (_isTraining && end == null)) {
      _say("Enter times like 5:00 PM");
      return;
    }
    if (end != null && end <= start) {
      _say("The end time must be after the start time");
      return;
    }
    if (dateOnly(_date).isBefore(dateOnly(serverNow()))) {
      _say("A session can only be moved to today or a later day");
      return;
    }
    final location = _locationController.text.trim();
    final opponent = _opponent ?? "";
    final changed =
        dateOnly(_date) != dateOnly(session.date) ||
        start != parseDisplayTime(session.time) ||
        (_isTraining && end != parseDisplayTime(session.timeEnd ?? "")) ||
        location != session.location.trim() ||
        (!_isTraining && opponent != (session.opponent ?? "").trim());
    if (!changed) {
      Navigator.pop(context);
      return;
    }
    // Families are messaged about it, so make sure first.
    final players = session.playerIds.length;
    final confirmed = await showConfirmDialog(
      context,
      title: "Save these changes?",
      message: players == 0
          ? "Nobody is on this session yet, so no one will be messaged."
          : "The families of the $players player${players == 1 ? '' : 's'} "
                "on it will get a message saying what changed.",
      confirmLabel: "SAVE",
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      final notified = await updateSession(
        session,
        date: _date,
        startTime: _timeController.text.trim(),
        endTime: _isTraining ? _timeEndController.text.trim() : null,
        location: location,
        opponent: _isTraining ? null : opponent,
      );
      if (!mounted) return;
      Navigator.pop(context, (date: _date, notified: notified));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _say(friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isTraining ? "EDIT TRAINING" : "EDIT GAME",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              session.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            DatePickerField(label: "Date", value: _date, onTap: _pickDate),
            const SizedBox(height: 16),
            if (_isTraining)
              Row(
                children: [
                  Expanded(
                    child: _TimeField(
                      label: "Time Start",
                      controller: _timeController,
                      endController: _timeEndController,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TimeField(
                      label: "Time End",
                      controller: _timeEndController,
                    ),
                  ),
                ],
              )
            else
              _TimeField(label: "Time", controller: _timeController),
            const SizedBox(height: 14),
            _SheetField(label: "Location", controller: _locationController),
            if (!_isTraining) ...[
              const SizedBox(height: 14),
              OpponentPickerField(
                tournamentId: session.tournamentId,
                value: _opponent,
                onChanged: (value) => setState(() => _opponent = value),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  _saving ? "SAVING..." : "SAVE CHANGES",
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

/// A time of day picked from a clock instead of typed ("5pm", "17:00" and
/// "5.00" were all refused). Shows [controller]'s text and writes the pick
/// back as "4:00 PM", the form the sheets already read and send.
///
/// Given an [endController] (on a start time), moving the start moves the
/// end with it, keeping the session the same length, the way calendar apps
/// do: pushing a 5-6 PM session to 7 PM makes it 7-8 PM, not "ends before
/// it starts".
class _TimeField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextEditingController? endController;

  const _TimeField({
    required this.label,
    required this.controller,
    this.endController,
  });

  static String _display(int minutes) {
    final hour24 = (minutes ~/ 60) % 24;
    final minute = (minutes % 60).toString().padLeft(2, '0');
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return "$hour12:$minute ${hour24 < 12 ? 'AM' : 'PM'}";
  }

  Future<void> _pick(BuildContext context) async {
    final was = parseDisplayTime(controller.text);
    final current = was ?? 17 * 60;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: label.toUpperCase(),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            onPrimary: Colors.white,
            surface: _card,
            onSurface: Colors.white,
          ),
          timePickerTheme: TimePickerThemeData(
            backgroundColor: _card,
            // AM / PM: the chosen one filled green, like the hour and minute.
            dayPeriodColor: WidgetStateColor.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? _accent
                  : Colors.transparent,
            ),
            dayPeriodTextColor: WidgetStateColor.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.white
                  : Colors.white70,
            ),
            dayPeriodBorderSide: const BorderSide(color: _accent),
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    final start = picked.hour * 60 + picked.minute;
    controller.text = _display(start);

    final end = endController;
    if (end == null) return;
    final oldEnd = parseDisplayTime(end.text);
    final length = was != null && oldEnd != null && oldEnd > was
        ? oldEnd - was
        : 60;
    // Capped at 11:59 PM: a session can't run past midnight.
    final newEnd = start + length > 23 * 60 + 59
        ? 23 * 60 + 59
        : start + length;
    if (newEnd > start) end.text = _display(newEnd);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, color: _accent, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => Text(
                      value.text.trim().isEmpty ? "Select a time" : value.text,
                      style: TextStyle(
                        color: value.text.trim().isEmpty
                            ? Colors.white38
                            : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _SheetField({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          inputFormatters: [noEmoji],
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
