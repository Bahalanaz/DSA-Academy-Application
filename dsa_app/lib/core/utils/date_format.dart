const monthNames = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

/// The first day of a month, as MySQL wants it ("2026-09-01"). Training
/// fees are keyed by month, and the DATE column that holds them stores the
/// month as its first day.
String toSqlMonth(DateTime month) =>
    "${month.year.toString().padLeft(4, '0')}-"
    "${month.month.toString().padLeft(2, '0')}-01";

/// Formats a [DateTime] as "May 24, 2025", prefixed with "Today, " when
/// it falls on the current calendar day.
String formatAdminDate(DateTime date) {
  final now = DateTime.now();
  final isToday =
      date.year == now.year && date.month == now.month && date.day == now.day;
  final formatted = "${monthNames[date.month - 1]} ${date.day}, ${date.year}";
  return isToday ? "Today, $formatted" : formatted;
}
