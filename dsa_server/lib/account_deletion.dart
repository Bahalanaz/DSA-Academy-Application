import 'package:bcrypt/bcrypt.dart';
import 'package:mysql_client/mysql_client.dart';

import 'auth.dart';
import 'billing.dart';
import 'ledger.dart';

/// Deletes a parent account for good: the family deleting their own
/// (POST /auth/delete-account) or the admin deleting it for them
/// (POST /admin/users/<id>/delete). One set of rules for both.
///
/// Refused while the family owes anything or the club holds training credit
/// for them — that money has to be settled first. Otherwise the account is
/// anonymised rather than erased: name, username, email, phone and photo are
/// replaced, the password stops working, and every device is signed out.
/// Their children come off the club's lists, upcoming rosters, live
/// tournaments and training defaults. Bills and payments stay, linked to the
/// children, because the club's accounts have to keep them. The same email
/// and username can be used to sign up again.
///
/// Run inside [withMoneyLock], so a payment recorded at the same moment
/// can't slip past the "nothing owed" check. Throws [LedgerError] with a
/// message worded for whoever asked ([byAdmin]).
Future<void> deleteParentAccount(
  MySQLConnection conn,
  int uid, {
  required bool byAdmin,
}) async {
  // Still there, still a parent, not deleted already (another phone may
  // have got there first). The id is an integer, written in.
  final found = await conn.execute(
    'SELECT role, deleted_at FROM users WHERE id = $uid FOR UPDATE',
  );
  if (found.rows.isEmpty ||
      found.rows.first.assoc()['role'] != 'parent' ||
      found.rows.first.assoc()['deleted_at'] != null) {
    throw const LedgerError('No parent account with that id', 404);
  }

  await reconcilePastMonths(conn);
  final positions = await openPositions(conn, parentId: uid);
  final owed = positions.owed.fold<num>(0, (sum, i) => sum + i.amount);
  if (cents(owed) > 0) {
    throw LedgerError(
      byAdmin
          ? 'This family still owes AED ${money(owed)}. Record or waive it '
                'on Payments first, then delete the account.'
          : 'Your children still have AED ${money(owed)} to pay. Please '
                'settle it with the academy before deleting your account.',
      409,
    );
  }
  final credit = positions.credit.values.fold<num>(0, (a, b) => a + b);
  if (cents(credit) > 0) {
    throw LedgerError(
      byAdmin
          ? 'The academy is holding AED ${money(credit)} of training credit for '
                'this family. Refund it on Payments first, then delete the '
                'account.'
          : 'The academy is holding AED ${money(credit)} of training credit for '
                'your children. Please ask the academy to refund it before '
                'deleting your account.',
      409,
    );
  }

  final kids = 'SELECT id FROM players WHERE parent_id = $uid';
  await conn.execute(
    "DELETE FROM orders WHERE status = 'pending' AND player_id IN ($kids)",
  );
  await conn.execute(
    'DELETE a FROM attendance a JOIN sessions s ON s.id = a.session_id '
    'WHERE s.session_date > CURRENT_DATE AND a.player_id IN ($kids)',
  );
  await conn.execute(
    'DELETE sp FROM session_players sp '
    'JOIN sessions s ON s.id = sp.session_id '
    'WHERE s.session_date > CURRENT_DATE AND sp.player_id IN ($kids)',
  );
  // Off live tournaments, unless a fee stands for it (that's money on
  // record, and stays with the tournament).
  await conn.execute('''
    DELETE tp FROM tournament_players tp
    JOIN tournaments t ON t.id = tp.tournament_id
    WHERE t.deleted_at IS NULL AND tp.player_id IN ($kids)
      AND NOT EXISTS (
        SELECT 1 FROM payments pay
        WHERE pay.tournament_id = tp.tournament_id
          AND pay.player_id = tp.player_id
          AND pay.status IN ('pending','paid'))
  ''');
  await conn.execute(
    'DELETE FROM training_default_players WHERE player_id IN ($kids)',
  );
  // Their photo and their children's photos go with the account.
  await conn.execute(
    "DELETE FROM profile_photos WHERE (kind = 'user' AND owner_id = $uid) "
    "OR (kind = 'player' AND owner_id IN ($kids))",
  );
  await conn.execute(
    'UPDATE players SET photo_url = NULL WHERE parent_id = $uid',
  );
  await conn.execute('UPDATE players SET is_active = 0 WHERE parent_id = $uid');
  await conn.execute(
    "UPDATE users SET full_name = 'Deleted account', "
    "username = CONCAT('deleted_', id), "
    "email = CONCAT('deleted_', id, '@deleted.invalid'), "
    "phone = NULL, photo_url = NULL, password_hash = :hash, "
    "status = 'disabled', must_change_password = 0, deleted_at = NOW() "
    'WHERE id = :id',
    {
      'id': uid,
      // Nobody knows this password: the account can't be signed into.
      'hash': BCrypt.hashpw(newSessionToken(), BCrypt.gensalt()),
    },
  );
  await conn.execute('DELETE FROM password_resets WHERE user_id = $uid');
  await conn.execute('DELETE FROM auth_sessions WHERE user_id = $uid');
}
