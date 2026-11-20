import 'dart:async';

import 'package:http/http.dart' as http;

import '../services/api_client.dart' show ApiException;
import 'network_error_web.dart' if (dart.library.io) 'network_error_io.dart';

/// What people see when something goes wrong: plain sentences that say what
/// happened and what to do, never program names, status codes or field
/// names. Every screen shows errors through [friendlyError]; the messages for
/// a lost connection live here too so the app words them one way.

/// No internet, or the phone can't find the server.
const noConnectionMessage =
    "Connection lost. Please check your internet connection and try again.";

/// The connection is there but nothing came back in time.
const slowConnectionMessage =
    "The connection is too slow. Please check your internet connection and "
    "try again.";

/// The server is down, restarting, or being updated.
const unavailableMessage =
    "Service is temporarily unavailable. Please try again in a few minutes.";

/// A fault on our side the person can't fix.
const somethingWrongMessage = "Something went wrong. Please try again.";

/// The app sent something the server couldn't make sense of.
const checkEntryMessage =
    "Something isn't right with what was entered. Please check it and try "
    "again.";

/// The message to show for any failure.
///
/// An [ApiException] or an `Exception('...')` we threw ourselves already
/// carries a sentence meant for people; it's kept, apart from the few that
/// were written for developers. Anything else (a lost connection, bad data,
/// a bug) gets one of the standard messages above.
String friendlyError(Object error) {
  // A sentence a screen wrote itself ("…was added, but the photo couldn't
  // be saved"): already meant for people.
  if (error is String) return error;
  if (error is ApiException) return _tidy(error.message);
  if (error is TimeoutException) return slowConnectionMessage;
  if (error is http.ClientException || isNetworkError(error)) {
    return noConnectionMessage;
  }
  if (error is FormatException || error is Error) return somethingWrongMessage;

  final text = error.toString();
  // Our own `Exception('...')` reads "Exception: ..."; anything else that
  // reaches here (a plugin's error, say) isn't worded for people.
  if (!text.startsWith('Exception: ')) return somethingWrongMessage;
  return _tidy(text.substring('Exception: '.length));
}

/// "No order with that id" and friends, from a server message that was
/// written with a developer in mind.
final _missingThing = RegExp(
  r'^No (?:pending |active |deactivated )?(.+?) (?:with that id|here)$',
);

/// Field names ("playerId"), routes ("/training-fees"), formats ("YYYY") and
/// internal wording that mean nothing to a parent or a coach.
///
/// A field name starts lower case ("playerId", "paymentInfo"); a person's
/// name doesn't, so "McArthur is already on this account" is kept as is.
final _technical = RegExp(
  r'\b[a-z]+[A-Z]\w*|/|YYYY|^Unknown |must be (?:true|a list)|device token|'
  r'row is missing',
);

String _tidy(String message) {
  // The sign-in messages say "username/email". That's plain enough for
  // people, but the slash made the check below take it for a route, so a
  // mistyped password used to show "Something isn't right with what was
  // entered".
  final trimmed = message
      .trim()
      .replaceAll(
        'Invalid username/email or password',
        'Wrong username, email or password. Please try again.',
      )
      .replaceAll('Username/email', 'Username or email');
  if (trimmed.isEmpty) return somethingWrongMessage;

  final missing = _missingThing.firstMatch(trimmed);
  if (missing != null) {
    final what = missing.group(1)!;
    return what == 'photo'
        ? "There's no photo here yet."
        : "That $what is no longer available. Please refresh and try again.";
  }
  if (trimmed.startsWith('No category called')) {
    return "That category is no longer available. Please refresh and try "
        "again.";
  }
  if (_technical.hasMatch(trimmed)) return checkEntryMessage;
  return trimmed;
}
