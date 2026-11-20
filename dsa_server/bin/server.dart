import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../lib/db.dart';
import '../lib/awards_routes.dart';
import '../lib/auth.dart';
import '../lib/billing.dart';
import '../lib/auth_routes.dart';
import '../lib/admin_routes.dart';
import '../lib/players_routes.dart';
import '../lib/trainings_routes.dart';
import '../lib/sessions_routes.dart';
import '../lib/announcements_routes.dart';
import '../lib/tournaments_routes.dart';
import '../lib/payments_routes.dart';
import '../lib/orders_routes.dart';
import '../lib/mailer.dart';
import '../lib/notices.dart' show sendBirthdayGreetings;
import '../lib/photos_routes.dart';
import '../lib/push.dart';
import '../lib/text_rules.dart';
import '../lib/ledger.dart' show LedgerError;

const _mysqlDuplicateEntry = 1062;

Future<void> main() async {
  final env = DotEnv(includePlatformEnvironment: true)..load();
  final db = await Db.connect(env);
  print('Connected to ${env['DB_NAME']} at ${env['DB_HOST']}');

  final router = Router();
  router.mount('/', buildAuthRouter(db).call);
  router.mount('/', buildAdminRouter(db).call);
  router.mount('/', buildPlayersRouter(db).call);
  router.mount('/', buildTrainingsRouter(db).call);
  router.mount('/', buildSessionsRouter(db).call);
  router.mount('/', buildAnnouncementsRouter(db).call);
  router.mount('/', buildTournamentsRouter(db).call);
  router.mount('/', buildPaymentsRouter(db).call);
  router.mount('/', buildOrdersRouter(db).call);
  router.mount('/', buildDevicesRouter(db).call);
  router.mount('/', buildPhotosRouter(db).call);
  router.mount('/', buildAwardsRouter(db).call);

  // Proves the whole chain: Flutter -> this server -> MySQL -> back.
  // Everything else follows this same shape: query, map rows, jsonEncode.
  router.get('/categories', (Request request) async {
    final result = await db.execute(
      'SELECT id, code, birth_year, label FROM categories '
      'WHERE is_active = 1 ORDER BY birth_year',
    );
    // assoc() gives {column_name: value} directly, so adding a column to
    // the SELECT doesn't require also updating index positions here.
    final categories = result.rows.map((row) => row.assoc()).toList();
    return Response.ok(
      jsonEncode(categories),
      headers: {'Content-Type': 'application/json'},
    );
  });

  Response json(Object body, [int status = 200]) => Response(
    status,
    body: jsonEncode(body),
    headers: {'Content-Type': 'application/json'},
  );

  /// A category is always B + a four-digit birth year, and the year is taken
  /// from the code itself — a mismatched birthYear used to be stored as sent.
  /// Adding back a category that was removed brings the old one back.
  router.post('/categories', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final code = '${body['code'] ?? ''}'.trim().toUpperCase();
    final match = RegExp(r'^B(\d{4})$').firstMatch(code);
    if (match == null) {
      return json({
        'error': 'A category is B and a 4-digit birth year, like B2013',
      }, 400);
    }
    final birthYear = int.parse(match.group(1)!);
    // B0000 is the academy's special group for any age (coaches, staff,
    // mixed teams): no birthday is in year 0, so nobody falls into it by
    // their birthday, and the admin adds players to its trainings and
    // tournaments by hand ("Others" on Add Players).
    if (birthYear != 0 &&
        (birthYear < 1950 || birthYear > DateTime.now().year)) {
      return json({'error': 'Check the birth year in $code'}, 400);
    }
    final existing = await db.execute(
      'SELECT is_active FROM categories WHERE code = :code',
      {'code': code},
    );
    if (existing.rows.isNotEmpty) {
      if (existing.rows.first.assoc()['is_active'] == '1') {
        return json({'error': '$code already exists'}, 409);
      }
      await db.execute(
        'UPDATE categories SET is_active = 1, birth_year = :birthYear '
        'WHERE code = :code',
        {'code': code, 'birthYear': birthYear},
      );
      return json({'code': code, 'birthYear': birthYear}, 201);
    }
    try {
      await db.execute(
        'INSERT INTO categories (code, birth_year, label) '
        'VALUES (:code, :birthYear, :label)',
        {
          'code': code,
          'birthYear': birthYear,
          'label': birthYear == 0 ? 'Special (any age)' : 'Born $birthYear',
        },
      );
      return json({'code': code, 'birthYear': birthYear}, 201);
    } on MySQLServerException catch (e) {
      if (e.errorCode == _mysqlDuplicateEntry) {
        return json({'error': '$code already exists'}, 409);
      }
      rethrow;
    }
  });

  /// Hides a category rather than deleting it. A hard delete cascaded
  /// through announcement_categories, so messages sent to that birth year
  /// lost their audience and disappeared for the parents they were sent to.
  /// Refused while an active training or tournament still uses it.
  router.delete('/categories/<code>', (Request request, String code) async {
    final found = await db.execute(
      'SELECT id FROM categories WHERE code = :code AND is_active = 1',
      {'code': code},
    );
    if (found.rows.isEmpty) return json({'error': '$code not found'}, 404);
    final id = found.rows.first.assoc()['id'];
    final use = await db.execute(
      'SELECT '
      '(SELECT COUNT(*) FROM training_program_categories tpc '
      ' JOIN training_programs t ON t.id = tpc.training_program_id '
      '  AND t.is_active = 1 WHERE tpc.category_id = $id) AS trainings, '
      '(SELECT COUNT(*) FROM tournaments '
      ' WHERE category_id = $id AND deleted_at IS NULL) AS tournaments, '
      // A player's category IS their birth year. Hiding it while children
      // born that year are still active dropped every one of them out of
      // every category filter and message audience, with no category left.
      // A child still waiting on Player Validation counts too (they'd have
      // no category once approved), but is named as such: the admin's
      // Players list doesn't show them.
      '(SELECT COUNT(*) FROM players p JOIN categories c ON c.id = $id '
      ' WHERE p.is_active = 1 AND p.is_approved = 1 '
      ' AND YEAR(p.birthday) = c.birth_year) AS players, '
      '(SELECT COUNT(*) FROM players p JOIN categories c ON c.id = $id '
      ' WHERE p.is_active = 1 AND p.is_approved = 0 '
      ' AND YEAR(p.birthday) = c.birth_year) AS waiting',
    );
    final counts = use.rows.first.assoc();
    final trainings = int.parse(counts['trainings']!);
    final tournaments = int.parse(counts['tournaments']!);
    final players = int.parse(counts['players']!);
    final waiting = int.parse(counts['waiting']!);
    if (trainings > 0 || tournaments > 0 || players > 0 || waiting > 0) {
      final parts = [
        if (players > 0) '$players player${players == 1 ? '' : 's'}',
        if (waiting > 0)
          '$waiting new player${waiting == 1 ? '' : 's'} waiting on Player '
              'Validation',
        if (trainings > 0) '$trainings training${trainings == 1 ? '' : 's'}',
        if (tournaments > 0)
          '$tournaments tournament${tournaments == 1 ? '' : 's'}',
      ];
      return json({
        'error':
            '$code is still used by ${parts.join(' and ')}. Delete those '
            'first.',
      }, 409);
    }
    await db.execute('UPDATE categories SET is_active = 0 WHERE id = :id', {
      'id': id,
    });
    return json({'deleted': code});
  });

  // Quick liveness check — hit this first when something looks broken.
  // Asks the database too: a server that's up but can't reach MySQL used
  // to answer "ok" while every screen in the app failed.
  router.get('/health', (Request request) async {
    try {
      await db.execute('SELECT 1');
      return Response.ok(jsonEncode({'status': 'ok'}));
    } catch (_) {
      return Response(
        503,
        body: jsonEncode({'status': 'error', 'database': 'unreachable'}),
      );
    }
  });

  // Every route except /health, /auth/login and /auth/signup requires a
  // valid session token, and non-admins are limited to the routes a parent
  // needs (see auth.dart).
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_errorsAsJson())
      .addMiddleware(authMiddleware(db))
      .addMiddleware(_plainTextOnly())
      .addHandler(router.call);

  final port = int.parse(env['PORT'] ?? '8080');
  // 0.0.0.0 (not just localhost) so a phone on the same Wi-Fi, or the
  // Android emulator's 10.0.2.2 alias, can actually reach this.
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  print('Listening on http://${server.address.host}:${server.port}');

  // Billing's "today" and "this month" come from MySQL's clock, so MySQL
  // must run on UAE time (+04:00). A new host defaults to UTC: after 8 pm
  // "today" would already be tomorrow and months would close 4 hours early.
  // Fix on the database server with:  SET PERSIST time_zone = '+04:00';
  try {
    final clock = await db.execute(
      'SELECT TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW()) AS offset_min',
    );
    final offset = clock.rows.first.assoc()['offset_min'];
    if (offset != '240') {
      print('');
      print(
        '!!! WARNING: MySQL is NOT on UAE time (offset $offset minutes, '
        'should be 240).',
      );
      print(
        "!!! Billing dates will be wrong. Run as MySQL root: "
        "SET PERSIST time_zone = '+04:00';",
      );
      print('');
    }
  } catch (e) {
    print('Could not check the MySQL time zone: $e');
  }

  // Email (password-reset codes) through Brevo: lib/mailer.dart.
  Mailer.configure(env);

  // Push notifications for new messages (lib/push.dart). Off until the
  // Firebase server key is configured in .env.
  await Push.start(db, env);

  // Bills finished months on its own. It used to happen only when someone
  // opened the app, so on the 1st nobody was billed until somebody did.
  // Hourly (not once at midnight) so a restart or a missed tick can't skip
  // a month; the close is safe to repeat.
  Future<void> closeMonths() async {
    try {
      final result = await closeTrainingFees(db);
      if (result.values.any((count) => count > 0)) {
        print('Month close: $result');
      }
    } catch (e) {
      print('Month close failed: $e');
    }
  }

  // Expired logins were only cleared when someone logged in, and used or
  // expired password-reset links never were.
  Future<void> tidyUp() async {
    try {
      await db.execute('DELETE FROM auth_sessions WHERE expires_at < NOW()');
      await db.execute(
        'DELETE FROM password_resets WHERE expires_at < NOW() - INTERVAL 7 DAY '
        'OR used_at < NOW() - INTERVAL 7 DAY',
      );
    } catch (e) {
      print('Tidy-up failed: $e');
    }
  }

  // A happy-birthday message to each player's family on the day (from 7 am,
  // once a year). Hourly like the rest, so a restart can't skip a day.
  Future<void> birthdays() async {
    try {
      final sent = await sendBirthdayGreetings(
        db,
        // Only for testing on a computer: BIRTHDAY_FROM_HOUR=0 sends them
        // straight away. Unset (live) it is 7 am.
        fromHour: int.tryParse(env['BIRTHDAY_FROM_HOUR'] ?? '') ?? 7,
      );
      if (sent > 0) print('Birthday messages sent: $sent');
    } catch (e) {
      print('Birthday messages failed: $e');
    }
  }

  await closeMonths();
  await tidyUp();
  await birthdays();
  Timer.periodic(const Duration(hours: 1), (_) {
    closeMonths();
    tidyUp();
    birthdays();
  });
}

/// Refuses emoji in any text sent to the server, so names, messages, titles
/// and notes stay formal whichever app version or tool sent them. Passwords
/// are left alone: nobody ever sees them.
Middleware _plainTextOnly() {
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'GET' || request.method == 'HEAD') {
        return inner(request);
      }
      final text = await request.readAsString();
      Object? body;
      try {
        body = jsonDecode(text);
      } on FormatException {
        body = null; // Not JSON: the route itself reports that.
      }
      if (_containsEmoji(body)) {
        return Response(
          400,
          body: jsonEncode({
            'error': "Emoji aren't allowed. Please use plain text.",
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }
      // The body can only be read once, so hand the route a fresh copy.
      return inner(request.change(body: text));
    };
  };
}

bool _containsEmoji(Object? value, [String key = '']) => switch (value) {
  String() => !key.toLowerCase().contains('password') && hasEmoji(value),
  Map() => value.entries.any((e) => _containsEmoji(e.value, '${e.key}')),
  List() => value.any((v) => _containsEmoji(v, key)),
  _ => false,
};

const _mysqlDataTooLong = 1406;
const _mysqlBadValue = 1292;
const _mysqlOutOfRange = 1264;
const _mysqlCheckFailed = 3819;
const _mysqlTruncated = 1265;
const _mysqlIncorrectValue = 1366;
const _mysqlBadDate = 1525;
const _mysqlNoParentRow = 1452;

/// Turns anything a route didn't handle into a JSON error the app can show.
///
/// Without this, a request that wasn't JSON (or a value too long for its
/// column) got shelf's plain-text "Internal Server Error", which the app can
/// only report as "Something went wrong (HTTP 500)".
Middleware _errorsAsJson() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on HijackException {
        rethrow;
      } catch (e, st) {
        final (status, message) = switch (e) {
          // A rule the money or jersey code states itself ("The server is
          // busy. Please try again in a moment."), with its own status.
          LedgerError(:final status, :final message) => (status, message),
          FormatException() || TypeError() => (
            400,
            "The request wasn't in the format the server expected.",
          ),
          MySQLServerException(errorCode: _mysqlDataTooLong) => (
            400,
            'One of the values is too long.',
          ),
          MySQLServerException(
            errorCode: _mysqlBadValue ||
                _mysqlBadDate ||
                _mysqlTruncated ||
                _mysqlIncorrectValue,
          ) =>
            (400, 'One of the values is not valid.'),
          // Something the request points at (a player, a tournament) doesn't
          // exist. Routes check the usual cases; this is the backstop, and
          // replaces the raw "foreign key constraint fails" text.
          MySQLServerException(errorCode: _mysqlNoParentRow) => (
            404,
            'Something this refers to no longer exists. Please refresh.',
          ),
          MySQLServerException(errorCode: _mysqlDuplicateEntry) => (
            409,
            'That already exists.',
          ),
          MySQLServerException(errorCode: _mysqlOutOfRange) => (
            400,
            'One of the amounts is too large.',
          ),
          // A CHECK constraint refused it: a negative amount, more paid than
          // charged, a month that isn't the 1st. The code checks these first,
          // so reaching here means a path was missed — the database held.
          MySQLServerException(errorCode: _mysqlCheckFailed) => (
            400,
            "That value isn't allowed.",
          ),
          _ => (500, 'Something went wrong on the server. Please try again.'),
        };
        if (status == 500 || e is TypeError) {
          print(
            'Unhandled error on ${request.method} /${request.url}: $e\n$st',
          );
        }
        return Response(
          status,
          body: jsonEncode({'error': message}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    };
  };
}
