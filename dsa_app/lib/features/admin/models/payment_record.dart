import '../../../core/services/api_client.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart';
import 'admin_player.dart';

/// What kind of obligation a payment record represents.
enum PaymentType { trainingFee, tournament, misc }

/// How money arrived. 'online_test' marks a parent's in-app payment while
/// there is no real card processing yet; Stripe will replace it.
const paymentMethodLabels = {
  'cash': 'Cash',
  'card': 'Card',
  'bank': 'Bank transfer',
  'online_test': 'In-app (test)',
  'stripe': 'Card (Stripe)',
  'other': 'Other',
  // Money moved from one training fee to the next, not received or paid
  // out: see carryForwardCredit on the server.
  'credit': 'Credit carried over',
};

/// A single bill, backed by the `payments` table.
///
/// Every change to what's been paid goes through the server's transaction
/// log; this is just the current state of the bill.
class PaymentRecord {
  final String id;
  final int playerId;
  final String playerName;
  final PaymentType type;
  final String title;
  final String? description;
  final double amount;

  /// How much of [amount] has actually been handed over.
  double amountPaid;

  /// 'pending', 'paid', 'waived' or 'refunded'. (Voided rows are history
  /// only and never loaded.)
  String status;

  /// How the most recent payment on it arrived, if any.
  final String? method;
  final DateTime createdDate;
  final int? tournamentId;

  /// Training fees only: the first day of the month the fee covers.
  final DateTime? periodMonth;
  DateTime? paidDate;

  PaymentRecord({
    required this.id,
    this.playerId = 0,
    required this.playerName,
    required this.type,
    required this.title,
    this.description,
    required this.amount,
    this.amountPaid = 0,
    this.status = 'pending',
    this.method,
    required this.createdDate,
    this.tournamentId,
    this.periodMonth,
    this.paidDate,
  });

  bool get paid => status == 'paid';

  /// Still owed something. Waived and refunded bills are closed.
  bool get isOpen => status == 'pending';

  /// What's still owed on this one bill.
  double get remaining {
    if (!isOpen) return 0;
    final left = amount - amountPaid;
    return left < 0 ? 0 : left;
  }

  bool get partlyPaid => isOpen && amountPaid > 0;
}

const _typeFromSql = {
  'training_fee': PaymentType.trainingFee,
  'tournament': PaymentType.tournament,
  'misc': PaymentType.misc,
};

/// The stored payment_type as the app's enum. Anything unrecognised reads as
/// misc, which is where a bill with no other home belongs anyway.
PaymentType paymentTypeFromSql(Object? raw) =>
    _typeFromSql['$raw'] ?? PaymentType.misc;

const _typeToSql = {
  PaymentType.trainingFee: 'training_fee',
  PaymentType.tournament: 'tournament',
  PaymentType.misc: 'misc',
};

/// Every bill this user can see — all of them for an admin, only their own
/// family's for a parent (the server enforces that).
final List<PaymentRecord> mockPayments = [];

PaymentRecord _fromRow(Map<String, dynamic> row) => PaymentRecord(
  id: '${row['id']}',
  playerId: asInt(row['player_id']),
  playerName: row['player_name'] as String,
  type: _typeFromSql[row['payment_type']] ?? PaymentType.misc,
  title: row['title'] as String,
  description: row['description'] as String?,
  amount: asDouble(row['amount']),
  amountPaid: asDouble(row['amount_paid']),
  status: row['status'] as String? ?? 'pending',
  method: row['method'] as String?,
  createdDate: asDate(row['created_at']) ?? DateTime.now(),
  tournamentId: row['tournament_id'] == null
      ? null
      : asInt(row['tournament_id']),
  periodMonth: asDate(row['period_month']),
  paidDate: asDate(row['paid_at']),
);

/// Makes sure every finished month has been billed. The server also does
/// this on its own every hour; calling it just guarantees it's current.
Future<void> closeDueTrainingFees() async {
  await ApiClient.post('/training-fees/close');
}

Future<void> loadPayments() async {
  final rows = await ApiClient.getList('/payments');
  mockPayments
    ..clear()
    ..addAll(
      rows
          .cast<Map<String, dynamic>>()
          // A voided row is a payment that was undone; it only matters to
          // the history, never to what anyone owes or has paid.
          .where((row) => row['status'] != 'void')
          .map(_fromRow),
    );
}

/// Creates a tournament or misc bill (admin). [paid] records it as settled
/// straight away, by [method].
Future<void> addPayment({
  required int playerId,
  required PaymentType type,
  required String title,
  required double amount,
  String? description,
  String? miscType,
  int? tournamentId,
  DateTime? periodMonth,
  bool paid = false,
  String method = 'cash',
}) async {
  await ApiClient.post('/payments', {
    'playerId': playerId,
    'type': _typeToSql[type],
    'title': title,
    'amount': amount,
    'description': description,
    'miscType': miscType,
    'tournamentId': tournamentId,
    'periodMonth': periodMonth == null ? null : toSqlMonth(periodMonth),
    'paid': paid,
    'method': method,
  });
  await loadPayments();
}

/// Settles everything still owed on a bill, by hand (admin).
Future<void> markPaymentPaid(
  PaymentRecord record, {
  String method = 'cash',
}) async {
  await ApiClient.post('/payments/${record.id}/paid', {'method': method});
  await loadPayments();
}

/// Pays part (or all) of one bill. The server refuses more than what's
/// still owed. A parent's payment is recorded as in-app; an admin's by
/// [method].
Future<void> payTowards(
  PaymentRecord record,
  double amount, {
  String method = 'cash',
}) async {
  final result = await ApiClient.post('/payments/${record.id}/pay', {
    'amount': amount,
    'method': method,
  });
  record.amountPaid = asDouble(result['amountPaid']);
  record.status = result['status'] as String? ?? record.status;
  if (record.paid) record.paidDate = DateTime.now();
}

/// Undoes payments recorded by mistake (admin). Logged as a reversal; a
/// training fee's month is then recalculated.
Future<void> markPaymentUnpaid(PaymentRecord record) async {
  await ApiClient.post('/payments/${record.id}/unpaid');
  await loadPayments();
}

/// Hands money back on a tournament or misc bill (admin). Lowers what was
/// paid and what's charged by the same amount, so nothing new is owed.
Future<void> refundPayment(
  PaymentRecord record, {
  required double amount,
  String method = 'cash',
  String? note,
}) async {
  await ApiClient.post('/payments/${record.id}/refund', {
    'amount': amount,
    'method': method,
    'note': note,
  });
  await loadPayments();
}

/// Writes off what's still owed on a bill (admin).
Future<void> waivePayment(PaymentRecord record, {String? note}) async {
  await ApiClient.post('/payments/${record.id}/waive', {'note': note});
  await loadPayments();
}

/// One line of a bill's money history.
typedef PaymentHistoryEntry = ({
  /// The log row's id: the receipt number ("R-001493").
  int id,
  String kind,
  double amount,
  String? method,
  String? note,
  String? recordedBy,
  DateTime? at,
});

Future<List<PaymentHistoryEntry>> loadPaymentHistory(
  PaymentRecord record,
) async {
  final rows = await ApiClient.getList('/payments/${record.id}/transactions');
  return [
    for (final row in rows.cast<Map<String, dynamic>>())
      (
        id: asInt(row['id']),
        kind: row['kind'] as String,
        amount: asDouble(row['amount']),
        method: row['method'] as String?,
        note: row['note'] as String?,
        recordedBy: row['recorded_by'] as String?,
        at: asDate(row['created_at']),
      ),
  ];
}

// ---------------------------------------------------------------------------
// Per-player monthly overrides
// ---------------------------------------------------------------------------

// Keyed by player id, never by name.
String _monthKey(int playerId, DateTime month) =>
    "$playerId|${month.year}-${month.month}";

/// A custom total for one player's month (a discount, an arrangement).
final Map<String, double> _trainingFeeOverrides = {};

Future<void> loadTrainingFeeOverrides() async {
  final rows = await ApiClient.getList('/training-fee-overrides');
  _trainingFeeOverrides.clear();
  for (final row in rows.cast<Map<String, dynamic>>()) {
    final month = asDate(row['period_month']);
    if (month == null) continue;
    _trainingFeeOverrides[_monthKey(asInt(row['player_id']), month)] = asDouble(
      row['amount'],
    );
  }
}

double? trainingFeeOverride(AdminPlayer player, DateTime month) =>
    _trainingFeeOverrides[_monthKey(player.id, month)];

Future<void> setTrainingFeeOverride(
  AdminPlayer player,
  DateTime month,
  double amount,
) async {
  await ApiClient.put('/training-fee-overrides', {
    'playerId': player.id,
    'periodMonth': toSqlMonth(month),
    'amount': amount,
  });
  _trainingFeeOverrides[_monthKey(player.id, month)] = amount;
}

Future<void> clearTrainingFeeOverride(
  AdminPlayer player,
  DateTime month,
) async {
  await ApiClient.delete(
    '/training-fee-overrides/${player.id}/${toSqlMonth(month)}',
  );
  _trainingFeeOverrides.remove(_monthKey(player.id, month));
}

// ---------------------------------------------------------------------------
// The training fee itself
// ---------------------------------------------------------------------------

/// Every training-fee bill for this player and month.
List<PaymentRecord> _trainingFeeRows(int playerId, DateTime month) =>
    mockPayments
        .where(
          (p) =>
              p.type == PaymentType.trainingFee &&
              p.playerId == playerId &&
              p.periodMonth?.year == month.year &&
              p.periodMonth?.month == month.month,
        )
        .toList();

/// What was actually handed over for a month (part-payments included,
/// refunds already taken off).
double trainingFeePaidFor(AdminPlayer player, DateTime month) =>
    _trainingFeeRows(
      player.id,
      month,
    ).fold(0.0, (sum, p) => sum + p.amountPaid);

/// Whether a month has been closed off and billed.
bool trainingFeeIsBilled(AdminPlayer player, DateTime month) =>
    !_isCurrentMonth(month) && _trainingFeeRows(player.id, month).isNotEmpty;

bool _isCurrentMonth(DateTime month) {
  final current = kCurrentMonth;
  return month.year == current.year && month.month == current.month;
}

/// A month that hasn't started yet. Nothing in it is owed: its bill only
/// goes out once the month has ended, so "0 remaining" for it would read as
/// "paid" when it really means "not billed yet".
bool isFutureMonth(DateTime month) =>
    DateTime(month.year, month.month).isAfter(kCurrentMonth);

/// The month's full fee: a custom total if one is set, otherwise what the
/// server priced it at.
///
/// Nothing at all for a month the player wasn't on a single session, even
/// with a custom total set. The server bills it that way, and showing the
/// custom figure asked a parent for money the server then refused to take.
double trainingFeeTotal(AdminPlayer player, DateTime month) {
  final counts = monthlyAttendanceCounts(player, month);
  if (counts.scheduled <= 0) return 0;
  return trainingFeeOverride(player, month) ?? trainingFeeOwed(counts);
}

/// What's still owed for this player's training fee in [month].
///
/// Live for the current month (more sessions can still happen); for a
/// finished month, whatever is still open on its bill.
double unpaidTrainingFee(AdminPlayer player, DateTime month) {
  if (!_isCurrentMonth(month)) {
    return _trainingFeeRows(
      player.id,
      month,
    ).where((r) => r.isOpen).fold(0.0, (sum, r) => sum + r.remaining);
  }
  final remaining =
      trainingFeeTotal(player, month) - trainingFeePaidFor(player, month);
  return remaining < 0 ? 0 : remaining;
}

/// Money paid for a month beyond what it came to — typically after
/// attendance was corrected downwards. Zero for a month not yet started.
double trainingFeeOverpaid(AdminPlayer player, DateTime month) {
  if (isFutureMonth(month)) return 0;
  final over =
      trainingFeePaidFor(player, month) - trainingFeeTotal(player, month);
  return over > 0.004 ? over : 0;
}

/// Pays towards a month's training fee. The server works out what's owed
/// and refuses anything above it; [amount] defaults to all of it.
///
/// An [advance] (admin only, this month only) may be more than is owed:
/// the extra becomes credit, which the month close carries on to the next
/// training fee.
Future<void> markTrainingFeePaid(
  AdminPlayer player,
  DateTime month, {
  double? amount,
  String method = 'cash',
  bool advance = false,
}) async {
  final owed = unpaidTrainingFee(player, month);
  if (owed <= 0 && !advance) return;
  await ApiClient.post('/training-fees/pay', {
    'playerId': player.id,
    'periodMonth': toSqlMonth(month),
    'amount': amount ?? owed,
    'method': method,
    'advance': advance,
  });
  await loadPayments();
}

/// Forgives what's still owed for a month's training fee (admin) — this
/// month included, which has no bill of its own yet. What was paid stays
/// paid, and the month is fixed at that, so later sessions don't bring the
/// fee back.
Future<void> waiveTrainingFee(AdminPlayer player, DateTime month) async {
  await ApiClient.post('/training-fees/waive', {
    'playerId': player.id,
    'periodMonth': toSqlMonth(month),
  });
  await loadTrainingFeeOverrides();
  await loadPayments();
}

/// Money paid beyond what this month's training fee comes to — an advance,
/// or credit carried over from an earlier month. It goes towards the next
/// training fee automatically at the month close unless it's refunded first.
double trainingFeeCredit(AdminPlayer player) =>
    trainingFeeOverpaid(player, kCurrentMonth);

/// Gives back what was overpaid for a month (admin).
Future<void> refundTrainingFeeOverpayment(
  AdminPlayer player,
  DateTime month, {
  required double amount,
  String method = 'cash',
}) async {
  await ApiClient.post('/training-fees/refund', {
    'playerId': player.id,
    'periodMonth': toSqlMonth(month),
    'amount': amount,
    'method': method,
  });
  await loadPayments();
}

List<PaymentRecord> unpaidRecordsFor(AdminPlayer player) =>
    mockPayments.where((p) => p.playerId == player.id && p.isOpen).toList();

/// Bills with money on them — fully or partly paid.
List<PaymentRecord> paidRecordsFor(AdminPlayer player) => mockPayments
    .where((p) => p.playerId == player.id && p.amountPaid > 0)
    .toList();

/// What this player owes of one particular kind.
double pendingForType(AdminPlayer player, PaymentType type) {
  if (type == PaymentType.trainingFee) {
    return unpaidTrainingFee(player, kCurrentMonth) +
        unpaidRecordsFor(player)
            .where(
              (r) =>
                  r.type == PaymentType.trainingFee &&
                  !_isCurrentMonth(r.periodMonth ?? kCurrentMonth),
            )
            .fold(0.0, (sum, r) => sum + r.remaining);
  }
  return unpaidRecordsFor(player)
      .where((r) => r.type == type)
      .fold(0.0, (sum, r) => sum + r.remaining);
}

/// Total this player currently owes across everything.
///
/// This month's training fee is live and has no bill yet, so it's added
/// from the running total; every other open bill counts by what's left on
/// it. (A current-month training row is only ever a receipt, never a bill,
/// so it isn't counted twice.)
double totalPendingFor(AdminPlayer player) {
  final trainingFee = unpaidTrainingFee(player, kCurrentMonth);
  final others = unpaidRecordsFor(player)
      .where(
        (r) =>
            r.type != PaymentType.trainingFee ||
            !_isCurrentMonth(r.periodMonth ?? kCurrentMonth),
      )
      .fold(0.0, (sum, p) => sum + p.remaining);
  return trainingFee + others;
}

bool playerHasPendingPayment(AdminPlayer player) => totalPendingFor(player) > 0;
