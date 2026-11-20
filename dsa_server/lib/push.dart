import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// The phone tells the server where to send its notifications:
/// POST /devices {"token": "<FCM token>", "platform": "android|ios|web"}.
/// Sent after every sign-in and whenever Firebase gives the phone a new
/// token. The token is filed under THIS login, so logging out (or a
/// password change, deactivation, deletion) removes it with the login.
Router buildDevicesRouter(Db db) {
  final router = Router();

  router.post('/devices', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString());
    final token = body is Map ? '${body['token'] ?? ''}'.trim() : '';
    final platform = body is Map ? '${body['platform'] ?? ''}' : '';
    if (token.isEmpty || token.length > 512) {
      return _json({'error': 'A device token is required'}, status: 400);
    }
    if (!const {'android', 'ios', 'web'}.contains(platform)) {
      return _json({'error': 'Unknown platform'}, status: 400);
    }
    final header = request.headers['authorization'] ?? '';
    final session = hashToken(header.substring(7).trim());
    // A phone that someone else used before belongs to whoever signed in
    // on it last.
    await db.execute(
      'INSERT INTO device_tokens (token, session_hash, user_id, platform) '
      'VALUES (:token, :session, :userId, :platform) '
      'ON DUPLICATE KEY UPDATE session_hash = VALUES(session_hash), '
      'user_id = VALUES(user_id), platform = VALUES(platform), '
      'updated_at = NOW()',
      {
        'token': token,
        'session': session,
        'userId': user.id,
        'platform': platform,
      },
    );
    return _json({'registered': true});
  });

  return router;
}

/// Sends push notifications through Firebase Cloud Messaging for every new
/// message a family receives (club announcements, messages to one or
/// several families, the automatic schedule-change and cancellation
/// notices), every new bill, and every tournament invitation.
///
/// It watches the announcements, payments and tournament_players tables
/// (their pushed_at) rather than being called from each place they're
/// written: they're written inside transactions (that might still roll
/// back), by many routes. Every few seconds it takes
/// the messages not yet pushed (announcements.pushed_at IS NULL), works out
/// which parents can see each one — the same rules as GET /announcements —
/// and sends to their phones. Each message is claimed first, so it's never
/// sent twice.
///
/// It waits until a message is 15 seconds old, so an UNDO straight after
/// cancelling a session (8 seconds) takes the notice back before any phone
/// buzzes.
///
/// Off until the Firebase server key is in place: .env must have
/// FIREBASE_SERVICE_ACCOUNT=<path to the service-account JSON file>.
class Push {
  final Db _db;
  final AutoRefreshingAuthClient _client;
  final String _projectId;
  bool _busy = false;

  Push._(this._db, this._client, this._projectId);

  static const _scope = 'https://www.googleapis.com/auth/firebase.messaging';

  /// Starts sending, or returns null (and says why) when not configured.
  static Future<Push?> start(Db db, DotEnv env) async {
    final path = (env['FIREBASE_SERVICE_ACCOUNT'] ?? '').trim();
    if (path.isEmpty) {
      print('Push notifications: off (FIREBASE_SERVICE_ACCOUNT not set).');
      return null;
    }
    final file = File(path);
    if (!file.existsSync()) {
      print('Push notifications: off (no file at $path).');
      return null;
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      final projectId = '${json['project_id'] ?? ''}';
      final client = await clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(json),
        [_scope],
      );
      final push = Push._(db, client, projectId);
      Timer.periodic(const Duration(seconds: 10), (_) => push._tick());
      print('Push notifications: on (Firebase project $projectId).');
      return push;
    } catch (e) {
      print('Push notifications: off (could not use $path: $e).');
      return null;
    }
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      await sendPending();
    } catch (e) {
      print('Push: failed this round: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> sendPending() async {
    await _skipStale();
    await _sendMessages();
    await _sendBills();
    await _sendInvitations();
  }

  /// Anything still unsent after 2 hours is marked done without sending —
  /// when notifications are first switched on (a new server, a restored
  /// database) families mustn't get a burst of old news.
  Future<void> _skipStale() async {
    await _db.execute(
      'UPDATE announcements SET pushed_at = NOW() WHERE pushed_at IS NULL '
      'AND created_at < NOW() - INTERVAL 2 HOUR',
    );
    await _db.execute(
      'UPDATE payments SET pushed_at = NOW() WHERE pushed_at IS NULL '
      'AND created_at < NOW() - INTERVAL 2 HOUR',
    );
    await _db.execute(
      'UPDATE tournament_players SET pushed_at = NOW() WHERE pushed_at IS NULL '
      'AND added_at < NOW() - INTERVAL 2 HOUR',
    );
  }

  /// Messages: club announcements, messages to families, schedule changes
  /// and cancellations.
  Future<void> _sendMessages() async {
    final due = await _db.execute(
      'SELECT id, title, body, deleted_at IS NOT NULL AS gone '
      'FROM announcements WHERE pushed_at IS NULL '
      'AND created_at <= NOW() - INTERVAL 15 SECOND ORDER BY id LIMIT 20',
    );
    for (final row in due.rows) {
      final r = row.assoc();
      final id = int.parse(r['id']!);
      // Claimed before sending: a second server, or a crash halfway, never
      // sends the same message twice.
      final claimed = await _db.execute(
        'UPDATE announcements SET pushed_at = NOW() '
        'WHERE id = :id AND pushed_at IS NULL',
        {'id': id},
      );
      if (claimed.affectedRows.toInt() == 0) continue;
      // Taken back (an undo, or the admin deleted it) before it went out.
      if (r['gone'] == '1') continue;
      final tokens = await _db.execute(_recipientTokens(id));
      final list = [for (final t in tokens.rows) t.assoc()['token']!];
      if (list.isEmpty) continue;
      final removed = await _sendAll(
        list,
        r['title']!,
        r['body']!,
        'message',
        '$id',
      );
      _log('message $id', list.length, removed);
    }
  }

  /// New bills: a tournament fee, an approved order, the month's training
  /// fee, a request from the admin. Only one still open when it goes out
  /// (one paid at once from credit, or withdrawn, isn't news).
  Future<void> _sendBills() async {
    final due = await _db.execute(
      'SELECT pay.id, pay.title, pay.amount, pay.amount_paid, pay.status, '
      'pay.player_id, p.full_name '
      'FROM payments pay JOIN players p ON p.id = pay.player_id '
      'WHERE pay.pushed_at IS NULL '
      'AND pay.created_at <= NOW() - INTERVAL 15 SECOND '
      'ORDER BY pay.id LIMIT 50',
    );
    for (final row in due.rows) {
      final r = row.assoc();
      final id = int.parse(r['id']!);
      final claimed = await _db.execute(
        'UPDATE payments SET pushed_at = NOW() '
        'WHERE id = :id AND pushed_at IS NULL',
        {'id': id},
      );
      if (claimed.affectedRows.toInt() == 0) continue;
      final owed =
          (num.tryParse(r['amount'] ?? '') ?? 0) -
          (num.tryParse(r['amount_paid'] ?? '') ?? 0);
      if (r['status'] != 'pending' || owed <= 0) continue;
      final list = await _parentTokens(int.parse(r['player_id']!));
      if (list.isEmpty) continue;
      final removed = await _sendAll(
        list,
        'New payment request',
        '${r['title']} for ${r['full_name']}: AED ${owed.toStringAsFixed(2)}. '
            'Open Payments to see it.',
        'bill',
        '$id',
      );
      _log('bill $id', list.length, removed);
    }
  }

  /// Tournament invitations still waiting for the family's answer.
  Future<void> _sendInvitations() async {
    final due = await _db.execute(
      'SELECT tp.tournament_id, tp.player_id, tp.consent, t.name, '
      't.deleted_at IS NOT NULL AS gone, p.full_name '
      'FROM tournament_players tp '
      'JOIN tournaments t ON t.id = tp.tournament_id '
      'JOIN players p ON p.id = tp.player_id '
      'WHERE tp.pushed_at IS NULL '
      'AND tp.added_at <= NOW() - INTERVAL 15 SECOND LIMIT 50',
    );
    for (final row in due.rows) {
      final r = row.assoc();
      final tournamentId = int.parse(r['tournament_id']!);
      final playerId = int.parse(r['player_id']!);
      final claimed = await _db.execute(
        'UPDATE tournament_players SET pushed_at = NOW() '
        'WHERE tournament_id = :t AND player_id = :p AND pushed_at IS NULL',
        {'t': tournamentId, 'p': playerId},
      );
      if (claimed.affectedRows.toInt() == 0) continue;
      // Already answered, or the tournament was deleted, before it went out.
      if (r['consent'] != 'pending' || r['gone'] == '1') continue;
      final list = await _parentTokens(playerId);
      if (list.isEmpty) continue;
      final removed = await _sendAll(
        list,
        'Tournament invitation',
        '${r['full_name']} is invited to ${r['name']}. Open Tournaments to '
            'accept or decline.',
        'invitation',
        '$tournamentId',
      );
      _log('invitation $tournamentId/$playerId', list.length, removed);
    }
  }

  /// The phones of a child's parent (active child, approved account).
  Future<List<String>> _parentTokens(int playerId) async {
    final tokens = await _db.execute(
      'SELECT DISTINCT d.token FROM device_tokens d '
      'JOIN users u ON u.id = d.user_id AND u.role = \'parent\' '
      "AND u.status = 'approved' AND u.deleted_at IS NULL "
      'JOIN players p ON p.parent_id = u.id AND p.is_active = 1 '
      'WHERE p.id = :id',
      {'id': playerId},
    );
    return [for (final t in tokens.rows) t.assoc()['token']!];
  }

  void _log(String what, int phones, int removed) => print(
    'Push: $what to $phones phone(s)'
    '${removed > 0 ? ' ($removed old token(s) removed)' : ''}.',
  );

  /// The phones of every parent who can see message [id]: the same rules
  /// as GET /announcements. Admins aren't sent anything. [id] is an integer
  /// from the database, written in.
  static String _recipientTokens(int id) =>
      '''
    SELECT DISTINCT d.token
    FROM device_tokens d
    JOIN users u ON u.id = d.user_id AND u.role = 'parent'
                AND u.status = 'approved' AND u.deleted_at IS NULL
    JOIN announcements a ON a.id = $id
    WHERE a.is_everyone = 1
       OR EXISTS (SELECT 1 FROM announcement_users au
                  WHERE au.announcement_id = a.id AND au.user_id = u.id)
       OR EXISTS (SELECT 1 FROM announcement_players ap
                  JOIN players p ON p.id = ap.player_id AND p.is_active = 1
                  WHERE ap.announcement_id = a.id AND p.parent_id = u.id)
       OR EXISTS (SELECT 1 FROM announcement_categories ac
                  JOIN categories c ON c.id = ac.category_id
                  JOIN players p ON YEAR(p.birthday) = c.birth_year
                                AND p.is_active = 1
                  WHERE ac.announcement_id = a.id AND p.parent_id = u.id)
       OR EXISTS (SELECT 1 FROM announcement_trainings atr
                  JOIN sessions s
                    ON s.training_program_id = atr.training_program_id
                   AND s.session_date >=
                       DATE_SUB(DATE(a.created_at), INTERVAL 60 DAY)
                  JOIN session_players sp ON sp.session_id = s.id
                  JOIN players p ON p.id = sp.player_id AND p.is_active = 1
                  WHERE atr.announcement_id = a.id AND p.parent_id = u.id)
       OR EXISTS (SELECT 1 FROM announcement_tournaments atn
                  JOIN tournament_players tp
                    ON tp.tournament_id = atn.tournament_id
                   AND tp.consent <> 'declined'
                  JOIN players p ON p.id = tp.player_id AND p.is_active = 1
                  WHERE atn.announcement_id = a.id AND p.parent_id = u.id)
  ''';

  /// Sends to each phone (a few at a time). Returns how many tokens Firebase
  /// said are dead (app uninstalled, data cleared) — those are removed.
  Future<int> _sendAll(
    List<String> tokens,
    String title,
    String body,
    String kind,
    String id,
  ) async {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = text.length > 180 ? '${text.substring(0, 177)}...' : text;
    var removed = 0;
    for (var i = 0; i < tokens.length; i += 20) {
      final batch = tokens.skip(i).take(20);
      final results = await Future.wait(
        batch.map((token) => _sendOne(token, title, short, kind, id)),
      );
      removed += results.where((dead) => dead).length;
    }
    return removed;
  }

  /// True when the token is dead and was removed.
  Future<bool> _sendOne(
    String token,
    String title,
    String body,
    String kind,
    String id,
  ) async {
    try {
      final response = await _client.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_projectId/messages:send',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': {
            'token': token,
            'notification': {'title': title, 'body': body},
            'data': {'kind': kind, 'id': id},
            'android': {'priority': 'high'},
            'apns': {
              'payload': {
                'aps': {'sound': 'default'},
              },
            },
          },
        }),
      );
      if (response.statusCode == 200) return false;
      // The phone no longer has the app (or its data was cleared).
      if (response.statusCode == 404 ||
          response.body.contains('UNREGISTERED') ||
          response.body.contains('registration-token-not-registered')) {
        await _db.execute('DELETE FROM device_tokens WHERE token = :token', {
          'token': token,
        });
        return true;
      }
      print('Push: Firebase said ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
      print('Push: could not reach Firebase: $e');
      return false;
    }
  }
}
