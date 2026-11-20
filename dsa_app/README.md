# dsa_app

The Flutter app for families and coaches. One codebase builds the Android
app and the web version (installable on iPhone and laptops).

```
lib/
  main.dart                 start-up, saved sign-in, routing by role
  core/config/              API address and Firebase web settings
  core/services/            API client, push notifications, saved login, updates
  core/theme/               colours and text styles
  core/widgets/             shared widgets (jersey picker, bill descriptions…)
  core/utils/               training-fee and date rules
  features/auth/            sign in, sign up, forgot password
  features/admin/           the academy's screens and models
  features/parent/          the families' screens
database/
  schema.sql                the whole database, with seed config rows
  migrations/               dated changes applied to an existing database
  app_user_grants.sql       the server's limited MySQL user
  seed_test_data.sql        made-up families for local testing
test/                       unit and widget tests
```

## Running

The app talks to `http://localhost:8080` unless told otherwise:

```bash
flutter pub get
flutter run -d chrome
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080   # Android emulator
flutter test
```

Start the backend first (see the [main README](../README.md)).

## Push notifications (optional)

Without Firebase the app works normally and simply shows no notifications.
To turn them on with your own Firebase project:

- **Android:** download `google-services.json` into `android/app/` (it is
  gitignored). The Google Services Gradle plugin is applied only when that
  file exists.
- **Web:** fill in the placeholders in `lib/core/config/firebase_web.dart`
  and `web/firebase-messaging-sw.js`.
- **Server:** set `FIREBASE_SERVICE_ACCOUNT` in `dsa_server/.env`.

## Release signing

Release builds are signed with a key described by `android/key.properties`
(see `key.properties.example`). Neither the key nor that file is ever
committed; without them the build falls back to the debug key.
