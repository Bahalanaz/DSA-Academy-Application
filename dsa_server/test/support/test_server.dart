// Starts the real server against a throwaway MySQL database for the API
// tests, and talks to it over HTTP like the app does.
//
// Needs a MySQL 8 server and an account that may create databases, given
// through environment variables:
//
//   TEST_MYSQL_PASSWORD   required; without it the API tests are skipped
//   TEST_MYSQL_HOST       default 127.0.0.1
//   TEST_MYSQL_PORT       default 3306
//   TEST_MYSQL_USER       default root
//   TEST_DB_NAME          default dsa_test (dropped and rebuilt every run)
//
// The database is rebuilt from dsa_app/database/schema.sql, so it starts
// with the schema's seed rows (categories, fees, order items and the dev
// admin "admin" / "admin123"). It refuses to touch a database named dsa_db.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:dotenv/dotenv.dart';
import 'package:mysql_client/mysql_client.dart';

import '../../lib/db.dart';

final _env = Platform.environment;

/// Why the API tests can't run here, or null if they can.
String? get skipReason => (_env['TEST_MYSQL_PASSWORD'] ?? '').isEmpty
    ? 'Set TEST_MYSQL_PASSWORD (and a MySQL server) to run the API tests'
    : null;

String get _dbName => _env['TEST_DB_NAME'] ?? 'dsa_test';

/// The admin the schema seeds for development databases.
const adminLogin = (username: 'admin', password: 'admin123');

class TestServer {
  final Process _process;
  final MySQLConnection _sql;
  final Uri base;

  TestServer._(this._process, this._sql, this.base);

  /// Rebuilds the test database and starts `bin/server.dart` on a free port.
  static Future<TestServer> start() async {
    if (_dbName == 'dsa_db') {
      throw StateError('TEST_DB_NAME must not be the real database (dsa_db)');
    }
    final sql = await MySQLConnection.createConnection(
      host: _env['TEST_MYSQL_HOST'] ?? '127.0.0.1',
      port: int.parse(_env['TEST_MYSQL_PORT'] ?? '3306'),
      userName: _env['TEST_MYSQL_USER'] ?? 'root',
      password: _env['TEST_MYSQL_PASSWORD']!,
    );
    await sql.connect();
    await sql.execute('DROP DATABASE IF EXISTS `$_dbName`');
    for (final statement in _schemaStatements()) {
      await sql.execute(statement);
    }

    final port = await _freePort();
    final serverDir = Directory.current.path;
    // Run from an empty folder, so the developer's own dsa_server/.env (which
    // points at the real database) is never loaded.
    final runDir = await Directory.systemTemp.createTemp('dsa_test_');
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['$serverDir${Platform.pathSeparator}bin${Platform.pathSeparator}server.dart'],
      workingDirectory: runDir.path,
      environment: {
        'DB_HOST': _env['TEST_MYSQL_HOST'] ?? '127.0.0.1',
        'DB_PORT': _env['TEST_MYSQL_PORT'] ?? '3306',
        'DB_USER': _env['TEST_MYSQL_USER'] ?? 'root',
        'DB_PASSWORD': _env['TEST_MYSQL_PASSWORD']!,
        'DB_NAME': _dbName,
        'PORT': '$port',
        // Push and email stay off.
        'FIREBASE_SERVICE_ACCOUNT': '',
        'BREVO_API_KEY': '',
      },
    );
    final log = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);

    final base = Uri.parse('http://127.0.0.1:$port');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      try {
        final health = await http.get(base.resolve('/health'));
        if (health.statusCode == 200) break;
      } on Exception {
        // Not listening yet.
      }
      if (DateTime.now().isAfter(deadline)) {
        process.kill();
        throw StateError('The server did not start:\n$log');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return TestServer._(process, sql, base);
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    await _sql.close();
  }

  /// The first column of the first row, as text ('' if there's no row), for
  /// checking what actually got stored.
  Future<String> value(String query, [Map<String, dynamic>? params]) async {
    final result = await _sql.execute(query, params);
    if (result.rows.isEmpty) return '';
    return result.rows.first.colAt(0) ?? '';
  }

  /// The server's own database handle, on the test database, for calling
  /// jobs the server runs on a timer (like the birthday messages) directly.
  /// Close it with `db.pool.close()`.
  Future<Db> openDb() => Db.connect(
    DotEnv()..addAll({
      'DB_HOST': _env['TEST_MYSQL_HOST'] ?? '127.0.0.1',
      'DB_PORT': _env['TEST_MYSQL_PORT'] ?? '3306',
      'DB_USER': _env['TEST_MYSQL_USER'] ?? 'root',
      'DB_PASSWORD': _env['TEST_MYSQL_PASSWORD']!,
      'DB_NAME': _dbName,
    }),
  );

  /// Signs in and returns a client carrying the session token.
  Future<Client> logIn(String identifier, String password) async {
    final response = await Client(
      base,
      null,
    ).post('/auth/login', {'identifier': identifier, 'password': password});
    if (response.status != 200) {
      throw StateError('Login as $identifier failed: ${response.body}');
    }
    return Client(base, response.json['token'] as String);
  }

  Future<Client> logInAdmin() =>
      logIn(adminLogin.username, adminLogin.password);

  /// Signs up a parent, has [admin] approve the account, and signs them in.
  Future<({int id, Client client})> newParent(
    Client admin,
    String username,
    String fullName,
  ) async {
    const password = 'test-pass-123';
    final signup = await Client(base, null).post('/auth/signup', {
      'username': username,
      'fullName': fullName,
      'email': '$username@example.com',
      'phone': '+971 50 000 0000',
      'password': password,
    });
    if (signup.status != 201) {
      throw StateError('Signup of $username failed: ${signup.body}');
    }
    final id = int.parse(
      await value('SELECT id FROM users WHERE username = :u', {'u': username}),
    );
    await admin.post('/admin/users/$id/approve');
    return (id: id, client: await logIn(username, password));
  }

  static Iterable<String> _schemaStatements() sync* {
    final schema = File('../dsa_app/database/schema.sql')
        .readAsStringSync()
        .replaceAll(RegExp(r'\bdsa_db\b'), _dbName);
    final withoutComments = schema
        .split('\n')
        .map((line) => _stripComment(line))
        .join('\n');
    for (final statement in withoutComments.split(RegExp(r';[ \t]*\n'))) {
      if (statement.trim().isNotEmpty) yield statement.trim();
    }
  }

  /// A line without its trailing `-- comment`, ignoring any `--` inside a
  /// quoted string.
  static String _stripComment(String line) {
    var inString = false;
    for (var i = 0; i < line.length - 1; i++) {
      if (line[i] == "'") inString = !inString;
      if (!inString && line[i] == '-' && line[i + 1] == '-') {
        return line.substring(0, i);
      }
    }
    return line;
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}

/// An HTTP client for one signed-in user (or nobody, with no token).
class Client {
  final Uri _base;
  final String? _token;

  Client(this._base, this._token);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json; charset=utf-8',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<Reply> get(String path) async =>
      Reply(await http.get(_base.resolve(path), headers: _headers));

  Future<Reply> post(String path, [Object? body]) async => Reply(
    await http.post(
      _base.resolve(path),
      headers: _headers,
      body: body == null ? null : jsonEncode(body),
    ),
  );

  Future<Reply> put(String path, Object body) async => Reply(
    await http.put(
      _base.resolve(path),
      headers: _headers,
      body: jsonEncode(body),
    ),
  );

  Future<Reply> delete(String path) async =>
      Reply(await http.delete(_base.resolve(path), headers: _headers));
}

class Reply {
  final http.Response _response;

  Reply(this._response);

  int get status => _response.statusCode;
  String get body => utf8.decode(_response.bodyBytes);
  dynamic get json => jsonDecode(body);

  @override
  String toString() => '$status $body';
}
