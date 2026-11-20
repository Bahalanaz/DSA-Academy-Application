import 'dart:convert';

import 'package:mysql_client/mysql_client.dart';

import 'db.dart';

/// Messages the server sends by itself when the schedule changes under a
/// family's feet: sessions cancelled, or a whole tournament called off.
///
/// They go to exactly the players affected, frozen at the moment of the
/// cancellation (announcement_players), unlike an admin's training or
/// tournament message, whose audience is worked out when it's read.
///
/// Cancelling several sessions produces ONE message listing every date, not
/// one per session. That holds whether they're cancelled together (a
/// training deleted, which cancels all its upcoming sessions) or one after
/// another from the schedule: a cancellation within [_foldWindow] of an
/// earlier notice to exactly the same players is added to that notice,
/// which is rewritten and marked unread again.
///
/// Call these inside the same transaction as the cancellation itself, so a
/// notice can never describe a cancellation that was rolled back.

/// How long an automatic notice stays open for more dates to be added.
const _foldWindow = 'INTERVAL 30 MINUTE';

/// A session as a family reads it in a message: the day and times already
/// formatted the way every notice writes them.
typedef SessionView = ({
  int id,
  String type,
  String date,
  String day,
  String when,
  String? location,
  String? label,
  String? opponent,
});

/// Tells the families of everyone rostered on [sessionIds] that those
/// sessions are cancelled. Sessions before today are skipped: cancelling
/// one of those corrects the record of something that didn't happen, and a
/// "cancelled" message about last week helps nobody.
///
/// Returns how many messages were sent or updated.
Future<int> notifySessionsCancelled(
  MySQLConnection conn, {
  required List<int> sessionIds,
  required int sentBy,
}) async {
  final ids = sessionIds.toSet().toList();
  if (ids.isEmpty) return 0;
  // Validated integers only, so they're written in as a list.
  final idList = ids.join(',');
  await _retractRecentChanges(conn, idList);
  // A session scheduled by mistake and cancelled before its "new training"
  // message went out: the message is taken back, and nobody is told it's
  // cancelled either.
  final unannounced = await _retractRecentAdds(conn, idList);
  final told = ids.where((id) => !unannounced.contains(id)).toList();
  if (told.isEmpty) return 0;

  final groups = _groupByPlayers(await _rosters(conn, told.join(',')));

  var sent = 0;
  for (final group in groups) {
    final existing = await _openNoticeFor(
      conn,
      group.players,
      kind: 'sessions_cancelled',
    );
    if (existing == null) {
      final id = await _insertNotice(
        conn,
        kind: 'sessions_cancelled',
        sentBy: sentBy,
        players: group.players,
      );
      await _linkSessions(conn, id, group.sessions);
      await _rewriteSessionsNotice(conn, id);
    } else {
      await _linkSessions(conn, existing, group.sessions);
      await _rewriteSessionsNotice(conn, existing);
      // New dates in it: show it as unread again.
      await conn.execute(
        'DELETE FROM announcement_reads WHERE announcement_id = :id',
        {'id': existing},
      );
    }
    sent++;
  }
  return sent;
}

/// Each player's own set of sessions, grouped: players with exactly the
/// same sessions share a message, and someone who's only on one of three
/// isn't told about the other two. [onlyPlayers] leaves out everyone else.
List<({Set<int> sessions, Set<int> players})> _groupByPlayers(
  IResultSet rosters, {
  Set<int>? onlyPlayers,
}) {
  final byPlayer = <int, Set<int>>{};
  for (final row in rosters.rows) {
    final r = row.assoc();
    final playerId = int.parse(r['player_id']!);
    if (onlyPlayers != null && !onlyPlayers.contains(playerId)) continue;
    byPlayer
        .putIfAbsent(playerId, () => <int>{})
        .add(int.parse(r['session_id']!));
  }
  final groups = <String, ({Set<int> sessions, Set<int> players})>{};
  for (final entry in byPlayer.entries) {
    final key = (entry.value.toList()..sort()).join(',');
    groups
        .putIfAbsent(key, () => (sessions: entry.value, players: <int>{}))
        .players
        .add(entry.key);
  }
  return groups.values.toList();
}

/// Tells the families of the players on [sessionIds] that those sessions
/// are on their child's schedule: a session just created (everyone on it,
/// e.g. the training's default players), or children just put on one
/// ([onlyPlayers]). Sessions before today are skipped, like cancellations:
/// a past session is the admin recording what happened, not news.
///
/// Scheduling several sessions at once makes ONE message listing every
/// date: one added to exactly the same players while an earlier "new"
/// message is still waiting to go to their phones is added to it. Once a
/// message has gone out, the next session gets a message (and a buzz) of
/// its own, so every date reaches the phones.
///
/// Returns how many messages were sent or updated.
Future<int> notifySessionsAdded(
  MySQLConnection conn, {
  required List<int> sessionIds,
  required int sentBy,
  Set<int>? onlyPlayers,
}) async {
  final ids = sessionIds.toSet().toList();
  if (ids.isEmpty || (onlyPlayers != null && onlyPlayers.isEmpty)) return 0;
  final groups = _groupByPlayers(
    await _rosters(conn, ids.join(',')),
    onlyPlayers: onlyPlayers,
  );

  var sent = 0;
  for (final group in groups) {
    final existing = await _openNoticeFor(
      conn,
      group.players,
      kind: 'sessions_added',
    );
    if (existing == null) {
      final id = await _insertNotice(
        conn,
        kind: 'sessions_added',
        sentBy: sentBy,
        players: group.players,
        title: 'New training',
      );
      await _linkSessions(conn, id, group.sessions);
      await _rewriteAddedNotice(conn, id);
    } else {
      await _linkSessions(conn, existing, group.sessions);
      await _rewriteAddedNotice(conn, existing);
      // More dates in it: unread again.
      await conn.execute(
        'DELETE FROM announcement_reads WHERE announcement_id = :id',
        {'id': existing},
      );
    }
    sent++;
  }
  return sent;
}

/// A session cancelled straight after it was scheduled — a slip put right
/// at once: every "new training" message about it is under 15 seconds old
/// and still unsent (the notification sender waits 15 seconds for exactly
/// this; see push.dart). It's taken off those messages (one left with no
/// sessions is withdrawn, one with others is rewritten), and its id is
/// returned: a "cancelled" message about a session the family never heard
/// of would only confuse.
///
/// Anything older may already have been seen, in the app if not as a
/// notification: its "new training" message stays as it was, like an older
/// "changed" message, and the family is told it's cancelled.
Future<Set<int>> _retractRecentAdds(MySQLConnection conn, String idList) async {
  final rows = await conn.execute('''
    SELECT a.id, s.session_id,
           a.pushed_at IS NULL
             AND a.created_at > NOW() - INTERVAL 15 SECOND AS unsent
    FROM announcements a
    JOIN announcement_sessions s ON s.announcement_id = a.id
    WHERE a.auto_kind = 'sessions_added' AND a.deleted_at IS NULL
      AND s.session_id IN ($idList)
  ''');
  final unsent = <int>{};
  final seen = <int>{};
  final noticesOf = <int, Set<int>>{};
  for (final row in rows.rows) {
    final r = row.assoc();
    final sessionId = int.parse(r['session_id']!);
    noticesOf.putIfAbsent(sessionId, () => <int>{}).add(int.parse(r['id']!));
    ('${r['unsent']}' == '1' ? unsent : seen).add(sessionId);
  }
  final quiet = unsent.difference(seen);
  for (final sessionId in quiet) {
    for (final id in noticesOf[sessionId]!) {
      await conn.execute(
        'DELETE FROM announcement_sessions '
        'WHERE announcement_id = $id AND session_id = $sessionId',
      );
      final left = await conn.execute(
        'SELECT COUNT(*) AS n FROM announcement_sessions '
        'WHERE announcement_id = $id',
      );
      if (int.parse('${left.rows.first.assoc()['n']}') == 0) {
        await conn.execute(
          'UPDATE announcements SET deleted_at = NOW() WHERE id = $id',
        );
      } else {
        await _rewriteAddedNotice(conn, id);
      }
    }
  }
  return quiet;
}

/// A child taken back off a session straight after being put on it (by
/// mistake), before its "new training" message went to the phones (under
/// 15 seconds, as above): the family is taken off that
/// message, which is withdrawn if nobody's left on it. Only a message
/// about that one session; once sent, it stays.
Future<void> retractUnsentAdd(
  MySQLConnection conn, {
  required int sessionId,
  required int playerId,
}) async {
  final notices = await conn.execute('''
    SELECT a.id FROM announcements a
    JOIN announcement_sessions s ON s.announcement_id = a.id
    JOIN announcement_players ap ON ap.announcement_id = a.id
    WHERE a.auto_kind = 'sessions_added' AND a.deleted_at IS NULL
      AND a.pushed_at IS NULL AND a.created_at > NOW() - INTERVAL 15 SECOND
      AND s.session_id = $sessionId
      AND ap.player_id = $playerId
      AND NOT EXISTS (SELECT 1 FROM announcement_sessions o
                      WHERE o.announcement_id = a.id
                        AND o.session_id <> $sessionId)
  ''');
  for (final row in notices.rows) {
    final id = int.parse(row.assoc()['id']!);
    await conn.execute(
      'DELETE FROM announcement_players '
      'WHERE announcement_id = $id AND player_id = $playerId',
    );
    await conn.execute(
      'UPDATE announcements SET deleted_at = NOW() WHERE id = $id '
      'AND NOT EXISTS (SELECT 1 FROM announcement_players ap '
      'WHERE ap.announcement_id = $id)',
    );
  }
}

/// Rebuilds a "new training" message's title and body from every session
/// now linked to it, in date order.
///
///   New training: Tuesday, 6 October
///
///   Training on Tuesday, 6 October has been added to the schedule.
///
///   Time: 5:00 PM to 6:30 PM
///   Where: DSA Gym
///   Group: B2013, B2014
Future<void> _rewriteAddedNotice(MySQLConnection conn, int id) async {
  final linked = await conn.execute(
    'SELECT session_id FROM announcement_sessions WHERE announcement_id = :id',
    {'id': id},
  );
  final sessions = await _sessions(conn, {
    for (final row in linked.rows) int.parse(row.assoc()['session_id']!),
  });
  if (sessions.isEmpty) return;

  final allTraining = sessions.every((s) => s.type == 'training');
  final allGames = sessions.every((s) => s.type == 'tournament');
  final one = sessions.length == 1;
  final heading = allTraining
      ? (one ? 'New training' : 'New trainings')
      : allGames
      ? (one ? 'New game' : 'New games')
      : 'New trainings and games';
  final title = _fit(
    '$heading: ${one ? _friendlyDay(sessions.first.date) : _dateList(sessions)}',
    fallback: heading,
  );
  final String body;
  if (one) {
    final s = sessions.first;
    body = [
      '${_subject(s)} on ${_friendlyDay(s.date)} has been added to the '
          'schedule.',
      _details(s),
    ].where((part) => part.isNotEmpty).join('\n\n');
  } else {
    final labels = {for (final s in sessions) _clean(s.label)}..remove(null);
    final noun = allTraining
        ? 'trainings'
        : allGames
        ? 'games'
        : 'trainings and games';
    body = [
      'These $noun have been added to the schedule:',
      sessions.map((s) => _listLine(s, named: !allTraining)).join('\n'),
      if (allTraining && labels.length == 1) 'Group: ${labels.first}',
    ].join('\n\n');
  }
  await conn.execute(
    'UPDATE announcements SET title = :title, body = :body WHERE id = :id',
    {'id': id, 'title': title, 'body': body},
  );
}

/// A "changed" message about any of [idList]'s sessions sent within
/// [_foldWindow] is taken back when they're cancelled: "the time moved to
/// 4 PM" followed a minute later by "cancelled" only confuses, and the
/// cancellation already gives the time it had moved to. Older ones stay:
/// by then families may have acted on them.
Future<void> _retractRecentChanges(MySQLConnection conn, String idList) =>
    conn.execute('''
      UPDATE announcements a
      JOIN announcement_sessions s ON s.announcement_id = a.id
      SET a.deleted_at = NOW()
      WHERE a.auto_kind = 'session_changed' AND a.deleted_at IS NULL
        AND a.created_at >= NOW() - $_foldWindow
        AND s.session_id IN ($idList)
    ''');

/// A cancelled session put back on the schedule.
///
/// Its cancellation message, if sent within [_foldWindow] (an admin undoing
/// a slip), is taken back: the session comes off it, and it's rewritten
/// for any other sessions it lists (and shown as unread again), or
/// withdrawn if this was its only one. An older cancellation has been read
/// and planned around, so the families are told it's back on instead.
Future<void> notifySessionRestored(
  MySQLConnection conn, {
  required int sessionId,
  required int sentBy,
}) async {
  final notices = await conn.execute('''
    SELECT a.id, a.created_at >= NOW() - $_foldWindow AS recent
    FROM announcements a
    JOIN announcement_sessions s ON s.announcement_id = a.id
    WHERE a.auto_kind = 'sessions_cancelled' AND a.deleted_at IS NULL
      AND s.session_id = $sessionId
  ''');
  // No cancellation message: it was cancelled before anyone heard of it
  // (see _retractRecentAdds), so put back, it's news again.
  if (notices.rows.isEmpty) {
    await notifySessionsAdded(conn, sessionIds: [sessionId], sentBy: sentBy);
    return;
  }
  var tellBackOn = false;
  for (final row in notices.rows) {
    final id = int.parse(row.assoc()['id']!);
    if ('${row.assoc()['recent']}' != '1') {
      tellBackOn = true;
      continue;
    }
    await conn.execute(
      'DELETE FROM announcement_sessions '
      'WHERE announcement_id = $id AND session_id = $sessionId',
    );
    final left = await conn.execute(
      'SELECT COUNT(*) AS n FROM announcement_sessions '
      'WHERE announcement_id = $id',
    );
    if (int.parse('${left.rows.first.assoc()['n']}') == 0) {
      await conn.execute(
        'UPDATE announcements SET deleted_at = NOW() WHERE id = $id',
      );
    } else {
      await _rewriteSessionsNotice(conn, id);
      await conn.execute(
        'DELETE FROM announcement_reads WHERE announcement_id = $id',
      );
    }
  }
  if (!tellBackOn) return;

  final s = await describeSession(conn, sessionId);
  if (s == null) return;
  final rosters = await _rosters(conn, '$sessionId');
  final players = {
    for (final row in rosters.rows) int.parse(row.assoc()['player_id']!),
  };
  if (players.isEmpty) return;
  final kind = s.type == 'training' ? 'Training' : 'Game';
  final day = _friendlyDay(s.date);
  final id = await _insertNotice(
    conn,
    kind: 'session_changed',
    sentBy: sentBy,
    players: players,
    title: _fit('$kind back on: $day', fallback: '$kind back on'),
    body: [
      '${_subject(s)} on $day is back on and will go ahead as planned.',
      _details(s),
    ].where((part) => part.isNotEmpty).join('\n\n'),
  );
  await _linkSessions(conn, id, {sessionId});
}

/// Who is on each of [idList]'s sessions, for those today or later. A
/// tournament game's roster is its tournament's (see GET /sessions), minus
/// anyone whose family declined it.
Future<IResultSet> _rosters(MySQLConnection conn, String idList) =>
    conn.execute('''
      SELECT s.id AS session_id, sp.player_id
      FROM sessions s
      JOIN session_players sp ON sp.session_id = s.id
      JOIN players p ON p.id = sp.player_id AND p.is_active = 1
      WHERE s.id IN ($idList) AND s.session_date >= CURRENT_DATE
      UNION
      SELECT s.id, tp.player_id
      FROM sessions s
      JOIN tournament_players tp ON tp.tournament_id = s.tournament_id
                                AND tp.consent <> 'declined'
      JOIN players p ON p.id = tp.player_id AND p.is_active = 1
      WHERE s.id IN ($idList) AND s.session_date >= CURRENT_DATE
        AND s.session_type = 'tournament'
    ''');

/// One session as families would read it, or null if there's no such id.
Future<SessionView?> describeSession(MySQLConnection conn, int id) async {
  final found = await _sessions(conn, {id});
  return found.isEmpty ? null : found.first;
}

/// Tells the families of everyone on a session what changed about it: the
/// date, the time, the place or the opponent. [before] is the session as it
/// was (describeSession, taken before the change, in the same transaction).
///
/// Nothing is sent when nothing a family would notice changed, or nobody is
/// on it. Returns the message's id, or null.
///
/// Edits within [_foldWindow] of an earlier "changed" message about the same
/// session rewrite THAT message, compared against the session as it was
/// before the first edit: fixing a time twice is one message, and a change
/// put straight back takes its message back (soft-deleted). A message the
/// admin has edited by hand has no auto_kind any more and is left alone.
Future<int?> notifySessionChanged(
  MySQLConnection conn, {
  required SessionView before,
  required int sentBy,
}) async {
  final after = await describeSession(conn, before.id);
  if (after == null) return null;
  // This save itself changed nothing a family would notice: leave any
  // earlier message exactly as it is (not rewritten, not marked unread).
  if (_changes(before, after).isEmpty) return null;

  final open = await conn.execute('''
    SELECT a.id, s.was_json
    FROM announcements a
    JOIN announcement_sessions s ON s.announcement_id = a.id
    WHERE a.auto_kind = 'session_changed' AND a.deleted_at IS NULL
      AND a.created_at >= NOW() - $_foldWindow
      AND s.session_id = ${before.id} AND s.was_json IS NOT NULL
    ORDER BY a.id DESC
    LIMIT 1
  ''');
  int? existing;
  if (open.rows.isNotEmpty) {
    final row = open.rows.first.assoc();
    final was = _viewFromJson(row['was_json']);
    if (was != null) {
      existing = int.parse(row['id']!);
      before = was;
    }
  }
  final changes = _changes(before, after);
  if (changes.isEmpty) {
    // Back exactly as it was: the earlier message is no longer true.
    if (existing != null) {
      await conn.execute(
        'UPDATE announcements SET deleted_at = NOW() WHERE id = :id',
        {'id': existing},
      );
    }
    return null;
  }

  final rosters = await _rosters(conn, '${after.id}');
  final players = {
    for (final row in rosters.rows) int.parse(row.assoc()['player_id']!),
  };
  if (players.isEmpty) return null;

  final (:title, :body) = _changedMessage(before, after);
  if (existing != null) {
    await conn.execute(
      'UPDATE announcements SET title = :title, body = :body WHERE id = :id',
      {'id': existing, 'title': title, 'body': body.toString()},
    );
    // The roster may have changed since; and it's news again, so unread.
    await conn.execute(
      'DELETE FROM announcement_players WHERE announcement_id = :id',
      {'id': existing},
    );
    for (final playerId in players) {
      await conn.execute(
        'INSERT IGNORE INTO announcement_players (announcement_id, player_id) '
        'VALUES (:id, :playerId)',
        {'id': existing, 'playerId': playerId},
      );
    }
    await conn.execute(
      'DELETE FROM announcement_reads WHERE announcement_id = :id',
      {'id': existing},
    );
    return existing;
  }

  final id = await _insertNotice(
    conn,
    kind: 'session_changed',
    sentBy: sentBy,
    players: players,
    title: title,
    body: body.toString(),
  );
  await conn.execute(
    'INSERT INTO announcement_sessions (announcement_id, session_id, was_json) '
    'VALUES (:id, :sessionId, :was)',
    {'id': id, 'sessionId': after.id, 'was': _viewToJson(before)},
  );
  return id;
}

/// A "session changed" message, written for a parent reading it on a phone:
/// one plain sentence saying what happened, then each change as "New ...:"
/// over "Was:", then the details that stayed the same. Families know the
/// session by the day it WAS on, so that's the day the title names.
///
///   Training time changed: Saturday, 26 September
///
///   Training on Saturday, 26 September has a new time.
///
///   New time: 4:00 PM to 6:00 PM
///   Was: 5:00 PM to 6:00 PM
///
///   Where: DSA Gym
///   Group: B2013, B2014, B2015
({String title, String body}) _changedMessage(
  SessionView before,
  SessionView after,
) {
  final dayMoved = after.date != before.date;
  final timeMoved = after.when != before.when;
  final placeMoved = _place(after) != _place(before);
  final opponentChanged = _opponent(after) != _opponent(before);
  final count = [
    dayMoved,
    timeMoved,
    placeMoved,
    opponentChanged,
  ].where((changed) => changed).length;

  final kind = after.type == 'training' ? 'Training' : 'Game';
  final was = _friendlyDay(before.date);
  final now = _friendlyDay(after.date);

  final title = dayMoved
      ? 'Training moved: $was to $now'.replaceFirst('Training', kind)
      : count == 1 && timeMoved
      ? '$kind time changed: $was'
      : count == 1 && placeMoved
      ? '$kind place changed: $was'
      : count == 1 && opponentChanged
      ? '$kind opponent changed: $was'
      : '$kind changed: $was';

  // No opening sentence: the title already says what happened. Just the
  // new details, then what stayed the same. Which of the family's children
  // it's about is added by the app (each family sees only its own).
  final changed = [
    if (dayMoved) 'New day: $now',
    if (timeMoved) 'New time: ${_times(after)}',
    if (placeMoved) 'New place: ${_place(after) ?? 'to be confirmed'}',
    if (opponentChanged)
      'New opponent: ${_opponent(after) ?? 'to be confirmed'}',
  ];
  final unchanged = [
    if (!timeMoved && after.when.isNotEmpty) 'Time: ${_times(after)}',
    if (!placeMoved && _place(after) != null) 'Where: ${_place(after)}',
    if (!opponentChanged && _opponent(after) != null)
      'Opponent: ${_opponent(after)}',
  ];
  final body = [
    changed.join('\n'),
    if (unchanged.isNotEmpty) unchanged.join('\n'),
  ].join('\n\n');
  return (title: _fit(title, fallback: '$kind changed'), body: body);
}

String? _clean(String? value) =>
    value == null || value.trim().isEmpty ? null : value.trim();

String? _place(SessionView s) => _clean(s.location);

String? _opponent(SessionView s) =>
    _clean(s.opponent) == null ? null : 'vs ${_clean(s.opponent)}';

/// "5:00 PM to 6:30 PM", or just "10:00 AM" for a game.
String _times(SessionView s) => s.when.replaceAll(' - ', ' to ');

/// "Training", or "The Victory Cup game".
String _subject(SessionView s) {
  if (s.type == 'training') return 'Training';
  final label = _clean(s.label);
  return label == null ? 'The game' : 'The $label game';
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// "Saturday, 26 September" — with the year only when it isn't this year.
String _friendlyDay(String isoDate) {
  final date = DateTime.parse(isoDate);
  final year = date.year == DateTime.now().year ? '' : ' ${date.year}';
  return '${_weekdays[date.weekday - 1]}, ${date.day} '
      '${_months[date.month - 1]}$year';
}

/// One session on one line, for a list of several:
/// "Saturday, 13 September, 5:00 PM to 6:30 PM at DSA Gym".
///
/// [named] says what each one is — "(Training)", "(Victory Cup vs Hawks)"
/// — for a list that isn't all training: a game and a training cancelled
/// together otherwise read the same. A game always names its opponent.
String _listLine(SessionView s, {bool named = true}) {
  final parts = StringBuffer('• ${_friendlyDay(s.date)}');
  if (s.when.isNotEmpty) parts.write(', ${_times(s)}');
  if (_place(s) != null) parts.write(' at ${_place(s)}');
  final what = s.type == 'training'
      ? (named ? 'Training' : '')
      : [
          if (named && _clean(s.label) != null) _clean(s.label),
          if (_opponent(s) != null) _opponent(s),
        ].join(' ');
  if (what.isNotEmpty) parts.write(' ($what)');
  return parts.toString();
}

/// The details of one session, one "Label: value" line each.
String _details(SessionView s) => [
  if (s.when.isNotEmpty) 'Time: ${_times(s)}',
  if (_place(s) != null) 'Where: ${_place(s)}',
  if (s.type == 'tournament' && _opponent(s) != null)
    'Opponent: ${_opponent(s)}',
  if (s.type == 'training' && _clean(s.label) != null)
    'Group: ${_clean(s.label)}',
].join('\n');

/// What a family would notice between two versions of a session, one line
/// each: date, time, location, opponent. (Empty = nothing to tell them.)
List<String> _changes(SessionView before, SessionView after) {
  String? clean(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
  return [
    if (after.date != before.date)
      '• Date: now ${after.day} (was ${before.day})',
    if (after.when != before.when)
      '• Time: now ${after.when} (was ${before.when})',
    if (clean(after.location) != clean(before.location))
      '• Location: now ${clean(after.location) ?? 'to be confirmed'}'
          '${clean(before.location) == null ? '' : ' (was ${clean(before.location)})'}',
    if (clean(after.opponent) != clean(before.opponent))
      '• Opponent: now ${clean(after.opponent) ?? 'to be confirmed'}'
          '${clean(before.opponent) == null ? '' : ' (was ${clean(before.opponent)})'}',
  ];
}

String _viewToJson(SessionView s) => jsonEncode({
  'id': s.id,
  'type': s.type,
  'date': s.date,
  'day': s.day,
  'when': s.when,
  'location': s.location,
  'label': s.label,
  'opponent': s.opponent,
});

SessionView? _viewFromJson(String? raw) {
  if (raw == null) return null;
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return (
      id: m['id'] as int,
      type: m['type'] as String,
      date: m['date'] as String,
      day: m['day'] as String,
      when: m['when'] as String,
      location: m['location'] as String?,
      label: m['label'] as String?,
      opponent: m['opponent'] as String?,
    );
  } catch (_) {
    return null;
  }
}

/// Tells the families of everyone on a tournament that it's been called
/// off. [cancelledGames] are its upcoming games that were cancelled with it.
Future<void> notifyTournamentCancelled(
  MySQLConnection conn, {
  required Object tournamentId,
  required int sentBy,
  required List<int> cancelledGames,
}) async {
  final tournament = await conn.execute(
    'SELECT name, location FROM tournaments WHERE id = :id',
    {'id': tournamentId},
  );
  if (tournament.rows.isEmpty) return;
  final name = tournament.rows.first.assoc()['name']!;

  // Declined families were never going; everyone else was.
  final roster = await conn.execute(
    'SELECT tp.player_id FROM tournament_players tp '
    'JOIN players p ON p.id = tp.player_id AND p.is_active = 1 '
    "WHERE tp.tournament_id = :id AND tp.consent <> 'declined'",
    {'id': tournamentId},
  );
  final players = {
    for (final row in roster.rows) int.parse(row.assoc()['player_id']!),
  };
  if (players.isEmpty) return;

  final billed = await conn.execute(
    'SELECT COUNT(*) AS n FROM payments WHERE tournament_id = :id',
    {'id': tournamentId},
  );
  final hadFees = int.parse('${billed.rows.first.assoc()['n']}') > 0;

  final games = cancelledGames.isEmpty
      ? const <SessionView>[]
      : await _sessions(conn, cancelledGames.toSet());
  if (cancelledGames.isNotEmpty) {
    await _retractRecentChanges(conn, cancelledGames.toSet().join(','));
  }
  final body = StringBuffer('$name has been cancelled.');
  if (games.isNotEmpty) {
    body
      ..write(
        games.length == 1
            ? "\n\nThis game won't take place:\n"
            : "\n\nThese games won't take place:\n",
      )
      ..write(games.map((g) => _listLine(g, named: false)).join('\n'));
  }
  if (hadFees) {
    body.write(
      "\n\nIf you've already paid the tournament fee, the academy will contact "
      "you about a refund. Any fee you hadn't paid yet has been cancelled.",
    );
  }

  final id = await _insertNotice(
    conn,
    kind: 'tournament_cancelled',
    sentBy: sentBy,
    players: players,
    title: _fit('Tournament cancelled: $name'),
    body: body.toString(),
  );
  await conn.execute(
    'INSERT IGNORE INTO announcement_tournaments '
    '(announcement_id, tournament_id) VALUES (:id, :tournamentId)',
    {'id': id, 'tournamentId': tournamentId},
  );
  if (games.isNotEmpty) {
    await _linkSessions(conn, id, {for (final g in games) g.id});
  }
}

/// A recent automatic notice of [kind] ('sessions_cancelled' or
/// 'sessions_added') addressed to exactly [players], if there is one still
/// open for more dates. A "new" message stays open only until it has gone
/// to the phones.
Future<int?> _openNoticeFor(
  MySQLConnection conn,
  Set<int> players, {
  required String kind,
}) async {
  // Row by row, not GROUP_CONCAT: that stops at 1024 bytes without saying
  // so, and a big roster's list would never match, sending a fresh message
  // for every session cancelled.
  final rows = await conn.execute('''
    SELECT a.id, ap.player_id
    FROM announcements a
    JOIN announcement_players ap ON ap.announcement_id = a.id
    WHERE a.auto_kind = '$kind'
      ${kind == 'sessions_added' ? 'AND a.pushed_at IS NULL' : ''}
      AND a.deleted_at IS NULL
      AND a.created_at >= NOW() - $_foldWindow
    ORDER BY a.id DESC
  ''');
  final byNotice = <int, Set<int>>{};
  for (final row in rows.rows) {
    byNotice
        .putIfAbsent(int.parse(row.assoc()['id']!), () => <int>{})
        .add(int.parse(row.assoc()['player_id']!));
  }
  for (final entry in byNotice.entries) {
    final sent = entry.value;
    if (sent.length == players.length && sent.containsAll(players)) {
      return entry.key;
    }
  }
  return null;
}

Future<int> _insertNotice(
  MySQLConnection conn, {
  required String kind,
  required int? sentBy,
  required Set<int> players,
  String title = 'Session Cancelled',
  String body = '',
}) async {
  final inserted = await conn.execute(
    'INSERT INTO announcements (title, body, is_everyone, auto_kind, sent_by) '
    'VALUES (:title, :body, 0, :kind, :sentBy)',
    {'title': title, 'body': body, 'kind': kind, 'sentBy': sentBy},
  );
  final id = inserted.lastInsertID.toInt();
  for (final playerId in players) {
    await conn.execute(
      'INSERT IGNORE INTO announcement_players (announcement_id, player_id) '
      'VALUES (:id, :playerId)',
      {'id': id, 'playerId': playerId},
    );
  }
  return id;
}

Future<void> _linkSessions(
  MySQLConnection conn,
  int announcementId,
  Set<int> sessionIds,
) async {
  for (final sessionId in sessionIds) {
    await conn.execute(
      'INSERT IGNORE INTO announcement_sessions (announcement_id, session_id) '
      'VALUES (:id, :sessionId)',
      {'id': announcementId, 'sessionId': sessionId},
    );
  }
}

/// Rebuilds a sessions-cancelled notice's title and body from every session
/// now linked to it, in date order.
Future<void> _rewriteSessionsNotice(MySQLConnection conn, int id) async {
  final linked = await conn.execute(
    'SELECT session_id FROM announcement_sessions WHERE announcement_id = :id',
    {'id': id},
  );
  final sessions = await _sessions(conn, {
    for (final row in linked.rows) int.parse(row.assoc()['session_id']!),
  });
  if (sessions.isEmpty) return;

  final allTraining = sessions.every((s) => s.type == 'training');
  final allGames = sessions.every((s) => s.type == 'tournament');
  final anyTraining = sessions.any((s) => s.type == 'training');
  final one = sessions.length == 1;
  final heading = allTraining
      ? 'Training cancelled'
      : allGames
      ? (one ? 'Game cancelled' : 'Games cancelled')
      : 'Trainings and games cancelled';

  // One session: its weekday too ("Thursday, 1 October"), like a change
  // message. Several: the dates grouped ("13, 14 and 15 September").
  final title = _fit(
    '$heading: ${one ? _friendlyDay(sessions.first.date) : _dateList(sessions)}',
    fallback: heading,
  );
  final String body;
  if (one) {
    // "Training on Thursday, 1 October is cancelled." then its details.
    final s = sessions.first;
    body = [
      '${_subject(s)} on ${_friendlyDay(s.date)} is cancelled.',
      _details(s),
      if (anyTraining) "You won't be charged for it.",
    ].where((part) => part.isNotEmpty).join('\n\n');
  } else {
    final labels = {for (final s in sessions) _clean(s.label)}..remove(null);
    final noun = allTraining
        ? 'trainings'
        : allGames
        ? 'games'
        : 'trainings and games';
    body = [
      'These $noun are cancelled:',
      sessions.map((s) => _listLine(s, named: !allTraining)).join('\n'),
      if (allTraining && labels.length == 1) 'Group: ${labels.first}',
      if (anyTraining) "You won't be charged for cancelled trainings.",
    ].join('\n\n');
  }
  await conn.execute(
    'UPDATE announcements SET title = :title, body = :body WHERE id = :id',
    {'id': id, 'title': title, 'body': body.toString()},
  );
}

Future<List<SessionView>> _sessions(MySQLConnection conn, Set<int> ids) async {
  if (ids.isEmpty) return const [];
  final result = await conn.execute('''
    SELECT s.id, s.session_type,
           DATE_FORMAT(s.session_date, '%Y-%m-%d') AS date,
           DATE_FORMAT(s.session_date, '%W, %e %M %Y') AS day,
           TRIM(CONCAT(TIME_FORMAT(s.start_time, '%l:%i %p'),
                       COALESCE(CONCAT(' - ', TRIM(TIME_FORMAT(s.end_time,
                                '%l:%i %p'))), ''))) AS time_range,
           s.location,
           COALESCE(NULLIF(TRIM(t.name), ''),
                    NULLIF(TRIM(s.category_label), '')) AS label,
           s.opponent
    FROM sessions s
    LEFT JOIN tournaments t ON t.id = s.tournament_id
    WHERE s.id IN (${ids.join(',')})
    ORDER BY s.session_date, s.start_time, s.id
  ''');
  return [
    for (final row in result.rows)
      (
        id: int.parse(row.assoc()['id']!),
        type: row.assoc()['session_type']!,
        date: row.assoc()['date']!,
        day: row.assoc()['day']!,
        when: row.assoc()['time_range'] ?? '',
        location: row.assoc()['location'],
        label: row.assoc()['label'],
        opponent: row.assoc()['opponent'],
      ),
  ];
}

const _months = [
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

/// The dates, grouped by month: "13, 14 and 15 September",
/// "30 September and 1 October". The year only when they span two.
String _dateList(List<SessionView> sessions) {
  final dates = {for (final s in sessions) DateTime.parse(s.date)}.toList()
    ..sort();
  final spansYears = dates.first.year != dates.last.year;
  final byMonth = <String, List<int>>{};
  final labels = <String, String>{};
  for (final date in dates) {
    final key = '${date.year}-${date.month}';
    byMonth.putIfAbsent(key, () => []).add(date.day);
    labels[key] =
        '${_months[date.month - 1]}${spansYears ? ' ${date.year}' : ''}';
  }
  final chunks = [
    for (final entry in byMonth.entries)
      '${_and(entry.value.map((d) => '$d').toList())} ${labels[entry.key]}',
  ];
  return _and(chunks);
}

String _and(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// Titles are VARCHAR(160). A long list of dates falls back to [fallback].
String _fit(String title, {String? fallback}) {
  if (title.length <= 160) return title;
  return fallback ?? '${title.substring(0, 157)}...';
}

/// Tells a family the academy answered the jersey number they asked for.
/// [given] is the number the child now wears when approved (the admin may
/// have chosen a different one than [asked]; null = no number), and is
/// ignored when declined. [newPlayer]: the child was waiting to be added.
Future<void> notifyJerseyDecision(
  MySQLConnection conn, {
  required int playerId,
  required int sentBy,
  required bool approved,
  required String asked,
  String? given,
  required bool newPlayer,
}) async {
  final name = await _playerName(conn, playerId);
  if (name == null) return;
  final String title;
  final String body;
  if (!approved) {
    title = 'Jersey #$asked not approved';
    body =
        "The academy didn't approve jersey #$asked for $name. Please open "
        'My Players and choose another number.'
        '${newPlayer ? ' $name will be added once a number is settled.' : ''}';
  } else {
    final number = given == null ? 'no number' : 'jersey #$given';
    final changed = given != asked;
    title = newPlayer
        ? '$name has been added'
        : given == null
        ? 'Jersey number updated'
        : 'Jersey #$given approved';
    body = [
      newPlayer
          ? '$name is now a player at the academy, with $number.'
          : '$name now has $number.',
      if (changed)
        'You asked for #$asked; the academy chose '
            '${given == null ? 'no number' : '#$given'} instead.',
    ].join(' ');
  }
  await _insertNotice(
    conn,
    kind: 'jersey_number',
    sentBy: sentBy,
    players: {playerId},
    title: _fit(title),
    body: body,
  );
}

/// Tells the family that the admin has marked one of their bills as fully
/// paid: a training fee, a tournament fee, a kit order or another payment.
/// Call it in the same transaction, right after the payment that settled
/// the bill. Nothing is sent unless the bill really is paid now.
///
/// Only for money the admin records. A family paying in the app already
/// sees it paid, and credit carried on from another month isn't a payment.
Future<void> notifyPaymentPaid(
  MySQLConnection conn, {
  required int paymentId,
  required int sentBy,
}) async {
  final found = await conn.execute(
    'SELECT pay.player_id, pay.payment_type, pay.misc_type, pay.title, '
    'pay.amount, pay.status, pl.full_name '
    'FROM payments pay JOIN players pl ON pl.id = pay.player_id '
    'WHERE pay.id = :id',
    {'id': paymentId},
  );
  if (found.rows.isEmpty) return;
  final row = found.rows.first.assoc();
  if (row['status'] != 'paid') return;
  final heading = switch ((row['payment_type'], row['misc_type'])) {
    ('training_fee', _) => 'Training fee paid',
    ('tournament', _) => 'Tournament fee paid',
    ('misc', 'uniform' || 'merch') => 'Order paid',
    _ => 'Payment received',
  };
  final amount = num.tryParse('${row['amount']}') ?? 0;
  await _insertNotice(
    conn,
    kind: 'payment_paid',
    sentBy: sentBy,
    players: {int.parse(row['player_id']!)},
    title: _fit(heading),
    body:
        '${row['title']} for ${row['full_name']} '
        '(AED ${amount.toStringAsFixed(2)}) has been marked as paid. '
        'Thank you!',
  );
}

/// Reminds families who haven't answered a tournament invitation yet to
/// accept or decline: one message (and phone notification) per child.
///
/// [playerIds] limits it to those children; null = everyone still waiting.
/// Children who have answered, aren't on the tournament, or were reminded
/// in the last two minutes (a double tap) are skipped.
Future<({int reminded, int skipped})> notifyTournamentReminder(
  MySQLConnection conn, {
  required int tournamentId,
  required int sentBy,
  List<int>? playerIds,
}) async {
  final tournament = await conn.execute(
    'SELECT name FROM tournaments WHERE id = :id AND deleted_at IS NULL',
    {'id': tournamentId},
  );
  if (tournament.rows.isEmpty) return (reminded: 0, skipped: 0);
  final name = tournament.rows.first.assoc()['name']!;
  final waiting = await conn.execute(
    'SELECT tp.player_id, p.full_name, '
    '  EXISTS (SELECT 1 FROM announcements a '
    '    JOIN announcement_players ap ON ap.announcement_id = a.id '
    "    WHERE a.auto_kind = 'tournament_reminder' "
    '      AND ap.player_id = tp.player_id AND a.deleted_at IS NULL '
    '      AND a.created_at > NOW() - INTERVAL 2 MINUTE) AS just_reminded '
    'FROM tournament_players tp '
    'JOIN players p ON p.id = tp.player_id AND p.is_active = 1 '
    "WHERE tp.tournament_id = :id AND tp.consent = 'pending'",
    {'id': tournamentId},
  );
  final wanted = playerIds?.toSet();
  var reminded = 0;
  var skipped = 0;
  for (final row in waiting.rows) {
    final r = row.assoc();
    final playerId = int.parse(r['player_id']!);
    if (wanted != null && !wanted.contains(playerId)) continue;
    if (r['just_reminded'] == '1') {
      skipped++;
      continue;
    }
    await _insertNotice(
      conn,
      kind: 'tournament_reminder',
      sentBy: sentBy,
      players: {playerId},
      title: _fit('Reminder: $name'),
      body:
          '${r['full_name']} is invited to $name. Please open Tournaments '
          'to accept or decline.',
    );
    reminded++;
  }
  return (reminded: reminded, skipped: skipped);
}

/// Tells the admin that a family declined a tournament invitation, and why.
/// For the admin only: it's sent to no family (no audience), so only the
/// admin's Messages list shows it. Admins get no phone notifications.
Future<void> notifyTournamentDeclined(
  MySQLConnection conn, {
  required int tournamentId,
  required int playerId,
  required String? reason,
  required int sentBy,
}) async {
  final found = await conn.execute(
    'SELECT t.name, p.full_name FROM tournaments t, players p '
    'WHERE t.id = :t AND p.id = :p',
    {'t': tournamentId, 'p': playerId},
  );
  if (found.rows.isEmpty) return;
  final row = found.rows.first.assoc();
  await conn.execute(
    'INSERT INTO announcements (title, body, is_everyone, auto_kind, sent_by) '
    "VALUES (:title, :body, 0, 'tournament_declined', :sentBy)",
    {
      'title': _fit('${row['full_name']} declined ${row['name']}'),
      'body': reason == null
          ? '${row['full_name']} won\'t join ${row['name']}. No reason was '
                'given.'
          : '${row['full_name']} won\'t join ${row['name']}.\n\n'
                'Reason: $reason',
      'sentBy': sentBy,
    },
  );
}

Future<String?> _playerName(MySQLConnection conn, int playerId) async {
  final found = await conn.execute(
    'SELECT full_name FROM players WHERE id = :id',
    {'id': playerId},
  );
  return found.rows.isEmpty ? null : found.rows.first.assoc()['full_name'];
}

/// Wishes every player whose birthday is today a happy birthday: one
/// message (and phone notification) to their family, once a year. Run
/// every hour by the server; nothing is sent before [fromHour] (7) in the
/// morning (UAE time), so no phone buzzes at midnight. A child born on
/// 29 February is wished on the 28th in other years.
///
/// Returns how many were sent.
Future<int> sendBirthdayGreetings(Db db, {int fromHour = _birthdayHour}) async {
  return db.transaction((conn) async {
    final due = await conn.execute('''
      SELECT p.id, p.full_name, p.nickname,
             TIMESTAMPDIFF(YEAR, p.birthday, CURDATE()) AS age
      FROM players p
      WHERE p.is_active = 1 AND p.is_approved = 1 AND p.birthday IS NOT NULL
        AND HOUR(NOW()) >= $fromHour
        AND (DATE_FORMAT(p.birthday, '%m-%d') = DATE_FORMAT(CURDATE(), '%m-%d')
             OR (DATE_FORMAT(p.birthday, '%m-%d') = '02-29'
                 AND DATE_FORMAT(CURDATE(), '%m-%d') = '02-28'
                 AND DAY(LAST_DAY(CURDATE())) = 28))
        AND NOT EXISTS (
          SELECT 1 FROM announcements a
          JOIN announcement_players ap ON ap.announcement_id = a.id
          WHERE a.auto_kind = 'birthday' AND ap.player_id = p.id
            AND YEAR(a.created_at) = YEAR(CURDATE()))
      FOR UPDATE
    ''');
    var sent = 0;
    for (final row in due.rows) {
      final r = row.assoc();
      final fullName = r['full_name']!;
      final nickname = r['nickname'];
      // What the team calls them, or their first name.
      final callName = nickname != null && nickname.isNotEmpty
          ? nickname
          : fullName.split(' ').first;
      final age = int.tryParse('${r['age']}');
      final birthday = age == null || age <= 0
          ? 'birthday'
          : '${_ordinal(age)} birthday';
      await _insertNotice(
        conn,
        kind: 'birthday',
        sentBy: null,
        players: {int.parse(r['id']!)},
        title: _fit('Happy Birthday, $callName!'),
        body:
            'Happy $birthday, $fullName! Everyone at DSA Elite Academy '
            'wishes you a wonderful day. Enjoy it, and see you at training!',
      );
      sent++;
    }
    return sent;
  });
}

/// The earliest hour (UAE time) a birthday message goes out.
const _birthdayHour = 7;

/// 1st, 2nd, 3rd, 4th ... 11th, 12th, 13th ... 21st, 22nd.
String _ordinal(int n) {
  final lastTwo = n % 100;
  if (lastTwo >= 11 && lastTwo <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}
