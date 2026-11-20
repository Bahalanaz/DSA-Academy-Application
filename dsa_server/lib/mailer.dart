import 'dart:convert';

import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;

/// Sends email through Brevo (brevo.com, free plan: 300 emails a day) —
/// for now only the password-reset codes.
///
/// Configured in .env:
///   BREVO_API_KEY=...            Brevo > SMTP & API > API keys
///   MAIL_FROM_EMAIL=...          a sender verified in Brevo (Senders,
///                                domains & dedicated IPs)
///   MAIL_FROM_NAME=DSA Elite Academy
/// Until BREVO_API_KEY and MAIL_FROM_EMAIL are set, email is off and
/// "Forgot Password?" says so.
class Mailer {
  Mailer._();

  static String? _apiKey;
  static String? _fromEmail;
  static String _fromName = 'DSA Elite Academy';

  static bool get isConfigured => _apiKey != null && _fromEmail != null;

  static void configure(DotEnv env) {
    final key = (env['BREVO_API_KEY'] ?? '').trim();
    final from = (env['MAIL_FROM_EMAIL'] ?? '').trim();
    final name = (env['MAIL_FROM_NAME'] ?? '').trim();
    _apiKey = key.isEmpty ? null : key;
    _fromEmail = from.isEmpty ? null : from;
    if (name.isNotEmpty) _fromName = name;
    print(
      isConfigured
          ? 'Email: on (Brevo, from $_fromEmail).'
          : 'Email: off (BREVO_API_KEY / MAIL_FROM_EMAIL not set).',
    );
  }

  /// True when Brevo accepted the email for delivery.
  static Future<bool> send({
    required String toEmail,
    required String toName,
    required String subject,
    required String text,
    required String html,
  }) async {
    if (!isConfigured) return false;
    try {
      final response = await http
          .post(
            Uri.parse('https://api.brevo.com/v3/smtp/email'),
            headers: {
              'api-key': _apiKey!,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'sender': {'name': _fromName, 'email': _fromEmail},
              'to': [
                {'email': toEmail, 'name': toName},
              ],
              'subject': subject,
              'textContent': text,
              'htmlContent': html,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 200 && response.statusCode < 300) return true;
      print('Email: Brevo said ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
      print('Email: could not reach Brevo: $e');
      return false;
    }
  }
}
