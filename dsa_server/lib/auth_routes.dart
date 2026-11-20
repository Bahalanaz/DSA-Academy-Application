import 'dart:convert';
import 'dart:io' show HttpConnectionInfo, InternetAddress;
import 'dart:math' show Random;

import 'package:bcrypt/bcrypt.dart';
import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'account_deletion.dart';
import 'auth.dart';
import 'billing.dart';
import 'db.dart';
import 'ledger.dart';
import 'mailer.dart';
import 'text_rules.dart';

const _mysqlDuplicateEntry = 1062;

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Signup, login and logout. A successful login returns a session token
/// the app sends as `Authorization: Bearer <token>` on every other request
/// (checked by authMiddleware in auth.dart).
Router buildAuthRouter(Db db) {
  final router = Router();

  // Recent failed logins, per username-or-email and address. Without a
  // limit, a password could be guessed as fast as requests could be sent.
  // Kept in memory: a restart clears it, which is fine for slowing guessing.
  final failures = <String, List<DateTime>>{};

  // Sign-ups per address in the last hour. Without a limit a script could
  // fill Account Validation with fake accounts faster than anyone could
  // delete them.
  final signups = <String, List<DateTime>>{};

  router.post('/auth/signup', (Request request) async {
    final now = DateTime.now();
    final address = _clientAddress(request);
    if (signups.length > 1000) {
      signups.removeWhere(
        (_, times) =>
            times.isEmpty || now.difference(times.last) > _signupWindow,
      );
    }
    final recentSignups = (signups[address] ?? [])
      ..removeWhere((time) => now.difference(time) > _signupWindow);
    if (recentSignups.length >= _maxSignupsPerWindow) {
      return _json({
        'error': 'Too many sign-ups from this device. Please try again later.',
      }, status: 429);
    }
    final body = jsonDecode(await request.readAsString()) as Map;
    final username = (body['username'] as String? ?? '').trim();
    final fullName = normalizeSpaces(body['fullName'] as String? ?? '');
    final email = (body['email'] as String? ?? '').trim();
    final phone = (body['phone'] as String? ?? '').trim();
    final password = (body['password'] as String? ?? '');
    if (fullName.length > 120) {
      return _json({
        'error': 'Name must be 120 characters or fewer',
      }, status: 400);
    }
    final nameError = fullName.isEmpty ? null : personNameError(fullName);
    if (nameError != null) {
      return _json({'error': nameError}, status: 400);
    }

    if (username.isEmpty || email.isEmpty || password.isEmpty) {
      return _json({
        'error': 'Username, email, and password are required',
      }, status: 400);
    }
    // Checked here so a bad value gets a clear message rather than a
    // database error. An @ is kept out of usernames because login accepts
    // "username or email" — a username shaped like someone else's email
    // could log in as the wrong account. Plain letters, numbers, dots,
    // dashes and underscores only, so usernames stay formal too.
    if (username.length < 3 ||
        username.length > 60 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(username)) {
      return _json({
        'error':
            'Username must be 3 to 60 letters, numbers, dots, dashes or '
            'underscores',
      }, status: 400);
    }
    if (email.length > 160 || !emailPattern.hasMatch(email)) {
      return _json({'error': 'Enter a valid email address'}, status: 400);
    }
    final phoneProblem = phoneError(phone);
    if (phoneProblem != null) {
      return _json({'error': phoneProblem}, status: 400);
    }
    final passwordError = _checkNewPassword(password);
    if (passwordError != null) {
      return _json({'error': passwordError}, status: 400);
    }

    final hash = BCrypt.hashpw(password, BCrypt.gensalt());

    try {
      final result = await db.execute(
        'INSERT INTO users '
        '(role, full_name, username, email, phone, password_hash, status) '
        'VALUES '
        "('parent', :fullName, :username, :email, :phone, :hash, 'pending')",
        {
          // The parent's real name, shown to the admin as the guardian. It
          // used to be the username ("zzmaria"), because the form had no name
          // field; older app versions still don't send one.
          'fullName': fullName.isEmpty ? username : fullName,
          'username': username,
          'email': email,
          'phone': phone.isEmpty ? null : phone,
          'hash': hash,
        },
      );
      signups[address] = recentSignups..add(now);
      return _json({
        'id': result.lastInsertID.toInt(),
        'username': username,
        'status': 'pending',
      }, status: 201);
    } on MySQLServerException catch (e) {
      if (e.errorCode == _mysqlDuplicateEntry) {
        return _json({
          'error': 'That username or email is already taken',
        }, status: 409);
      }
      rethrow;
    }
  });

  router.post('/auth/login', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final identifier = (body['identifier'] as String? ?? '').trim();
    final password = (body['password'] as String? ?? '');

    if (identifier.isEmpty || password.isEmpty) {
      return _json({
        'error': 'Username/email and password are required',
      }, status: 400);
    }

    final now = DateTime.now();
    if (failures.length > 1000) {
      failures.removeWhere((_, times) => now.difference(times.last) > _lockout);
    }
    final key = '${identifier.toLowerCase()}|${_clientAddress(request)}';
    final recent = (failures[key] ?? [])
      ..removeWhere((time) => now.difference(time) > _lockout);
    if (recent.length >= _maxFailedLogins) {
      final minutes = ((_lockout - now.difference(recent.first)).inSeconds / 60)
          .ceil();
      return _json({
        'error':
            'Too many wrong passwords. Try again in $minutes '
            'minute${minutes == 1 ? '' : 's'}.',
      }, status: 429);
    }

    final result = await db.execute(
      'SELECT id, role, full_name, username, email, phone, password_hash, '
      'status, must_change_password, photo_url '
      'FROM users WHERE username = :identifier OR email = :identifier '
      'LIMIT 1',
      {'identifier': identifier},
    );

    // Same generic message whether the account doesn't exist or the
    // password is wrong — never reveal which, that's a login-enumeration
    // vulnerability.
    const badCredentials = 'Invalid username/email or password';
    if (result.rows.isEmpty) {
      failures[key] = recent..add(now);
      return _json({'error': badCredentials}, status: 401);
    }
    final row = result.rows.first.assoc();
    if (!BCrypt.checkpw(password, row['password_hash']!)) {
      failures[key] = recent..add(now);
      return _json({'error': badCredentials}, status: 401);
    }
    failures.remove(key);

    switch (row['status']) {
      case 'pending':
        return _json({
          'error': 'Your account is awaiting admin approval.',
        }, status: 403);
      case 'rejected':
        return _json({
          'error': 'Your account was not approved. Contact the admin.',
        }, status: 403);
      case 'disabled':
        return _json({
          'error':
              'This account has been deactivated. Please contact the academy '
              'if you think this is a mistake.',
        }, status: 403);
    }

    // A fresh session token. Only its hash is stored; the token itself is
    // handed back once and the app sends it with every request after this.
    final token = newSessionToken();
    await db.execute('DELETE FROM auth_sessions WHERE expires_at < NOW()');
    await db.execute(
      'INSERT INTO auth_sessions (token_hash, user_id, expires_at) '
      'VALUES (:hash, :userId, DATE_ADD(NOW(), INTERVAL '
      '${sessionLifetime.inDays} DAY))',
      {'hash': hashToken(token), 'userId': row['id']},
    );

    return _json({
      'id': int.parse(row['id']!),
      'role': row['role'],
      'fullName': row['full_name'],
      'username': row['username'],
      'email': row['email'],
      // The Account screen shows and saves this; without it the phone field
      // started blank and saving the profile wiped the number.
      'phone': row['phone'],
      // Their account photo, if any ('/photos/user/<id>?v=...').
      'photoUrl': row['photo_url'],
      'token': token,
      // The admin reset this password: the app asks for a new one before
      // letting them in (and the server refuses everything else until then).
      'mustChangePassword': row['must_change_password'] == '1',
    });
  });

  /// Changes the logged-in user's password. Every other device they're
  /// signed in on is logged out; this one stays signed in.
  router.post('/auth/change-password', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final current = body['currentPassword'] as String? ?? '';
    final next = body['newPassword'] as String? ?? '';

    final newError = _checkNewPassword(next);
    if (newError != null) return _json({'error': newError}, status: 400);
    if (next == current) {
      return _json({
        'error': 'Choose a password different from your current one',
      }, status: 400);
    }

    final found = await db.execute(
      'SELECT password_hash FROM users WHERE id = :id',
      {'id': user.id},
    );
    // 400, not 401: the app treats 401 as "your login has ended" and signs
    // the user out, which a mistyped password shouldn't do.
    if (found.rows.isEmpty ||
        !BCrypt.checkpw(current, found.rows.first.assoc()['password_hash']!)) {
      return _json({
        'error': 'Your current password is incorrect',
      }, status: 400);
    }

    final header = request.headers['authorization'] ?? '';
    final thisToken = hashToken(header.substring(7).trim());
    await db.execute(
      'UPDATE users SET password_hash = :hash, must_change_password = 0 '
      'WHERE id = :id',
      {'id': user.id, 'hash': BCrypt.hashpw(next, BCrypt.gensalt())},
    );
    await db.execute(
      'DELETE FROM auth_sessions WHERE user_id = :id AND token_hash <> :token',
      {'id': user.id, 'token': thisToken},
    );
    return _json({'changed': true});
  });

  /// A parent deletes their own account (Google Play requires any app with
  /// sign-up to offer this in the app). Asks for the password again.
  ///
  /// Refused while their children owe money or the club is holding training
  /// credit for them: that's settled or refunded by the club first.
  /// Otherwise the account is anonymised rather than erased: name,
  /// username, email, phone and photo are replaced, the password stops
  /// working, and every device is signed out. Their children come off the
  /// club's lists and upcoming rosters. Bills and payments stay, linked to
  /// the children, because the club's accounts have to keep them. The same
  /// email and username can be used to sign up again.
  router.post('/auth/delete-account', (Request request) async {
    final user = userOf(request);
    if (user.isAdmin) {
      return _json({
        'error': "An admin account can't be deleted from the app.",
      }, status: 403);
    }
    final body = jsonDecode(await request.readAsString());
    final password = body is Map ? '${body['password'] ?? ''}' : '';
    final found = await db.execute(
      'SELECT password_hash FROM users WHERE id = :id',
      {'id': user.id},
    );
    // 400, not 401: the app treats 401 as "signed out".
    if (found.rows.isEmpty ||
        !BCrypt.checkpw(password, found.rows.first.assoc()['password_hash']!)) {
      return _json({'error': 'Your password is incorrect'}, status: 400);
    }
    try {
      await withMoneyLock(
        db,
        (conn) => deleteParentAccount(conn, user.id, byAdmin: false),
      );
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    }
    return _json({'deleted': true});
  });

  // "Forgot Password?" requests per address, so it can't be used to flood
  // someone's inbox. In memory, like the login lockout.
  final resetRequests = <String, List<DateTime>>{};

  // A family may ask for at most this many codes an hour; after that they
  // wait out the rest of the hour, and are told for how long.
  const maxCodesPerHour = 3;

  // Codes asked for an email / username with no account behind it. Counted
  // the same way as a real account's, so the limit (and its message) can't
  // be used to find out which accounts exist.
  final unknownRequests = <String, List<DateTime>>{};

  Response tooManyCodes(int minutes) => _json({
    'error':
        "You've asked for $maxCodesPerHour codes in the last hour. Please "
        'try again in $minutes minute${minutes == 1 ? '' : 's'}, or use the '
        'newest code you received.',
    'retryInMinutes': minutes,
  }, status: 429);

  /// Step 1 of "Forgot Password?": {"identifier": "<email or username>"}.
  ///
  /// Emails a 6-digit code (through Brevo, see mailer.dart) that works for
  /// 15 minutes. Only the newest code works. At most 3 codes an hour per
  /// account (however they type it: email or username) — the 4th gets a 429
  /// saying how many minutes are left — and 10 requests an hour per device.
  /// The answer, codesLeft included, is the same whether or not the account
  /// exists, so this can't be used to find out who has an account.
  router.post('/auth/forgot-password', (Request request) async {
    if (!Mailer.isConfigured) {
      return _json({
        'error':
            "Password reset by email isn't set up yet. Please contact the "
            'academy.',
      }, status: 503);
    }
    final body = jsonDecode(await request.readAsString());
    final identifier = body is Map ? '${body['identifier'] ?? ''}'.trim() : '';
    if (identifier.isEmpty) {
      return _json({'error': 'Enter your email or username'}, status: 400);
    }
    final now = DateTime.now();
    final address = _clientAddress(request);
    final recent = (resetRequests[address] ?? [])
      ..removeWhere((time) => now.difference(time) > const Duration(hours: 1));
    if (recent.length >= 10) {
      return _json({
        'error': 'Too many requests from this device. Please try again later.',
      }, status: 429);
    }
    resetRequests[address] = recent..add(now);

    final found = await db.execute(
      'SELECT id, full_name, email FROM users '
      'WHERE (username = :identifier OR email = :identifier) '
      "AND status = 'approved' AND deleted_at IS NULL LIMIT 1",
      {'identifier': identifier},
    );
    if (found.rows.isEmpty) {
      if (unknownRequests.length > 5000) unknownRequests.clear();
      final key = identifier.toLowerCase();
      final asked = (unknownRequests[key] ?? [])
        ..removeWhere(
          (time) => now.difference(time) > const Duration(hours: 1),
        );
      if (asked.length >= maxCodesPerHour) {
        final wait = const Duration(hours: 1) - now.difference(asked.first);
        return tooManyCodes((wait.inSeconds / 60).ceil().clamp(1, 60));
      }
      unknownRequests[key] = asked..add(now);
      return _json({'sent': true, 'codesLeft': maxCodesPerHour - asked.length});
    }
    final row = found.rows.first.assoc();
    final userId = int.parse(row['id']!);
    // From the database, so a server restart doesn't reset the count.
    final lately = await db.execute(
      'SELECT COUNT(*) AS n, TIMESTAMPDIFF(SECOND, NOW(), '
      'MIN(created_at) + INTERVAL 1 HOUR) AS wait FROM password_resets '
      'WHERE user_id = :id AND created_at > NOW() - INTERVAL 1 HOUR',
      {'id': userId},
    );
    final asked = int.parse('${lately.rows.first.assoc()['n']}');
    if (asked >= maxCodesPerHour) {
      final wait = int.tryParse('${lately.rows.first.assoc()['wait']}') ?? 60;
      return tooManyCodes((wait / 60).ceil().clamp(1, 60));
    }

    final code = '${Random.secure().nextInt(900000) + 100000}';
    await db.transaction((conn) async {
      // Only the newest code works.
      await conn.execute(
        'UPDATE password_resets SET used_at = NOW() '
        'WHERE user_id = :id AND used_at IS NULL',
        {'id': userId},
      );
      await conn.execute(
        'INSERT INTO password_resets (user_id, token_hash, expires_at) '
        'VALUES (:id, :hash, NOW() + INTERVAL 15 MINUTE)',
        {'id': userId, 'hash': hashToken('$userId:$code')},
      );
    });
    final name = row['full_name'] ?? '';
    final sent = await Mailer.send(
      toEmail: row['email']!,
      toName: name,
      subject: 'Your DSA Elite Academy password reset code',
      text:
          'Hi $name,\n\n'
          'Your code to reset your DSA Elite Academy password is: $code\n\n'
          'Enter it in the app within 15 minutes. If you didn\'t ask for '
          'this, ignore this email: your password stays the same.\n\n'
          'DSA Elite Academy',
      html: _resetEmailHtml(name, code),
    );
    if (!sent) print('Password reset: the email to user $userId failed.');
    return _json({'sent': true, 'codesLeft': maxCodesPerHour - asked - 1});
  });

  /// Step 2: {"identifier", "code", "newPassword"}. The newest code for the
  /// account, within 15 minutes and 5 tries. On success the password
  /// changes and every phone signed in to the account is signed out.
  router.post('/auth/reset-password', (Request request) async {
    final body = jsonDecode(await request.readAsString());
    final identifier = body is Map ? '${body['identifier'] ?? ''}'.trim() : '';
    final code = body is Map ? '${body['code'] ?? ''}'.trim() : '';
    final password = body is Map ? '${body['newPassword'] ?? ''}' : '';
    const wrong =
        'That code is wrong or has expired. Ask for a new code if you need '
        'one.';
    final problem = _checkNewPassword(password);
    if (problem != null) return _json({'error': problem}, status: 400);
    if (identifier.isEmpty || !RegExp(r'^\d{6}$').hasMatch(code)) {
      return _json({'error': wrong}, status: 400);
    }
    final changed = await db.transaction((conn) async {
      final found = await conn.execute(
        'SELECT u.id, r.id AS reset_id, r.token_hash, r.attempts '
        'FROM users u JOIN password_resets r ON r.user_id = u.id '
        'AND r.used_at IS NULL AND r.expires_at > NOW() '
        'WHERE (u.username = :identifier OR u.email = :identifier) '
        "AND u.status = 'approved' AND u.deleted_at IS NULL "
        'ORDER BY r.id DESC LIMIT 1 FOR UPDATE',
        {'identifier': identifier},
      );
      if (found.rows.isEmpty) return false;
      final row = found.rows.first.assoc();
      final userId = int.parse(row['id']!);
      final resetId = int.parse(row['reset_id']!);
      if (int.parse(row['attempts']!) >= 5) return false;
      if (row['token_hash'] != hashToken('$userId:$code')) {
        await conn.execute(
          'UPDATE password_resets SET attempts = attempts + 1 WHERE id = :id',
          {'id': resetId},
        );
        return false;
      }
      await conn.execute(
        'UPDATE users SET password_hash = :hash, must_change_password = 0 '
        'WHERE id = :id',
        {'id': userId, 'hash': BCrypt.hashpw(password, BCrypt.gensalt())},
      );
      await conn.execute(
        'UPDATE password_resets SET used_at = NOW() WHERE id = :id',
        {'id': resetId},
      );
      // Signed out everywhere: whoever knew the old password is out too.
      await conn.execute('DELETE FROM auth_sessions WHERE user_id = :id', {
        'id': userId,
      });
      return true;
    });
    if (!changed) return _json({'error': wrong}, status: 400);
    // A lockout from wrong passwords earlier doesn't keep them out now.
    failures.removeWhere(
      (key, _) => key.startsWith('${identifier.toLowerCase()}|'),
    );
    return _json({'reset': true});
  });

  /// Ends this session. The token stops working immediately.
  router.post('/auth/logout', (Request request) async {
    final header = request.headers['authorization'] ?? '';
    if (header.startsWith('Bearer ')) {
      await db.execute('DELETE FROM auth_sessions WHERE token_hash = :hash', {
        'hash': hashToken(header.substring(7).trim()),
      });
    }
    return _json({'loggedOut': true});
  });

  return router;
}

/// Wrong passwords allowed within [_lockout] before logins are refused.
const _maxFailedLogins = 5;

/// Accounts one address can create per [_signupWindow].
const _maxSignupsPerWindow = 10;
const _signupWindow = Duration(hours: 1);
const _lockout = Duration(minutes: 15);

/// The address of the phone making the request, for the sign-up, wrong-
/// password and reset-code limits.
///
/// Online, every request reaches this server through Caddy (the HTTPS front
/// door) on the same machine, so the connection always comes from
/// 127.0.0.1: counted by that, one family's wrong passwords would lock
/// everyone out. Caddy passes the phone's real address in X-Forwarded-For.
/// It's only believed when the connection itself is from this machine — a
/// phone talking to the server directly (on the laptop, over Wi-Fi) could
/// otherwise make up any address to dodge the limits. The last entry is the
/// one Caddy added; anything before it came from the phone.
String _clientAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return 'unknown';
  final remote = info.remoteAddress;
  if (remote.isLoopback) {
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null && forwarded.trim().isNotEmpty) {
      final last = forwarded.split(',').last.trim();
      if (InternetAddress.tryParse(last) != null) return last;
    }
  }
  return remote.address;
}

/// bcrypt only reads the first 72 bytes, so anything longer would quietly
/// accept a different password that shares those bytes.
///
/// Counted in bytes, the way bcrypt counts: an Arabic letter is two bytes,
/// so 40 of them passed a character count, then made bcrypt throw — a
/// server error on sign-up instead of a message.
String? _checkNewPassword(String password) {
  if (password.length < 6) return 'Password must be at least 6 characters';
  if (utf8.encode(password).length > 72) {
    return 'Password is too long: it must be 72 bytes or fewer (about 36 '
        'Arabic letters, or 72 English ones)';
  }
  return null;
}

/// The reset email: the code large and clear, in the club's colours.
/// [name] and [code] are escaped (the name is what the family typed).
String _resetEmailHtml(String name, String code) {
  const escape = HtmlEscape();
  final safeName = escape.convert(name);
  return '''
<div style="font-family:Arial,Helvetica,sans-serif;background:#121212;padding:24px;color:#ffffff">
  <div style="max-width:420px;margin:0 auto;background:#1D1D1F;border-radius:14px;padding:24px">
    <p style="margin:0 0 6px;color:#4CAF50;font-weight:bold;letter-spacing:0.5px">DSA ELITE ACADEMY</p>
    <p style="margin:0 0 16px">Hi $safeName,</p>
    <p style="margin:0 0 12px;color:#cccccc">Your code to reset your password:</p>
    <p style="margin:0 0 16px;font-size:32px;font-weight:bold;letter-spacing:8px">${escape.convert(code)}</p>
    <p style="margin:0 0 8px;color:#cccccc">Enter it in the app within 15 minutes.</p>
    <p style="margin:0;color:#888888;font-size:13px">If you didn't ask for this, ignore this email: your password stays the same.</p>
  </div>
</div>''';
}
