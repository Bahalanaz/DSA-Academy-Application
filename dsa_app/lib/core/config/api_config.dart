/// Where the Flutter app finds the dsa_server backend.
///
/// Chosen when the app is built, so the same code serves every target:
///   - by default: a server on the same machine (`docker compose up`, or
///     `dart run bin/server.dart` in dsa_server).
///   - the Android emulator reaches its host computer as 10.0.2.2:
///       `--dart-define=API_BASE_URL=http://10.0.2.2:8080`
///   - a real deployment: `--dart-define=API_BASE_URL=https://your-server`
class ApiConfig {
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: "http://localhost:8080",
  );
}
