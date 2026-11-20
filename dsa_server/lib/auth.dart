import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import 'db.dart';

/// Who is making a request, as proven by their session token.
///
/// Before this existed the server trusted every request: anyone who could
/// reach it could mark bills paid, change prices or read every family's
/// payments. Now every route except login and signup needs a valid token,
/// and handlers read the caller with [userOf].
class AuthUser {
  final int id;
  final String role;
  final String fullName;

  const AuthUser({
    required this.id,
    required this.role,
    required this.fullName,
  });

  bool get isAdmin => role == 'admin';
}

const _contextKey = 'dsa.user';

/// How long a login lasts. No time limit, at the club's request: with
/// "Keep me signed in" a family stays signed in until they log out. A login
/// still ends at once when the password is changed (every other phone),
/// the account is deactivated or deleted, or the person logs out. The
/// column is NOT NULL, so "no limit" is stored as 100 years from sign-in.
const sessionLifetime = Duration(days: 36500);

/// The authenticated caller. Only valid inside a route behind
/// [authMiddleware] — which is every route but the public ones.
AuthUser userOf(Request request) => request.context[_contextKey] as AuthUser;

/// 32 random bytes from the OS's secure generator, base64url-encoded.
String newSessionToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Only the hash is stored. A leaked copy of auth_sessions can't be replayed
/// as a login, the same reason passwords are stored hashed.
String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

Response _json(Object body, int status) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Reachable without logging in.
const _publicPaths = {
  'health',
  'auth/login',
  'auth/signup',
  // "Forgot Password?" — used by someone who can't log in.
  'auth/forgot-password',
  'auth/reset-password',
};

/// Everything a parent is allowed to call. Anything not listed is admin-only.
///
/// Being on this list only gets a parent through the door: each of these
/// handlers still narrows the data to the parent's own children, so a parent
/// can call GET /payments but only ever sees their own family's.
final _parentRoutes = <(String, RegExp)>[
  ('GET', RegExp(r'^categories$')),
  ('GET', RegExp(r'^players$')),
  ('POST', RegExp(r'^players$')),
  ('PUT', RegExp(r'^players/\d+$')),
  ('DELETE', RegExp(r'^players/\d+$')),
  // Their own child's awards: read and add; change or remove only the ones
  // they added (checked in awards_routes.dart).
  ('GET', RegExp(r'^players/\d+/awards$')),
  ('POST', RegExp(r'^players/\d+/awards$')),
  ('PUT', RegExp(r'^awards/\d+$')),
  ('DELETE', RegExp(r'^awards/\d+$')),
  ('GET', RegExp(r'^attendance-summary$')),
  ('GET', RegExp(r'^trainings$')),
  ('GET', RegExp(r'^tournaments$')),
  ('POST', RegExp(r'^tournaments/\d+/players/\d+/consent$')),
  ('DELETE', RegExp(r'^tournaments/\d+/players/\d+$')),
  // A tournament's standings and games, read only, for a tournament one of
  // their children is on (the routes check which).
  ('GET', RegExp(r'^tournaments/\d+/(opponents|games)$')),
  ('GET', RegExp(r'^sessions$')),
  ('GET', RegExp(r'^announcements$')),
  ('POST', RegExp(r'^announcements/\d+/read$')),
  ('GET', RegExp(r'^fee-settings$')),
  ('GET', RegExp(r'^payments$')),
  // A bill's own record (their receipts); the route checks it's theirs.
  ('GET', RegExp(r'^payments/\d+/transactions$')),
  ('POST', RegExp(r'^auth/delete-account$')),
  // Parents follow what's owed and paid; they don't pay in the app (the
  // club records payments, and in-app payment is not planned). These two
  // stay admin-only — they trust the amount they're sent:
  //   ('POST', RegExp(r'^payments/\d+/pay$')),
  //   ('POST', RegExp(r'^training-fees/pay$')),
  ('POST', RegExp(r'^training-fees/close$')),
  ('GET', RegExp(r'^training-fee-overrides$')),
  // Which jersey numbers are taken (numbers only, no names).
  ('GET', RegExp(r'^jersey-numbers$')),
  ('GET', RegExp(r'^order-items$')),
  ('GET', RegExp(r'^orders$')),
  ('POST', RegExp(r'^orders$')),
  ('POST', RegExp(r'^orders/\d+/cancel$')),
  ('PUT', RegExp(r'^users/\d+$')),
  ('POST', RegExp(r'^auth/logout$')),
  ('POST', RegExp(r'^auth/change-password$')),
  // Where to send this phone's notifications (lib/push.dart).
  ('POST', RegExp(r'^devices$')),
  // Their own account photo and their children's (the route checks which).
  ('GET', RegExp(r'^photos/(user|player)/\d+$')),
  ('PUT', RegExp(r'^photos/(user|player)/\d+$')),
  ('DELETE', RegExp(r'^photos/(user|player)/\d+$')),
];

/// Deliberately loose — something@something.something. Its job is catching
/// typos like a missing @, not policing what counts as a real address.
final emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

Middleware authMiddleware(Db db) {
  return (Handler inner) {
    return (Request request) async {
      final path = request.url.path;
      if (request.method == 'OPTIONS' || _publicPaths.contains(path)) {
        return inner(request);
      }

      final header = request.headers['authorization'] ?? '';
      final token = header.startsWith('Bearer ')
          ? header.substring(7).trim()
          : '';
      if (token.isEmpty) {
        return _json({'error': 'Please log in first.'}, 401);
      }

      // An account that's been rejected or reset to pending since logging in
      // loses access immediately, not when the token happens to expire.
      final found = await db.execute(
        'SELECT u.id, u.role, u.full_name, u.must_change_password '
        'FROM auth_sessions s '
        'JOIN users u ON u.id = s.user_id '
        "WHERE s.token_hash = :hash AND s.expires_at > NOW() "
        "AND u.status = 'approved'",
        {'hash': hashToken(token)},
      );
      if (found.rows.isEmpty) {
        return _json({
          'error': 'Your session has expired. Please log in again.',
        }, 401);
      }
      final row = found.rows.first.assoc();
      // The admin reset this password to a temporary one: nothing works
      // until the parent picks their own. Enforced here, not just in the
      // app, so an older app version can't skip it. 403, not 401 — a 401
      // makes the app sign the user out.
      if (row['must_change_password'] == '1' &&
          path != 'auth/change-password' &&
          path != 'auth/logout') {
        return _json({
          'error': 'Please choose a new password first.',
          'mustChangePassword': true,
        }, 403);
      }
      final user = AuthUser(
        id: int.parse(row['id']!),
        role: row['role']!,
        fullName: row['full_name']!,
      );

      if (!user.isAdmin &&
          !_parentRoutes.any(
            (route) => route.$1 == request.method && route.$2.hasMatch(path),
          )) {
        return _json({'error': 'Only an admin can do that.'}, 403);
      }

      return inner(request.change(context: {_contextKey: user}));
    };
  };
}

/// Whether [user] may act on this player: admins on any current player,
/// parents only on their own children. A player that isn't theirs reads as
/// "doesn't exist" rather than "forbidden", so ids can't be probed.
///
/// A removed player counts as gone for everyone, so nothing new (an order,
/// a payment, an edit) can be attached to them after removal. So does a
/// child still waiting on Player Validation, unless [includeUnapproved]:
/// only their own details, photo and removal are open before approval.
Future<bool> canAccessPlayer(
  Db db,
  AuthUser user,
  Object? playerId, {
  bool includeUnapproved = false,
}) async {
  final id = int.tryParse('$playerId');
  if (id == null) return false;
  final approved = includeUnapproved ? '' : ' AND is_approved = 1';
  final result = await db.execute(
    user.isAdmin
        ? 'SELECT id FROM players WHERE id = :id AND is_active = 1$approved'
        : 'SELECT id FROM players WHERE id = :id AND parent_id = :parentId '
              'AND is_active = 1$approved',
    {'id': id, if (!user.isAdmin) 'parentId': user.id},
  );
  return result.rows.isNotEmpty;
}

/// Same rule as [canAccessPlayer], for a payment (by its player).
Future<bool> canAccessPayment(Db db, AuthUser user, Object? paymentId) async {
  final id = int.tryParse('$paymentId');
  if (id == null) return false;
  final result = await db.execute(
    user.isAdmin
        ? 'SELECT id FROM payments WHERE id = :id'
        : 'SELECT pay.id FROM payments pay JOIN players p ON p.id = pay.player_id '
              'WHERE pay.id = :id AND p.parent_id = :parentId',
    {'id': id, if (!user.isAdmin) 'parentId': user.id},
  );
  return result.rows.isNotEmpty;
}
