import 'package:mysql_client/mysql_client.dart';

/// Every change to how much has been paid on a bill goes through this file.
///
/// Each function updates the `payments` row AND appends a row to
/// `payment_transactions` in the same database transaction, so the running
/// total (payments.amount_paid) always equals the sum of its logged money
/// movements. The app's database user can only SELECT and INSERT on the
/// transaction table: history can be added to, never rewritten.
///
/// Call these inside `withMoneyLock` (billing.dart).
class LedgerError implements Exception {
  final String message;
  final int status;

  const LedgerError(this.message, [this.status = 400]);

  @override
  String toString() => message;
}

/// Methods an admin may record by hand. 'online_test' and 'stripe' are only
/// ever set by the server's own payment paths, never typed in.
const _manualMethods = {'cash', 'card', 'bank', 'other'};

String normalizeMethod(Object? raw) {
  final method = '$raw';
  return _manualMethods.contains(method) ? method : 'cash';
}

/// Money compared in whole fils, so 0.1 + 0.2 floating-point noise can't
/// decide whether a bill is settled.
int cents(num value) => (value * 100).round();

num asMoney(Object? value) => num.tryParse('${value ?? 0}') ?? 0;

String money(num value) => value.toStringAsFixed(2);

/// The largest amount a DECIMAL(10,2) column holds. Anything above it used
/// to reach the database and come back as a raw "Out of range" error, or a
/// server error on the settings screens.
const maxMoney = 99999999.99;

typedef PaymentRow = ({
  int id,
  String type,
  int playerId,
  String? periodMonth,
  num amount,
  num paid,
  String status,
});

/// Reads and row-locks one payment for the rest of the transaction.
Future<PaymentRow> lockPayment(MySQLConnection conn, int id) async {
  final result = await conn.execute(
    'SELECT id, payment_type, player_id, period_month, amount, amount_paid, '
    'status FROM payments WHERE id = :id FOR UPDATE',
    {'id': id},
  );
  if (result.rows.isEmpty) {
    throw const LedgerError('No payment with that id', 404);
  }
  final r = result.rows.first.assoc();
  return (
    id: id,
    type: r['payment_type']!,
    playerId: int.parse(r['player_id']!),
    periodMonth: r['period_month'],
    amount: asMoney(r['amount']),
    paid: asMoney(r['amount_paid']),
    status: r['status']!,
  );
}

Future<void> _log(
  MySQLConnection conn, {
  required int paymentId,
  required String kind,
  required num amount,
  String? method,
  String? note,
  int? recordedBy,
  String? stripeIntentId,
}) async {
  await conn.execute(
    'INSERT INTO payment_transactions '
    '(payment_id, kind, amount, method, note, recorded_by, '
    ' stripe_payment_intent_id) '
    'VALUES (:paymentId, :kind, :amount, :method, :note, :recordedBy, '
    ' :intent)',
    {
      'paymentId': paymentId,
      'kind': kind,
      'amount': money(amount),
      'method': method,
      'note': note,
      'recordedBy': recordedBy,
      'intent': stripeIntentId,
    },
  );
}

/// Money received against a pending bill, in part or in full.
///
/// Overpaying is refused rather than silently absorbed: more than what's
/// owed is a typing slip, and taking it would create a credit nobody asked
/// for. The bill flips to 'paid' only once the whole amount is covered.
Future<({num amountPaid, num remaining, String status})> recordPayment(
  MySQLConnection conn, {
  required int paymentId,
  required num amount,
  required String method,
  int? recordedBy,
  String? note,
  String? stripeIntentId,
}) async {
  if (cents(amount) <= 0) {
    throw const LedgerError('Enter an amount above zero');
  }
  final row = await lockPayment(conn, paymentId);
  if (row.status != 'pending') {
    throw LedgerError('That payment is already ${row.status}', 409);
  }
  final remaining = row.amount - row.paid;
  if (cents(amount) > cents(remaining)) {
    throw LedgerError(
      'That is more than the ${money(remaining)} still owed on this payment',
    );
  }
  final nowPaid = row.paid + amount;
  final settled = cents(nowPaid) >= cents(row.amount);
  final status = settled ? 'paid' : 'pending';
  await conn.execute(
    'UPDATE payments SET amount_paid = :paid, method = :method, '
    'status = :status, paid_at = ${settled ? 'NOW()' : 'paid_at'} '
    'WHERE id = :id',
    {
      'id': paymentId,
      'paid': money(nowPaid),
      'method': method,
      'status': status,
    },
  );
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'payment',
    amount: amount,
    method: method,
    note: note,
    recordedBy: recordedBy,
    stripeIntentId: stripeIntentId,
  );
  return (amountPaid: nowPaid, remaining: row.amount - nowPaid, status: status);
}

/// Money handed back to the family.
///
/// A refund lowers what was paid AND what was charged by the same amount,
/// so nothing new becomes owed: refunding 100 of a 250 tournament fee leaves
/// a 150 fee, fully paid. Refunding everything on a paid bill marks it
/// 'refunded' and keeps its original amount for the record.
Future<void> recordRefund(
  MySQLConnection conn, {
  required int paymentId,
  required num amount,
  required String method,
  int? recordedBy,
  String? note,
}) async {
  if (cents(amount) <= 0) {
    throw const LedgerError('Enter an amount above zero');
  }
  final row = await lockPayment(conn, paymentId);
  if (row.status != 'paid' && row.status != 'pending') {
    throw LedgerError("A ${row.status} payment can't be refunded", 409);
  }
  if (cents(amount) > cents(row.paid)) {
    throw LedgerError(
      'Only ${money(row.paid)} has been paid on this, so that is the most '
      'that can be refunded',
    );
  }
  final everything = cents(amount) == cents(row.paid);
  if (everything &&
      (row.status == 'paid' || cents(row.amount) == cents(amount))) {
    await conn.execute(
      "UPDATE payments SET amount_paid = 0, status = 'refunded' WHERE id = :id",
      {'id': paymentId},
    );
  } else {
    // `amount` is a validated number, written in as a literal.
    final value = money(amount);
    await conn.execute(
      'UPDATE payments SET amount = amount - $value, '
      'amount_paid = amount_paid - $value WHERE id = :id',
      {'id': paymentId},
    );
  }
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'refund',
    amount: -amount,
    method: method,
    note: note,
    recordedBy: recordedBy,
  );
}

/// Takes [amount] of what was paid on a bill back out of it, so it can pay a
/// different bill: a training-fee credit moving on to the next fee.
///
/// Nothing leaves the club, so the matching payment must be recorded on the
/// bill it moves to in the same transaction (see carryForwardCredit in
/// billing.dart). Logged as a refund with method 'credit' — the pair nets to
/// zero, and each bill's amount_paid still equals the sum of its own rows.
///
/// Lowers what was charged and what was paid together, like a refund, so
/// this bill doesn't become owed. A receipt emptied completely is voided: it
/// no longer holds any money, and a "0.00 paid" line in the family's history
/// would only confuse. Its log rows stay.
Future<void> recordCreditOut(
  MySQLConnection conn, {
  required int paymentId,
  required num amount,
  String? note,
}) async {
  if (cents(amount) <= 0) {
    throw const LedgerError('Enter an amount above zero');
  }
  final row = await lockPayment(conn, paymentId);
  if (row.status != 'paid' && row.status != 'pending') {
    throw LedgerError("A ${row.status} payment can't be moved", 409);
  }
  if (cents(amount) > cents(row.paid)) {
    throw LedgerError('Only ${money(row.paid)} has been paid on this');
  }
  // `amount` is a validated number, written in as a literal.
  final value = money(amount);
  final emptied = cents(amount) == cents(row.paid);
  await conn.execute(
    'UPDATE payments SET amount = amount - $value, '
    'amount_paid = amount_paid - $value'
    "${emptied ? ", status = 'void'" : ''} WHERE id = :id",
    {'id': paymentId},
  );
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'refund',
    amount: -amount,
    method: 'credit',
    note: note,
  );
}

/// Undoes payments that were recorded by mistake. Nothing is handed back —
/// the money never really arrived — so this is logged as a reversal, not a
/// refund, and the bill becomes owed again.
///
/// A training fee row is voided rather than reopened: its month is then
/// re-derived (live for this month, a fresh bill at month close for a past
/// one). Reopening it instead counted the same fee twice — once as this
/// pending row and again in the live total.
///
/// A card payment made through Stripe can't be undone this way; money
/// really moved, so it has to go back as a refund.
Future<String> recordReversal(
  MySQLConnection conn, {
  required int paymentId,
  int? recordedBy,
  String? note,
}) async {
  final row = await lockPayment(conn, paymentId);
  if (cents(row.paid) <= 0) {
    throw const LedgerError('Nothing has been paid on this to undo', 409);
  }
  final stripe = await conn.execute(
    "SELECT COUNT(*) AS n FROM payment_transactions WHERE payment_id = :id "
    "AND kind = 'payment' AND method = 'stripe'",
    {'id': paymentId},
  );
  if (int.parse('${stripe.rows.first.assoc()['n']}') > 0) {
    throw const LedgerError(
      'This was paid by card through Stripe, so it has to be refunded '
      'instead of undone.',
      409,
    );
  }
  // Credit is money the family really paid, in an earlier month. Undoing
  // the bill it paid would erase it: the month it came from no longer holds
  // it, so it would simply disappear from the books.
  final fromCredit = await conn.execute(
    "SELECT COUNT(*) AS n FROM payment_transactions WHERE payment_id = :id "
    "AND kind = 'payment' AND method = 'credit'",
    {'id': paymentId},
  );
  if (int.parse('${fromCredit.rows.first.assoc()['n']}') > 0) {
    throw const LedgerError(
      'This was paid from training credit carried over from an earlier '
      "month, so it can't be undone. To give the money back, refund the "
      "credit from the player's payments.",
      409,
    );
  }
  // A training fee is re-derived from its month. A tournament fee for a
  // child since taken off the tournament, or for one since deleted, isn't
  // owed by anyone: it used to come back as owed, for a tournament the
  // child was no longer going to.
  final newStatus =
      row.type == 'training_fee' ||
          (row.type == 'tournament' && !await _stillOnTournament(conn, row.id))
      ? 'void'
      : 'pending';
  await conn.execute(
    "UPDATE payments SET amount_paid = 0, status = '$newStatus', "
    'paid_at = NULL WHERE id = :id',
    {'id': paymentId},
  );
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'reversal',
    amount: -row.paid,
    note: note,
    recordedBy: recordedBy,
  );
  return row.type;
}

/// Whether a tournament bill's player is still on that (live) tournament. A
/// tournament bill raised by hand, with no tournament linked, counts as on.
Future<bool> _stillOnTournament(MySQLConnection conn, int paymentId) async {
  final found = await conn.execute(
    'SELECT pay.tournament_id IS NULL OR EXISTS ('
    '  SELECT 1 FROM tournament_players tp '
    '  JOIN tournaments t ON t.id = tp.tournament_id AND t.deleted_at IS NULL '
    '  WHERE tp.tournament_id = pay.tournament_id '
    '    AND tp.player_id = pay.player_id'
    ') AS still_on FROM payments pay WHERE pay.id = $paymentId',
  );
  return '${found.rows.first.assoc()['still_on']}' == '1';
}

/// Takes back credit that was carried onto this bill from a payment since
/// undone: the money behind it never arrived, so neither did the credit.
///
/// The mirror of recordCreditOut: what was charged and what was paid drop
/// together, and a bill left with nothing is voided. The month close then
/// bills whatever that leaves owed. Logged as a reversal (no method), since
/// nothing is handed back; the credit move itself stays on record, so the
/// 'credit' rows still net to zero.
Future<void> recordCreditTakenBack(
  MySQLConnection conn, {
  required int paymentId,
  required num amount,
  int? recordedBy,
  String? note,
}) async {
  final row = await lockPayment(conn, paymentId);
  if (cents(amount) <= 0 || cents(amount) > cents(row.paid)) {
    throw LedgerError('Only ${money(row.paid)} is paid on that bill', 409);
  }
  // `amount` is a validated number, written in as a literal.
  final value = money(amount);
  final emptied = cents(row.amount - amount) <= 0;
  await conn.execute(
    'UPDATE payments SET amount = amount - $value, '
    'amount_paid = amount_paid - $value'
    "${emptied ? ", status = 'void', paid_at = NULL" : ''} WHERE id = :id",
    {'id': paymentId},
  );
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'reversal',
    amount: -amount,
    note: note,
    recordedBy: recordedBy,
  );
}

/// Writes off whatever is still owed on a pending bill.
///
/// Anything already paid stays paid: the bill is reduced to that amount and
/// closed. Nothing paid at all marks it 'waived'. For a training fee the
/// month's total is also pinned (via training_fee_overrides) to what was
/// paid, or the month close would simply raise the forgiven amount again.
Future<void> recordWaiver(
  MySQLConnection conn, {
  required int paymentId,
  int? recordedBy,
  String? note,
}) async {
  final row = await lockPayment(conn, paymentId);
  if (row.status != 'pending') {
    throw LedgerError('Only a pending payment can be waived', 409);
  }
  final remaining = row.amount - row.paid;
  if (cents(remaining) <= 0) {
    throw const LedgerError('Nothing is left to waive on this', 409);
  }
  if (cents(row.paid) > 0) {
    await conn.execute(
      "UPDATE payments SET amount = amount_paid, status = 'paid', "
      'paid_at = COALESCE(paid_at, NOW()) WHERE id = :id',
      {'id': paymentId},
    );
  } else {
    await conn.execute("UPDATE payments SET status = 'waived' WHERE id = :id", {
      'id': paymentId,
    });
  }
  await _log(
    conn,
    paymentId: paymentId,
    kind: 'waiver',
    amount: remaining,
    note: note,
    recordedBy: recordedBy,
  );

  final month = row.periodMonth;
  if (row.type == 'training_fee' && month != null) {
    await pinTrainingFeeToSettled(
      conn,
      playerId: row.playerId,
      periodMonth: month,
      recordedBy: recordedBy,
      note: note ?? 'Waived',
    );
  }
}

/// Sets a month's training-fee total to exactly what has been paid for it,
/// so the month close treats it as settled.
Future<void> pinTrainingFeeToSettled(
  MySQLConnection conn, {
  required int playerId,
  required String periodMonth,
  int? recordedBy,
  String? note,
}) async {
  final settled = await conn.execute(
    "SELECT COALESCE(SUM(amount_paid), 0) AS total FROM payments "
    "WHERE payment_type = 'training_fee' AND player_id = :playerId "
    'AND period_month = :month',
    {'playerId': playerId, 'month': periodMonth},
  );
  await conn.execute(
    'INSERT INTO training_fee_overrides '
    '(player_id, period_month, amount, note, set_by) '
    'VALUES (:playerId, :month, :amount, :note, :setBy) '
    'ON DUPLICATE KEY UPDATE amount = VALUES(amount), note = VALUES(note), '
    'set_by = VALUES(set_by)',
    {
      'playerId': playerId,
      'month': periodMonth,
      'amount': settled.rows.first.assoc()['total'],
      'note': note,
      'setBy': recordedBy,
    },
  );
}

/// Reads a money amount from a request: a number, or a number sent as text,
/// rounded to whole fils ONCE, here.
///
/// Without the rounding, 100.005 was saved as 100.00 by one step and checked
/// as 100.01 by the next, and the payment was refused as "more than owed".
/// Anything that isn't a real finite number — "NaN", "Infinity" — is refused
/// (null) rather than reaching the rounding and failing there.
num? readMoney(Object? value) {
  final raw = value is num ? value : num.tryParse('$value');
  if (raw == null || !raw.isFinite) return null;
  return (raw * 100).round() / 100;
}
