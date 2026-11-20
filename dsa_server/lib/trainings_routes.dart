import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';
import 'notices.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// training_programs.name is VARCHAR(120).
const _maxNameLength = 120;

/// Rolls back a new training when none of its categories exist.
class _NoCategories implements Exception {
  const _NoCategories();
}

/// Training programs — the recurring thing an admin sets up, spanning one
/// or more categories (e.g. B2012 and B2013 train together). The category
/// list comes back comma-joined; the app splits it for its label.
Router buildTrainingsRouter(Db db) {
  final router = Router();

  router.get('/trainings', (Request request) async {
    final result = await db.execute('''
      SELECT
        t.id,
        t.name,
        GROUP_CONCAT(c.code ORDER BY c.birth_year) AS categories
      FROM training_programs t
      LEFT JOIN training_program_categories tpc
             ON tpc.training_program_id = t.id
      LEFT JOIN categories c ON c.id = tpc.category_id
      WHERE t.is_active = 1
      GROUP BY t.id, t.name
      ORDER BY t.id
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.post('/trainings', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final codes = (body['categories'] as List? ?? []).cast<String>();
    // Optional: a blank name means the app shows "<categories> Training".
    // Stored as NULL rather than '' so "no name" has exactly one spelling.
    final rawName = (body['name'] as String? ?? '').trim();
    final name = rawName.isEmpty ? null : rawName;
    if (codes.isEmpty) {
      return _json({'error': 'At least one category is required'}, status: 400);
    }
    if (name != null && name.length > _maxNameLength) {
      return _json({
        'error': 'Training name must be $_maxNameLength characters or fewer',
      }, status: 400);
    }
    try {
      final id = await db.transaction((conn) async {
        final inserted = await conn.execute(
          'INSERT INTO training_programs (name) VALUES (:name)',
          {'name': name},
        );
        final newId = inserted.lastInsertID.toInt();
        var linked = 0;
        for (final code in codes) {
          final result = await conn.execute(
            'INSERT IGNORE INTO training_program_categories '
            '(training_program_id, category_id) '
            'SELECT :id, id FROM categories WHERE code = :code AND is_active = 1',
            {'id': newId, 'code': code},
          );
          linked += result.affectedRows.toInt();
        }
        // Unknown codes used to be skipped silently, which could leave a
        // training with no categories at all.
        if (linked == 0) throw const _NoCategories();
        return newId;
      });
      return _json({'id': id, 'categories': codes}, status: 201);
    } on _NoCategories {
      return _json({
        'error': 'None of those categories exist any more',
      }, status: 400);
    } on MySQLServerException {
      rethrow;
    }
  });

  /// Removes a training program without rewriting anything that already
  /// happened.
  ///
  /// * The program is soft-deleted (is_active = 0). A hard delete would
  ///   cascade through sessions.training_program_id and take every past
  ///   session, roster and attendance mark with it — and with those gone,
  ///   fees the players already ran up this month would silently vanish.
  /// * Sessions AFTER today are cancelled. Nobody has trained in them yet,
  ///   so they shouldn't commit anyone to a fee, and they vanish from both
  ///   schedules. A player whose only sessions this month were future ones
  ///   stops being billed at all.
  /// * Sessions up to and including TODAY are kept. They may already have
  ///   happened (today's may be under way with attendance not marked yet),
  ///   so the fees they earned still stand, and closed months' bills keep
  ///   the sessions they were built from. The admin can still cancel one
  ///   individually if it didn't take place.
  ///
  /// The counts come back so the app can say exactly what happened.
  /// A training's default players (Trainings > a training > settings): they
  /// are put on every NEW session of this training automatically, so the
  /// admin doesn't add the same group each time. Each training has its own.
  /// Changing them never touches sessions already scheduled.
  router.get('/trainings/<id>/defaults', (Request request, String id) async {
    final trainingId = int.tryParse(id);
    if (trainingId == null || !await _isActiveTraining(db, trainingId)) {
      return _json({'error': 'No training with that id'}, status: 404);
    }
    final rows = await db.execute(
      'SELECT d.player_id FROM training_default_players d '
      'JOIN players p ON p.id = d.player_id AND p.is_active = 1 '
      'WHERE d.training_program_id = :id ORDER BY p.full_name, p.id',
      {'id': trainingId},
    );
    return _json({
      'trainingId': trainingId,
      'playerIds': [
        for (final row in rows.rows) int.parse(row.assoc()['player_id']!),
      ],
    });
  });

  /// Replaces a training's default players: {"playerIds": [..]}. An empty
  /// list clears them. Removed players are skipped.
  router.put('/trainings/<id>/defaults', (Request request, String id) async {
    final trainingId = int.tryParse(id);
    if (trainingId == null || !await _isActiveTraining(db, trainingId)) {
      return _json({'error': 'No training with that id'}, status: 404);
    }
    final body = jsonDecode(await request.readAsString());
    // Required, and a list: a body without it used to read as "no players"
    // and wipe the training's defaults.
    final raw = body is Map ? body['playerIds'] : null;
    if (raw is! List) {
      return _json({'error': 'playerIds must be a list'}, status: 400);
    }
    final playerIds = [for (final item in raw) ?int.tryParse('$item')].toSet();
    final saved = await db.transaction((conn) async {
      // Validated integers, written in.
      await conn.execute(
        'DELETE FROM training_default_players '
        'WHERE training_program_id = $trainingId',
      );
      var count = 0;
      for (final playerId in playerIds) {
        final added = await conn.execute(
          'INSERT IGNORE INTO training_default_players '
          '(training_program_id, player_id) '
          'SELECT $trainingId, id FROM players '
          'WHERE id = $playerId AND is_active = 1 AND is_approved = 1',
        );
        count += added.affectedRows.toInt();
      }
      return count;
    });
    return _json({'trainingId': trainingId, 'saved': saved});
  });

  router.delete('/trainings/<id>', (Request request, String id) async {
    final exists = await db.execute(
      'SELECT is_active FROM training_programs WHERE id = :id',
      {'id': id},
    );
    if (exists.rows.isEmpty) {
      return _json({'error': 'No training with that id'}, status: 404);
    }

    final counts = await db.transaction((conn) async {
      await conn.execute(
        'UPDATE training_programs SET is_active = 0 WHERE id = :id',
        {'id': id},
      );
      // Nothing can be scheduled for it any more.
      await conn.execute(
        'DELETE FROM training_default_players WHERE training_program_id = :id',
        {'id': id},
      );
      final upcoming = await conn.execute(
        'SELECT id FROM sessions '
        'WHERE training_program_id = :id AND is_cancelled = 0 '
        'AND session_date > CURRENT_DATE FOR UPDATE',
        {'id': id},
      );
      final upcomingIds = [
        for (final row in upcoming.rows) int.parse(row.assoc()['id']!),
      ];
      final cancelled = await conn.execute(
        'UPDATE sessions SET is_cancelled = 1 '
        'WHERE training_program_id = :id AND is_cancelled = 0 '
        'AND session_date > CURRENT_DATE',
        {'id': id},
      );
      // One message per family listing every date they lose, not one per
      // session.
      await notifySessionsCancelled(
        conn,
        sessionIds: upcomingIds,
        sentBy: userOf(request).id,
      );
      final kept = await conn.execute(
        'SELECT COUNT(*) AS kept FROM sessions '
        'WHERE training_program_id = :id AND is_cancelled = 0',
        {'id': id},
      );
      return (
        cancelled: cancelled.affectedRows.toInt(),
        kept: int.parse('${kept.rows.first.assoc()['kept']}'),
      );
    });

    return _json({
      'id': int.parse(id),
      'removed': true,
      'cancelledSessions': counts.cancelled,
      'keptSessions': counts.kept,
    });
  });

  return router;
}

Future<bool> _isActiveTraining(Db db, int id) async {
  final found = await db.execute(
    'SELECT id FROM training_programs WHERE id = :id AND is_active = 1',
    {'id': id},
  );
  return found.rows.isNotEmpty;
}
