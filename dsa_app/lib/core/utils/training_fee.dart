import '../services/api_client.dart';
import 'date_format.dart';
import '../../features/admin/models/admin_player.dart';

/// Flat monthly coaches' fee, as of today. Admin-editable from the Training
/// Fees screen's settings icon; the database (fee_settings) is the source.
///
/// Never multiply this or [kPerSessionRate] into a total: the server prices
/// every month against its rate history (a change applies from the day it's
/// made; before October 2026 it also prorated a player's first month).
/// Use [trainingFeeOwed].
double kCoachFee = 100;

/// Per billable session, as of today. See [kCoachFee].
double kPerSessionRate = 31.25;

Future<void> loadFeeSettings() async {
  final row = await ApiClient.getMap('/fee-settings');
  kCoachFee = asDouble(row['coach_fee']);
  kPerSessionRate = asDouble(row['per_session_rate']);
  final serverTime = asDate(row['server_time']);
  if (serverTime != null) {
    _serverTime = serverTime;
    _serverTimeReadAt = DateTime.now();
  }
}

/// The server's clock as last read, and when (by this device's clock).
DateTime? _serverTime;
DateTime? _serverTimeReadAt;

/// Now, by the server's clock once it's known.
///
/// The phone's own clock decided "this month" before. A phone set to the
/// wrong date or time zone showed next month's fee on the 30th, and the
/// server then refused the payment because that month hadn't started.
DateTime serverNow() {
  final serverTime = _serverTime;
  final readAt = _serverTimeReadAt;
  if (serverTime == null || readAt == null) return DateTime.now();
  return serverTime.add(DateTime.now().difference(readAt));
}

/// Saves both rates, then keeps the in-memory copies in step so the
/// settings dialog shows the new values immediately.
Future<void> saveFeeSettings({
  required double coachFee,
  required double perSessionRate,
}) async {
  await ApiClient.put('/fee-settings', {
    'coachFee': coachFee,
    'perSessionRate': perSessionRate,
  });
  kCoachFee = coachFee;
  kPerSessionRate = perSessionRate;
}

/// The month the app treats as "now" for fees and attendance totals.
DateTime get kCurrentMonth {
  final now = serverNow();
  return DateTime(now.year, now.month);
}

/// One player's month: how many sessions, and what they came to.
///
/// [charges], [coachFee] and [coachFeeFull] are money the server worked out
/// from its rate history. [coachFee] is the same flat fee for everyone from
/// October 2026 (before then it was prorated in the month a player
/// joined); [coachFeeFull] is the unprorated figure, for display.
typedef MonthFees = ({
  int present,
  int absent,
  int exempt,
  int scheduled,
  double charges,
  double coachFee,
  double coachFeeFull,
});

const MonthFees _emptyMonth = (
  present: 0,
  absent: 0,
  exempt: 0,
  scheduled: 0,
  charges: 0,
  coachFee: 0,
  coachFeeFull: 0,
);

final Map<int, MonthFees> _monthAttendance = {};
DateTime? _loadedMonth;

/// Attendance and money for one specific month, fetched on demand. The
/// player list only carries the current month; call this before showing
/// any other.
Future<void> loadMonthAttendance(DateTime month) async {
  final rows = await ApiClient.getList(
    '/attendance-summary?month=${toSqlMonth(month)}',
  );
  _monthAttendance.clear();
  for (final row in rows.cast<Map<String, dynamic>>()) {
    _monthAttendance[asInt(row['player_id'])] = (
      present: asInt(row['present_count']),
      absent: asInt(row['absent_count']),
      exempt: asInt(row['exempt_count']),
      scheduled: asInt(row['scheduled_count']),
      charges: asDouble(row['session_charges']),
      coachFee: asDouble(row['coach_fee']),
      coachFeeFull: asDouble(row['coach_fee_full']),
    );
  }
  _loadedMonth = DateTime(month.year, month.month);
}

bool _isLoaded(DateTime month) =>
    _loadedMonth != null &&
    _loadedMonth!.year == month.year &&
    _loadedMonth!.month == month.month;

MonthFees monthlyAttendanceCounts(AdminPlayer player, DateTime month) {
  if (_isLoaded(month)) {
    return _monthAttendance[player.id] ?? _emptyMonth;
  }
  final current = kCurrentMonth;
  if (month.year == current.year && month.month == current.month) {
    return (
      present: player.monthlyPresent,
      absent: player.monthlyAbsent,
      exempt: player.monthlyExempt,
      scheduled: player.monthlyScheduled,
      charges: player.monthlyCharges,
      coachFee: player.monthlyCoachFee,
      coachFeeFull: player.monthlyCoachFeeFull,
    );
  }
  return _emptyMonth;
}

/// Sessions actually charged for. Exempt sessions cost nothing.
int billableSessions(MonthFees m) => m.present + m.absent;

/// Whether the coach fee was reduced because the player joined mid-month.
bool isCoachFeeProrated(MonthFees m) =>
    m.scheduled > 0 &&
    (m.coachFee * 100).round() < (m.coachFeeFull * 100).round();

/// Training fee owed for the month: the (possibly prorated) coach fee plus
/// what the billable sessions came to. A player who wasn't put on a single
/// session that month owes nothing — being rostered is what commits them.
double trainingFeeOwed(MonthFees m) {
  if (m.scheduled <= 0) return 0;
  return m.coachFee + m.charges;
}
