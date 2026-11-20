import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// This APK's build number (the "+21" of "1.0.20+21" in pubspec.yaml), set
/// by the release build script. 0 in a debug build: never offered an update.
const appBuild = int.fromEnvironment('APP_BUILD');

/// A newer family APK on the server: published next to it as
/// /download/version.json by the publish script.
class AppUpdate {
  final int build;
  final String version;
  final String url;

  const AppUpdate({
    required this.build,
    required this.version,
    required this.url,
  });
}

Future<AppUpdate?>? _check;

/// The newer version, or null if this one is the latest (or it can't be
/// told: no connection, nothing published yet, a debug build). Asked once
/// per app run.
Future<AppUpdate?> checkForAppUpdate() => _check ??= _fetch();

Future<AppUpdate?> _fetch() async {
  // The web version is always the newest (the server hands out whatever was
  // published last), and an iPhone can't install an APK anyway.
  if (kIsWeb || appBuild <= 0) return null;
  try {
    final response = await http
        .get(Uri.parse('${ApiConfig.baseUrl}/download/version.json'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final build = int.tryParse('${body['build']}') ?? 0;
    final url = '${body['url'] ?? ''}';
    if (build <= appBuild || !url.startsWith('https://')) return null;
    return AppUpdate(build: build, version: '${body['version']}', url: url);
  } catch (_) {
    // Offline or unreadable: just no banner this time.
    _check = null;
    return null;
  }
}

/// Opens the download link in the phone's browser (Android: MainActivity's
/// "dsa/settings" channel). False if it couldn't.
Future<bool> openAppDownload(String url) async {
  try {
    return await const MethodChannel('dsa/settings')
            .invokeMethod<bool>('openUrl', {'url': url}) ??
        false;
  } catch (_) {
    return false;
  }
}
