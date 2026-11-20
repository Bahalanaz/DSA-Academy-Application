import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart' show MySQLConnection;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'billing.dart';
import 'db.dart';
import 'fee_rates.dart';
import 'ledger.dart';
import 'notices.dart' show notifyJerseyDecision;
import 'photos_routes.dart';
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// First day of the current month, as a DATE — matches how
/// v_player_month_attendance keys its rows.
const _currentMonthExpr =
    'DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY)';

/// Players, with the guardian, category and this month's attendance and
/// money joined in. Parents only ever see their own children.
Router buildPlayersRouter(Db db) {
  final router = Router();

  router.get('/players', (Request request) async {
    final user = userOf(request);
    // A parent sees their own children, including any still waiting on
    // Player Validation (shown as pending). The admin's lists only hold
    // approved players: a pending one isn't on the academy's books yet.
    final scope = user.isAdmin
        ? 'AND p.is_approved = 1'
        : 'AND p.parent_id = ${user.id}';
    final result = await db.execute('''
      SELECT
        p.id,
        p.full_name,
        p.nickname,
        p.jersey_number,
        p.jersey_size,
        p.is_approved,
        p.jersey_request,
        p.jersey_request_status,
        p.birthday,
        p.parent_id,
        p.photo_url,
        u.full_name AS parent_name,
        u.phone     AS parent_phone,
        GROUP_CONCAT(c.code ORDER BY c.birth_year) AS categories,
        COALESCE(ar.attendance_rate, 0) AS attendance_rate,
        COALESCE(ma.present_count, 0)   AS monthly_present,
        COALESCE(ma.absent_count, 0)    AS monthly_absent,
        COALESCE(ma.exempt_count, 0)    AS monthly_exempt,
        -- Being rostered on a session this month is what starts the fee.
        COALESCE(sched.session_count, 0) AS monthly_scheduled,
        -- Priced here, against the rate history, not multiplied in the app.
        COALESCE(sched.session_charges, 0) AS monthly_charges,
        -- The flat monthly fee (prorated in the month a player joined only
        -- before October 2026, see fee_rates.dart); the full figure
        -- alongside so the app can say when proration applied.
        ${proratedCoachFeeAt('p.id', _currentMonthExpr)} AS monthly_coach_fee,
        ${coachFeeAt(_currentMonthExpr)} AS monthly_coach_fee_full
      FROM players p
      JOIN users u ON u.id = p.parent_id
      LEFT JOIN categories c
             ON c.birth_year = YEAR(p.birthday) AND c.is_active = 1
      LEFT JOIN v_player_attendance_rate ar ON ar.player_id = p.id
      LEFT JOIN v_player_month_attendance ma
             ON ma.player_id = p.id AND ma.period_month = $_currentMonthExpr
      LEFT JOIN (
        SELECT
          sp.player_id,
          COUNT(*) AS session_count,
          COALESCE(SUM(CASE WHEN a.status IN ('present','absent')
                             AND s.session_date <= CURRENT_DATE
                            THEN ${sessionRateAt('s.session_date')}
                            ELSE 0 END), 0) AS session_charges
        FROM session_players sp
        -- Training sessions only: a tournament game is paid for by its
        -- tournament fee, never as a training session.
        JOIN sessions s ON s.id = sp.session_id AND s.is_cancelled = 0
                       AND s.session_type = 'training'
        LEFT JOIN attendance a
               ON a.session_id = sp.session_id AND a.player_id = sp.player_id
        WHERE DATE_SUB(s.session_date,
                       INTERVAL DAYOFMONTH(s.session_date) - 1 DAY)
              = $_currentMonthExpr
        GROUP BY sp.player_id
      ) sched ON sched.player_id = p.id
      WHERE p.is_active = 1 $scope
      GROUP BY p.id, p.full_name, p.nickname, p.jersey_number, p.jersey_size,
               p.birthday,
               p.photo_url, p.is_approved, p.jersey_request,
               p.jersey_request_status,
               p.parent_id, u.full_name, u.phone, ar.attendance_rate,
               ma.present_count, ma.absent_count, ma.exempt_count,
               sched.session_count, sched.session_charges
      ORDER BY p.full_name
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// Attendance and money for ONE month, per player rostered in it.
  router.get('/attendance-summary', (Request request) async {
    final user = userOf(request);
    final month = request.url.queryParameters['month'];
    // Validated to the exact shape of a date and written into the SQL: the
    // driver's named parameters don't work in a query with scalar
    // subqueries. Ten digits and dashes leave nothing to break out of.
    // A real date: "2026-13-01" matched the shape and crashed the query.
    if (month == null || realDate(month) == null) {
      return _json({'error': 'month is required, as YYYY-MM-01'}, status: 400);
    }
    final scope = user.isAdmin ? '' : 'AND p.parent_id = ${user.id}';
    final monthLiteral = "'$month'";
    final result = await db.execute('''
      SELECT
        sp.player_id,
        COUNT(*) AS scheduled_count,
        COUNT(CASE WHEN a.status = 'present'
                    AND s.session_date <= CURRENT_DATE THEN 1 END) AS present_count,
        COUNT(CASE WHEN a.status = 'absent'
                    AND s.session_date <= CURRENT_DATE THEN 1 END) AS absent_count,
        COUNT(CASE WHEN a.status = 'exempt'  THEN 1 END) AS exempt_count,
        COALESCE(SUM(CASE WHEN a.status IN ('present','absent')
                           AND s.session_date <= CURRENT_DATE
                          THEN ${sessionRateAt('s.session_date')}
                          ELSE 0 END), 0) AS session_charges,
        ${proratedCoachFeeAt('sp.player_id', monthLiteral)} AS coach_fee,
        ${coachFeeAt(monthLiteral)} AS coach_fee_full
      FROM session_players sp
      JOIN sessions s ON s.id = sp.session_id AND s.is_cancelled = 0
                     AND s.session_type = 'training'
      JOIN players p  ON p.id = sp.player_id AND p.is_active = 1
      LEFT JOIN attendance a
             ON a.session_id = sp.session_id AND a.player_id = sp.player_id
      WHERE DATE_SUB(s.session_date,
                     INTERVAL DAYOFMONTH(s.session_date) - 1 DAY) = $monthLiteral
            $scope
      GROUP BY sp.player_id
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// A parent can only add a child under their own account.
  router.post('/players', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final fullName = normalizeSpaces(body['fullName'] as String? ?? '');
    final parentId = user.isAdmin ? body['parentId'] : user.id;
    if (parentId == null) {
      return _json({'error': 'parentId is required'}, status: 400);
    }
    // An admin adding a child names the account it goes under. It has to be
    // a real, approved parent: a pending signup, another admin or a made-up
    // id used to be accepted (the last with a raw database error).
    if (user.isAdmin) {
      final parent = await db.execute(
        "SELECT id FROM users WHERE id = :id AND role = 'parent' "
        "AND status = 'approved'",
        {'id': int.tryParse('$parentId') ?? 0},
      );
      if (parent.rows.isEmpty) {
        return _json({
          'error': 'Choose an approved parent account for this player',
        }, status: 400);
      }
    }
    final invalid = _validatePlayer(body);
    if (invalid != null) return _json({'error': invalid}, status: 400);
    final wanted = _numberOf(body['jerseyNumber']);
    final allowTaken = body['allowTaken'] == true;

    // A double tap on Save used to add the same child twice.
    final duplicate = await db.execute(
      'SELECT id FROM players WHERE parent_id = :parentId AND is_active = 1 '
      'AND full_name = :fullName AND birthday = :birthday',
      {
        'parentId': parentId,
        'fullName': fullName,
        'birthday': _emptyToNull(body['birthday'] as String?),
      },
    );
    if (duplicate.rows.isNotEmpty) {
      return _json({
        'error': '$fullName is already on this account',
      }, status: 409);
    }
    try {
      // Checked and written under one lock, so two families picking the
      // same free number at the same moment can't both get it unasked.
      final outcome = await _withJerseyLock(db, (conn) async {
        final taken = wanted != null && await _numberTaken(conn, wanted);
        if (taken && !allowTaken) return (taken: true, id: 0, pending: false);
        // A family asking for a taken number: the child waits on Player
        // Validation and isn't a player yet. The admin is the one who
        // approves, so an admin choosing a taken number just gets it.
        final pending = taken && !user.isAdmin;
        final result = await conn.execute(
          'INSERT INTO players (parent_id, full_name, nickname, '
          'jersey_number, jersey_size, birthday, is_approved, '
          'jersey_request, jersey_request_status, jersey_requested_at) '
          'VALUES (:parentId, :fullName, :nickname, :jersey, :size, '
          ':birthday, '
          ":approved, :request, :status, ${pending ? 'NOW()' : 'NULL'})",
          {
            'parentId': parentId,
            'fullName': fullName,
            'nickname': _nicknameOf(body),
            'jersey': pending || wanted == null ? null : _numberText(wanted),
            'size': _jerseySizeOf(body),
            'birthday': _emptyToNull(body['birthday'] as String?),
            'approved': pending ? 0 : 1,
            'request': pending ? _numberText(wanted) : null,
            'status': pending ? 'pending' : null,
          },
        );
        return (
          taken: false,
          id: result.lastInsertID.toInt(),
          pending: pending,
        );
      });
      if (outcome.taken) {
        return _json({
          'error': _takenMessage(wanted!),
          'code': 'jersey_taken',
        }, status: 409);
      }
      return _json({
        'id': outcome.id,
        'fullName': fullName,
        'pending': outcome.pending,
      }, status: 201);
    } on MySQLServerException catch (e) {
      // Added from two phones at once: both passed the check above, and the
      // database's uq_players_active_child refused the second.
      if (e.errorCode == 1062 && e.message.contains('active_child')) {
        return _json({
          'error': '$fullName is already on this account',
        }, status: 409);
      }
      rethrow;
    }
  });

  router.put('/players/<id>', (Request request, String id) async {
    final user = userOf(request);
    // Including a child still waiting on Player Validation: picking another
    // number is how a family answers a declined one.
    if (!await canAccessPlayer(db, user, id, includeUnapproved: true)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    final body = jsonDecode(await request.readAsString()) as Map;
    final fullName = normalizeSpaces(body['fullName'] as String? ?? '');
    final invalid = _validatePlayer(body);
    if (invalid != null) return _json({'error': invalid}, status: 400);
    // The birth year is the category. A parent changing it for a child the
    // admin had already put on a team moved them to another category while
    // they stayed on the old one's sessions and tournaments. The admin can
    // still correct it.
    if (!user.isAdmin) {
      final playerId = int.parse(id);
      final current = await db.execute('''
        SELECT YEAR(p.birthday) AS birth_year, p.full_name,
          (EXISTS (SELECT 1 FROM session_players sp
                   JOIN sessions s ON s.id = sp.session_id
                   WHERE sp.player_id = p.id AND s.is_cancelled = 0
                     AND s.session_date >= CURRENT_DATE)
           OR EXISTS (SELECT 1 FROM tournament_players tp
                      JOIN tournaments t ON t.id = tp.tournament_id
                      WHERE tp.player_id = p.id AND t.deleted_at IS NULL
                        AND tp.consent <> 'declined'))
            AS on_team
        FROM players p WHERE p.id = $playerId
      ''');
      final row = current.rows.first.assoc();
      final newYear = (body['birthday'] as String).trim().substring(0, 4);
      if ('${row['on_team']}' == '1' && row['birth_year'] != newYear) {
        return _json({
          'error':
              "${row['full_name']} is already on a team for their current "
              "category, so the birth year can't be changed here. Please ask "
              'the admin to correct it.',
        }, status: 409);
      }
    }
    final playerId = int.parse(id);
    final wanted = _numberOf(body['jerseyNumber']);
    final allowTaken = body['allowTaken'] == true;
    // The size only when it's sent: an app from before sizes existed saves
    // without one, and mustn't wipe the size set from a newer app.
    final setSize = body.containsKey('jerseySize');
    // The nickname is the academy's to change once the child is added (a
    // family sets it only when adding them), and only when it's sent: an
    // app from before nicknames existed mustn't wipe it.
    final setNickname = user.isAdmin && body.containsKey('nickname');

    final outcome = await _withJerseyLock(db, (conn) async {
      final found = await conn.execute(
        'SELECT jersey_number, is_approved, jersey_request, '
        'jersey_request_status FROM players WHERE id = :id FOR UPDATE',
        {'id': playerId},
      );
      final row = found.rows.first.assoc();
      final current = _numberOf(row['jersey_number']);
      final approved = row['is_approved'] == '1';
      final request = _numberOf(row['jersey_request']);
      final requestPending = row['jersey_request_status'] == 'pending';

      // What happens to the number, as SQL for the UPDATE below.
      String jersey;
      if (approved && wanted == current) {
        // The number they already wear. A parent going back to it withdraws
        // any request (or clears a declined one); an admin's save leaves a
        // family's request for Player Validation to answer.
        jersey = user.isAdmin
            ? ''
            : ', jersey_request = NULL, jersey_request_status = NULL, '
                  'jersey_requested_at = NULL';
      } else {
        final taken =
            wanted != null &&
            await _numberTaken(conn, wanted, exceptPlayerId: playerId);
        // Asking again for the number already waiting is no new request.
        final alreadyAsked = requestPending && wanted == request;
        if (taken && !allowTaken && !alreadyAsked) {
          return (taken: true, pending: false);
        }
        if (!taken || user.isAdmin) {
          // Free (or the admin's own decision): the number is theirs, and a
          // child who was waiting becomes a player.
          jersey =
              ', jersey_number = ${wanted == null ? 'NULL' : "'${_numberText(wanted)}'"}, '
              'is_approved = 1, jersey_request = NULL, '
              'jersey_request_status = NULL, jersey_requested_at = NULL';
        } else if (alreadyAsked) {
          jersey = '';
        } else {
          // A family asking for a taken number. They keep the one they
          // have (if any) until the admin says yes.
          jersey =
              ", jersey_request = '${_numberText(wanted)}', "
              "jersey_request_status = 'pending', "
              'jersey_requested_at = NOW()';
        }
      }
      await conn.execute(
        'UPDATE players SET full_name = :fullName, birthday = :birthday'
        '${setSize ? ', jersey_size = :size' : ''}'
        '${setNickname ? ', nickname = :nickname' : ''}$jersey WHERE id = :id',
        {
          'id': playerId,
          'fullName': fullName,
          'birthday': _emptyToNull(body['birthday'] as String?),
          if (setSize) 'size': _jerseySizeOf(body),
          if (setNickname) 'nickname': _nicknameOf(body),
        },
      );
      final after = await conn.execute(
        'SELECT jersey_request_status FROM players WHERE id = :id',
        {'id': playerId},
      );
      return (
        taken: false,
        pending: after.rows.first.assoc()['jersey_request_status'] == 'pending',
      );
    });
    if (outcome.taken) {
      return _json({
        'error': _takenMessage(wanted!),
        'code': 'jersey_taken',
      }, status: 409);
    }
    return _json({
      'id': playerId,
      'fullName': fullName,
      'pending': outcome.pending,
    });
  });

  /// The numbers other players already wear, so the 1-99 picker can mark
  /// them. Numbers only, never who has them: a parent mustn't learn another
  /// family's child's name. [except] leaves out the player being edited.
  router.get('/jersey-numbers', (Request request) async {
    final user = userOf(request);
    final except = int.tryParse(request.url.queryParameters['except'] ?? '');
    final result = await db.execute(
      'SELECT ${_jerseyKey('jersey_number')} AS n, full_name, '
      'YEAR(birthday) AS birth_year FROM players '
      'WHERE is_active = 1 AND is_approved = 1 '
      "AND jersey_number REGEXP '^[0-9]+\$' AND id <> :except "
      'ORDER BY n, full_name',
      {'except': except ?? 0},
    );
    // Keyed by how the number is written ("00", "7").
    final holders = <String, List<String>>{};
    for (final r in result.rows) {
      final row = r.assoc();
      holders
          .putIfAbsent(_numberText(int.parse(row['n']!)), () => [])
          .add('${row['full_name']} (B${row['birth_year']})');
    }
    return _json({
      // Plain numbers only: the app from before "00" reads this as numbers.
      'taken': [
        for (final n in holders.keys)
          if (n != '00') int.parse(n),
      ],
      // "00" separately, for apps that offer it.
      'doubleZeroTaken': holders.containsKey('00'),
      // Who wears each one, so the admin's "use this number?" window can
      // list them. Never sent to a parent.
      if (user.isAdmin) 'holders': holders,
    });
  });

  /// Player Validation (admin): families asking for a number another player
  /// already wears — a new child waiting to be added, or an existing one
  /// asking to change. Oldest first. Admin only (not in auth.dart's parent
  /// list).
  router.get('/player-validation', (Request request) async {
    final result = await db.execute('''
      SELECT p.id, p.full_name, p.birthday, YEAR(p.birthday) AS birth_year,
             p.jersey_number, p.jersey_request, p.jersey_size,
             p.is_approved, p.photo_url, p.jersey_requested_at,
             u.full_name AS parent_name, u.phone AS parent_phone,
             (SELECT GROUP_CONCAT(
                       CONCAT(o.full_name, ' (B', YEAR(o.birthday), ')')
                       ORDER BY o.full_name SEPARATOR ', ')
              FROM players o
              WHERE o.is_active = 1 AND o.is_approved = 1 AND o.id <> p.id
                AND o.jersey_number REGEXP '^[0-9]+\$'
                AND ${_jerseyKey('o.jersey_number')}
                    = ${_jerseyKey('p.jersey_request')}) AS worn_by
      FROM players p
      -- Not a deactivated (or deleted) family's: approving would add a
      -- child to an account that can't log in. Shown again if reactivated.
      JOIN users u ON u.id = p.parent_id AND u.status = 'approved'
                  AND u.deleted_at IS NULL
      WHERE p.is_active = 1 AND p.jersey_request_status = 'pending'
      ORDER BY p.jersey_requested_at, p.id
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// Yes: the child gets the number they asked for, shared with whoever
  /// already wears it, and a new child becomes a player.
  router.post('/player-validation/<id>/approve', (
    Request request,
    String id,
  ) async {
    // The admin may give a different number than the one asked for
    // ("jerseyNumber": 21, or null for none). Their decision, so it isn't
    // checked against who else wears it.
    // An app before this sends no body (or "null"): the number asked for.
    final raw = await request.readAsString();
    final decoded = raw.trim().isEmpty ? null : jsonDecode(raw);
    final body = decoded is Map ? decoded : const {};
    final chosen = body.containsKey('jerseyNumber');
    final number = _numberOf(body['jerseyNumber']);
    if (chosen &&
        number != null &&
        number != _doubleZero &&
        (number < 0 || number > 999)) {
      return _json({
        'error': 'Jersey number must be 1 to 3 digits',
      }, status: 400);
    }
    final playerId = int.tryParse(id) ?? 0;
    final adminId = userOf(request).id;
    final answered = await db.transaction((conn) async {
      final found = await conn.execute(
        'SELECT p.jersey_request, p.is_approved FROM players p '
        "JOIN users u ON u.id = p.parent_id AND u.status = 'approved' "
        'AND u.deleted_at IS NULL '
        'WHERE p.id = :id AND p.is_active = 1 '
        "AND p.jersey_request_status = 'pending' FOR UPDATE",
        {'id': playerId},
      );
      if (found.rows.isEmpty) return false;
      final asked = found.rows.first.assoc()['jersey_request']!;
      final newPlayer = found.rows.first.assoc()['is_approved'] != '1';
      await conn.execute(
        'UPDATE players SET jersey_number = '
        '${chosen ? ':number' : 'jersey_request'}, is_approved = 1, '
        'jersey_request = NULL, jersey_request_status = NULL, '
        'jersey_requested_at = NULL WHERE id = :id',
        {
          'id': playerId,
          if (chosen) 'number': number == null ? null : _numberText(number),
        },
      );
      // The family hears about it, with the number the child now has.
      await notifyJerseyDecision(
        conn,
        playerId: playerId,
        sentBy: adminId,
        approved: true,
        asked: _storedText(asked),
        given: chosen
            ? (number == null ? null : _numberText(number))
            : _storedText(asked),
        newPlayer: newPlayer,
      );
      return true;
    });
    if (!answered) {
      return _json({
        'error': 'This request has already been answered.',
      }, status: 404);
    }
    return _json({'id': playerId, 'approved': true});
  });

  /// No: the family is asked to pick another number. An existing player
  /// keeps the number they had; a new child stays off the academy's lists
  /// until a free (or approved) number is chosen.
  router.post('/player-validation/<id>/decline', (
    Request request,
    String id,
  ) async {
    final playerId = int.tryParse(id) ?? 0;
    final adminId = userOf(request).id;
    final answered = await db.transaction((conn) async {
      final found = await conn.execute(
        'SELECT jersey_request, is_approved FROM players '
        'WHERE id = :id AND is_active = 1 '
        "AND jersey_request_status = 'pending' FOR UPDATE",
        {'id': playerId},
      );
      if (found.rows.isEmpty) return false;
      final asked = found.rows.first.assoc()['jersey_request']!;
      await conn.execute(
        "UPDATE players SET jersey_request_status = 'declined' "
        'WHERE id = :id',
        {'id': playerId},
      );
      // So the family knows to pick another number.
      await notifyJerseyDecision(
        conn,
        playerId: playerId,
        sentBy: adminId,
        approved: false,
        asked: _storedText(asked),
        newPlayer: found.rows.first.assoc()['is_approved'] != '1',
      );
      return true;
    });
    if (!answered) {
      return _json({
        'error': 'This request has already been answered.',
      }, status: 404);
    }
    return _json({'id': playerId, 'declined': true});
  });

  /// Removes a player (soft delete, so history survives).
  ///
  /// A player who still owes money can't simply vanish: their bills would
  /// sit unpaid with no screen showing them, and this month's fee would
  /// never be billed at all. So removal is refused while anything is owed —
  /// past bills or this month's running fee. A parent has to settle first;
  /// an admin can pass ?waive=true to write the balance off and remove them
  /// in one step, which is logged against each bill.
  router.delete('/players/<id>', (Request request, String id) async {
    final user = userOf(request);
    final playerId = int.tryParse(id);
    if (playerId == null ||
        !await canAccessPlayer(db, user, playerId, includeUnapproved: true)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    final waive =
        user.isAdmin && request.url.queryParameters['waive'] == 'true';

    try {
      final outcome = await withMoneyLock(db, (conn) async {
        // Removed from another phone a moment ago (checked again here, under
        // the lock): say it's gone rather than "removed" a second time.
        final still = await conn.execute(
          'SELECT is_active FROM players WHERE id = :id FOR UPDATE',
          {'id': playerId},
        );
        if (still.rows.isEmpty ||
            still.rows.first.assoc()['is_active'] != '1') {
          throw const LedgerError('No player with that id', 404);
        }

        // Bill any finished month first, so "what they owe" is complete.
        await reconcilePastMonths(conn);

        // Money the club is holding for them — an advance, or credit
        // carried over — has to go back first. Removing them used to drop
        // it silently, even with ?waive=true, which only ever forgives what
        // the FAMILY owes. The month close just above has moved every credit
        // it can vouch for onto this month (carryForwardCredit), so this
        // month is where it lives; older history it can't vouch for (keyed
        // in with no sessions behind it) is deliberately left out, as there.
        final nowMonth = await conn.execute(
          "SELECT DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS m",
        );
        final held = await monthPosition(
          conn,
          playerId,
          nowMonth.rows.first.assoc()['m']!,
        );
        final over = held.settled - held.owed;
        final num credit = cents(over) > 0 ? over : 0;
        if (cents(credit) > 0) {
          return (removed: false, outstanding: 0 as num, credit: credit);
        }

        final pending = await conn.execute(
          "SELECT id, amount - amount_paid AS remaining FROM payments "
          "WHERE player_id = :playerId AND status = 'pending'",
          {'playerId': playerId},
        );
        num billed = 0;
        for (final row in pending.rows) {
          billed += asMoney(row.assoc()['remaining']);
        }
        // The database's month, like the rest of billing — not this
        // process's clock, which can be in another time zone when hosted.
        final thisMonth = await conn.execute(
          "SELECT DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS m",
        );
        final month = thisMonth.rows.first.assoc()['m']!;
        final position = await monthPosition(conn, playerId, month);
        final running = position.owed - position.settled;
        final accrued = cents(running) > 0 ? running : 0;
        final total = billed + accrued;

        if (cents(total) > 0 && !waive) {
          return (removed: false, outstanding: total, credit: 0 as num);
        }
        if (cents(total) > 0) {
          for (final row in pending.rows) {
            await recordWaiver(
              conn,
              paymentId: int.parse(row.assoc()['id']!),
              recordedBy: user.id,
              note: 'Waived when the player was removed',
            );
          }
          if (cents(accrued) > 0) {
            await pinTrainingFeeToSettled(
              conn,
              playerId: playerId,
              periodMonth: month,
              recordedBy: user.id,
              note: 'Waived when the player was removed',
            );
          }
        }
        // Orders still waiting for approval go with the player. Left behind
        // they sat on Order Validation forever, and couldn't be approved.
        await conn.execute(
          "DELETE FROM orders WHERE player_id = :id AND status = 'pending'",
          {'id': playerId},
        );
        // A removed child's photo goes with them.
        await deletePhoto(conn, kind: 'player', ownerId: playerId);
        await conn.execute('UPDATE players SET is_active = 0 WHERE id = :id', {
          'id': playerId,
        });
        // Off every training's default players, so they aren't quietly put
        // back on new sessions if the player is ever restored.
        await conn.execute(
          'DELETE FROM training_default_players WHERE player_id = :id',
          {'id': playerId},
        );
        return (removed: true, outstanding: total, credit: 0 as num);
      });

      if (!outcome.removed && cents(outcome.credit) > 0) {
        final held = money(outcome.credit);
        return _json({
          'error': user.isAdmin
              ? 'This player has AED $held of training credit. Refund it '
                    'from their payments before removing them.'
              : 'This player has AED $held of training credit. Please ask '
                    'the academy to refund it before removing them.',
          'credit': held,
        }, status: 409);
      }
      if (!outcome.removed) {
        final owed = money(outcome.outstanding);
        return _json({
          'error': user.isAdmin
              ? 'This player still owes AED $owed. Waive the balance to remove them.'
              : 'This player still owes AED $owed. Please settle the balance '
                    'before removing them.',
          'outstanding': owed,
          'requiresWaiver': user.isAdmin,
        }, status: 409);
      }
      return _json({
        'id': playerId,
        'removed': true,
        'waived': money(outcome.outstanding),
      });
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    }
  });

  return router;
}

String? _emptyToNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Jersey "00": a shirt of its own, not the same as "0". Every other number
/// is compared as a number ("07" and "7" are the same shirt), so "00" is
/// kept apart under this key.
const _doubleZero = -1;

/// A jersey number as a number ("07" and "7" are the same shirt), with
/// "00" as [_doubleZero], or null for none. Already checked to be 1 to 3
/// digits by [_validatePlayer].
int? _numberOf(Object? raw) {
  final text = '${raw ?? ''}'.trim();
  return text == '00' ? _doubleZero : int.tryParse(text);
}

/// How [number] is written: "00" for [_doubleZero], otherwise the plain
/// number ("7", never "07").
String _numberText(int number) => number == _doubleZero ? '00' : '$number';

/// A stored number (a request, say) written the way [_numberText] does,
/// or as stored when it isn't a number.
String _storedText(String stored) {
  final number = _numberOf(stored);
  return number == null ? stored : _numberText(number);
}

/// SQL for a jersey column's number, comparable with [_numberOf]: "00" is
/// [_doubleZero], anything else its value. For rows already filtered to
/// digits only.
String _jerseyKey(String column) =>
    "(CASE WHEN $column = '00' THEN $_doubleZero "
    'ELSE CAST($column AS SIGNED) END)';

/// Whether another active, approved player anywhere in the academy wears
/// [number]. One number per academy: two of the same would be two identical
/// shirts on the kit order, unless the admin agreed to it.
Future<bool> _numberTaken(
  MySQLConnection conn,
  int number, {
  int exceptPlayerId = 0,
}) async {
  final taken = await conn.execute(
    'SELECT id FROM players WHERE is_active = 1 AND is_approved = 1 '
    "AND jersey_number REGEXP '^[0-9]+\$' "
    'AND ${_jerseyKey('jersey_number')} = :number '
    'AND id <> :except LIMIT 1',
    {'number': number, 'except': exceptPlayerId},
  );
  return taken.rows.isNotEmpty;
}

/// Doesn't say who has it: a parent asking would learn another family's
/// child's name. (An app from before Player Validation shows this as is.)
String _takenMessage(int number) =>
    'Jersey #${_numberText(number)} is already taken by another player. '
    'Please choose another number.';

/// Runs [body] holding the jersey-number lock, so a check that a number is
/// free and the write that takes it can't be split by another family doing
/// the same at the same moment.
Future<T> _withJerseyLock<T>(
  Db db,
  Future<T> Function(MySQLConnection conn) body,
) {
  return db.transaction((conn) async {
    final got = await conn.execute("SELECT GET_LOCK('dsa_jersey', 20) AS got");
    if ('${got.rows.first.assoc()['got']}' != '1') {
      throw const LedgerError(
        'The server is busy. Please try again in a moment.',
        503,
      );
    }
    try {
      return await body(conn);
    } finally {
      await conn.execute("SELECT RELEASE_LOCK('dsa_jersey')");
    }
  });
}

/// Shirt sizes a player can have (players.jersey_size). Optional: players
/// added before sizes existed have none until someone sets it.
const jerseySizes = [
  '3XS',
  '2XS',
  'XS',
  'S',
  'M',
  'L',
  'XL',
  '2XL',
  '3XL',
  '9-10',
  '11-12',
];

/// The size in [body] ("jerseySize"), or null for none. Checked first by
/// [_validatePlayer].
///
/// "XXS" is the old name for 2XS. The families' app from before the rename
/// (1.0.23) still offers XXS, so it's taken as 2XS rather than refused.
String? _jerseySizeOf(Map body) {
  final size = '${body['jerseySize'] ?? ''}'.trim();
  if (size.isEmpty) return null;
  return size == 'XXS' ? '2XS' : size;
}

/// What's wrong with a player's details, or null if they're fine.
///
/// The birthday is required because it IS the category (B2013 = born
/// 2013): a missing or mistyped one silently puts a child in the wrong
/// group, which then decides their trainings and announcements.
/// The optional nickname as it's stored: spaces tidied, null when empty.
String? _nicknameOf(Map body) {
  final raw = body['nickname'];
  if (raw is! String) return null;
  final nickname = normalizeSpaces(raw);
  return nickname.isEmpty ? null : nickname;
}

/// Longest nickname (players.nickname is VARCHAR(30)).
const _maxNickname = 30;

String? _validatePlayer(Map body) {
  final fullName = (body['fullName'] as String? ?? '').trim();
  if (fullName.isEmpty) return "Enter the player's name";
  if (fullName.length > 120) {
    return 'Player name must be 120 characters or fewer';
  }
  final nameError = personNameError(fullName, label: 'Player name');
  if (nameError != null) return nameError;

  // Optional, and freer than a name ("CR7" is a fine nickname), but no
  // emoji, like every other text the academy keeps.
  final nickname = _nicknameOf(body);
  if (nickname != null) {
    if (nickname.length > _maxNickname) {
      return 'Nickname must be $_maxNickname characters or fewer';
    }
    if (hasEmoji(nickname)) return "Nickname can't contain emoji";
  }

  final jersey = (body['jerseyNumber'] as String? ?? '').trim();
  if (jersey.isNotEmpty && !RegExp(r'^\d{1,3}$').hasMatch(jersey)) {
    return 'Jersey number must be 1 to 3 digits';
  }

  final size = _jerseySizeOf(body);
  if (size != null && !jerseySizes.contains(size)) {
    return 'Jersey size must be one of ${jerseySizes.join(', ')}';
  }

  final birthday = (body['birthday'] as String? ?? '').trim();
  if (birthday.isEmpty) return "Enter the player's birthday";
  final parsed = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(birthday)
      ? DateTime.tryParse(birthday)
      : null;
  // Round-tripped, because DateTime.tryParse rolls "2014-02-30" over into
  // March instead of rejecting it.
  final valid =
      parsed != null &&
      '${parsed.year.toString().padLeft(4, '0')}-'
              '${parsed.month.toString().padLeft(2, '0')}-'
              '${parsed.day.toString().padLeft(2, '0')}' ==
          birthday;
  if (!valid) return 'Birthday must be a real date, as YYYY-MM-DD';
  if (parsed.isAfter(DateTime.now())) return "Birthday can't be in the future";
  // Players are children. A parent's own birthday typed by mistake (1980),
  // or a baby's, made a player that no category or team fits.
  final age = _ageOn(parsed, DateTime.now());
  if (age < _minPlayerAge || age > _maxPlayerAge) {
    return 'Check the birthday: players must be $_minPlayerAge to '
        '$_maxPlayerAge years old';
  }
  return null;
}

const _minPlayerAge = 3;
const _maxPlayerAge = 21;

int _ageOn(DateTime birthday, DateTime day) {
  final hadBirthday =
      day.month > birthday.month ||
      (day.month == birthday.month && day.day >= birthday.day);
  return day.year - birthday.year - (hadBirthday ? 0 : 1);
}
