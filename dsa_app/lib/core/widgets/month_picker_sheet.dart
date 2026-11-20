import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/date_format.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Pick a month: a year at a time, twelve months in a grid.
///
/// A flat list of every month works until a club has a few seasons behind it
/// and it's forty rows long. A grid is the same size forever, every month
/// keeps its place (March is always third), and the year steps with the
/// arrows. Pass [totals] and each month carries its figure, so the grid
/// doubles as the year at a glance.
///
/// Months outside [earliest]–[latest] are shown but can't be picked: money
/// can't move in a month that hasn't happened, or before the club's first
/// entry. Returns null if the sheet is dismissed.
Future<DateTime?> showMonthPicker(
  BuildContext context, {
  required DateTime selected,
  required DateTime earliest,
  required DateTime latest,
  Map<DateTime, double> totals = const {},
  String title = "JUMP TO MONTH",
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: _card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _MonthPickerSheet(
      selected: selected,
      earliest: DateTime(earliest.year, earliest.month),
      latest: DateTime(latest.year, latest.month),
      totals: totals,
      title: title,
    ),
  );
}

class _MonthPickerSheet extends StatefulWidget {
  final DateTime selected;
  final DateTime earliest;
  final DateTime latest;
  final Map<DateTime, double> totals;
  final String title;

  const _MonthPickerSheet({
    required this.selected,
    required this.earliest,
    required this.latest,
    required this.totals,
    required this.title,
  });

  @override
  State<_MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<_MonthPickerSheet> {
  late int _year = widget.selected.year;

  bool get _canGoBack => _year > widget.earliest.year;
  bool get _canGoForward => _year < widget.latest.year;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  onPressed: _canGoBack
                      ? () => setState(() => _year -= 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                  color: Colors.white70,
                  disabledColor: Colors.white24,
                ),
                Expanded(
                  child: Text(
                    "$_year",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _canGoForward
                      ? () => setState(() => _year += 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                  color: Colors.white70,
                  disabledColor: Colors.white24,
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.7,
              children: [
                for (var month = 1; month <= 12; month++)
                  _MonthCell(
                    month: DateTime(_year, month),
                    selected: widget.selected,
                    earliest: widget.earliest,
                    latest: widget.latest,
                    total: widget.totals[DateTime(_year, month)],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthCell extends StatelessWidget {
  final DateTime month;
  final DateTime selected;
  final DateTime earliest;
  final DateTime latest;
  final double? total;

  const _MonthCell({
    required this.month,
    required this.selected,
    required this.earliest,
    required this.latest,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final inRange = !month.isBefore(earliest) && !month.isAfter(latest);
    final isSelected = month == DateTime(selected.year, selected.month);
    final label = monthNames[month.month - 1].substring(0, 3).toUpperCase();

    return Material(
      color: isSelected ? _accent : _bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: inRange ? () => Navigator.pop(context, month) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? _accent : Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : inRange
                      ? Colors.white
                      : Colors.white24,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                // A month inside the range with nothing in it still reads as
                // a real month you can open; one outside it never happened.
                !inRange
                    ? "—"
                    : total == null
                    ? "—"
                    : "AED ${_grouped(total!)}",
                style: TextStyle(
                  color: isSelected
                      ? Colors.white70
                      : inRange
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white24,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "4298.75" -> "4,299". Whole AED only: the cell has room for the figure,
/// not the fils, and this is for recognising a month, not reconciling it.
String _grouped(double value) {
  final rounded = value.round();
  final digits = rounded.abs().toString();
  final out = StringBuffer(rounded < 0 ? "-" : "");
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(",");
    out.write(digits[i]);
  }
  return out.toString();
}
