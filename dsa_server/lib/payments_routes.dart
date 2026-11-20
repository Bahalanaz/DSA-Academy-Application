import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'billing.dart';
import 'db.dart';
import 'ledger.dart';
import 'notices.dart' show notifyPaymentPaid;
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Turns ledger and database errors into the usual {"error": ...} replies.
Future<Response> _guard(Future<Response> Function() handler) async {
  try {
    return await handler();
  } on LedgerError catch (e) {
    return _json({'error': e.message}, status: e.status);
  } on MySQLServerException {
    rethrow;
  }
}

Future<Map> _body(Request request) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) return const {};
  return jsonDecode(raw) as Map? ?? const {};
}

/// Money: fee settings, bills, the transaction log, and training-fee
/// payments, refunds and overrides.
///
/// Rule for everything below: a bill's amount_paid only ever changes through
/// ledger.dart, under withMoneyLock, with a transaction logged alongside.
Router buildPaymentsRouter(Db db) {
  final router = Router();

  /// Closes finished months into bills. Also runs on its own every hour
  /// (see bin/server.dart); calling it here just makes sure it's current.
  router.post(
    '/training-fees/close',
    (Request request) => _guard(() async {
      return _json(await closeTrainingFees(db));
    }),
  );

  /// Pays towards a player's training fee for one month.
  ///
  /// The server works out what's owed itself, so the app can't pay more
  /// than that or invent a fee. A past month pays down its bill; the current
  /// month (not billed yet) records a receipt against the running total.
  /// Parents' payments are marked 'online_test' until Stripe replaces this
  /// path; admins record how the money actually arrived.
  router.post(
    '/training-fees/pay',
    (Request request) => _guard(() async {
      final user = userOf(request);
      final body = await _body(request);
      final playerId = int.tryParse('${body['playerId']}');
      final month = '${body['periodMonth']}';
      final amount = _asNum(body['amount']);
      if (playerId == null || !monthPattern.hasMatch(month) || amount == null) {
        return _json({
          'error': 'playerId, periodMonth (YYYY-MM-01) and amount are required',
        }, status: 400);
      }
      if (!await canAccessPlayer(db, user, playerId)) {
        return _json({'error': 'No player with that id'}, status: 404);
      }
      // The database's clock — the one billing runs on — not this process's,
      // which can be in a different time zone once the server is hosted.
      final thisMonth = await db.execute(
        "SELECT DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS m",
      );
      final currentMonth = '${thisMonth.rows.first.assoc()['m']}';
      if (month.compareTo(currentMonth) > 0) {
        return _json({
          'error': "That month hasn't started, so nothing is owed for it yet",
        }, status: 400);
      }
      // Paying more than a training fee comes to is allowed — parents too.
      // The extra is training credit: it waits on this month's fee and the
      // month close carries whatever is left on to the next training fee
      // (carryForwardCredit), so paying ahead lowers what's owed next
      // instead of being refused. Only training fees work like this; a
      // tournament or kit bill is a fixed price.
      //
      // One request, one amount, split here under the money lock: first
      // whatever [month] still owes, then the rest as an advance on this
      // month. Stripe will charge the parent the whole amount once and hand
      // it to this same split, so nothing here changes when it arrives.
      final advance = body['advance'] == true;
      if (cents(amount) <= 0 || amount > maxMoney) {
        return _json({
          'error': 'Enter an amount from 0.01 to ${money(maxMoney)}',
        }, status: 400);
      }
      final method = user.isAdmin
          ? normalizeMethod(body['method'])
          : 'online_test';

      final result = await withMoneyLock(db, (conn) async {
        await reconcilePastMonths(conn);
        final position = await monthPosition(conn, playerId, month);
        final outstanding = position.owed - position.settled;
        if (!advance && cents(outstanding) <= 0) {
          throw const LedgerError('Nothing is owed for that month', 409);
        }
        if (!advance && cents(amount) > cents(outstanding)) {
          throw LedgerError(
            'That is more than the ${money(outstanding)} owed for that '
            'month. To pay ahead, pay it as an advance.',
          );
        }
        final num owedPart = cents(outstanding) <= 0
            ? 0
            : (cents(amount) > cents(outstanding) ? outstanding : amount);
        final extra = amount - owedPart;

        Future<int> receipt(String forMonth, num value) async {
          final inserted = await conn.execute(
            'INSERT INTO payments '
            '(player_id, payment_type, title, period_month, amount, status, '
            ' created_by) '
            "VALUES (:playerId, 'training_fee', :title, :month, :amount, "
            " 'pending', :createdBy)",
            {
              'playerId': playerId,
              'title': monthTitle(forMonth),
              'month': forMonth,
              'amount': money(value),
              'createdBy': user.id,
            },
          );
          return inserted.lastInsertID.toInt();
        }

        int? paymentId;
        if (cents(owedPart) > 0) {
          paymentId = position.invoiceId ?? await receipt(month, owedPart);
          final paid = await recordPayment(
            conn,
            paymentId: paymentId,
            amount: owedPart,
            method: method,
            recordedBy: user.id,
          );
          // A finished month the admin has now settled: tell the family.
          // Not the month still running, which more sessions can add to.
          if (user.isAdmin &&
              paid.status == 'paid' &&
              month.compareTo(currentMonth) < 0) {
            await notifyPaymentPaid(
              conn,
              paymentId: paymentId,
              sentBy: user.id,
            );
          }
        }
        if (cents(extra) > 0) {
          // Its own receipt on this month, marked as an advance so the
          // month close knows to carry it even if the child has no
          // sessions this month.
          final advanceId = await receipt(currentMonth, extra);
          await recordPayment(
            conn,
            paymentId: advanceId,
            amount: extra,
            method: method,
            recordedBy: user.id,
            note: advanceNote,
          );
          paymentId ??= advanceId;
        }
        final left = outstanding - owedPart;
        return {
          'paymentId': paymentId,
          'paid': money(amount),
          'stillOwedForMonth': money(cents(left) > 0 ? left : 0),
          'credit': money(extra),
        };
      });
      return _json(result);
    }),
  );

  /// Writes off what's still owed for one player's training fee in one
  /// month — including THIS month, which has no bill to waive yet.
  ///
  /// Whatever has been paid stays paid. The month is then fixed at exactly
  /// that (recordWaiver pins it via training_fee_overrides), so sessions
  /// later in the month don't bring the fee back.
  router.post(
    '/training-fees/waive',
    (Request request) => _guard(() async {
      final user = userOf(request);
      final body = await _body(request);
      final playerId = int.tryParse('${body['playerId']}');
      final month = '${body['periodMonth']}';
      if (playerId == null || !monthPattern.hasMatch(month)) {
        return _json({
          'error': 'playerId and periodMonth (YYYY-MM-01) are required',
        }, status: 400);
      }
      if (!await canAccessPlayer(db, user, playerId)) {
        return _json({'error': 'No player with that id'}, status: 404);
      }
      final note = _emptyToNull(body['note'] as String?) ?? 'Waived by admin';
      final noteTooLong = lengthError('Note', note, 255);
      if (noteTooLong != null) {
        return _json({'error': noteTooLong}, status: 400);
      }
      final waived = await withMoneyLock(db, (conn) async {
        await reconcilePastMonths(conn);
        final position = await monthPosition(conn, playerId, month);
        final outstanding = position.owed - position.settled;
        if (cents(outstanding) <= 0) {
          throw const LedgerError('Nothing is owed for that month', 409);
        }
        var paymentId = position.invoiceId;
        if (paymentId == null) {
          // The running month: raise the bill for what's left, then waive
          // it, so the log shows exactly what was forgiven.
          final inserted = await conn.execute(
            'INSERT INTO payments '
            '(player_id, payment_type, title, period_month, amount, status, '
            ' created_by) '
            "VALUES (:playerId, 'training_fee', :title, :month, :amount, "
            " 'pending', :createdBy)",
            {
              'playerId': playerId,
              'title': monthTitle(month),
              'month': month,
              'amount': money(outstanding),
              'createdBy': user.id,
            },
          );
          paymentId = inserted.lastInsertID.toInt();
        }
        await recordWaiver(
          conn,
          paymentId: paymentId,
          recordedBy: user.id,
          note: note,
        );
        return outstanding;
      });
      return _json({'waived': money(waived)});
    }),
  );

  /// Gives back money paid over what a month came to — after attendance was
  /// corrected downwards, say. Only the overpaid part can be refunded here;
  /// to forgive a fee that's genuinely owed, waive it or set a custom total.
  router.post(
    '/training-fees/refund',
    (Request request) => _guard(() async {
      final user = userOf(request);
      final body = await _body(request);
      final playerId = int.tryParse('${body['playerId']}');
      final month = '${body['periodMonth']}';
      final amount = _asNum(body['amount']);
      if (playerId == null || !monthPattern.hasMatch(month) || amount == null) {
        return _json({
          'error': 'playerId, periodMonth (YYYY-MM-01) and amount are required',
        }, status: 400);
      }
      final method = normalizeMethod(body['method']);

      final refunded = await withMoneyLock(db, (conn) async {
        await reconcilePastMonths(conn);
        final position = await monthPosition(conn, playerId, month);
        final overpaid = position.settled - position.owed;
        if (cents(overpaid) <= 0) {
          throw const LedgerError('Nothing was overpaid for that month', 409);
        }
        if (cents(amount) > cents(overpaid)) {
          throw LedgerError(
            'Only ${money(overpaid)} was overpaid for that month',
          );
        }
        final rows = await conn.execute(
          "SELECT id, amount_paid FROM payments WHERE payment_type = "
          "'training_fee' AND player_id = :playerId AND period_month = :month "
          'AND amount_paid > 0 ORDER BY id DESC',
          {'playerId': playerId, 'month': month},
        );
        var left = amount;
        for (final row in rows.rows) {
          if (cents(left) <= 0) break;
          final r = row.assoc();
          final paid = asMoney(r['amount_paid']);
          final chunk = cents(left) > cents(paid) ? paid : left;
          await recordRefund(
            conn,
            paymentId: int.parse(r['id']!),
            amount: chunk,
            method: method,
            recordedBy: user.id,
            note: 'Overpaid training fee',
          );
          left -= chunk;
        }
        return amount - left;
      });
      return _json({'refunded': money(refunded)});
    }),
  );

  // ---------------------------------------------------------------------
  // Fee settings
  // ---------------------------------------------------------------------

  router.get('/fee-settings', (Request request) async {
    final result = await db.execute(
      // server_time lets the app use the server's clock for "this month"
      // rather than the phone's, which can be wrong or in another zone.
      'SELECT coach_fee, per_session_rate, currency, NOW() AS server_time '
      'FROM fee_settings WHERE id = 1',
    );
    if (result.rows.isEmpty) {
      return _json({'error': 'Fee settings row is missing'}, status: 500);
    }
    return _json(result.rows.first.assoc());
  });

  router.put('/fee-settings', (Request request) async {
    final user = userOf(request);
    final body = await _body(request);
    final coachFee = _asNum(body['coachFee']);
    final perSessionRate = _asNum(body['perSessionRate']);
    if (coachFee == null || perSessionRate == null) {
      return _json({
        'error': 'coachFee and perSessionRate are required',
      }, status: 400);
    }
    if (coachFee < 0 || perSessionRate < 0) {
      return _json({'error': 'Rates can\'t be negative'}, status: 400);
    }
    if (coachFee > maxMoney || perSessionRate > maxMoney) {
      return _json({
        'error': 'Rates must be ${money(maxMoney)} or less',
      }, status: 400);
    }
    // fee_settings is "the rate right now"; fee_rates records when it
    // started applying. A change takes effect from today, never before.
    await db.transaction((conn) async {
      await conn.execute(
        'UPDATE fee_settings SET coach_fee = :coachFee, '
        'per_session_rate = :perSessionRate, updated_by = :userId WHERE id = 1',
        {
          'coachFee': coachFee,
          'perSessionRate': perSessionRate,
          'userId': user.id,
        },
      );
      await conn.execute(
        'INSERT INTO fee_rates '
        '(effective_from, coach_fee, per_session_rate, set_by) '
        'VALUES (CURRENT_DATE, :coachFee, :perSessionRate, :userId) '
        'ON DUPLICATE KEY UPDATE coach_fee = VALUES(coach_fee), '
        'per_session_rate = VALUES(per_session_rate), set_by = VALUES(set_by)',
        {
          'coachFee': coachFee,
          'perSessionRate': perSessionRate,
          'userId': user.id,
        },
      );
    });
    return _json({'coachFee': coachFee, 'perSessionRate': perSessionRate});
  });

  // ---------------------------------------------------------------------
  // Bills
  // ---------------------------------------------------------------------

  /// A parent only ever gets their own children's bills.
  router.get('/payments', (Request request) async {
    final user = userOf(request);
    final scope = user.isAdmin ? '' : 'WHERE pl.parent_id = ${user.id}';
    final result = await db.execute('''
      SELECT
        pay.id, pay.player_id, pl.full_name AS player_name,
        pay.payment_type, pay.title, pay.description, pay.misc_type,
        pay.tournament_id, pay.period_month, pay.amount, pay.amount_paid,
        pay.status, pay.method, pay.paid_at, pay.created_at
      FROM payments pay
      JOIN players pl ON pl.id = pay.player_id
      $scope
      ORDER BY pay.created_at, pay.id
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// The full money history of one bill, oldest first.
  ///
  /// A parent can read it for their own children's bills: it's their
  /// receipt for what the club has recorded (the app is a tracker, and
  /// payments are made to the club directly). Each row's id is its receipt
  /// number. Which admin recorded it stays admin-side.
  router.get('/payments/<id>/transactions', (Request request, String id) async {
    final user = userOf(request);
    final paymentId = int.tryParse(id);
    if (paymentId == null || !await canAccessPayment(db, user, paymentId)) {
      return _json({'error': 'No payment with that id'}, status: 404);
    }
    final result = await db.execute(
      'SELECT t.id, t.kind, t.amount, t.method, t.note, t.created_at, '
      '${user.isAdmin ? 'u.full_name' : 'NULL'} AS recorded_by '
      'FROM payment_transactions t LEFT JOIN users u ON u.id = t.recorded_by '
      'WHERE t.payment_id = :id ORDER BY t.id',
      {'id': paymentId},
    );
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// Every bill ever raised and every movement of money against one, newest
  /// first — the admin's Transaction History screen.
  ///
  /// Two kinds of row, merged into one feed:
  ///   * 'request' — a bill was raised (payments.created_at). The amount is
  ///     what was asked for.
  ///   * payment / refund / reversal / waiver — money actually moved, from
  ///     payment_transactions. Refunds and reversals carry a negative amount,
  ///     the same sign convention the per-bill history uses.
  ///
  /// Admin-only: it spans every family, so it is deliberately not on the
  /// parent route list.
  router.get('/transactions', (Request request) async {
    // One month at a time. Without this the screen pulled every transaction
    // the club had ever made and threw most of them away on the phone.
    final month = request.url.queryParameters['month'];
    if (month != null && !monthPattern.hasMatch(month)) {
      return _json({'error': 'month must be YYYY-MM-01'}, status: 400);
    }
    // Checked against monthPattern above (four digits, two, then -01), then
    // written in as a literal — the same rule the rest of the month-keyed
    // queries follow. Each half is filtered before the union so both can use
    // their own index on created_at.
    String window(String column) => month == null
        ? ''
        : "WHERE $column >= '$month' "
              "AND $column < DATE_ADD('$month', INTERVAL 1 MONTH)";
    final result = await db.execute('''
      SELECT * FROM (
        SELECT
          'request'          AS kind,
          pay.id             AS payment_id,
          0                  AS transaction_id,
          pay.created_at     AS at,
          pay.amount         AS amount,
          NULL               AS method,
          NULL               AS note,
          NULL               AS recorded_by,
          pay.payment_type   AS payment_type,
          pay.title          AS title,
          pay.status         AS status,
          pay.player_id      AS player_id,
          pl.full_name       AS player_name
        FROM payments pay
        JOIN players pl ON pl.id = pay.player_id
        ${window('pay.created_at')}
        UNION ALL
        SELECT
          t.kind, t.payment_id, t.id, t.created_at, t.amount, t.method,
          t.note, u.full_name, pay.payment_type, pay.title, pay.status,
          pay.player_id, pl.full_name
        FROM payment_transactions t
        JOIN payments pay ON pay.id = t.payment_id
        JOIN players pl ON pl.id = pay.player_id
        LEFT JOIN users u ON u.id = t.recorded_by
        ${window('t.created_at')}
      ) feed
      ORDER BY at DESC, transaction_id DESC
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// Which months have anything in them, newest first, with that month's
  /// takings — enough for the screen to offer a month list without loading
  /// a single transaction.
  router.get('/transactions/months', (Request request) async {
    final result = await db.execute('''
      SELECT month, SUM(entries) AS entries, SUM(collected) AS collected
      FROM (
        SELECT DATE_FORMAT(created_at, '%Y-%m-01') AS month,
               COUNT(*) AS entries, 0 AS collected
        FROM payments
        GROUP BY month
        UNION ALL
        SELECT DATE_FORMAT(created_at, '%Y-%m-01'),
               COUNT(*),
               -- Waivers forgive a bill rather than move money, so they
               -- don't count towards what was collected.
               SUM(CASE WHEN kind IN ('payment','refund','reversal')
                        THEN amount ELSE 0 END)
        FROM payment_transactions
        GROUP BY 1
      ) m
      GROUP BY month
      ORDER BY month DESC
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.post(
    '/payments',
    (Request request) => _guard(() async {
      final user = userOf(request);
      final body = await _body(request);
      final playerId = int.tryParse('${body['playerId']}');
      final type = (body['type'] as String? ?? '').trim();
      final title = (body['title'] as String? ?? '').trim();
      final amount = _asNum(body['amount']);

      if (playerId == null || title.isEmpty || amount == null) {
        return _json({
          'error': 'playerId, title and amount are required',
        }, status: 400);
      }
      if (!const ['training_fee', 'tournament', 'misc'].contains(type)) {
        return _json({'error': 'Unknown payment type "$type"'}, status: 400);
      }
      // Training fees come from attendance, month by month. A bill added by
      // hand was charged on top of the automatic one for the same month.
      if (type == 'training_fee') {
        return _json({
          'error':
              'Training fees are billed automatically from attendance. To '
              'change one, set a custom total on the Training Fees screen.',
        }, status: 400);
      }
      final tooLong =
          lengthError('Title', title, 160) ??
          lengthError('Description', body['description'], 2000);
      if (tooLong != null) return _json({'error': tooLong}, status: 400);
      final miscType = _emptyToNull(body['miscType'] as String?);
      if (miscType != null &&
          !const ['uniform', 'merch', 'others'].contains(miscType)) {
        return _json({'error': 'Unknown item type "$miscType"'}, status: 400);
      }
      // A current player only: a bill for a removed player was accepted and
      // then sat unpaid where no screen shows it.
      if (!await canAccessPlayer(db, user, playerId)) {
        return _json({'error': 'No player with that id'}, status: 404);
      }
      final tournamentId = type == 'tournament' ? body['tournamentId'] : null;
      if (tournamentId != null) {
        final live = await db.execute(
          'SELECT id FROM tournaments WHERE id = :id AND deleted_at IS NULL',
          {'id': int.tryParse('$tournamentId') ?? 0},
        );
        if (live.rows.isEmpty) {
          return _json({
            'error': 'That tournament has been deleted',
          }, status: 404);
        }
      }
      // In fils, the way it's stored: 0.001 passed "more than zero", was
      // saved as 0.00, and sat as an open bill nobody could pay or waive.
      if (cents(amount) <= 0) {
        return _json({
          'error': 'Amount must be at least AED 0.01',
        }, status: 400);
      }
      if (amount > maxMoney) {
        return _json({
          'error': 'Amount must be ${money(maxMoney)} or less',
        }, status: 400);
      }
      final result = await withMoneyLock(db, (conn) async {
        // One live tournament fee per player per tournament. A refunded,
        // waived or voided one doesn't block billing them again.
        if (type == 'tournament' && tournamentId != null) {
          // Checked under the money lock, which the consent route also takes,
          // so a family can't decline in the same instant they're billed.
          // This also catches a player who isn't on the tournament at all:
          // consentBlocker only looks at who IS on it, so billing someone
          // else's child for it used to go straight through.
          final place = await conn.execute(
            'SELECT consent FROM tournament_players '
            'WHERE tournament_id = :tournamentId AND player_id = :playerId '
            'FOR UPDATE',
            {'playerId': playerId, 'tournamentId': tournamentId},
          );
          if (place.rows.isEmpty) {
            throw const LedgerError(
              "That player isn't on this tournament, so they can't be billed "
              'for it',
            );
          }
          if (place.rows.first.assoc()['consent'] != 'accepted') {
            throw const LedgerError(
              "That player's family hasn't accepted this tournament yet",
              409,
            );
          }
          final existing = await conn.execute(
            'SELECT id FROM payments WHERE player_id = :playerId '
            "AND tournament_id = :tournamentId AND payment_type = 'tournament' "
            "AND status IN ('pending','paid')",
            {'playerId': playerId, 'tournamentId': tournamentId},
          );
          if (existing.rows.isNotEmpty) {
            throw const LedgerError(
              'That player has already been billed for this tournament',
              409,
            );
          }
        }
        final inserted = await conn.execute(
          'INSERT INTO payments '
          '(player_id, payment_type, title, description, misc_type, '
          ' tournament_id, period_month, amount, status, created_by) '
          'VALUES (:playerId, :type, :title, :description, :miscType, '
          " :tournamentId, :periodMonth, :amount, 'pending', :createdBy)",
          {
            'playerId': playerId,
            'type': type,
            'title': title,
            'description': _emptyToNull(body['description'] as String?),
            'miscType': miscType,
            'tournamentId': tournamentId,
            'periodMonth': null,
            'amount': money(amount),
            'createdBy': user.id,
          },
        );
        final newId = inserted.lastInsertID.toInt();
        if (body['paid'] == true) {
          await recordPayment(
            conn,
            paymentId: newId,
            amount: amount,
            method: normalizeMethod(body['method']),
            recordedBy: user.id,
          );
          await notifyPaymentPaid(conn, paymentId: newId, sentBy: user.id);
        }
        return newId;
      });
      return _json({'id': result}, status: 201);
    }),
  );

  /// Pays part or all of one bill. Parents can only pay their own, recorded
  /// as 'online_test' until Stripe takes over this path.
  router.post(
    '/payments/<id>/pay',
    (Request request, String id) => _guard(() async {
      final user = userOf(request);
      final paymentId = int.tryParse(id);
      if (paymentId == null || !await canAccessPayment(db, user, paymentId)) {
        return _json({'error': 'No payment with that id'}, status: 404);
      }
      final body = await _body(request);
      final amount = _asNum(body['amount']);
      if (amount == null) {
        return _json({'error': 'Enter an amount above zero'}, status: 400);
      }
      final method = user.isAdmin
          ? normalizeMethod(body['method'])
          : 'online_test';
      final outcome = await withMoneyLock(db, (conn) async {
        await _refreshTrainingFeeBill(conn, paymentId);
        final paid = await recordPayment(
          conn,
          paymentId: paymentId,
          amount: amount,
          method: method,
          recordedBy: user.id,
        );
        // The admin's payment settled the bill: tell the family. A family
        // paying in the app sees it paid already.
        if (user.isAdmin && paid.status == 'paid') {
          await notifyPaymentPaid(conn, paymentId: paymentId, sentBy: user.id);
        }
        return paid;
      });
      return _json({
        'id': paymentId,
        'amountPaid': money(outcome.amountPaid),
        'remaining': money(outcome.remaining),
        'status': outcome.status,
      });
    }),
  );

  /// Settles everything still owed on a bill, by hand (cash, bank, card).
  router.post(
    '/payments/<id>/paid',
    (Request request, String id) => _guard(() async {
      final user = userOf(request);
      final paymentId = int.tryParse(id) ?? 0;
      final body = await _body(request);
      await withMoneyLock(db, (conn) async {
        await _refreshTrainingFeeBill(conn, paymentId);
        final row = await lockPayment(conn, paymentId);
        if (row.status == 'paid') return;
        if (row.status != 'pending') {
          throw LedgerError('That payment is ${row.status}', 409);
        }
        await recordPayment(
          conn,
          paymentId: paymentId,
          amount: row.amount - row.paid,
          method: normalizeMethod(body['method']),
          recordedBy: user.id,
        );
        await notifyPaymentPaid(conn, paymentId: paymentId, sentBy: user.id);
      });
      return _json({'id': paymentId, 'status': 'paid'});
    }),
  );

  /// Undoes payments recorded by mistake (see recordReversal).
  router.post(
    '/payments/<id>/unpaid',
    (Request request, String id) => _guard(() async {
      final user = userOf(request);
      final paymentId = int.tryParse(id) ?? 0;
      await withMoneyLock(db, (conn) async {
        await takeBackCarriedCredit(
          conn,
          paymentId: paymentId,
          recordedBy: user.id,
        );
        final type = await recordReversal(
          conn,
          paymentId: paymentId,
          recordedBy: user.id,
          note: 'Payment undone by admin',
        );
        // A voided past-month fee needs its bill raised again straight away.
        if (type == 'training_fee') await reconcilePastMonths(conn);
      });
      return _json({'id': paymentId, 'undone': true});
    }),
  );

  /// Refunds a tournament or misc bill (see recordRefund). Training fees go
  /// through /training-fees/refund, which only allows refunding overpayment
  /// — refunding a fee that's genuinely owed would just get it billed again.
  router.post(
    '/payments/<id>/refund',
    (Request request, String id) => _guard(() async {
      final user = userOf(request);
      final paymentId = int.tryParse(id) ?? 0;
      final body = await _body(request);
      final amount = _asNum(body['amount']);
      if (amount == null) {
        return _json({'error': 'Enter an amount above zero'}, status: 400);
      }
      final noteTooLong = lengthError('Note', body['note'], 255);
      if (noteTooLong != null)
        return _json({'error': noteTooLong}, status: 400);
      await withMoneyLock(db, (conn) async {
        final row = await lockPayment(conn, paymentId);
        if (row.type == 'training_fee') {
          throw const LedgerError(
            'Refund training fees from the Training Fees screen, which only '
            'refunds what was overpaid.',
            409,
          );
        }
        await recordRefund(
          conn,
          paymentId: paymentId,
          amount: amount,
          method: normalizeMethod(body['method']),
          recordedBy: user.id,
          note: _emptyToNull(body['note'] as String?),
        );
      });
      return _json({'id': paymentId, 'refunded': money(amount)});
    }),
  );

  /// Writes off what's still owed on a bill (see recordWaiver).
  router.post(
    '/payments/<id>/waive',
    (Request request, String id) => _guard(() async {
      final user = userOf(request);
      final paymentId = int.tryParse(id) ?? 0;
      final body = await _body(request);
      final noteTooLong = lengthError('Note', body['note'], 255);
      if (noteTooLong != null)
        return _json({'error': noteTooLong}, status: 400);
      await withMoneyLock(
        db,
        (conn) => recordWaiver(
          conn,
          paymentId: paymentId,
          recordedBy: user.id,
          note: _emptyToNull(body['note'] as String?) ?? 'Waived by admin',
        ),
      );
      return _json({'id': paymentId, 'waived': true});
    }),
  );

  /// Only a bill nothing was ever paid on can be deleted. Once money has
  /// moved there's history to keep: refund, waive or undo it instead.
  router.delete(
    '/payments/<id>',
    (Request request, String id) => _guard(() async {
      final paymentId = int.tryParse(id) ?? 0;
      await withMoneyLock(db, (conn) async {
        final row = await lockPayment(conn, paymentId);
        final logged = await conn.execute(
          'SELECT COUNT(*) AS n FROM payment_transactions WHERE payment_id = :id',
          {'id': paymentId},
        );
        if (cents(row.paid) > 0 ||
            int.parse('${logged.rows.first.assoc()['n']}') > 0) {
          throw const LedgerError(
            'Money has been recorded against this bill, so it can\'t be '
            'deleted. Refund, waive or undo it instead.',
            409,
          );
        }
        // The bill an approved order turned into: without it the order isn't
        // going ahead. It used to stay "approved" with no bill behind it.
        await conn.execute(
          "UPDATE orders SET status = 'rejected' WHERE payment_id = :id",
          {'id': paymentId},
        );
        await conn.execute('DELETE FROM payments WHERE id = :id', {
          'id': paymentId,
        });
      });
      return _json({'id': paymentId, 'deleted': true});
    }),
  );

  // ---------------------------------------------------------------------
  // Per-player monthly fee overrides
  // ---------------------------------------------------------------------

  router.get('/training-fee-overrides', (Request request) async {
    final user = userOf(request);
    final scope = user.isAdmin ? '' : 'WHERE pl.parent_id = ${user.id}';
    final result = await db.execute('''
      SELECT o.player_id, pl.full_name AS player_name,
             o.period_month, o.amount, o.note
      FROM training_fee_overrides o
      JOIN players pl ON pl.id = o.player_id
      $scope
      ORDER BY o.period_month DESC, pl.full_name
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.put('/training-fee-overrides', (Request request) async {
    final user = userOf(request);
    final body = await _body(request);
    final playerId = int.tryParse('${body['playerId']}');
    final periodMonth = '${body['periodMonth']}';
    final amount = _asNum(body['amount']);
    // The month must be a first-of-month key, or billing never finds it: a
    // custom total saved for "2026-09-15" was stored and silently ignored.
    if (playerId == null ||
        !monthPattern.hasMatch(periodMonth) ||
        amount == null) {
      return _json({
        'error': 'playerId, periodMonth (YYYY-MM-01) and amount are required',
      }, status: 400);
    }
    if (amount < 0 || amount > maxMoney) {
      return _json({
        'error': 'Enter an amount from 0 to ${money(maxMoney)}',
      }, status: 400);
    }
    if (!await canAccessPlayer(db, user, playerId)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    final noteTooLong = lengthError('Note', body['note'], 255);
    if (noteTooLong != null) return _json({'error': noteTooLong}, status: 400);
    try {
      await db.execute(
        'INSERT INTO training_fee_overrides '
        '(player_id, period_month, amount, note, set_by) '
        'VALUES (:playerId, :periodMonth, :amount, :note, :setBy) '
        'ON DUPLICATE KEY UPDATE amount = VALUES(amount), '
        'note = VALUES(note), set_by = VALUES(set_by)',
        {
          'playerId': playerId,
          'periodMonth': periodMonth,
          'amount': amount,
          'note': _emptyToNull(body['note'] as String?),
          'setBy': user.id,
        },
      );
      return _json({
        'playerId': playerId,
        'periodMonth': periodMonth,
        'amount': amount,
      });
    } on MySQLServerException {
      rethrow;
    }
  });

  router.delete('/training-fee-overrides/<playerId>/<periodMonth>', (
    Request request,
    String playerId,
    String periodMonth,
  ) async {
    if (int.tryParse(playerId) == null || !monthPattern.hasMatch(periodMonth)) {
      return _json({
        'error': 'Use /training-fee-overrides/<playerId>/<YYYY-MM-01>',
      }, status: 400);
    }
    final result = await db.execute(
      'DELETE FROM training_fee_overrides '
      'WHERE player_id = :playerId AND period_month = :periodMonth',
      {'playerId': playerId, 'periodMonth': periodMonth},
    );
    return _json({
      'playerId': int.parse(playerId),
      'periodMonth': periodMonth,
      'cleared': result.affectedRows.toInt() > 0,
    });
  });

  return router;
}

num? _asNum(Object? value) => readMoney(value);

/// Brings a past month's training-fee bill up to date with attendance
/// before money is put on it. The hourly close is otherwise the only thing
/// that re-prices it, so a correction made since then (a session marked
/// exempt, say) would have the family pay the old, higher amount.
Future<void> _refreshTrainingFeeBill(
  MySQLConnection conn,
  int paymentId,
) async {
  final row = await lockPayment(conn, paymentId);
  if (row.type != 'training_fee') return;
  await reconcilePastMonths(conn);
  final still = await conn.execute(
    "SELECT id FROM payments WHERE id = :id AND status <> 'void'",
    {'id': paymentId},
  );
  if (still.rows.isEmpty) {
    throw const LedgerError(
      'This bill was recalculated from attendance and nothing is owed on it '
      'any more. Please refresh.',
      409,
    );
  }
}

String? _emptyToNull(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
