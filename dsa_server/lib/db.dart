import 'dart:async';
import 'dart:collection';

import 'package:dotenv/dotenv.dart';
import 'package:mysql_client/mysql_client.dart';

/// The one place the app's MySQL credentials get read, and the only way the
/// rest of the server should touch the database: [execute] and
/// [transaction]. Don't use [pool] directly.
///
/// Why the wrapper: mysql_client 0.0.27's pool has two bugs that together
/// froze the whole server.
///
///  1. `withConnection` (which `transactional` uses) only returns the
///     connection to the pool if the callback succeeds. Any error — and the
///     money code refuses bad requests by throwing — leaked a connection
///     for good.
///  2. When every connection is busy, the pool waits with
///     `Future.doWhile(() => idleConnectionsQty == 0)`. That condition is
///     synchronous, so it spins forever without yielding to the event loop:
///     no request can finish, so no connection is ever freed, and even
///     /health stops answering.
///
/// [execute] and [transaction] queue on a Dart-side semaphore sized to the
/// pool, so the pool is never asked for more connections than it has and
/// never reaches its spinning wait. [transaction] catches errors inside the
/// connection callback so the connection always goes back, then rethrows.
class Db {
  final MySQLConnectionPool pool;
  final _Semaphore _permits;

  Db._(this.pool, int maxConnections) : _permits = _Semaphore(maxConnections);

  static const _maxConnections = 10;

  static Future<Db> connect(DotEnv env) async {
    final pool = MySQLConnectionPool(
      host: env['DB_HOST'] ?? 'localhost',
      port: int.parse(env['DB_PORT'] ?? '3306'),
      userName: env['DB_USER'] ?? 'dsa_app_user',
      password: env['DB_PASSWORD'],
      databaseName: env['DB_NAME'] ?? 'dsa_db',
      maxConnections: _maxConnections,
    );
    final db = Db._(pool, _maxConnections);
    // Fails fast and loudly if the credentials or the server are wrong,
    // rather than the first request silently hanging.
    await db.execute('SELECT 1');
    return db;
  }

  /// One statement on a pooled connection.
  Future<IResultSet> execute(String query, [Map<String, dynamic>? params]) =>
      _permits.run(() => pool.execute(query, params));

  /// Runs [body] in a database transaction: committed if it completes,
  /// rolled back (and the error rethrown) if it throws. The connection is
  /// returned to the pool either way.
  ///
  /// Inside [body], use only the `conn` it's given. Calling [execute] or
  /// [transaction] again from in there would wait for a second connection
  /// while holding the first.
  Future<T> transaction<T>(Future<T> Function(MySQLConnection conn) body) {
    return _permits.run(() async {
      final outcome = <T>[];
      Object? error;
      StackTrace? trace;
      await pool.withConnection((conn) async {
        try {
          outcome.add(await conn.transactional(body));
        } catch (e, st) {
          error = e;
          trace = st;
        }
      });
      if (error != null) Error.throwWithStackTrace(error!, trace!);
      return outcome.single;
    });
  }
}

/// A plain counting semaphore: at most [_max] actions run at once, the rest
/// wait their turn in order.
class _Semaphore {
  final int _max;
  int _inUse = 0;
  final _waiting = Queue<Completer<void>>();

  _Semaphore(this._max);

  Future<T> run<T>(Future<T> Function() action) async {
    if (_inUse < _max) {
      _inUse++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      // The finishing action hands its permit straight to us, so the count
      // doesn't change here.
      await turn.future;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _inUse--;
      }
    }
  }
}
