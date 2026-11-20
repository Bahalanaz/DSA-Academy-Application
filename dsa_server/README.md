# dsa_server

The REST API behind the app: Dart, [shelf](https://pub.dev/packages/shelf)
and MySQL 8. Compiles to a single native executable.

```
bin/server.dart       routing, auth middleware, start-up
lib/auth.dart         tokens, roles, which routes a parent may call
lib/db.dart           connection pool, transactions, named locks
lib/billing.dart      monthly training fees, closing a month
lib/ledger.dart       the append-only money history
lib/*_routes.dart     one file per area (players, sessions, tournaments…)
lib/push.dart         Firebase Cloud Messaging
lib/mailer.dart       password-reset emails through Brevo
test/                 rule tests and API tests
```

## Running

```bash
cp .env.example .env        # database settings; never committed
dart pub get
dart run bin/server.dart    # http://localhost:8080/health
```

Or start it together with MySQL using `docker compose up` from the
repository root. Firebase and email are optional: leave their settings empty
and those features are off.

## Tests

```bash
dart test                                        # rule tests; API tests skip
TEST_MYSQL_PASSWORD=<password> dart test         # everything
```

The API tests start the real server against a throwaway database,
`dsa_test`, rebuilt from `../dsa_app/database/schema.sql` on each run
(`TEST_MYSQL_HOST`, `TEST_MYSQL_PORT` and `TEST_MYSQL_USER` are optional).
They refuse to run against a database named `dsa_db`.
