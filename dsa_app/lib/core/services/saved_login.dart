import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_api.dart';

/// "Keep me signed in": the login is kept in the phone's secure storage
/// (Android Keystore / iOS Keychain), so reopening the app goes straight to
/// Home instead of asking for the password again.
///
/// What's kept is the session token the server issued (it has no time limit;
/// the server can end it at any time) and the profile shown on the Account
/// screen. Never the password.
///
/// Every call is safe to make: secure storage can throw (a restored phone
/// backup the keys no longer match, a locked keystore), and none of that
/// should ever stop the app. A failure just means "not remembered".
class SavedLogin {
  static const _key = 'dsa_login_v1';
  static const _storage = FlutterSecureStorage();

  static Future<void> save(AuthUser user) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(user.toJson()));
    } catch (e) {
      debugPrint('Could not save the login: $e');
    }
  }

  static Future<AuthUser?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      final user = AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return user.token.isEmpty ? null : user;
    } catch (e) {
      debugPrint('Could not read the saved login: $e');
      // Unreadable (keys changed): drop it so it can't fail every launch.
      await clear();
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (e) {
      debugPrint('Could not clear the saved login: $e');
    }
  }
}
