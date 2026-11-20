import 'package:mysql_client/mysql_client.dart';

import 'db.dart';
import 'fee_rates.dart';
import 'ledger.dart';

/// Training-fee billing shared by the payments, players and scheduler code:
/// what a player owes for a month, and closing finished months into bills.

const thisMonthStart =
    'DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY)';

/// A billing month as sent over the API: always the first of the month.
/// Month 01-12 only: "2026-13-01" used to pass and crash the query.
final monthPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])-01$');

String monthKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-01';

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "2026-09-01" -> "September 2026 Training Fee".
String monthTitle(String periodMonth) {
  final date = DateTime.parse(periodMonth);
  return '${_monthNames[date.month - 1]} ${date.year} Training Fee';
}

/// Runs [body] in one database transaction while holding a server-wide lock.
///
/// Every operation that moves money or reshapes a bill takes this lock:
/// paying, refunding, waiving, undoing, and the month close. Without it, two
/// of them overlapping (a parent paying while the hourly close re-prices the
/// same bill, say) could each act on a stale reading of the other.
Future<T> withMoneyLock<T>(
  Db db,
  Future<T> Function(MySQLConnection conn) body,
) {
  return db.transaction((conn) async {
    final got = await conn.execute("SELECT GET_LOCK('dsa_money', 20) AS got");
    if ('${got.rows.first.assoc()['got']}' != '1') {
      throw const LedgerError(
        'The server is busy. Please try again in a moment.',
        503,
      );
    }
    try {
      return await body(conn);
    } finally {
      await conn.execute("SELECT RELEASE_LOCK('dsa_money')");
    }
  });
}

/// One row per player per month they were rostered in, with everything
/// needed to decide what they owe for it. [where] filters on `roster.*`.
///
/// Built from fixed SQL plus validated integers and dates only — the
/// driver's named parameters don't work in a query holding scalar
/// subqueries, and the rate lookups are scalar subqueries.
String ledgerSql(String where) =>
    '''
  SELECT
    roster.player_id,
    roster.period_month,
    roster.billable_sessions,
    roster.session_charges,
    ${proratedCoachFeeAt('roster.player_id', 'roster.period_month')} AS coach_fee,
    ovr.amount                        AS override_amount,
    COALESCE(settled.total, 0)        AS settled,
    invoice.id                        AS invoice_id,
    COALESCE(invoice.amount, 0)       AS invoice_amount,
    COALESCE(invoice.amount_paid, 0)  AS invoice_paid
  FROM (
    SELECT
      sp.player_id,
      DATE_SUB(s.session_date,
               INTERVAL DAYOFMONTH(s.session_date) - 1 DAY) AS period_month,
      COUNT(CASE WHEN a.status IN ('present','absent')
                  AND s.session_date <= CURRENT_DATE THEN 1 END)
        AS billable_sessions,
      COALESCE(SUM(CASE WHEN a.status IN ('present','absent')
                         AND s.session_date <= CURRENT_DATE
                        THEN ${sessionRateAt('s.session_date')}
                        ELSE 0 END), 0) AS session_charges
    FROM session_players sp
    -- Training sessions only. A tournament game with a roster used to be
    -- billed as a training session (coach fee and per-session rate).
    JOIN sessions s ON s.id = sp.session_id AND s.is_cancelled = 0
                   AND s.session_type = 'training'
    JOIN players p  ON p.id = sp.player_id AND p.is_active = 1
    LEFT JOIN attendance a
           ON a.session_id = sp.session_id AND a.player_id = sp.player_id
    GROUP BY sp.player_id, period_month
  ) roster
  LEFT JOIN training_fee_overrides ovr
         ON ovr.player_id = roster.player_id
        AND ovr.period_month = roster.period_month
  LEFT JOIN (
    SELECT player_id, period_month, SUM(amount_paid) AS total
    FROM payments
    WHERE payment_type = 'training_fee'
    GROUP BY player_id, period_month
  ) settled
         ON settled.player_id = roster.player_id
        AND settled.period_month = roster.period_month
  LEFT JOIN payments invoice
         ON invoice.player_id = roster.player_id
        AND invoice.period_month = roster.period_month
        AND invoice.payment_type = 'training_fee'
        AND invoice.status = 'pending'
  WHERE $where
''';

/// The month's full fee: the admin's override if there is one, otherwise
/// the (possibly prorated) coach fee plus the sessions charged.
num owedFrom(Map<String, String?> row) {
  final override = row['override_amount'];
  if (override != null) return asMoney(override);
  return asMoney(row['coach_fee']) + asMoney(row['session_charges']);
}

/// Where one player stands for one month.
typedef MonthPosition = ({
  num owed,
  num settled,
  int? invoiceId,
  num invoiceRemaining,
});

Future<MonthPosition> monthPosition(
  MySQLConnection conn,
  int playerId,
  String periodMonth,
) async {
  final result = await conn.execute(
    ledgerSql(
      "roster.player_id = $playerId AND roster.period_month = '$periodMonth'",
    ),
  );
  if (result.rows.isNotEmpty) {
    final r = result.rows.first.assoc();
    return (
      owed: owedFrom(r),
      settled: asMoney(r['settled']),
      invoiceId: int.tryParse('${r['invoice_id']}'),
      invoiceRemaining:
          asMoney(r['invoice_amount']) - asMoney(r['invoice_paid']),
    );
  }
  // Not rostered that month: nothing is owed, but money may still have been
  // paid for it (e.g. before they were taken off every session).
  final settled = await conn.execute(
    "SELECT COALESCE(SUM(amount_paid), 0) AS total FROM payments "
    "WHERE payment_type = 'training_fee' AND player_id = :playerId "
    'AND period_month = :month',
    {'playerId': playerId, 'month': periodMonth},
  );
  return (
    owed: 0,
    settled: asMoney(settled.rows.first.assoc()['total']),
    invoiceId: null,
    invoiceRemaining: 0,
  );
}

/// Turns every finished month into a bill, and keeps those bills correct.
///
/// Reconciles rather than inserting blindly, so running it any number of
/// times is safe:
///   * nothing billed yet      -> create a bill for what's outstanding
///   * a bill already there    -> correct its amount if attendance changed
///   * nothing left owed       -> close the bill
///
/// Closing a bill that has money on it never deletes it. That used to
/// happen: a part-paid bill that became fully covered was deleted, which
/// dropped the money paid on it out of the month's total, and the next run
/// billed it again. Now it's reduced to what was paid and marked paid.
Future<Map<String, int>> reconcilePastMonths(MySQLConnection conn) async {
  final result = await conn.execute(
    ledgerSql('roster.period_month < $thisMonthStart'),
  );
  final rostered = [for (final row in result.rows) row.assoc()];

  var created = 0;
  var updated = 0;
  var closed = 0;
  for (final r in rostered) {
    final month = r['period_month']!;
    final owed = owedFrom(r);
    final settled = asMoney(r['settled']);
    final outstanding = owed - settled;
    final invoiceId = int.tryParse('${r['invoice_id']}');
    final invoicePaid = asMoney(r['invoice_paid']);

    if (cents(outstanding) <= 0) {
      if (invoiceId != null) {
        if (cents(invoicePaid) > 0) {
          await conn.execute(
            "UPDATE payments SET amount = amount_paid, status = 'paid', "
            'paid_at = COALESCE(paid_at, NOW()) WHERE id = :id',
            {'id': invoiceId},
          );
        } else {
          final logged = await conn.execute(
            'SELECT COUNT(*) AS n FROM payment_transactions '
            'WHERE payment_id = :id',
            {'id': invoiceId},
          );
          final hasHistory = int.parse('${logged.rows.first.assoc()['n']}') > 0;
          await conn.execute(
            hasHistory
                ? "UPDATE payments SET status = 'void' WHERE id = :id"
                : 'DELETE FROM payments WHERE id = :id',
            {'id': invoiceId},
          );
        }
        closed++;
      }
      continue;
    }

    final amount = outstanding + invoicePaid;
    if (invoiceId != null) {
      if (cents(asMoney(r['invoice_amount'])) != cents(amount)) {
        await conn.execute(
          'UPDATE payments SET amount = :amount WHERE id = :id',
          {'id': invoiceId, 'amount': money(amount)},
        );
        updated++;
      }
      continue;
    }

    await conn.execute(
      'INSERT INTO payments '
      '(player_id, payment_type, title, period_month, amount, status) '
      "VALUES (:playerId, 'training_fee', :title, :month, :amount, "
      "'pending')",
      {
        'playerId': r['player_id'],
        'title': monthTitle(month),
        'month': month,
        'amount': money(amount),
      },
    );
    created++;
  }

  final carried = await carryForwardCredit(conn, rostered);

  return {
    'created': created,
    'updated': updated,
    'withdrawn': closed,
    'carried': carried,
  };
}

/// The note on an admin's advance payment. carryForwardCredit looks for it,
/// so it is a constant rather than free text.
const advanceNote = 'Advance payment';

/// "2026-08-01" -> "August 2026".
String monthName(String periodMonth) =>
    monthTitle(periodMonth).replaceFirst(' Training Fee', '');

/// Moves money paid beyond a finished month's fee on to the next training
/// fee, so an advance or an overpayment is used rather than left sitting.
///
/// For every finished month where more was paid than it came to (a parent
/// paid ahead, or sessions were cancelled after they paid), the extra goes:
///   1. to any training fee still owed, oldest first, then
///   2. onto this month's running fee, where it waits for the sessions to
///      happen. If it's still more than this month comes to, the next month
///      close carries the rest on again.
/// Until it's used, the admin can refund it instead (/training-fees/refund
/// on this month).
///
/// [rostered] is the month-close's own ledger rows, which already hold what
/// each rostered month came to; a month the player wasn't rostered in came
/// to nothing. Only active players: a removed player's money is settled
/// when they're removed.
///
/// Only months the app can vouch for carry on by themselves: ones the
/// player was put on a training session in (even if every session was then
/// cancelled — the usual way a month ends up overpaid), and ones holding
/// money this code put there as credit or an admin recorded as an advance.
/// Anything else — history keyed in or imported without the sessions
/// behind it — is left where it is for the admin to look at: it still
/// shows as overpaid on Training Fees, with a refund button. Without this,
/// five months of test bills with no sessions behind them all read as
/// overpaid and turned into one large, fictional credit.
Future<int> carryForwardCredit(
  MySQLConnection conn,
  List<Map<String, String?>> rostered,
) async {
  final owedBy = {
    for (final r in rostered)
      '${r['player_id']}|${r['period_month']}': owedFrom(r),
  };
  final paidMonths = await conn.execute('''
    SELECT pay.player_id,
           DATE_FORMAT(pay.period_month, '%Y-%m-%d') AS period_month,
           SUM(pay.amount_paid) AS settled
    FROM payments pay
    JOIN players p ON p.id = pay.player_id AND p.is_active = 1
    WHERE pay.payment_type = 'training_fee'
      AND pay.period_month < $thisMonthStart
      AND (
        EXISTS (
          SELECT 1 FROM session_players sp
          JOIN sessions s ON s.id = sp.session_id
                         AND s.session_type = 'training'
          WHERE sp.player_id = pay.player_id
            AND s.session_date >= pay.period_month
            AND s.session_date < pay.period_month + INTERVAL 1 MONTH
        )
        OR EXISTS (
          SELECT 1 FROM payment_transactions t
          JOIN payments b ON b.id = t.payment_id
          WHERE b.player_id = pay.player_id
            AND b.payment_type = 'training_fee'
            AND b.period_month = pay.period_month
            AND t.kind = 'payment'
            AND (t.method = 'credit' OR t.note = '$advanceNote')
        )
      )
    GROUP BY pay.player_id, pay.period_month
    HAVING SUM(pay.amount_paid) > 0
    ORDER BY pay.player_id, pay.period_month
  ''');

  var moved = 0;
  for (final row in paidMonths.rows) {
    final r = row.assoc();
    final playerId = int.parse(r['player_id']!);
    final month = r['period_month']!;
    final excess = asMoney(r['settled']) - (owedBy['$playerId|$month'] ?? 0);
    if (cents(excess) <= 0) continue;
    await _moveCredit(
      conn,
      playerId: playerId,
      fromMonth: month,
      amount: excess,
    );
    moved++;
  }
  return moved;
}

Future<void> _moveCredit(
  MySQLConnection conn, {
  required int playerId,
  required String fromMonth,
  required num amount,
}) async {
  final from = monthName(fromMonth);

  // Out of the month it was overpaid in, newest receipt first.
  final sources = await conn.execute(
    "SELECT id, amount_paid FROM payments WHERE payment_type = 'training_fee' "
    'AND player_id = :playerId AND period_month = :month AND amount_paid > 0 '
    'ORDER BY id DESC',
    {'playerId': playerId, 'month': fromMonth},
  );
  num credit = 0;
  for (final row in sources.rows) {
    final left = amount - credit;
    if (cents(left) <= 0) break;
    final paid = asMoney(row.assoc()['amount_paid']);
    final chunk = cents(left) > cents(paid) ? paid : left;
    await recordCreditOut(
      conn,
      paymentId: int.parse(row.assoc()['id']!),
      amount: chunk,
      note: 'Credit carried forward from $from',
    );
    credit += chunk;
  }
  if (cents(credit) <= 0) return;

  // Into whatever training fee is still owed, oldest first.
  final owing = await conn.execute(
    "SELECT id, amount, amount_paid FROM payments WHERE payment_type = "
    "'training_fee' AND player_id = :playerId AND status = 'pending' "
    'AND period_month <> :month ORDER BY period_month, id',
    {'playerId': playerId, 'month': fromMonth},
  );
  var left = credit;
  for (final row in owing.rows) {
    if (cents(left) <= 0) break;
    final r = row.assoc();
    final open = asMoney(r['amount']) - asMoney(r['amount_paid']);
    if (cents(open) <= 0) continue;
    final chunk = cents(left) > cents(open) ? open : left;
    await recordPayment(
      conn,
      paymentId: int.parse(r['id']!),
      amount: chunk,
      method: 'credit',
      note: 'Credit from $from',
    );
    left -= chunk;
  }
  if (cents(left) <= 0) return;

  // The rest waits on this month's fee, as a receipt against it.
  final current = await conn.execute(
    "SELECT DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS m",
  );
  final thisMonth = '${current.rows.first.assoc()['m']}';
  final inserted = await conn.execute(
    'INSERT INTO payments '
    '(player_id, payment_type, title, period_month, amount, status) '
    "VALUES (:playerId, 'training_fee', :title, :month, :amount, 'pending')",
    {
      'playerId': playerId,
      'title': monthTitle(thisMonth),
      'month': thisMonth,
      'amount': money(left),
    },
  );
  await recordPayment(
    conn,
    paymentId: inserted.lastInsertID.toInt(),
    amount: left,
    method: 'credit',
    note: 'Credit from $from',
  );
}

/// Before a training-fee payment is undone: any of it already carried on as
/// credit (carryForwardCredit) is taken back from the fees it went on to pay.
///
/// Undo means the money never arrived. Without this, only what was still on
/// the bill was undone, and the family kept the credit that had moved on —
/// money they never paid. The fees it paid are found by the note the move
/// left on them ("Credit from August 2026"), newest first, each only up to
/// what it received from that month and hasn't already given back.
///
/// If some of it can't be found any more — refunded to the family, or
/// carried on again by a later month close — the undo is refused rather
/// than half done.
Future<void> takeBackCarriedCredit(
  MySQLConnection conn, {
  required int paymentId,
  int? recordedBy,
}) async {
  final row = await lockPayment(conn, paymentId);
  final month = row.periodMonth;
  if (row.type != 'training_fee' || month == null) return;
  final out = await conn.execute(
    'SELECT COALESCE(-SUM(amount), 0) AS moved FROM payment_transactions '
    "WHERE payment_id = :id AND kind = 'refund' AND method = 'credit'",
    {'id': paymentId},
  );
  final moved = asMoney(out.rows.first.assoc()['moved']);
  if (cents(moved) <= 0 || cents(row.paid) <= 0) return;

  // Month names are letters, a space and digits: safe as literals, and the
  // driver's named parameters don't survive the CASE expressions.
  final from = monthName(month);
  final gave = 'Credit from $from';
  final tookBack = 'Credit from $from taken back';
  final targets = await conn.execute('''
    SELECT b.id, b.amount_paid,
           SUM(CASE WHEN t.kind = 'payment' AND t.method = 'credit'
                     AND t.note = '$gave' THEN t.amount
                    WHEN t.kind = 'reversal' AND t.note = '$tookBack'
                    THEN t.amount ELSE 0 END) AS still_has
    FROM payments b
    JOIN payment_transactions t ON t.payment_id = b.id
    WHERE b.player_id = ${row.playerId} AND b.payment_type = 'training_fee'
      AND b.id <> $paymentId
    GROUP BY b.id, b.amount_paid
    HAVING still_has > 0
    ORDER BY b.id DESC
  ''');
  final plan = <({int id, num take})>[];
  var left = moved;
  for (final t in targets.rows) {
    if (cents(left) <= 0) break;
    final r = t.assoc();
    final stillHas = asMoney(r['still_has']);
    final paid = asMoney(r['amount_paid']);
    final available = cents(stillHas) < cents(paid) ? stillHas : paid;
    if (cents(available) <= 0) continue;
    final take = cents(left) < cents(available) ? left : available;
    plan.add((id: int.parse(r['id']!), take: take));
    left -= take;
  }
  if (cents(left) > 0) {
    throw LedgerError(
      'AED ${money(moved)} of this payment was carried on as training '
      'credit, and ${money(left)} of that has since been refunded or '
      "carried on again, so it can't be undone here. Please adjust it by "
      'hand.',
      409,
    );
  }
  for (final step in plan) {
    await recordCreditTakenBack(
      conn,
      paymentId: step.id,
      amount: step.take,
      recordedBy: recordedBy,
      note: tookBack,
    );
  }
}

/// One thing a family still owes: an open bill, or this month's training
/// fee so far (billed only when the month closes).
typedef OwedItem = ({
  int playerId,
  String playerName,
  int parentId,
  String parentName,
  String type,
  String title,
  num amount,
});

/// Everything owed right now, and the training credit the club holds, for
/// active players: what a family deleting their account must settle first.
///
/// Owed = every open bill, except this month's training fee, which is
/// worked out live (what the sessions so far come to, less what's been
/// paid) exactly as the app shows it. Credit = paid for this month beyond
/// what it comes to, waiting for the month close to carry it on.
///
/// [parentId] narrows it to one family.
Future<({List<OwedItem> owed, Map<int, num> credit})> openPositions(
  MySQLConnection conn, {
  int? parentId,
}) async {
  final family = parentId == null ? '' : 'AND p.parent_id = $parentId';
  final playerRows = await conn.execute('''
    SELECT p.id, p.full_name, p.parent_id, u.full_name AS parent_name
    FROM players p
    JOIN users u ON u.id = p.parent_id
    WHERE p.is_active = 1 $family
  ''');
  final players = {
    for (final row in playerRows.rows)
      int.parse(row.assoc()['id']!): (
        name: row.assoc()['full_name']!,
        parentId: int.parse(row.assoc()['parent_id']!),
        parentName: row.assoc()['parent_name']!,
      ),
  };
  final owed = <OwedItem>[];
  final credit = <int, num>{};
  if (players.isEmpty) return (owed: owed, credit: credit);
  final ids = players.keys.join(',');

  OwedItem item(int playerId, String type, String title, num amount) {
    final p = players[playerId]!;
    return (
      playerId: playerId,
      playerName: p.name,
      parentId: p.parentId,
      parentName: p.parentName,
      type: type,
      title: title,
      amount: amount,
    );
  }

  final bills = await conn.execute('''
    SELECT player_id, payment_type, title, amount - amount_paid AS remaining
    FROM payments
    WHERE status = 'pending' AND amount > amount_paid
      AND player_id IN ($ids)
      AND NOT (payment_type = 'training_fee'
               AND period_month = $thisMonthStart)
    ORDER BY period_month IS NULL, period_month, id
  ''');
  for (final row in bills.rows) {
    final r = row.assoc();
    owed.add(
      item(
        int.parse(r['player_id']!),
        r['payment_type']!,
        r['title']!,
        asMoney(r['remaining']),
      ),
    );
  }

  // This month's training, live.
  final monthOwed = <int, num>{};
  final month = await conn.execute(
    ledgerSql(
      'roster.period_month = $thisMonthStart AND roster.player_id IN ($ids)',
    ),
  );
  for (final row in month.rows) {
    final r = row.assoc();
    final playerId = int.parse(r['player_id']!);
    final owedNow = owedFrom(r);
    monthOwed[playerId] = owedNow;
    final left = owedNow - asMoney(r['settled']);
    if (cents(left) > 0) {
      owed.add(
        item(
          playerId,
          'training_fee',
          '${monthTitle(r['period_month']!)} (so far)',
          left,
        ),
      );
    }
  }
  // Paid for this month beyond what it comes to — players with no sessions
  // this month included (an advance paid before any were scheduled).
  final paid = await conn.execute('''
    SELECT player_id, SUM(amount_paid) AS settled
    FROM payments
    WHERE payment_type = 'training_fee' AND period_month = $thisMonthStart
      AND player_id IN ($ids)
    GROUP BY player_id
  ''');
  for (final row in paid.rows) {
    final playerId = int.parse(row.assoc()['player_id']!);
    final over = asMoney(row.assoc()['settled']) - (monthOwed[playerId] ?? 0);
    if (cents(over) > 0) credit[playerId] = over;
  }
  return (owed: owed, credit: credit);
}

/// The month close, as the scheduler and the API trigger it.
Future<Map<String, int>> closeTrainingFees(Db db) =>
    withMoneyLock(db, reconcilePastMonths);
