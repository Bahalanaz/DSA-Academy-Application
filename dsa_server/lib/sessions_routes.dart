import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';
import 'notices.dart';
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

/// The calendar: sessions, each session's roster, and attendance.
///
/// Rosters and attendance are keyed by player ID. They used to be keyed by
/// name, so two players called the same thing got each other's attendance
/// marks — and attendance is what training fees are charged on.
Router buildSessionsRouter(Db db) {
  final router = Router();

  /// A parent sees every session (it's the club calendar) but only their
  /// own children in its roster. roster_count is the full count, so the app
  /// can still tell "nobody rostered yet" apart from "rostered, but not mine".
  ///
  /// A tournament game's roster is its tournament's roster. Games have no
  /// session roster of their own, so they used to reach every parent in the
  /// category rather than the families whose child is actually playing.
  router.get('/sessions', (Request request) async {
    final user = userOf(request);
    final sessions = await db.execute('''
      SELECT id, session_type, training_program_id, tournament_id,
             category_label, session_date, start_time, end_time, location,
             opponent
      FROM sessions
      WHERE is_cancelled = 0
      ORDER BY session_date, start_time
    ''');
    // Rosters are fetched as rows and grouped here rather than
    // GROUP_CONCAT'd. GROUP_CONCAT stops at 1024 bytes without saying so, so
    // a big roster quietly lost players, and the app splitting names on
    // commas broke on any name containing one.
    final rosters = await db.execute('''
      SELECT r.session_id, p.id, p.full_name, p.parent_id
      FROM (
        SELECT session_id, player_id FROM session_players
        UNION
        SELECT ts.id, tp.player_id
        FROM sessions ts
        JOIN tournament_players tp ON tp.tournament_id = ts.tournament_id
                                  AND tp.consent <> 'declined'
        WHERE ts.session_type = 'tournament'
      ) r
      JOIN players p ON p.id = r.player_id AND p.is_active = 1
      ORDER BY p.full_name, p.id
    ''');
    // How many of each session's current roster have a mark. A past session
    // left unmarked charges nobody for it, and nothing used to show that.
    final marks = await db.execute('''
      SELECT a.session_id, COUNT(*) AS marked
      FROM attendance a
      JOIN session_players sp
        ON sp.session_id = a.session_id AND sp.player_id = a.player_id
      JOIN players p ON p.id = a.player_id AND p.is_active = 1
      GROUP BY a.session_id
    ''');
    final marked = {
      for (final row in marks.rows)
        row.assoc()['session_id']!: int.parse(row.assoc()['marked']!),
    };
    final ids = <String, List<int>>{};
    final names = <String, List<String>>{};
    final counts = <String, int>{};
    for (final row in rosters.rows) {
      final r = row.assoc();
      final sessionId = r['session_id']!;
      counts[sessionId] = (counts[sessionId] ?? 0) + 1;
      if (!user.isAdmin && r['parent_id'] != '${user.id}') continue;
      ids.putIfAbsent(sessionId, () => []).add(int.parse(r['id']!));
      names.putIfAbsent(sessionId, () => []).add(r['full_name']!);
    }
    return _json([
      for (final row in sessions.rows)
        {
          ...row.assoc(),
          'player_ids': ids[row.assoc()['id']] ?? const <int>[],
          'player_names': names[row.assoc()['id']] ?? const <String>[],
          'roster_count': counts[row.assoc()['id']] ?? 0,
          'marked_count': user.isAdmin ? (marked[row.assoc()['id']] ?? 0) : 0,
        },
    ]);
  });

  router.post('/sessions', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final type = body['sessionType'] as String?;
    final date = body['sessionDate'] as String?;
    final startTime = body['startTime'] as String?;
    if (type == null || date == null || startTime == null) {
      return _json({
        'error': 'sessionType, sessionDate and startTime are required',
      }, status: 400);
    }
    // chk_sessions_link enforces both of these in the database as well;
    // checking here gives the admin a readable message.
    if (type == 'training' && body['trainingProgramId'] == null) {
      return _json({
        'error': 'A training session needs a training program',
      }, status: 400);
    }
    if (type == 'tournament' && body['tournamentId'] == null) {
      return _json({
        'error': 'A tournament session needs a tournament',
      }, status: 400);
    }
    final invalid = await _checkNewSession(db, body);
    if (invalid != null) return invalid;
    try {
      final newId = await db.transaction((conn) async {
        final result = await conn.execute(
          'INSERT INTO sessions (session_type, training_program_id, '
          'tournament_id, category_label, session_date, start_time, end_time, '
          'location, opponent, created_by) VALUES (:type, :programId, '
          ':tournamentId, :label, :date, :startTime, :endTime, :location, '
          ':opponent, :createdBy)',
          {
            'type': type,
            // Only the link its type uses: a stray id for the other one
            // broke chk_sessions_link and came back as "That value isn't
            // allowed."
            'programId': type == 'training' ? body['trainingProgramId'] : null,
            'tournamentId': type == 'tournament' ? body['tournamentId'] : null,
            'label': body['categoryLabel'],
            'date': date,
            'startTime': startTime,
            'endTime': body['endTime'],
            'location': body['location'],
            'opponent': body['opponent'],
            'createdBy': user.id,
          },
        );
        final newId = result.lastInsertID.toInt();
        // The training's default players (Trainings > a training > settings)
        // go straight onto every new session of it, so the admin doesn't add
        // the same group each time. Same transaction, so a session never
        // exists without them. Validated integers, written in.
        if (type == 'training') {
          final programId = int.tryParse('${body['trainingProgramId']}') ?? 0;
          await conn.execute(
            'INSERT IGNORE INTO session_players '
            '(session_id, player_id, added_by) '
            'SELECT $newId, d.player_id, ${user.id} '
            'FROM training_default_players d '
            'JOIN players p ON p.id = d.player_id AND p.is_active = 1 '
            'WHERE d.training_program_id = $programId',
          );
        }
        // The families of everyone on it (a training's default players, a
        // game's tournament roster) get a "New training" message.
        await notifySessionsAdded(conn, sessionIds: [newId], sentBy: user.id);
        return newId;
      });
      return _json({'id': newId}, status: 201);
    } on MySQLServerException catch (e) {
      // Saved from two phones at once: both passed the check above, and
      // the database's uq_sessions_live_slot refused the second.
      if (e.errorCode == _duplicateEntry) return _alreadyScheduled();
      rethrow;
    }
  });

  /// Changes a session that hasn't happened yet: any of "sessionDate",
  /// "startTime", "endTime" (training), "location" and "opponent"
  /// (tournament games). Which training or tournament it belongs to, and so
  /// who is on it, stays as it is.
  ///
  /// The families of the players on it get a message saying exactly what
  /// changed, in the same transaction as the change.
  router.put('/sessions/<id>', (Request request, String id) async {
    final user = userOf(request);
    final sessionId = int.tryParse(id);
    final body = jsonDecode(await request.readAsString()) as Map;
    if (sessionId == null) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    final found = await db.execute(
      "SELECT session_type, training_program_id, tournament_id, "
      "category_label, DATE_FORMAT(session_date, '%Y-%m-%d') AS session_date, "
      "TIME_FORMAT(start_time, '%H:%i') AS start_time, "
      "TIME_FORMAT(end_time, '%H:%i') AS end_time, location, opponent, "
      'is_cancelled, session_date < CURRENT_DATE AS past '
      'FROM sessions WHERE id = :id',
      {'id': sessionId},
    );
    if (found.rows.isEmpty) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    final old = found.rows.first.assoc();
    if (old['is_cancelled'] == '1') {
      return _json({
        'error': "This session was cancelled, so it can't be changed.",
      }, status: 409);
    }
    // A session that's been and gone is what attendance and fees were
    // worked out on; moving it now would rewrite that history.
    if ('${old['past']}' == '1') {
      return _json({
        'error':
            "This session has already taken place, so it can't be changed. "
            "If it didn't happen, cancel it instead.",
      }, status: 409);
    }
    final training = old['session_type'] == 'training';
    // Anything not sent stays as it was.
    final date = '${body['sessionDate'] ?? old['session_date']}'.trim();
    final start = '${body['startTime'] ?? old['start_time']}'.trim();
    final end = training
        ? (body.containsKey('endTime') ? body['endTime'] : old['end_time'])
        : null;
    // Any value is read as text: a number sent as a location used to fail
    // a cast and come back as a server error.
    final location = body.containsKey('location')
        ? body['location']?.toString().trim()
        : old['location'];
    final opponent = training
        ? null
        : body.containsKey('opponent')
        ? body['opponent']?.toString().trim()
        : old['opponent'];
    final updated = {
      'sessionType': old['session_type'],
      'trainingProgramId': old['training_program_id'],
      'tournamentId': old['tournament_id'],
      'categoryLabel': old['category_label'],
      'sessionDate': date,
      'startTime': start,
      'endTime': end,
      'location': location == null || location.isEmpty ? null : location,
      'opponent': opponent == null || opponent.isEmpty ? null : opponent,
    };
    final invalid = await _checkNewSession(db, updated, excludeId: sessionId);
    if (invalid != null) return invalid;

    // Not moved into the past: nobody could have been there.
    final when = await db.execute('SELECT :date < CURRENT_DATE AS past', {
      'date': date,
    });
    if ('${when.rows.first.assoc()['past']}' == '1') {
      return _json({
        'error': 'A session can only be moved to today or a later day.',
      }, status: 400);
    }
    // Moving a session with someone already marked present or absent would
    // carry that mark to a day it didn't happen on.
    if (date != old['session_date']) {
      final marked = await db.execute(
        'SELECT COUNT(*) AS n FROM attendance WHERE session_id = :id '
        "AND status IN ('present','absent')",
        {'id': sessionId},
      );
      if (int.parse('${marked.rows.first.assoc()['n']}') > 0) {
        return _json({
          'error':
              "Attendance has already been marked for this session, so its "
              "date can't be changed. Clear the marks first.",
        }, status: 409);
      }
    }

    final int? notified;
    try {
      notified = await db.transaction((conn) async {
        final before = await describeSession(conn, sessionId);
        // A final score belongs to the team it was played against, so it
        // goes if the opponent changes. Assignments run left to right, so
        // the score columns are set while `opponent` still has its old value.
        await conn.execute(
          'UPDATE sessions SET '
          'dsa_score = IF(opponent <=> :sameOpponent, dsa_score, NULL), '
          'opponent_score = IF(opponent <=> :sameOpponent2, opponent_score, '
          'NULL), '
          'session_date = :date, start_time = :start, '
          'end_time = :end, location = :location, opponent = :opponent '
          'WHERE id = :id',
          {
            'id': sessionId,
            'date': date,
            'start': updated['startTime'],
            'end': updated['endTime'],
            'location': updated['location'],
            'opponent': updated['opponent'],
            'sameOpponent': updated['opponent'],
            'sameOpponent2': updated['opponent'],
          },
        );
        if (before == null) return null;
        return notifySessionChanged(conn, before: before, sentBy: user.id);
      });
    } on MySQLServerException catch (e) {
      if (e.errorCode == _duplicateEntry) return _alreadyScheduled();
      rethrow;
    }
    return _json({'id': sessionId, 'notified': notified != null});
  });

  /// Cancels sessions and tells the families of the players on them, in one
  /// transaction. Returns the ids that were live and are now cancelled;
  /// already-cancelled ones are skipped, so nobody is told twice.
  Future<List<int>> cancelSessions(List<int> ids, int sentBy) async {
    if (ids.isEmpty) return const [];
    return db.transaction((conn) async {
      final live = await conn.execute(
        'SELECT id FROM sessions WHERE is_cancelled = 0 '
        'AND id IN (${ids.join(',')}) FOR UPDATE',
      );
      final cancelled = [
        for (final row in live.rows) int.parse(row.assoc()['id']!),
      ];
      if (cancelled.isEmpty) return cancelled;
      await conn.execute(
        'UPDATE sessions SET is_cancelled = 1 '
        'WHERE id IN (${cancelled.join(',')})',
      );
      await notifySessionsCancelled(
        conn,
        sessionIds: cancelled,
        sentBy: sentBy,
      );
      return cancelled;
    });
  }

  router.delete('/sessions/<id>', (Request request, String id) async {
    // Cancel rather than delete, so attendance already marked survives.
    final sessionId = int.tryParse(id);
    final exists = sessionId == null
        ? null
        : await db.execute('SELECT id FROM sessions WHERE id = :id', {
            'id': sessionId,
          });
    if (exists == null || exists.rows.isEmpty) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    await cancelSessions([sessionId!], userOf(request).id);
    return _json({'id': sessionId, 'cancelled': true});
  });

  /// Puts a cancelled session back on the schedule: the Undo after
  /// cancelling one by mistake. Any day, past sessions included, since a
  /// past one cancelled in error takes its training fees with it. Not for a
  /// training or tournament that has since been deleted, nor onto a slot
  /// another session of the same training now holds.
  router.post('/sessions/<id>/restore', (Request request, String id) async {
    final user = userOf(request);
    final sessionId = int.tryParse(id);
    if (sessionId == null) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    try {
      final problem = await db.transaction((conn) async {
        // Validated integer, written in: named parameters don't survive the
        // subqueries.
        final found = await conn.execute('''
          SELECT s.is_cancelled, s.session_type,
                 (s.training_program_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM training_programs tp
                    WHERE tp.id = s.training_program_id AND tp.is_active = 1))
                 OR (s.tournament_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM tournaments t
                    WHERE t.id = s.tournament_id AND t.deleted_at IS NULL))
                   AS owner_gone
          FROM sessions s WHERE s.id = $sessionId FOR UPDATE
        ''');
        if (found.rows.isEmpty) {
          return (status: 404, error: 'No session with that id');
        }
        final row = found.rows.first.assoc();
        if (row['is_cancelled'] != '1') {
          return (status: 409, error: "That session isn't cancelled.");
        }
        if ('${row['owner_gone']}' == '1') {
          return (
            status: 409,
            error: row['session_type'] == 'training'
                ? "That training has been deleted, so its sessions can't be "
                      'put back.'
                : "That tournament has been deleted, so its games can't be "
                      'put back.',
          );
        }
        await conn.execute(
          'UPDATE sessions SET is_cancelled = 0 WHERE id = $sessionId',
        );
        await notifySessionRestored(
          conn,
          sessionId: sessionId,
          sentBy: user.id,
        );
        return null;
      });
      if (problem != null) {
        return _json({'error': problem.error}, status: problem.status);
      }
      return _json({'id': sessionId, 'restored': true});
    } on MySQLServerException catch (e) {
      // uq_sessions_live_slot: something else took its day and time.
      if (e.errorCode == _duplicateEntry) {
        return _json({
          'error':
              'Another session of this training is now on the schedule at '
              "that day and time, so this one can't be put back.",
        }, status: 409);
      }
      rethrow;
    }
  });

  /// Cancels several sessions at once: {"sessionIds": [..]}. Families get
  /// one message listing every date, not one per session.
  router.post('/sessions/cancel', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final ids = _ids(body['sessionIds']);
    if (ids.isEmpty) {
      return _json({'error': 'Pick at least one session'}, status: 400);
    }
    final cancelled = await cancelSessions(ids, userOf(request).id);
    return _json({'cancelled': cancelled});
  });

  /// Adds players (by id) to a session's roster. Re-adding is harmless.
  /// The families of the players newly on it get a "New training" message
  /// (an upcoming session only).
  router.post('/sessions/<id>/players', (Request request, String id) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final playerIds = _ids(body['playerIds']);
    // Adding to a cancelled or non-existent session used to report success.
    final session = await db.execute(
      'SELECT is_cancelled FROM sessions WHERE id = :id',
      {'id': int.tryParse(id) ?? 0},
    );
    if (session.rows.isEmpty) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    if (session.rows.first.assoc()['is_cancelled'] == '1') {
      return _json({
        'error': "This session was cancelled, so players can't be added to it.",
      }, status: 409);
    }
    final sessionId = int.parse(id);
    await db.transaction((conn) async {
      final added = <int>{};
      for (final playerId in playerIds) {
        final result = await conn.execute(
          'INSERT IGNORE INTO session_players (session_id, player_id) '
          'SELECT :sessionId, p.id FROM players p '
          'WHERE p.id = :playerId AND p.is_active = 1 AND p.is_approved = 1',
          {'sessionId': sessionId, 'playerId': playerId},
        );
        if (result.affectedRows.toInt() > 0) added.add(playerId);
      }
      // Only those newly on it: someone already there has been told.
      await notifySessionsAdded(
        conn,
        sessionIds: [sessionId],
        sentBy: user.id,
        onlyPlayers: added,
      );
    });
    return _json({'sessionId': sessionId, 'added': playerIds});
  });

  router.delete('/sessions/<id>/players/<playerId>', (
    Request request,
    String id,
    String playerId,
  ) async {
    // The attendance mark goes with them. Left behind, it reappeared if the
    // player was added back later, and the screen counted it as a mark for
    // someone no longer on the roster.
    final removed = await db.transaction((conn) async {
      final params = {'sessionId': id, 'playerId': int.tryParse(playerId) ?? 0};
      final result = await conn.execute(
        'DELETE FROM session_players '
        'WHERE session_id = :sessionId AND player_id = :playerId',
        params,
      );
      await conn.execute(
        'DELETE FROM attendance '
        'WHERE session_id = :sessionId AND player_id = :playerId',
        params,
      );
      if (result.affectedRows.toInt() > 0) {
        await retractUnsentAdd(
          conn,
          sessionId: int.tryParse(id) ?? 0,
          playerId: int.tryParse(playerId) ?? 0,
        );
      }
      return result.affectedRows.toInt();
    });
    if (removed == 0) {
      return _json({
        'error': 'That player is not on this session',
      }, status: 404);
    }
    return _json({'sessionId': int.parse(id), 'removed': int.parse(playerId)});
  });

  /// {"<playerId>": "present" | "absent" | "exempt"} for one session.
  router.get('/sessions/<id>/attendance', (Request request, String id) async {
    final result = await db.execute(
      'SELECT player_id, status FROM attendance WHERE session_id = :id',
      {'id': id},
    );
    return _json({
      for (final row in result.rows)
        '${row.assoc()['player_id']}': row.assoc()['status'],
    });
  });

  /// Saves every mark for a session at once, keyed by player id. 'unmarked'
  /// deletes the mark ("no row = not yet marked").
  router.put('/sessions/<id>/attendance', (Request request, String id) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final marks = (body['marks'] as Map? ?? {}).cast<String, dynamic>();

    const allowed = {'present', 'absent', 'exempt', 'unmarked'};
    if (marks.values.any((s) => !allowed.contains(s))) {
      return _json({'error': 'Unknown attendance status'}, status: 400);
    }

    // Present and absent record something that HAPPENED, and both are
    // billed — so neither can be set before the session's day. Exempt
    // (excused in advance) is still allowed early, and is never charged.
    final marksAttendance = marks.values.any(
      (s) => s == 'present' || s == 'absent',
    );
    final session = await db.execute(
      "SELECT is_cancelled, session_date > CURRENT_DATE AS upcoming, "
      "DATE_FORMAT(session_date, '%M %e') AS day "
      "FROM sessions WHERE id = :id",
      {'id': id},
    );
    if (session.rows.isEmpty) {
      return _json({'error': 'No session with that id'}, status: 404);
    }
    final row = session.rows.first.assoc();
    if (row['is_cancelled'] == '1') {
      return _json({
        'error': 'This session was cancelled, so attendance can\'t be changed.',
      }, status: 409);
    }
    if (marksAttendance && '${row['upcoming']}' == '1') {
      return _json({
        'error':
            'This session is on ${row['day']}, so no one can be marked '
            'present or absent yet. You can mark players exempt in advance.',
      }, status: 400);
    }

    // Who a mark can be saved for. Anyone else is skipped (see below), and
    // the reply says so instead of counting them as saved.
    final roster = await db.execute(
      'SELECT sp.player_id FROM session_players sp '
      'JOIN players p ON p.id = sp.player_id AND p.is_active = 1 '
      'WHERE sp.session_id = :sessionId',
      {'sessionId': int.tryParse(id) ?? 0},
    );
    final onRoster = {
      for (final row in roster.rows) int.parse(row.assoc()['player_id']!),
    };
    final skipped = [
      for (final key in marks.keys)
        if (int.tryParse(key) == null ||
            (marks[key] != 'unmarked' && !onRoster.contains(int.parse(key))))
          key,
    ];
    try {
      await db.transaction((conn) async {
        for (final entry in marks.entries) {
          final playerId = int.tryParse(entry.key);
          if (playerId == null) continue;
          final status = entry.value as String;
          if (status == 'unmarked') {
            await conn.execute(
              'DELETE FROM attendance '
              'WHERE session_id = :sessionId AND player_id = :playerId',
              {'sessionId': id, 'playerId': playerId},
            );
            continue;
          }
          // Only for someone on this session's roster. Any active player id
          // used to be accepted, leaving marks for people who weren't there.
          await conn.execute(
            'INSERT INTO attendance (session_id, player_id, status, marked_by) '
            'SELECT sp.session_id, sp.player_id, :status, :markedBy '
            'FROM session_players sp '
            'JOIN players p ON p.id = sp.player_id AND p.is_active = 1 '
            'WHERE sp.session_id = :sessionId AND sp.player_id = :playerId '
            'ON DUPLICATE KEY UPDATE status = VALUES(status), '
            'marked_by = VALUES(marked_by)',
            {
              'sessionId': id,
              'playerId': playerId,
              'status': status,
              'markedBy': user.id,
            },
          );
        }
      });
      return _json({
        'sessionId': int.parse(id),
        'saved': marks.length - skipped.length,
        if (skipped.isNotEmpty) 'notOnRoster': skipped,
      });
    } on MySQLServerException {
      rethrow;
    }
  });

  return router;
}

final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$');

int _secondsOf(String time) {
  final parts = time.split(':').map(int.parse).toList();
  return parts[0] * 3600 + parts[1] * 60 + (parts.length > 2 ? parts[2] : 0);
}

/// What's wrong with a new session, or null if it can be saved.
///
/// Catches what the database either lets through or only rejects with an
/// unreadable error: a time the app couldn't read (it used to save those as
/// midnight), an end before the start, a training or tournament that has
/// since been deleted, and the same session scheduled twice.
/// Checks a session about to be saved. [excludeId] is the session being
/// edited, so it doesn't clash with itself.
Future<Response?> _checkNewSession(Db db, Map body, {int? excludeId}) async {
  final type = body['sessionType'];
  final date = '${body['sessionDate']}';
  final start = '${body['startTime']}';
  final end = body['endTime'] == null ? null : '${body['endTime']}';

  if (type != 'training' && type != 'tournament') {
    return _json({'error': 'Unknown session type'}, status: 400);
  }
  final day = _datePattern.hasMatch(date) ? realDate(date) : null;
  if (day == null) {
    return _json({'error': 'Enter a real date, as YYYY-MM-DD'}, status: 400);
  }
  // Far outside the season is a typo (2062 for 2026), and a session in a
  // long-closed month would re-open that month's bills.
  final today = DateTime.now();
  if (day.isBefore(DateTime(today.year - 1, today.month, today.day)) ||
      day.isAfter(DateTime(today.year + 2, today.month, today.day))) {
    return _json({
      'error':
          'Sessions can be scheduled from a year ago up to two years ahead',
    }, status: 400);
  }
  if (!_timePattern.hasMatch(start) ||
      (end != null && !_timePattern.hasMatch(end))) {
    return _json({
      'error': 'Enter real times of day, like 5:00 PM',
    }, status: 400);
  }
  if (end != null && _secondsOf(end) <= _secondsOf(start)) {
    return _json({
      'error': 'The end time must be after the start time',
    }, status: 400);
  }
  final tooLong =
      lengthError('Location', body['location'], 160) ??
      lengthError('Opponent', body['opponent'], 120) ??
      lengthError('Category label', body['categoryLabel'], 120);
  if (tooLong != null) return _json({'error': tooLong}, status: 400);

  final isTraining = type == 'training';
  final linkId = isTraining ? body['trainingProgramId'] : body['tournamentId'];
  final owner = await db.execute(
    isTraining
        ? 'SELECT id FROM training_programs WHERE id = :id AND is_active = 1'
        : 'SELECT id FROM tournaments WHERE id = :id AND deleted_at IS NULL',
    {'id': linkId},
  );
  if (owner.rows.isEmpty) {
    return _json({
      'error': isTraining
          ? 'That training has been deleted'
          : 'That tournament has been deleted',
    }, status: 400);
  }

  final clash = await db.execute(
    'SELECT id FROM sessions WHERE is_cancelled = 0 AND '
    '${isTraining ? 'training_program_id' : 'tournament_id'} = :linkId '
    'AND session_date = :date AND start_time = :start'
    '${excludeId == null ? '' : ' AND id <> $excludeId'}',
    {
      'linkId': linkId,
      'date': date,
      'start': start.length == 5 ? '$start:00' : start,
    },
  );
  if (clash.rows.isNotEmpty) return _alreadyScheduled();
  return null;
}

/// MySQL's "Duplicate entry" error code.
const _duplicateEntry = 1062;

Response _alreadyScheduled() => _json({
  'error': 'That is already on the schedule for this day and time',
}, status: 409);
