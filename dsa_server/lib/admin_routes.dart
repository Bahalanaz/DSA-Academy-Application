import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'account_deletion.dart';
import 'auth.dart';
import 'billing.dart';
import 'ledger.dart';
import 'db.dart';
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Account Validation: the signups sitting in users.status = 'pending'
/// that can't log in yet (see auth_routes.dart's /auth/login), plus the
/// two actions that resolve them.
///
/// Admin-only (enforced by authMiddleware); approved_by records which admin
/// let the account in.
Router buildAdminRouter(Db db) {
  final router = Router();

  router.get('/admin/pending-users', (Request request) async {
    final result = await db.execute(
      "SELECT id, full_name, username, email, phone FROM users "
      "WHERE status = 'pending' ORDER BY created_at",
    );
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.post('/admin/users/<id>/approve', (Request request, String id) async {
    final result = await db.execute(
      "UPDATE users SET status = 'approved', approved_at = NOW(), "
      "approved_by = :adminId WHERE id = :id AND status = 'pending'",
      {'id': id, 'adminId': userOf(request).id},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({'error': 'No pending account with that id'}, status: 404);
    }
    return _json({'id': int.parse(id), 'status': 'approved'});
  });

  // A rejected signup is just removed outright, matching what this screen
  // has always done — there's no separate "rejected accounts" view to
  // resurface it from, so keeping a status='rejected' row around would
  // only be dead weight.
  router.delete('/admin/users/<id>', (Request request, String id) async {
    final result = await db.execute(
      "DELETE FROM users WHERE id = :id AND status = 'pending'",
      {'id': id},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({'error': 'No pending account with that id'}, status: 404);
    }
    return _json({'id': int.parse(id), 'deleted': true});
  });

  /// A message to one family's account only (Parent Accounts > Send
  /// message): it shows in that parent's Messages and nobody else's, whether
  /// or not they have children registered. {"title": "...", "body": "..."}
  router.post('/admin/users/<id>/message', (Request request, String id) async {
    final userId = int.tryParse(id);
    final body = jsonDecode(await request.readAsString());
    final title = body is Map ? '${body['title'] ?? ''}'.trim() : '';
    final text = body is Map ? '${body['body'] ?? ''}'.trim() : '';
    if (title.isEmpty || text.isEmpty) {
      return _json({'error': 'Title and message are required'}, status: 400);
    }
    final tooLong =
        lengthError('Title', title, 160) ?? lengthError('Message', text, 5000);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);
    final found = userId == null
        ? null
        : await db.execute(
            "SELECT status FROM users WHERE id = :id AND role = 'parent' "
            'AND deleted_at IS NULL',
            {'id': userId},
          );
    if (found == null || found.rows.isEmpty) {
      return _json({'error': 'No parent account with that id'}, status: 404);
    }
    if (found.rows.first.assoc()['status'] != 'approved') {
      return _json({
        'error':
            "This account is deactivated, so they can't sign in to read it. "
            'Reactivate it first.',
      }, status: 409);
    }
    final newId = await db.transaction((conn) async {
      final inserted = await conn.execute(
        'INSERT INTO announcements (title, body, is_everyone, sent_by) '
        'VALUES (:title, :body, 0, :sentBy)',
        {'title': title, 'body': text, 'sentBy': userOf(request).id},
      );
      final messageId = inserted.lastInsertID.toInt();
      await conn.execute(
        'INSERT INTO announcement_users (announcement_id, user_id) '
        'VALUES (:messageId, :userId)',
        {'messageId': messageId, 'userId': userId},
      );
      return messageId;
    });
    return _json({'id': newId}, status: 201);
  });

  /// One message to several families at once (Parent Accounts > the message
  /// icon > tick families > ADD MESSAGE): {"userIds": [..], "title": "...",
  /// "body": "..."}. It's ONE message with a row per family in
  /// announcement_users, so each family sees it in their Messages (and only
  /// their own name as its recipient), each reads it on their own, and the
  /// admin's list shows it once. All or nothing: if any family picked has
  /// since been deactivated or deleted, nothing is sent and the admin is
  /// told to refresh.
  router.post('/admin/messages', (Request request) async {
    final body = jsonDecode(await request.readAsString());
    final raw = body is Map ? body['userIds'] : null;
    final title = body is Map ? '${body['title'] ?? ''}'.trim() : '';
    final text = body is Map ? '${body['body'] ?? ''}'.trim() : '';
    if (raw is! List) {
      return _json({'error': 'userIds must be a list'}, status: 400);
    }
    final userIds = {for (final item in raw) ?int.tryParse('$item')};
    if (userIds.isEmpty) {
      return _json({'error': 'Pick at least one family'}, status: 400);
    }
    if (userIds.length > 1000) {
      return _json({'error': 'Too many families at once'}, status: 400);
    }
    if (title.isEmpty || text.isEmpty) {
      return _json({'error': 'Title and message are required'}, status: 400);
    }
    final tooLong =
        lengthError('Title', title, 160) ?? lengthError('Message', text, 5000);
    if (tooLong != null) return _json({'error': tooLong}, status: 400);

    final sent = await db.transaction((conn) async {
      // Validated integers, written in. Locked so a family deactivated or
      // deleted from another phone right now is either in or refused.
      final ok = await conn.execute(
        'SELECT id FROM users WHERE id IN (${userIds.join(',')}) '
        "AND role = 'parent' AND status = 'approved' AND deleted_at IS NULL "
        'FOR UPDATE',
      );
      if (ok.rows.length != userIds.length) return null;
      final inserted = await conn.execute(
        'INSERT INTO announcements (title, body, is_everyone, sent_by) '
        'VALUES (:title, :body, 0, :sentBy)',
        {'title': title, 'body': text, 'sentBy': userOf(request).id},
      );
      final messageId = inserted.lastInsertID.toInt();
      await conn.execute(
        'INSERT INTO announcement_users (announcement_id, user_id) '
        'SELECT $messageId, id FROM users WHERE id IN (${userIds.join(',')})',
      );
      return messageId;
    });
    if (sent == null) {
      return _json({
        'error':
            'One or more of the families you picked has been deactivated or '
            'deleted since. Refresh the list and try again.',
      }, status: 409);
    }
    return _json({'id': sent, 'families': userIds.length}, status: 201);
  });

  /// Every parent account that has been let in — active and deactivated —
  /// with how many children each has, for the Parent Accounts screen.
  router.get('/admin/parents', (Request request) async {
    final result = await db.execute('''
      SELECT u.id, u.full_name, u.username, u.email, u.phone, u.status,
             u.must_change_password, u.created_at, u.photo_url,
             COUNT(p.id) AS children
      FROM users u
      LEFT JOIN players p ON p.parent_id = u.id AND p.is_active = 1
                         AND p.is_approved = 1
      WHERE u.role = 'parent' AND u.status IN ('approved','disabled')
        AND u.deleted_at IS NULL
      GROUP BY u.id, u.full_name, u.username, u.email, u.phone, u.status,
               u.must_change_password, u.created_at, u.photo_url
      ORDER BY u.status = 'disabled', u.full_name
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  /// Switches a parent account off. Reversible, and nothing else changes:
  /// their children, bills and history stay exactly as they are (take the
  /// children off rosters separately if the family has left). Every device
  /// they're signed in on stops working at once.
  router.post('/admin/users/<id>/deactivate', (
    Request request,
    String id,
  ) async {
    final userId = int.tryParse(id);
    if (userId == null) {
      return _json({
        'error': 'No active parent account with that id',
      }, status: 404);
    }
    final changed = await db.transaction((conn) async {
      final result = await conn.execute(
        "UPDATE users SET status = 'disabled' WHERE id = :id "
        "AND role = 'parent' AND status = 'approved'",
        {'id': userId},
      );
      if (result.affectedRows.toInt() == 0) return false;
      await conn.execute('DELETE FROM auth_sessions WHERE user_id = :id', {
        'id': userId,
      });
      return true;
    });
    if (!changed) {
      return _json({
        'error': 'No active parent account with that id',
      }, status: 404);
    }
    return _json({'id': userId, 'status': 'disabled'});
  });

  /// Deletes a parent account for good (Parent Accounts > a family >
  /// DELETE ACCOUNT), active or deactivated. Unlike deactivate it can't be
  /// undone: the same rules as a family deleting their own account
  /// (deleteParentAccount) — refused while they owe anything or credit is
  /// held; otherwise anonymised, signed out everywhere, children taken off
  /// the club's lists, bills and payments kept for the club's accounts.
  ///
  /// {"confirm": "<their username>"}: the app makes the admin type it, and
  /// the server checks it too, so a stale screen or a wrong id can't delete
  /// a different family.
  router.post('/admin/users/<id>/delete', (Request request, String id) async {
    final userId = int.tryParse(id);
    final body = jsonDecode(await request.readAsString());
    final confirm = body is Map ? '${body['confirm'] ?? ''}'.trim() : '';
    final found = userId == null
        ? null
        : await db.execute(
            "SELECT username FROM users WHERE id = :id AND role = 'parent' "
            "AND status IN ('approved','disabled') AND deleted_at IS NULL",
            {'id': userId},
          );
    if (found == null || found.rows.isEmpty) {
      return _json({'error': 'No parent account with that id'}, status: 404);
    }
    if (confirm.toLowerCase() !=
        found.rows.first.assoc()['username']!.toLowerCase()) {
      return _json({
        'error': "Type the account's username exactly to confirm.",
      }, status: 400);
    }
    try {
      await withMoneyLock(
        db,
        (conn) => deleteParentAccount(conn, userId!, byAdmin: true),
      );
    } on LedgerError catch (e) {
      return _json({'error': e.message}, status: e.status);
    }
    return _json({'id': userId, 'deleted': true});
  });

  router.post('/admin/users/<id>/reactivate', (
    Request request,
    String id,
  ) async {
    final result = await db.execute(
      "UPDATE users SET status = 'approved' WHERE id = :id "
      "AND role = 'parent' AND status = 'disabled' AND deleted_at IS NULL",
      {'id': int.tryParse(id) ?? 0},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({
        'error': 'No deactivated parent account with that id',
      }, status: 404);
    }
    return _json({'id': int.parse(id), 'status': 'approved'});
  });

  /// Profile edits from the Account screen (both admin and parent use
  /// the same one). Deliberately can't change role or status — those are
  /// the approval gate, and letting a profile edit touch them would mean
  /// any account could promote itself.
  router.put('/users/<id>', (Request request, String id) async {
    // Your own profile only — an admin may edit anyone's.
    final user = userOf(request);
    if (!user.isAdmin && '${user.id}' != id) {
      return _json({
        'error': 'You can only edit your own profile',
      }, status: 403);
    }
    final body = jsonDecode(await request.readAsString()) as Map;
    final fullName = normalizeSpaces(body['fullName'] as String? ?? '');
    final email = (body['email'] as String? ?? '').trim();
    final phone = (body['phone'] as String? ?? '').trim();
    if (fullName.isEmpty || email.isEmpty) {
      return _json({'error': 'Name and email are required'}, status: 400);
    }
    if (fullName.length > 120) {
      return _json({
        'error': 'Name must be 120 characters or fewer',
      }, status: 400);
    }
    final nameError = personNameError(fullName);
    if (nameError != null) {
      return _json({'error': nameError}, status: 400);
    }
    if (email.length > 160 || !emailPattern.hasMatch(email)) {
      return _json({'error': 'Enter a valid email address'}, status: 400);
    }
    final phoneProblem = phoneError(phone);
    if (phoneProblem != null) {
      return _json({'error': phoneProblem}, status: 400);
    }
    // The username (what they log in with) can be changed by an admin only,
    // with the same rules as signing up. Sent only by the admin Account
    // screen; leaving it out keeps the current one.
    final username = (body['username'] as String? ?? '').trim();
    final setUsername = user.isAdmin && body.containsKey('username');
    if (setUsername &&
        (username.length < 3 ||
            username.length > 60 ||
            !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(username))) {
      return _json({
        'error':
            'Username must be 3 to 60 letters, numbers, dots, dashes or '
            'underscores',
      }, status: 400);
    }
    try {
      final result = await db.execute(
        'UPDATE users SET full_name = :fullName, email = :email, '
        'phone = :phone${setUsername ? ', username = :username' : ''} '
        'WHERE id = :id',
        {
          'id': id,
          'fullName': fullName,
          'email': email,
          'phone': phone.isEmpty ? null : phone,
          if (setUsername) 'username': username,
        },
      );
      if (result.affectedRows.toInt() == 0) {
        // Also happens when nothing actually changed, which isn't an error.
        final exists = await db.execute('SELECT id FROM users WHERE id = :id', {
          'id': id,
        });
        if (exists.rows.isEmpty) {
          return _json({'error': 'No account with that id'}, status: 404);
        }
      }
      return _json({'id': int.parse(id), 'fullName': fullName, 'email': email});
    } on MySQLServerException catch (e) {
      if (e.errorCode == 1062) {
        return _json({
          'error': e.message.contains('uq_users_username')
              ? 'That username is already taken'
              : 'That email is already used by another account',
        }, status: 409);
      }
      rethrow;
    }
  });

  return router;
}
