import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../utils/friendly_error.dart';
import 'live_refresh.dart';
import 'session.dart';

/// A request the server refused.
///
/// [toString] keeps the "Exception: message" shape every screen already
/// trims for its SnackBar. [statusCode] and [body] are there for the few
/// callers that react to a specific refusal — a 409 saying a player still
/// owes money, for instance, carries the amount in [body].
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Map<String, dynamic> body;

  const ApiException(this.statusCode, this.message, [this.body = const {}]);

  @override
  String toString() => 'Exception: $message';
}

/// Shared plumbing for talking to the DSA server: builds the URL, sends the
/// session token, applies a timeout, and turns every failure into an
/// exception whose message is already fit to show in a SnackBar (screens
/// still pass it through friendlyError, which also covers anything else).
class ApiClient {
  static const _timeout = Duration(seconds: 10);

  /// Called once when the server says the login itself has ended — it
  /// expired, or the account was signed out elsewhere. main.dart sets this
  /// to send the user back to the start screen.
  static void Function(String message)? onSessionEnded;

  static Future<List<dynamic>> getList(String path) async {
    final response = await _send(() => http.get(_uri(path), headers: _headers));
    return jsonDecode(response.body) as List<dynamic>;
  }

  /// Raw bytes (a photo). Null when there's nothing there (404).
  static Future<Uint8List?> getBytes(String path) async {
    try {
      final response = await _send(
        () => http.get(_uri(path), headers: _headers),
      );
      return response.bodyBytes;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> getMap(String path) async {
    final response = await _send(() => http.get(_uri(path), headers: _headers));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final response = await _send(
      () => http.post(_uri(path), headers: _headers, body: jsonEncode(body)),
      change: true,
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _send(
      () => http.put(_uri(path), headers: _headers, body: jsonEncode(body)),
      change: true,
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> delete(String path) =>
      _send(() => http.delete(_uri(path), headers: _headers), change: true);

  /// For the deletes that report back what else they changed — removing a
  /// tournament player also withdraws their unpaid fee, and the caller
  /// needs to know that happened.
  static Future<Map<String, dynamic>> deleteJson(String path) async {
    final response = await _send(
      () => http.delete(_uri(path), headers: _headers),
      change: true,
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Uri _uri(String path) => Uri.parse('${ApiConfig.baseUrl}$path');

  /// Every request carries the logged-in user's token; the server rejects
  /// anything without one (except login and signup).
  static Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (Session.token != null) 'Authorization': 'Bearer ${Session.token}',
  };

  /// [change] is true for anything that writes (POST, PUT, DELETE).
  static Future<http.Response> _send(
    Future<http.Response> Function() request, {
    bool change = false,
  }) async {
    late final http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on TimeoutException {
      throw ApiException(0, slowConnectionMessage);
    } catch (_) {
      throw ApiException(0, noConnectionMessage);
    }
    if (response.statusCode >= 400) {
      final body = _bodyOf(response);
      // The server doesn't know this request at all: it's running older
      // code than this app (it wasn't restarted after an update).
      final outOfDate =
          response.statusCode == 404 &&
          response.body.trim() == 'Route not found';
      // 502/503/504 come from the web front door when the server behind it
      // is down or restarting, with no message of our own.
      final unavailable = const [502, 503, 504].contains(response.statusCode);
      final message = outOfDate || unavailable
          ? unavailableMessage
          : body['error'] as String? ?? somethingWrongMessage;
      // A 401 means the login has ended, not just that this request failed.
      // Without this the app stayed on the same screen and every action
      // failed with the same message until the app was restarted.
      // Clearing the session first means the requests still in flight come
      // back without a token and don't trigger this a second time.
      if (response.statusCode == 401 && Session.token != null) {
        Session.clear();
        onSessionEnded?.call(message);
      }
      // A change refused as a conflict (409: "already paid", "already
      // billed") or about something that's gone (404) usually means another
      // phone or admin got there first. Reload the screen in front straight
      // away, once the error has shown, rather than leave the old figures up
      // until the next scheduled refresh.
      if (change &&
          (response.statusCode == 409 || response.statusCode == 404)) {
        Future.delayed(const Duration(milliseconds: 800), LiveRefresh.now);
      }
      throw ApiException(response.statusCode, message, body);
    }
    return response;
  }

  static Map<String, dynamic> _bodyOf(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}

/// MySQL hands back every column as a String over this connector, so the
/// parsing helpers all start from String?.
int asInt(Object? value) => int.tryParse('$value') ?? 0;

/// DECIMAL columns arrive as strings like "31.25".
double asDouble(Object? value) => double.tryParse('$value') ?? 0;

/// DATE ("2026-09-01") and DATETIME ("2026-09-01 17:30:00") columns, both
/// of which DateTime.parse handles. Null stays null rather than becoming
/// some stand-in date — a missing paid_at means genuinely unpaid.
DateTime? asDate(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse('$value');
}

/// A list of strings from either a JSON array (rosters now come as real
/// arrays, so names containing commas survive) or a GROUP_CONCAT string like
/// "B2012,B2013" — or NULL when there are no rows.
List<String> asCsvList(Object? value) {
  if (value is List) return [for (final item in value) '$item'];
  final text = value as String?;
  if (text == null || text.isEmpty) return [];
  return text.split(',');
}

/// A GROUP_CONCAT of ids ("3,7,12") as ints.
List<int> asIdList(Object? value) =>
    asCsvList(value).map(int.tryParse).whereType<int>().toList();
