import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'billing.dart';
import 'db.dart';
import 'notices.dart';
import 'ledger.dart';
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

List<int> _ids(Object? raw) => (raw as List? ?? [])
    .map((e) => int.tryParse('$e'))
    .whereType<int>()
    .toSet()
    .toList();

/// Takes back every bill for a tournament roster slot that hasn't been
/// fully paid. Nothing paid: the bill goes (or is voided if it has
/// history). Part-paid: the unpaid remainder is waived and what was paid
/// stays on record. Fully paid bills are left alone — the caller reports
/// them so the admin can decide about a refund.
Future<int> _withdrawUnpaidBills(
  MySQLConnection conn, {
  required Object tournamentId,
  int? playerId,
  required int recordedBy,
  required String note,
}) async {
  final rows = await conn.execute(
    'SELECT id, amount_paid FROM payments WHERE tournament_id = :tournamentId '
    "AND status = 'pending' ${playerId == null ? '' : 'AND player_id = $playerId'}",
    {'tournamentId': tournamentId},
  );
  var withdrawn = 0;
  for (final row in rows.rows) {
    final r = row.assoc();
    final paymentId = int.parse(r['id']!);
    if (cents(asMoney(r['amount_paid'])) > 0) {
      await recordWaiver(
        conn,
        paymentId: paymentId,
        recordedBy: recordedBy,
        note: note,
      );
    } else {
      final logged = await conn.execute(
        'SELECT COUNT(*) AS n FROM payment_transactions WHERE payment_id = :id',
        {'id': paymentId},
      );
      final hasHistory = int.parse('${logged.rows.first.assoc()['n']}') > 0;
      await conn.execute(
        hasHistory
            ? "UPDATE payments SET status = 'void' WHERE id = :id"
            : 'DELETE FROM payments WHERE id = :id',
        {'id': paymentId},
      );
    }
    withdrawn++;
  }
  return withdrawn;
}

/// Tournaments and their rosters, keyed by player ID.
Router buildTournamentsRouter(Db db) {
  final router = Router();

  /// A parent sees every tournament but only their own children on its
  /// roster (and only their amounts).
  router.get('/tournaments', (Request request) async {
    final user = userOf(request);
    final tournaments = await db.execute('''
      SELECT t.id, t.name, t.location, t.payment_info, c.code AS category
      FROM tournaments t
      JOIN categories c ON c.id = t.category_id
      WHERE t.deleted_at IS NULL
      ORDER BY t.id DESC
    ''');
    // Grouped here, not GROUP_CONCAT'd — see GET /sessions for why.
    final rosters = await db.execute('''
      SELECT tp.tournament_id, p.id, p.full_name, p.parent_id, tp.amount,
             tp.consent, tp.decline_reason,
             DATE_FORMAT(tp.responded_at, '%Y-%m-%d %H:%i') AS responded_at,
             (responder.role = 'admin') AS answered_by_academy
      FROM tournament_players tp
      JOIN players p ON p.id = tp.player_id AND p.is_active = 1
      LEFT JOIN users responder ON responder.id = tp.responded_by
      ORDER BY p.full_name, p.id
    ''');
    final roster = <String, List<Map<String, String?>>>{};
    for (final row in rosters.rows) {
      final r = row.assoc();
      if (!user.isAdmin && r['parent_id'] != '${user.id}') continue;
      roster.putIfAbsent(r['tournament_id']!, () => []).add(r);
    }
    final out = <Map<String, dynamic>>[];
    for (final row in tournaments.rows) {
      final t = row.assoc();
      final players = roster[t['id']] ?? const [];
      out.add({
        ...t,
        'player_ids': [for (final p in players) int.parse(p['id']!)],
        'player_names': [for (final p in players) p['full_name']],
        'player_amounts': [for (final p in players) p['amount']],
        // 'pending', 'accepted' or 'declined', index for index.
        'player_consents': [for (final p in players) p['consent']],
        // Why a family declined (null if they didn't, or gave no reason),
        // and when they answered, index for index.
        'player_decline_reasons': [
          for (final p in players) p['decline_reason'],
        ],
        'player_responded_at': [for (final p in players) p['responded_at']],
        // True where the academy answered for the family (say they
        // couldn't log in), index for index.
        'player_answered_by_academy': [
          for (final p in players) p['answered_by_academy'] == '1',
        ],
      });
    }
    return _json(out);
  });

  router.post('/tournaments', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final name = (body['name'] as String? ?? '').trim();
    final category = (body['category'] as String? ?? '').trim();
    if (name.isEmpty || category.isEmpty) {
      return _json({'error': 'Name and category are required'}, status: 400);
    }
    final tooLong =
        lengthError('Tournament name', name, 120) ??
        lengthError('Location', body['location'], 160);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);
    try {
      final result = await db.execute(
        'INSERT INTO tournaments (category_id, name, location, created_by) '
        'SELECT id, :name, :location, :createdBy FROM categories '
        'WHERE code = :category AND is_active = 1',
        {
          'name': name,
          'location': body['location'] as String?,
          'category': category,
          'createdBy': user.id,
        },
      );
      if (result.affectedRows.toInt() == 0) {
        return _json({'error': 'No category called $category'}, status: 400);
      }
      return _json({
        'id': result.lastInsertID.toInt(),
        'name': name,
      }, status: 201);
    } on MySQLServerException {
      rethrow;
    }
  });

  router.put('/tournaments/<id>', (Request request, String id) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final name = (body['name'] as String?)?.trim();
    final categoryCode = (body['category'] as String?)?.trim();
    final hasPaymentInfo = body.containsKey('paymentInfo');

    if ((name == null || name.isEmpty) &&
        (categoryCode == null || categoryCode.isEmpty) &&
        !hasPaymentInfo) {
      return _json({
        'error': 'name, category or paymentInfo is required',
      }, status: 400);
    }
    final tooLong =
        lengthError('Tournament name', name, 120) ??
        lengthError('Payment details', body['paymentInfo'], 160);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    int? categoryId;
    if (categoryCode != null && categoryCode.isNotEmpty) {
      final found = await db.execute(
        'SELECT id FROM categories WHERE code = :category AND is_active = 1',
        {'category': categoryCode},
      );
      if (found.rows.isEmpty) {
        return _json({
          'error': 'No category called $categoryCode',
        }, status: 400);
      }
      categoryId = int.parse(found.rows.first.assoc()['id'] as String);
    }

    final setClauses = <String>[];
    final params = <String, dynamic>{'id': id};
    if (name != null && name.isNotEmpty) {
      setClauses.add('name = :name');
      params['name'] = name;
    }
    if (categoryId != null) {
      setClauses.add('category_id = :categoryId');
      params['categoryId'] = categoryId;
    }
    if (hasPaymentInfo) {
      setClauses.add('payment_info = :paymentInfo');
      params['paymentInfo'] = (body['paymentInfo'] as String?)?.trim();
    }

    try {
      await db.execute(
        'UPDATE tournaments SET ${setClauses.join(', ')} WHERE id = :id',
        params,
      );
      final exists = await db.execute(
        'SELECT id FROM tournaments WHERE id = :id',
        {'id': id},
      );
      if (exists.rows.isEmpty) {
        return _json({'error': 'No tournament with that id'}, status: 404);
      }
      return _json({
        'id': int.parse(id),
        if (name != null) 'name': name,
        if (categoryCode != null) 'category': categoryCode,
      });
    } on MySQLServerException {
      rethrow;
    }
  });

  /// Removes a tournament without erasing what already happened.
  ///
  /// It used to be a hard delete, which cascaded: every game scheduled for
  /// it vanished (past ones included, with their attendance), and messages
  /// sent to its players lost their audience so parents stopped seeing
  /// them. Now it's hidden instead:
  ///   * unpaid bills are taken back (they used to stay owed forever)
  ///   * games after today are cancelled; past games stay on record
  ///   * paid bills and messages already sent are untouched
  router.delete('/tournaments/<id>', (Request request, String id) async {
    final user = userOf(request);
    try {
      final deleted = await withMoneyLock(db, (conn) async {
        final found = await conn.execute(
          'SELECT id FROM tournaments WHERE id = :id AND deleted_at IS NULL '
          'FOR UPDATE',
          {'id': id},
        );
        if (found.rows.isEmpty) return false;
        final games = await conn.execute(
          'SELECT id FROM sessions WHERE tournament_id = :id '
          'AND is_cancelled = 0 AND session_date > CURRENT_DATE',
          {'id': id},
        );
        // Everyone on it hears straight away, with the games it takes with
        // it listed in the same message. Written before the unpaid bills
        // are withdrawn, while it can still tell whether there were any.
        await notifyTournamentCancelled(
          conn,
          tournamentId: id,
          sentBy: user.id,
          cancelledGames: [
            for (final row in games.rows) int.parse(row.assoc()['id']!),
          ],
        );
        await _withdrawUnpaidBills(
          conn,
          tournamentId: id,
          recordedBy: user.id,
          note: 'Tournament deleted',
        );
        await conn.execute(
          'UPDATE tournaments SET deleted_at = NOW() WHERE id = :id',
          {'id': id},
        );
        await conn.execute(
          'UPDATE sessions SET is_cancelled = 1 WHERE tournament_id = :id '
          'AND is_cancelled = 0 AND session_date > CURRENT_DATE',
          {'id': id},
        );
        return true;
      });
      if (!deleted) {
        return _json({'error': 'No tournament with that id'}, status: 404);
      }
      return _json({'id': int.parse(id), 'deleted': true});
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    }
  });

  /// A family answering a tournament invitation: {"accept": true|false}.
  ///
  /// Parents answer for their own children (an admin can too, say after a
  /// phone call). The answer can be changed until the fee has been sent;
  /// after that the club has to be asked.
  router.post('/tournaments/<id>/players/<playerId>/consent', (
    Request request,
    String id,
    String playerId,
  ) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final accept = body['accept'];
    if (accept is! bool) {
      return _json({'error': 'accept must be true or false'}, status: 400);
    }
    final pid = int.tryParse(playerId);
    if (pid == null || !await canAccessPlayer(db, user, pid)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    final params = {'tournamentId': int.parse(id), 'playerId': pid};
    final consent = accept ? 'accepted' : 'declined';
    // Why they're declining ("reason"): required from a family, optional
    // when the admin answers for them.
    final reasonText = accept ? '' : normalizeSpaces('${body['reason'] ?? ''}');
    final reason = reasonText.isEmpty ? null : reasonText;
    // A family must say why. The app from before the reason box (1.0.23)
    // can't, so it's told to update; accepting still works there. (No
    // slash or link in this text: the app shows a sentence with one as a
    // generic error.)
    if (!accept && !user.isAdmin && reason == null) {
      return _json({
        'error':
            'To decline, please update the DSA Elite app (the academy will '
            'send you the link), so you can tell the academy why.',
        'code': 'reason_required',
      }, status: 400);
    }
    if (reason != null && reason.length > 300) {
      return _json({
        'error': 'The reason must be 300 characters or fewer',
      }, status: 400);
    }
    if (reason != null && hasEmoji(reason)) {
      return _json({
        'error': 'Please leave emoji out of the reason',
      }, status: 400);
    }
    // Under the money lock, like billing: the "already billed?" check and
    // the answer can't be split by a payment request landing in between.
    final problem = await withMoneyLock(db, (conn) async {
      final onRoster = await conn.execute(
        'SELECT consent FROM tournament_players '
        'WHERE tournament_id = :tournamentId AND player_id = :playerId '
        'FOR UPDATE',
        params,
      );
      if (onRoster.rows.isEmpty) {
        return (status: 404, error: 'That player is not on this tournament');
      }
      final billed = await conn.execute(
        'SELECT COUNT(*) AS n FROM payments '
        'WHERE tournament_id = :tournamentId AND player_id = :playerId '
        "AND status IN ('pending','paid')",
        params,
      );
      if (int.parse('${billed.rows.first.assoc()['n']}') > 0) {
        return (
          status: 409,
          error:
              "The fee for this tournament has already been sent, so the "
              "answer can't be changed here. Please contact the academy.",
        );
      }
      final before = onRoster.rows.first.assoc()['consent'];
      await conn.execute(
        'UPDATE tournament_players SET consent = :consent, '
        'decline_reason = :reason, '
        'responded_at = NOW(), responded_by = :userId '
        'WHERE tournament_id = :tournamentId AND player_id = :playerId',
        {...params, 'consent': consent, 'reason': reason, 'userId': user.id},
      );
      // A family declining: the admin hears why, in Messages.
      if (!accept && before != 'declined' && !user.isAdmin) {
        await notifyTournamentDeclined(
          conn,
          tournamentId: int.parse(id),
          playerId: pid,
          reason: reason,
          sentBy: user.id,
        );
      }
      return null;
    });
    if (problem != null) {
      return _json({'error': problem.error}, status: problem.status);
    }
    return _json({
      'tournamentId': int.parse(id),
      'playerId': pid,
      'consent': consent,
    });
  });

  /// Admin: reminds families who haven't answered the invitation yet.
  /// {"playerIds": [..]} for those children only; no body = everyone still
  /// waiting. Each gets a message and a phone notification.
  router.post('/tournaments/<id>/remind', (Request request, String id) async {
    final tournamentId = int.tryParse(id);
    if (tournamentId == null || !await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    final raw = await request.readAsString();
    final decoded = raw.trim().isEmpty ? null : jsonDecode(raw);
    final body = decoded is Map ? decoded : const {};
    final playerIds = body.containsKey('playerIds')
        ? _ids(body['playerIds'])
        : null;
    final result = await db.transaction(
      (conn) => notifyTournamentReminder(
        conn,
        tournamentId: tournamentId,
        sentBy: userOf(request).id,
        playerIds: playerIds,
      ),
    );
    return _json({'reminded': result.reminded, 'skipped': result.skipped});
  });

  router.post('/tournaments/<id>/players', (Request request, String id) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final playerIds = _ids(body['playerIds']);
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    try {
      // Younger players may play up; older ones can't play down. The app's
      // picker already hid them, but the server took anyone it was sent.
      final tooOld = <String>[];
      final toAdd = <int>[];
      for (final playerId in playerIds) {
        final age = await db.execute(
          'SELECT p.full_name, YEAR(p.birthday) < c.birth_year AS too_old '
          'FROM players p '
          'JOIN tournaments t ON t.id = :tournamentId '
          'JOIN categories c ON c.id = t.category_id '
          'WHERE p.id = :playerId AND p.is_active = 1 AND p.is_approved = 1',
          {'tournamentId': id, 'playerId': playerId},
        );
        if (age.rows.isNotEmpty && age.rows.first.assoc()['too_old'] == '1') {
          tooOld.add(age.rows.first.assoc()['full_name']!);
          continue;
        }
        toAdd.add(playerId);
      }
      // A child taken off after paying and then put back on has already
      // said yes, and paid: they come back accepted. As a fresh "pending"
      // invitation they were stuck — the fee on file blocked the family
      // from answering, and them from being billed again.
      //
      // Under the money lock, which refunds take too, so a refund landing
      // at the same moment can't leave them accepted with nothing paid.
      final tournamentId = int.tryParse(id) ?? 0;
      final consents = await withMoneyLock(db, (conn) async {
        for (final playerId in toAdd) {
          // Validated integers, written in: the driver's named parameters
          // don't survive the subquery.
          await conn.execute('''
            INSERT IGNORE INTO tournament_players
              (tournament_id, player_id, consent, responded_at)
            SELECT t.id, p.id,
                   IF(paid.n > 0, 'accepted', 'pending'),
                   IF(paid.n > 0, NOW(), NULL)
            FROM players p
            JOIN tournaments t ON t.id = $tournamentId AND t.deleted_at IS NULL
            JOIN (
              SELECT COUNT(*) AS n FROM payments
              WHERE tournament_id = $tournamentId AND player_id = $playerId
                AND payment_type = 'tournament'
                AND status IN ('pending','paid')
            ) paid
            WHERE p.id = $playerId AND p.is_active = 1 AND p.is_approved = 1
          ''');
        }
        // Each child's standing as the app should now show it: 'accepted'
        // for one put back on with their fee paid, not always 'pending'.
        if (toAdd.isEmpty) return <String, String?>{};
        final rows = await conn.execute(
          'SELECT player_id, consent FROM tournament_players '
          'WHERE tournament_id = $tournamentId '
          'AND player_id IN (${toAdd.join(',')})',
        );
        return {
          for (final row in rows.rows)
            row.assoc()['player_id']!: row.assoc()['consent'],
        };
      });
      if (tooOld.isNotEmpty && tooOld.length == playerIds.length) {
        return _json({
          'error':
              '${tooOld.join(', ')} ${tooOld.length == 1 ? 'is' : 'are'} too '
              'old for this tournament\'s category.',
        }, status: 400);
      }
      return _json({
        'tournamentId': int.parse(id),
        'added': playerIds,
        'consents': consents,
        if (tooOld.isNotEmpty) 'tooOld': tooOld,
      });
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    } on MySQLServerException {
      rethrow;
    }
  });

  /// Each player's amount, sent as {"<playerId>": 400, ...}.
  ///
  /// Also re-prices bills already sent but not paid off. A bill can't be
  /// re-priced below what's already been paid on it, and a fully paid bill
  /// isn't touched: that money changed hands at the price quoted. Those
  /// players' names come back so the admin knows who didn't move.
  router.put('/tournaments/<id>/amounts', (Request request, String id) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final amounts = (body['amounts'] as Map?) ?? const {};
    if (amounts.values.any(
      (v) => (_asNum(v) ?? -1) < 0 || (_asNum(v) ?? 0) > maxMoney,
    )) {
      return _json({
        'error': 'Each amount must be a number from 0 to ${money(maxMoney)}',
      }, status: 400);
    }
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    try {
      final alreadyPaid = await withMoneyLock(db, (conn) async {
        final unchanged = <String>[];
        for (final entry in amounts.entries) {
          final playerId = int.tryParse('${entry.key}');
          if (playerId == null) continue;
          final amount = _asNum(entry.value) ?? 0;

          await conn.execute(
            'UPDATE tournament_players SET amount = :amount '
            'WHERE tournament_id = :tournamentId AND player_id = :playerId',
            {'tournamentId': id, 'playerId': playerId, 'amount': money(amount)},
          );

          // Free for this player now: take back what they haven't paid, as
          // removing them from the roster does. The unpaid bill used to stay
          // owed at the old price, with the player listed as "already paid".
          if (cents(amount) <= 0) {
            await _withdrawUnpaidBills(
              conn,
              tournamentId: id,
              playerId: playerId,
              recordedBy: user.id,
              note: 'Tournament fee changed to 0',
            );
            final kept = await conn.execute(
              'SELECT p.full_name FROM payments pay '
              'JOIN players p ON p.id = pay.player_id '
              'WHERE pay.tournament_id = :tournamentId '
              "AND pay.player_id = :playerId AND pay.status = 'paid'",
              {'tournamentId': id, 'playerId': playerId},
            );
            for (final row in kept.rows) {
              unchanged.add(row.assoc()['full_name']!);
            }
            continue;
          }

          final bills = await conn.execute(
            'SELECT pay.id, pay.amount_paid, pay.status, p.full_name '
            'FROM payments pay JOIN players p ON p.id = pay.player_id '
            'WHERE pay.tournament_id = :tournamentId AND pay.player_id = :playerId '
            "AND pay.status IN ('pending','paid') FOR UPDATE",
            {'tournamentId': id, 'playerId': playerId},
          );
          for (final row in bills.rows) {
            final r = row.assoc();
            final paid = asMoney(r['amount_paid']);
            if (r['status'] == 'paid' || cents(amount) < cents(paid)) {
              unchanged.add(r['full_name']!);
              continue;
            }
            final settled = cents(paid) >= cents(amount);
            await conn.execute(
              "UPDATE payments SET amount = :amount, status = :status, "
              "paid_at = ${settled ? 'COALESCE(paid_at, NOW())' : 'paid_at'} "
              'WHERE id = :id',
              {
                'id': r['id'],
                'amount': money(amount),
                'status': settled ? 'paid' : 'pending',
              },
            );
          }
        }
        return unchanged;
      });
      return _json({
        'tournamentId': int.parse(id),
        'saved': amounts.length,
        'alreadyPaid': alreadyPaid,
      });
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    } on MySQLServerException {
      rethrow;
    }
  });

  /// Takes a player off the roster and takes back their unpaid bill. Bills
  /// with money on them come back as `paidPayments` so the app can offer a
  /// refund on the spot instead of leaving it to be remembered.
  router.delete('/tournaments/<id>/players/<playerId>', (
    Request request,
    String id,
    String playerId,
  ) async {
    final user = userOf(request);
    final pid = int.tryParse(playerId);
    if (pid == null) {
      return _json({
        'error': 'That player is not on this tournament',
      }, status: 404);
    }
    // A family can take their own child off (Remove on their invitations
    // screen) — but not once a fee has been sent: then money is owed or has
    // moved, and that's for the club to sort out, not a tap to undo.
    if (!user.isAdmin && !await canAccessPlayer(db, user, pid)) {
      return _json({
        'error': 'That player is not on this tournament',
      }, status: 404);
    }
    try {
      final outcome = await withMoneyLock(db, (conn) async {
        if (!user.isAdmin) {
          final billed = await conn.execute(
            'SELECT COUNT(*) AS n FROM payments '
            'WHERE tournament_id = :tournamentId AND player_id = :playerId '
            "AND status IN ('pending','paid')",
            {'tournamentId': int.tryParse(id) ?? 0, 'playerId': pid},
          );
          if (int.parse('${billed.rows.first.assoc()['n']}') > 0) {
            throw const LedgerError(
              "The fee for this tournament has already been sent, so it can't "
              'be removed here. Please contact the academy.',
              409,
            );
          }
        }
        final removed = await conn.execute(
          'DELETE FROM tournament_players '
          'WHERE tournament_id = :tournamentId AND player_id = :playerId',
          {'tournamentId': id, 'playerId': pid},
        );
        if (removed.affectedRows.toInt() == 0) return null;

        final withdrawn = await _withdrawUnpaidBills(
          conn,
          tournamentId: id,
          playerId: pid,
          recordedBy: user.id,
          note: 'Removed from the tournament',
        );
        final kept = await conn.execute(
          'SELECT id, amount_paid FROM payments '
          'WHERE tournament_id = :tournamentId AND player_id = :playerId '
          "AND status = 'paid' AND amount_paid > 0",
          {'tournamentId': id, 'playerId': pid},
        );
        return (
          withdrawn: withdrawn,
          paid: [
            for (final row in kept.rows)
              {
                'id': int.parse(row.assoc()['id']!),
                'amountPaid': row.assoc()['amount_paid'],
              },
          ],
        );
      });

      if (outcome == null) {
        return _json({
          'error': 'That player is not on this tournament',
        }, status: 404);
      }
      return _json({
        'tournamentId': int.parse(id),
        'removed': pid,
        'cancelledRequests': outcome.withdrawn,
        'keptPaid': outcome.paid.length,
        'paidPayments': outcome.paid,
      });
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    } on MySQLServerException {
      rethrow;
    }
  });

  /// The tournament's opposing teams (its Standings screen), oldest first,
  /// each with its standing: games won by DSA and by them, counted from the
  /// final scores of the games against that team.
  router.get('/tournaments/<id>/opponents', (Request request, String id) async {
    if (!await _canView(db, userOf(request), id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    final rows = await db.execute(
      'SELECT o.id, o.name, '
      '  COUNT(CASE WHEN s.dsa_score > s.opponent_score THEN 1 END) '
      '    AS dsa_wins, '
      '  COUNT(CASE WHEN s.dsa_score < s.opponent_score THEN 1 END) '
      '    AS opponent_wins '
      'FROM tournament_opponents o '
      'LEFT JOIN sessions s ON s.tournament_id = o.tournament_id '
      '  AND s.is_cancelled = 0 '
      "  AND LOWER(s.opponent) = LOWER(CONCAT('$_opponentPrefix', o.name)) "
      'WHERE o.tournament_id = :id '
      'GROUP BY o.id, o.name ORDER BY o.id',
      {'id': id},
    );
    return _json([
      for (final row in rows.rows)
        {
          'id': int.parse(row.assoc()['id']!),
          'name': row.assoc()['name'],
          'dsa_wins': int.parse(row.assoc()['dsa_wins']!),
          'opponent_wins': int.parse(row.assoc()['opponent_wins']!),
        },
    ]);
  });

  /// Adds an opposing team: {"name": "Desert Warriors"}.
  router.post('/tournaments/<id>/opponents', (
    Request request,
    String id,
  ) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final raw = body['name'];
    final name = raw is String ? normalizeSpaces(raw) : '';
    if (name.isEmpty) {
      return _json({'error': "Please enter the team's name"}, status: 400);
    }
    if (hasEmoji(name)) {
      return _json({'error': "A team name can't contain emoji"}, status: 400);
    }
    final tooLong = lengthError('Team name', name, _maxTeamName);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    final taken = await db.execute(
      'SELECT name FROM tournament_opponents '
      'WHERE tournament_id = :id AND LOWER(name) = LOWER(:name)',
      {'id': id, 'name': name},
    );
    if (taken.rows.isNotEmpty) {
      return _json({
        'error': '${taken.rows.first.assoc()['name']} is already on the list',
      }, status: 409);
    }
    final result = await db.execute(
      'INSERT INTO tournament_opponents (tournament_id, name) '
      'VALUES (:id, :name)',
      {'id': id, 'name': name},
    );
    return _json({
      'id': result.lastInsertID.toInt(),
      'name': name,
      'dsa_wins': 0,
      'opponent_wins': 0,
    }, status: 201);
  });

  /// The tournament's games on the schedule (cancelled ones left out),
  /// earliest first, with each one's final score once it's entered.
  router.get('/tournaments/<id>/games', (Request request, String id) async {
    if (!await _canView(db, userOf(request), id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    if (!await _isLive(db, id)) {
      return _json({'error': 'No tournament with that id'}, status: 404);
    }
    final rows = await db.execute(
      _gameSelect +
          'WHERE tournament_id = :id AND is_cancelled = 0 '
              'ORDER BY session_date, start_time, id',
      {'id': id},
    );
    return _json([for (final row in rows.rows) _gameJson(row.assoc())]);
  });

  /// A played game's final score: {"dsaScore": 54, "opponentScore": 48}.
  /// The winner is whoever scored more, so a tie is refused (basketball
  /// plays overtime). Both null takes the result back off.
  router.put('/tournaments/<id>/games/<gameId>/result', (
    Request request,
    String id,
    String gameId,
  ) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final dsa = body['dsaScore'];
    final them = body['opponentScore'];
    final clearing = dsa == null && them == null;
    if (!clearing) {
      if (!_isScore(dsa) || !_isScore(them)) {
        return _json({
          'error':
              'Enter both final scores as whole numbers from 0 to '
              '$_maxScore',
        }, status: 400);
      }
      if (dsa == them) {
        return _json({
          'error':
              "A game can't end in a tie. Enter the score after "
              'overtime.',
        }, status: 400);
      }
    }
    final found = await db.execute(
      'SELECT opponent, session_date > CURRENT_DATE AS upcoming '
      'FROM sessions WHERE id = :gameId AND tournament_id = :id '
      'AND is_cancelled = 0',
      {'gameId': int.tryParse(gameId) ?? 0, 'id': int.tryParse(id) ?? 0},
    );
    if (found.rows.isEmpty || !await _isLive(db, id)) {
      return _json({'error': 'No game with that id'}, status: 404);
    }
    final game = found.rows.first.assoc();
    if (!clearing) {
      if ((game['opponent'] ?? '').trim().isEmpty) {
        return _json({
          'error':
              'Pick who this game is against first (edit the game on '
              'the schedule).',
        }, status: 409);
      }
      if ('${game['upcoming']}' == '1') {
        return _json({
          'error': "This game hasn't been played yet.",
        }, status: 409);
      }
    }
    await db.execute(
      'UPDATE sessions SET dsa_score = :dsa, opponent_score = :them '
      'WHERE id = :gameId',
      {'dsa': dsa, 'them': them, 'gameId': int.parse(gameId)},
    );
    final saved = await db.execute('${_gameSelect}WHERE id = :gameId', {
      'gameId': int.parse(gameId),
    });
    return _json(_gameJson(saved.rows.first.assoc()));
  });

  return router;
}

/// Whether [user] may see a tournament's standings and games: the academy
/// always, a parent only when one of their children is on it.
Future<bool> _canView(Db db, AuthUser user, String id) async {
  if (user.isAdmin) return true;
  final found = await db.execute(
    'SELECT 1 FROM tournament_players tp '
    'JOIN players p ON p.id = tp.player_id AND p.is_active = 1 '
    'WHERE tp.tournament_id = :id AND p.parent_id = :parent LIMIT 1',
    {'id': int.tryParse(id) ?? 0, 'parent': user.id},
  );
  return found.rows.isNotEmpty;
}

const _maxTeamName = 40;
const _maxScore = 999;

/// How a game's opponent is saved on the schedule: 'vs. Desert Warriors'.
const _opponentPrefix = 'vs. ';

bool _isScore(Object? value) =>
    value is int && value >= 0 && value <= _maxScore;

const _gameSelect =
    "SELECT id, DATE_FORMAT(session_date, '%Y-%m-%d') AS session_date, "
    "TIME_FORMAT(start_time, '%H:%i') AS start_time, location, opponent, "
    'dsa_score, opponent_score, session_date > CURRENT_DATE AS upcoming '
    'FROM sessions ';

Map<String, Object?> _gameJson(Map<String, String?> r) => {
  'id': int.parse(r['id']!),
  'session_date': r['session_date'],
  'start_time': r['start_time'],
  'location': r['location'],
  'opponent': r['opponent'],
  'dsa_score': int.tryParse(r['dsa_score'] ?? ''),
  'opponent_score': int.tryParse(r['opponent_score'] ?? ''),
  'upcoming': '${r['upcoming']}' == '1',
};

/// Whether a tournament exists and hasn't been deleted. A deleted one could
/// still be renamed, re-priced and given players.
Future<bool> _isLive(Db db, String id) async {
  final found = await db.execute(
    'SELECT id FROM tournaments WHERE id = :id AND deleted_at IS NULL',
    {'id': int.tryParse(id) ?? 0},
  );
  return found.rows.isNotEmpty;
}

num? _asNum(Object? value) => readMoney(value);
