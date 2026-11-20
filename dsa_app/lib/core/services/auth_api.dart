import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../utils/friendly_error.dart';
import 'api_client.dart';
import 'saved_login.dart';
import 'session.dart';

/// The signed-in user, as returned by /auth/login, including the session
/// token every later request is authorised with.
class AuthUser {
  final int id;
  final String role;
  final String fullName;
  final String username;
  final String email;
  final String? phone;
  final String token;

  /// Where their account photo loads from, or null.
  final String? photoUrl;

  /// The admin reset this password to a temporary one: a new one has to be
  /// chosen before anything else (the server refuses everything else).
  final bool mustChangePassword;

  AuthUser({
    required this.id,
    required this.role,
    required this.fullName,
    required this.username,
    required this.email,
    this.phone,
    required this.token,
    this.photoUrl,
    this.mustChangePassword = false,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as int,
    role: json['role'] as String,
    fullName: json['fullName'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
    phone: json['phone'] as String?,
    token: json['token'] as String? ?? '',
    photoUrl: json['photoUrl'] as String?,
    mustChangePassword: json['mustChangePassword'] == true,
  );

  /// What's kept for "keep me signed in" (see SavedLogin).
  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'fullName': fullName,
    'username': username,
    'email': email,
    'phone': phone,
    'token': token,
    'photoUrl': photoUrl,
  };

  bool get isAdmin => role == 'admin';
}

/// Thin wrapper around the server's /auth endpoints. Every failure path
/// (validation, wrong password, pending approval, unreachable server)
/// surfaces as an exception with a message that's already fine to show
/// directly in a SnackBar.
class AuthApi {
  static Future<void> signUp({
    required String username,
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    final response = await _post('/auth/signup', {
      'username': username,
      'fullName': fullName,
      'email': email,
      'phone': phone,
      'password': password,
    });
    if (response.statusCode != 201) {
      throw Exception(_errorMessage(response));
    }
  }

  static Future<AuthUser> logIn({
    required String identifier,
    required String password,
  }) async {
    final response = await _post('/auth/login', {
      'identifier': identifier,
      'password': password,
    });
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    return AuthUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// "Forgot Password?" step 1: emails a 6-digit code to the account's
  /// email. The server answers the same whether or not the account exists.
  /// Returns how many more codes may be asked for this hour (3 an hour); the
  /// 4th throws with how many minutes are left.
  static Future<int> forgotPassword({required String identifier}) async {
    final response = await _post('/auth/forgot-password', {
      'identifier': identifier,
    });
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    final body = jsonDecode(response.body);
    return body is Map ? (body['codesLeft'] as int? ?? 0) : 0;
  }

  /// Step 2: the code from the email and the new password. Every phone
  /// signed in to the account is signed out.
  static Future<void> resetPassword({
    required String identifier,
    required String code,
    required String newPassword,
  }) async {
    final response = await _post('/auth/reset-password', {
      'identifier': identifier,
      'code': code,
      'newPassword': newPassword,
    });
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
  }

  /// Ends the session on the server so the token stops working, then
  /// forgets it locally.
  ///
  /// The session is cleared FIRST, before the network call: otherwise a
  /// slow logout request finishing after someone has already logged in
  /// again would wipe out the new login.
  static Future<void> logOut() async {
    final token = Session.token;
    Session.clear();
    if (token == null || token.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/auth/logout'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best effort: the token expires on its own anyway.
    }
  }

  /// Saves the Account screen's profile fields. Can't change role or
  /// status — the server refuses to touch those from here.
  /// [username] only from the admin Account screen (the server ignores it
  /// from anyone else); left null, the username stays as it is.
  static Future<void> updateProfile({
    required int userId,
    required String fullName,
    required String email,
    required String phone,
    String? username,
  }) async {
    await ApiClient.put('/users/$userId', {
      'fullName': fullName,
      'email': email,
      'phone': phone,
      'username': ?username,
    });
    // Keep the in-memory session in step with what was just saved.
    final user = Session.current;
    if (user != null) {
      Session.current = AuthUser(
        id: user.id,
        role: user.role,
        fullName: fullName,
        username: username ?? user.username,
        email: email,
        phone: phone,
        token: user.token,
        photoUrl: user.photoUrl,
      );
      // The remembered profile follows, so it isn't the old one next launch.
      if (await SavedLogin.read() != null) {
        await SavedLogin.save(Session.current!);
      }
    }
  }

  /// After a new account photo is saved ('' = removed): this run and the
  /// remembered login both show it.
  static Future<void> setPhotoUrl(String url) async {
    final user = Session.current;
    if (user == null) return;
    Session.current = AuthUser(
      id: user.id,
      role: user.role,
      fullName: user.fullName,
      username: user.username,
      email: user.email,
      phone: user.phone,
      token: user.token,
      photoUrl: url.isEmpty ? null : url,
    );
    if (await SavedLogin.read() != null) {
      await SavedLogin.save(Session.current!);
    }
  }

  /// Changes the logged-in user's password. The server signs out every
  /// other device on the account; this one stays signed in.
  static Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await ApiClient.post('/auth/change-password', {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
  }

  /// Deletes the signed-in parent's account (the server refuses while money
  /// is owed or credit is held). Signed out here once it's done.
  static Future<void> deleteAccount({required String password}) async {
    await ApiClient.post('/auth/delete-account', {'password': password});
    Session.clear();
  }

  static Future<http.Response> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw ApiException(0, slowConnectionMessage);
    } catch (_) {
      throw ApiException(0, noConnectionMessage);
    }
  }

  static String _errorMessage(http.Response response) {
    // The web front door answers 502/503/504 when the server behind it is
    // down or restarting.
    if (const [502, 503, 504].contains(response.statusCode)) {
      return unavailableMessage;
    }
    try {
      final body = jsonDecode(response.body) as Map;
      return body['error'] as String? ?? somethingWrongMessage;
    } catch (_) {
      return somethingWrongMessage;
    }
  }
}
