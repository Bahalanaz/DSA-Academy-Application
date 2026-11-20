import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Thrown inside a transaction to roll it back when none of the requested
/// audiences exist any more, so no announcement is left addressed to nobody.
class _NoAudience implements Exception {}

List<int> _ids(Object? raw) => (raw as List? ?? [])
    .map((e) => int.tryParse('$e'))
    .whereType<int>()
    .toSet()
    .toList();

/// Announcements from admin to parents. An announcement goes to everyone
/// (is_everyone = 1), or to any mix of:
///   * categories  — every player born in that year
///   * trainings   — every player rostered on one of its sessions
///   * tournaments — every player on its roster
///
/// Who counts as "in" a training or tournament is resolved when the list is
/// read, not frozen at send time. So a player added to a tournament after a
/// message went out still sees it — the useful behaviour for "squad news",
/// and the reason these are link tables rather than a copied recipient list.
Router buildAnnouncementsRouter(Db db) {
  final router = Router();

  router.get('/announcements', (Request request) async {
    final user = userOf(request);
    // A parent sees messages from a month before their account was created
    // onwards. Every message the club had ever sent used to show to a family
    // that joined yesterday, years-old cancellations included.
    final since = user.isAdmin
        ? ''
        : 'AND a.created_at >= (SELECT DATE_SUB(u.created_at, INTERVAL 30 DAY) '
              'FROM users u WHERE u.id = ${user.id})';
    final base = await db.execute('''
      SELECT
        a.id,
        a.title,
        a.body,
        a.is_everyone,
        a.auto_kind,
        a.created_at,
        GROUP_CONCAT(c.code ORDER BY c.birth_year) AS audiences
      FROM announcements a
      LEFT JOIN announcement_categories ac ON ac.announcement_id = a.id
      LEFT JOIN categories c ON c.id = ac.category_id
      WHERE a.deleted_at IS NULL $since
      GROUP BY a.id, a.title, a.body, a.is_everyone, a.auto_kind, a.created_at
      ORDER BY a.created_at DESC
    ''');

    // Named the way the app names it: the admin's name if they gave one,
    // otherwise "<categories> Training". Includes deleted trainings, so an
    // old message still says who it went to.
    final trainings = await db.execute('''
      SELECT
        atr.announcement_id,
        t.id,
        COALESCE(
          NULLIF(TRIM(t.name), ''),
          CONCAT(GROUP_CONCAT(c.code ORDER BY c.birth_year SEPARATOR ', '),
                 ' Training'),
          'Training'
        ) AS name
      FROM announcement_trainings atr
      JOIN training_programs t ON t.id = atr.training_program_id
      LEFT JOIN training_program_categories tpc
             ON tpc.training_program_id = t.id
      LEFT JOIN categories c ON c.id = tpc.category_id
      GROUP BY atr.announcement_id, t.id, t.name
      ORDER BY t.id
    ''');

    final tournaments = await db.execute('''
      SELECT atn.announcement_id, tn.id, tn.name
      FROM announcement_tournaments atn
      JOIN tournaments tn ON tn.id = atn.tournament_id
      ORDER BY tn.id
    ''');

    // Cancelled sessions deliberately still count. Deleting a training
    // cancels its upcoming sessions; if that dropped their players from
    // the audience, the "training is cancelled" message would disappear
    // for exactly the people it was written for.
    //
    // Only sessions from 60 days before the message onwards, though. Anyone
    // ever rostered used to count, so a child who trained there once, a year
    // earlier, kept receiving every new message sent to that training.
    final members = await db.execute('''
      SELECT atr.announcement_id, sp.player_id
      FROM announcement_trainings atr
      JOIN announcements an ON an.id = atr.announcement_id
      JOIN sessions s
        ON s.training_program_id = atr.training_program_id
       AND s.session_date >= DATE_SUB(DATE(an.created_at), INTERVAL 60 DAY)
      JOIN session_players sp ON sp.session_id = s.id
      UNION
      SELECT atn.announcement_id, tp.player_id
      FROM announcement_tournaments atn
      -- A family that declined the tournament is out of it: its news and its
      -- cancellation aren't for them. (Undecided families still hear, so
      -- they have what they need to answer.)
      JOIN tournament_players tp ON tp.tournament_id = atn.tournament_id
                                AND tp.consent <> 'declined'
      UNION
      -- Sent to named players (the automatic cancellation notices): the
      -- players on the sessions or tournament when it was cancelled.
      SELECT ap.announcement_id, ap.player_id
      FROM announcement_players ap
    ''');

    // Those named players, so the admin's list can say who a notice went
    // to. Cut down to a parent's own children below, like the members.
    final direct = await db.execute('''
      SELECT ap.announcement_id, p.id AS player_id, p.full_name AS name
      FROM announcement_players ap
      JOIN players p ON p.id = ap.player_id
      ORDER BY p.full_name, p.id
    ''');

    // Sent to one family's account (Parent Accounts > Send message).
    final toAccounts = await db.execute('''
      SELECT au.announcement_id, u.id AS user_id, u.full_name AS name
      FROM announcement_users au
      JOIN users u ON u.id = au.user_id
      ORDER BY u.full_name, u.id
    ''');

    Map<String, List<Map<String, dynamic>>> group(IResultSet rows) {
      final out = <String, List<Map<String, dynamic>>>{};
      for (final row in rows.rows) {
        final r = row.assoc();
        out.putIfAbsent('${r['announcement_id']}', () => []).add(r);
      }
      return out;
    }

    final trainingsBy = group(trainings);
    final tournamentsBy = group(tournaments);
    final membersBy = group(members);
    final directBy = group(direct);
    final accountsBy = group(toAccounts);

    // A parent only receives what is addressed to them: club-wide messages,
    // their children's categories, or a training or tournament one of their
    // children is in. Member lists are cut down to their own children, so
    // other families' player ids never leave the server.
    Set<int>? ownIds;
    Set<String>? ownCodes;
    Set<String>? readIds;
    if (!user.isAdmin) {
      // Removed categories still count here: a category is only hidden when
      // it's removed, and messages already sent to it should stay visible.
      final own = await db.execute(
        'SELECT p.id, c.code FROM players p '
        'LEFT JOIN categories c ON c.birth_year = YEAR(p.birthday) '
        'WHERE p.parent_id = :parentId AND p.is_active = 1',
        {'parentId': user.id},
      );
      ownIds = {for (final r in own.rows) int.parse(r.assoc()['id']!)};
      ownCodes = {
        for (final r in own.rows)
          if (r.assoc()['code'] != null) r.assoc()['code']!,
      };
      // Which ones this parent has opened. announcement_reads existed but
      // nothing wrote to it, so no message ever showed as new.
      final reads = await db.execute(
        'SELECT announcement_id FROM announcement_reads WHERE user_id = :userId',
        {'userId': user.id},
      );
      readIds = {for (final r in reads.rows) r.assoc()['announcement_id']!};
    }

    final items = <Map<String, dynamic>>[];
    for (final row in base.rows) {
      final r = row.assoc();
      final id = '${r['id']}';
      var memberIds = [
        for (final m in membersBy[id] ?? []) int.parse('${m['player_id']}'),
      ];
      if (ownIds != null && ownCodes != null) {
        final codes = (r['audiences'] ?? '').split(',');
        final reaches =
            '${r['is_everyone']}' == '1' ||
            codes.any(ownCodes.contains) ||
            memberIds.any(ownIds.contains) ||
            (accountsBy[id] ?? []).any(
              (a) => '${a['user_id']}' == '${user.id}',
            );
        if (!reaches) continue;
        memberIds = memberIds.where(ownIds.contains).toList();
      }
      items.add({
        ...r,
        'trainings': [
          for (final t in trainingsBy[id] ?? [])
            {'id': t['id'], 'name': t['name']},
        ],
        'tournaments': [
          for (final t in tournamentsBy[id] ?? [])
            {'id': t['id'], 'name': t['name']},
        ],
        'member_player_ids': memberIds,
        'players': [
          for (final d in directBy[id] ?? [])
            if (ownIds == null ||
                ownIds.contains(int.parse('${d['player_id']}')))
              {'id': d['player_id'], 'name': d['name']},
        ],
        // Who a direct message went to. A parent only ever sees their own
        // account here, never another family's.
        'recipients': [
          for (final a in accountsBy[id] ?? [])
            if (user.isAdmin || '${a['user_id']}' == '${user.id}')
              {'id': a['user_id'], 'name': a['name']},
        ],
        if (readIds != null) 'is_read': readIds.contains(id),
      });
    }
    return _json(items);
  });

  /// Rewrites every audience link for [id]. Returns how many were written;
  /// throws [_NoAudience] (rolling the transaction back) when the request
  /// wasn't "everyone" and nothing it named still exists.
  Future<void> writeAudiences(
    MySQLConnection conn,
    Object id, {
    required bool isEveryone,
    required List<String> codes,
    required List<int> trainingIds,
    required List<int> tournamentIds,
    bool allowEmpty = false,
  }) async {
    for (final table in [
      'announcement_categories',
      'announcement_trainings',
      'announcement_tournaments',
    ]) {
      await conn.execute('DELETE FROM $table WHERE announcement_id = :id', {
        'id': id,
      });
    }
    if (isEveryone) return;

    var written = 0;
    for (final code in codes.toSet()) {
      final r = await conn.execute(
        'INSERT IGNORE INTO announcement_categories '
        '(announcement_id, category_id) '
        'SELECT :id, id FROM categories WHERE code = :code',
        {'id': id, 'code': code},
      );
      written += r.affectedRows.toInt();
    }
    // Existence only, not is_active: editing an old message that went to a
    // since-deleted training must keep that audience, not quietly drop it.
    for (final trainingId in trainingIds) {
      final r = await conn.execute(
        'INSERT IGNORE INTO announcement_trainings '
        '(announcement_id, training_program_id) '
        'SELECT :id, id FROM training_programs WHERE id = :trainingId',
        {'id': id, 'trainingId': trainingId},
      );
      written += r.affectedRows.toInt();
    }
    for (final tournamentId in tournamentIds) {
      final r = await conn.execute(
        'INSERT IGNORE INTO announcement_tournaments '
        '(announcement_id, tournament_id) '
        'SELECT :id, id FROM tournaments WHERE id = :tournamentId',
        {'id': id, 'tournamentId': tournamentId},
      );
      written += r.affectedRows.toInt();
    }
    if (written == 0 && !allowEmpty) throw _NoAudience();
  }

  ({
    String title,
    String text,
    bool isEveryone,
    List<String> codes,
    List<int> trainingIds,
    List<int> tournamentIds,
  })
  parse(Map body) => (
    title: (body['title'] as String? ?? '').trim(),
    text: (body['body'] as String? ?? '').trim(),
    isEveryone: body['isEveryone'] == true,
    codes: (body['audiences'] as List? ?? []).cast<String>(),
    trainingIds: _ids(body['trainingIds']),
    tournamentIds: _ids(body['tournamentIds']),
  );

  Response? validate(
    ({
      String title,
      String text,
      bool isEveryone,
      List<String> codes,
      List<int> trainingIds,
      List<int> tournamentIds,
    })
    p, {
    bool keepsPlayers = false,
  }) {
    if (p.title.isEmpty || p.text.isEmpty) {
      return _json({'error': 'Title and message are required'}, status: 400);
    }
    final tooLong =
        lengthError('Title', p.title, 160) ??
        lengthError('Message', p.text, 5000);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);
    // An automatic notice already goes to named players, so it can be
    // edited without picking another audience.
    if (!keepsPlayers &&
        !p.isEveryone &&
        p.codes.isEmpty &&
        p.trainingIds.isEmpty &&
        p.tournamentIds.isEmpty) {
      return _json({'error': 'Pick at least one audience'}, status: 400);
    }
    return null;
  }

  final noAudience = _json({
    'error': 'None of those audiences exist any more',
  }, status: 400);

  router.post('/announcements', (Request request) async {
    final p = parse(jsonDecode(await request.readAsString()) as Map);
    final invalid = validate(p);
    if (invalid != null) return invalid;

    try {
      final id = await db.transaction((conn) async {
        final inserted = await conn.execute(
          'INSERT INTO announcements (title, body, is_everyone, sent_by) '
          'VALUES (:title, :body, :isEveryone, :sentBy)',
          {
            'title': p.title,
            'body': p.text,
            'isEveryone': p.isEveryone ? 1 : 0,
            'sentBy': userOf(request).id,
          },
        );
        final newId = inserted.lastInsertID.toInt();
        await writeAudiences(
          conn,
          newId,
          isEveryone: p.isEveryone,
          codes: p.codes,
          trainingIds: p.trainingIds,
          tournamentIds: p.tournamentIds,
        );
        return newId;
      });
      return _json({'id': id}, status: 201);
    } on _NoAudience {
      return noAudience;
    } on MySQLServerException {
      rethrow;
    }
  });

  router.put('/announcements/<id>', (Request request, String id) async {
    final p = parse(jsonDecode(await request.readAsString()) as Map);
    // Already addressed to named players (an automatic notice) or to an
    // account (a direct message): editing it needs no other audience. The
    // id is an integer, written in: named parameters don't survive the
    // subqueries.
    final messageId = int.tryParse(id) ?? 0;
    final named = await db.execute(
      'SELECT (SELECT COUNT(*) FROM announcement_players '
      '        WHERE announcement_id = $messageId) + '
      '       (SELECT COUNT(*) FROM announcement_users '
      '        WHERE announcement_id = $messageId) AS n',
    );
    final keepsPlayers = int.parse('${named.rows.first.assoc()['n']}') > 0;
    final invalid = validate(p, keepsPlayers: keepsPlayers);
    if (invalid != null) return invalid;

    final exists = await db.execute(
      'SELECT id FROM announcements WHERE id = :id AND deleted_at IS NULL',
      {'id': id},
    );
    if (exists.rows.isEmpty) {
      return _json({'error': 'No announcement with that id'}, status: 404);
    }

    try {
      await db.transaction((conn) async {
        await conn.execute(
          // auto_kind cleared: once an admin has edited an automatic notice
          // it's their message, so a later cancellation starts a new notice
          // instead of rewriting their words.
          'UPDATE announcements SET title = :title, body = :body, '
          'is_everyone = :isEveryone, auto_kind = NULL WHERE id = :id',
          {
            'id': id,
            'title': p.title,
            'body': p.text,
            'isEveryone': p.isEveryone ? 1 : 0,
          },
        );
        await writeAudiences(
          conn,
          id,
          isEveryone: p.isEveryone,
          codes: p.codes,
          trainingIds: p.trainingIds,
          tournamentIds: p.tournamentIds,
          allowEmpty: keepsPlayers,
        );
        // An edited message shows as new again, so parents who read the
        // old version see that it changed.
        await conn.execute(
          'DELETE FROM announcement_reads WHERE announcement_id = :id',
          {'id': id},
        );
      });
      return _json({'id': int.parse(id), 'updated': true});
    } on _NoAudience {
      return noAudience;
    } on MySQLServerException {
      rethrow;
    }
  });

  /// A parent opening a message. Only their own read state is written, so
  /// nothing beyond the message existing needs checking.
  router.post('/announcements/<id>/read', (Request request, String id) async {
    await db.execute(
      'INSERT IGNORE INTO announcement_reads (announcement_id, user_id) '
      'SELECT id, :userId FROM announcements '
      'WHERE id = :id AND deleted_at IS NULL',
      {'id': int.tryParse(id) ?? 0, 'userId': userOf(request).id},
    );
    return _json({'id': int.tryParse(id), 'read': true});
  });

  // Soft delete — the schema keeps deleted_at precisely so a removed
  // announcement stays auditable rather than vanishing.
  router.delete('/announcements/<id>', (Request request, String id) async {
    final result = await db.execute(
      'UPDATE announcements SET deleted_at = NOW() '
      'WHERE id = :id AND deleted_at IS NULL',
      {'id': id},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({'error': 'No announcement with that id'}, status: 404);
    }
    return _json({'id': int.parse(id), 'deleted': true});
  });

  return router;
}
