import 'package:flutter/material.dart';

import '../../../core/utils/training_fee.dart';

import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/mock_roster.dart';
import '../../admin/models/mock_schedule.dart';
import '../models/mock_parent_players.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class ParentSchedule extends StatefulWidget {
  const ParentSchedule({super.key});

  @override
  State<ParentSchedule> createState() => _ParentScheduleState();
}

class _ParentScheduleState extends State<ParentSchedule>
    with LiveRefreshing<ParentSchedule> {
  @override
  Future<void> reloadQuietly() async {
    await loadSchedule();
    await loadPlayers();
  }

  // Opens on today. This was pinned to a fixed date back when the schedule
  // was hard-coded mock data, which left the calendar sitting in a year
  // nothing was scheduled in — every visit started with scrolling back to
  // the present. Date-only, so "today" matches the day cells exactly.
  DateTime _selectedDate = _dateOnly(serverNow());

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Loaded every time the tab opens. It used to rely only on the login
  /// warm-up, so a session the admin scheduled afterwards never appeared —
  /// and if the warm-up hadn't finished yet, the calendar started empty.
  Future<void> _refresh() async {
    try {
      await loadSchedule();
      await loadPlayers();
    } catch (_) {
      // Keeps showing whatever is already loaded.
    }
    if (mounted) setState(() {});
  }

  /// Only what concerns this parent's own players. A session counts if one
  /// of their players is on its roster; if the admin hasn't built a roster
  /// for it yet, fall back to matching the session's category so an
  /// upcoming session isn't invisible until rosters are filled in.
  bool _concernsMyPlayers(ScheduledSession session) {
    // By player id: two children can share a name. The server only sends
    // this parent's own children in the roster, so rosterCount is what
    // says whether the session has a roster at all.
    if (session.playerIds.any(myPlayerIds.contains)) return true;
    if (session.rosterCount > 0) return false;
    final myCategories = myPlayers.expand((p) => p.categories).toSet();
    return myCategories.any(session.category.contains);
  }

  /// Grouped off the same shared schedule the admin creates sessions in —
  /// no separate parent-side copy that could show a different calendar.
  Map<DateTime, List<ScheduledSession>> get _grouped {
    final map = <DateTime, List<ScheduledSession>>{};
    for (final session in mockSchedule.where(_concernsMyPlayers)) {
      map.putIfAbsent(dateOnly(session.date), () => []).add(session);
    }
    return map;
  }

  List<DateTime> get _weekDays {
    final startOfWeek = _selectedDate.subtract(
      Duration(days: _selectedDate.weekday - 1),
    );
    return List.generate(
      7,
      (i) => _dateOnly(startOfWeek.add(Duration(days: i))),
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
    // Grouped once per build — the week strip and the day list both read it.
    final grouped = _grouped;
    final entries = grouped[_dateOnly(_selectedDate)] ?? const [];

    return Container(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(width: 40),
                  const Expanded(
                    child: Text(
                      "SCHEDULE",
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
                    onPressed: _pickDate,
                    icon: const Icon(
                      Icons.calendar_today_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
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
                    final isSelected =
                        _dateOnly(day) == _dateOnly(_selectedDate);
                    final hasEvent =
                        (grouped[_dateOnly(day)] ?? const []).isNotEmpty;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedDate = day),
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
              child: entries.isEmpty
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
                            "Nothing scheduled on this date.",
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
                      itemBuilder: (context, index) => FadeSlideIn(
                        index: index,
                        child: _ScheduleCard(entry: entries[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  final ScheduledSession entry;

  const _ScheduleCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isTournament = entry.type == "Tournament";

    return Container(
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
            width: 68,
            child: Text(
              entry.displayTime,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
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
    );
  }
}
