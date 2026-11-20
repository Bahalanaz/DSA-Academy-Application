import 'auth_api.dart';
import 'saved_login.dart';

/// Who is currently logged in, for the lifetime of this app run.
///
/// Set on a successful login, cleared on logout. With "keep me signed in"
/// the login is also kept in secure storage (SavedLogin) and put back here
/// when the app starts. The session token inside [current] is what every
/// server request is authorised with.
class Session {
  static AuthUser? current;

  static bool get isLoggedIn => current != null;
  static bool get isAdmin => current?.isAdmin ?? false;

  /// Sent as `Authorization: Bearer <token>` by ApiClient.
  static String? get token => current?.token;

  /// The logged-in user's id — used as parent_id when this parent adds a
  /// player. Throws rather than silently writing an orphaned row.
  static int get requireUserId {
    final user = current;
    if (user == null) {
      throw Exception('Not logged in');
    }
    return user.id;
  }

  /// Also forgets the remembered login: logging out, an ended session and
  /// a deleted account must all mean the next launch asks for a password.
  static void clear() {
    current = null;
    SavedLogin.clear();
  }
}
