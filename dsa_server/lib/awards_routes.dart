import 'dart:convert';

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

/// Awards a player has received (MVP, Most Improved ...), shown on the
/// Player Profile's AWARDS tab: a title, an optional league, an optional
/// category (one of the academy's) and a date.
///
/// The admin adds, edits and removes any award. A parent adds awards for
/// their own children, and edits or removes only the ones they added
/// themselves: an award the academy gave stays as the academy gave it.
/// Nobody sees another family's children's awards.
Router buildAwardsRouter(Db db) {
  final router = Router();

  /// A player's awards, newest first. "can_edit" says whether the one
  /// asking may change it (the app shows edit or read-only from it).
  router.get('/players/<id>/awards', (Request request, String id) async {
    final user = userOf(request);
    if (!await canAccessPlayer(db, user, id)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    final result = await db.execute('''
      SELECT a.id, a.title, a.league, c.code AS category,
             DATE_FORMAT(a.award_date, '%Y-%m-%d') AS award_date,
             ${user.isAdmin ? '1' : 'a.created_by <=> ${user.id}'} AS can_edit
      FROM player_awards a
      LEFT JOIN categories c ON c.id = a.category_id
      WHERE a.player_id = ${int.parse(id)}
      ORDER BY a.award_date DESC, a.id DESC
    ''');
    return _json([for (final row in result.rows) row.assoc()]);
  });

  /// {"title", "league" (optional), "category" (optional code, e.g.
  /// "B2013"), "date": "YYYY-MM-DD"}.
  router.post('/players/<id>/awards', (Request request, String id) async {
    final user = userOf(request);
    if (!await canAccessPlayer(db, user, id)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }
    final award = await _readAward(db, request);
    if (award.error != null) return _json({'error': award.error}, status: 400);
    final result = await db.execute(
      'INSERT INTO player_awards '
      '(player_id, title, league, category_id, award_date, created_by) '
      'VALUES (:playerId, :title, :league, :categoryId, :date, :userId)',
      {
        'playerId': int.parse(id),
        'title': award.title,
        'league': award.league,
        'categoryId': award.categoryId,
        'date': award.date,
        'userId': user.id,
      },
    );
    return _json({'id': result.lastInsertID.toInt()}, status: 201);
  });

  router.put('/awards/<id>', (Request request, String id) async {
    final awardId = int.tryParse(id) ?? 0;
    final refused = await _mayChange(db, userOf(request), awardId);
    if (refused != null) return refused;
    final award = await _readAward(db, request);
    if (award.error != null) return _json({'error': award.error}, status: 400);
    await db.execute(
      'UPDATE player_awards SET title = :title, league = :league, '
      'category_id = :categoryId, award_date = :date WHERE id = :id',
      {
        'id': awardId,
        'title': award.title,
        'league': award.league,
        'categoryId': award.categoryId,
        'date': award.date,
      },
    );
    return _json({'id': awardId});
  });

  router.delete('/awards/<id>', (Request request, String id) async {
    final awardId = int.tryParse(id) ?? 0;
    final refused = await _mayChange(db, userOf(request), awardId);
    if (refused != null) return refused;
    await db.execute('DELETE FROM player_awards WHERE id = :id', {
      'id': awardId,
    });
    return _json({'deleted': true});
  });

  return router;
}

/// Null when [user] may edit or delete the award; otherwise the refusal.
/// The admin: any award that exists. A parent: only an award on one of their
/// own children that they added themselves. One on someone else's child is
/// "not found", so a parent can't learn which awards exist.
Future<Response?> _mayChange(Db db, AuthUser user, int awardId) async {
  final found = await db.execute(
    'SELECT a.created_by, p.parent_id, p.is_active FROM player_awards a '
    'JOIN players p ON p.id = a.player_id WHERE a.id = :id',
    {'id': awardId},
  );
  final gone = _json({'error': 'That award no longer exists'}, status: 404);
  if (found.rows.isEmpty) return gone;
  if (user.isAdmin) return null;
  final row = found.rows.first.assoc();
  if (row['parent_id'] != '${user.id}' || row['is_active'] != '1') {
    return gone;
  }
  if (row['created_by'] != '${user.id}') {
    return _json({
      'error':
          'This award was given by the academy, so only the academy can '
          'change it.',
    }, status: 403);
  }
  return null;
}

typedef _Award = ({
  String? error,
  String title,
  String? league,
  int? categoryId,
  String date,
});

/// An award from a request body, checked: a title (up to 120 characters),
/// an optional league (up to 120), an optional category that is one of the
/// academy's current ones, and a real date that isn't in the future — an
/// award is given for something that already happened.
Future<_Award> _readAward(Db db, Request request) async {
  Map body;
  try {
    final decoded = jsonDecode(await request.readAsString());
    body = decoded is Map ? decoded : const {};
  } on FormatException {
    body = const {};
  }
  final title = normalizeSpaces('${body['title'] ?? ''}');
  final rawLeague = normalizeSpaces('${body['league'] ?? ''}');
  final league = rawLeague.isEmpty ? null : rawLeague;
  final category = '${body['category'] ?? ''}'.trim();
  final date = '${body['date'] ?? ''}'.trim();
  _Award result(String? error, [int? categoryId]) => (
    error: error,
    title: title,
    league: league,
    categoryId: categoryId,
    date: date,
  );

  if (title.isEmpty) return result('Enter the award title');
  final tooLong =
      lengthError('Title', title, 120) ?? lengthError('League', league, 120);
  if (tooLong != null) return result(tooLong);

  int? categoryId;
  if (category.isNotEmpty) {
    final found = await db.execute(
      'SELECT id FROM categories WHERE code = :code AND is_active = 1',
      {'code': category},
    );
    if (found.rows.isEmpty) {
      return result("Choose one of the academy's categories");
    }
    categoryId = int.parse(found.rows.first.assoc()['id']!);
  }

  if (realDate(date) == null) return result('Choose the date of the award');
  // Against the database's clock (UAE time), not this machine's.
  final future = await db.execute('SELECT :date > CURRENT_DATE AS future', {
    'date': date,
  });
  if ('${future.rows.first.assoc()['future']}' == '1') {
    return result("The award date can't be in the future");
  }
  return result(null, categoryId);
}
