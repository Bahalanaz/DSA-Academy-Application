-- =============================================================================
-- DSA Elite — privileges for the app's database user
-- =============================================================================
-- dsa_server connects as its own MySQL user, never as root, so a leaked server
-- config can't drop the database. Run this AFTER schema.sql, and after you
-- have created the user with a password of your own choosing:
--
--   CREATE USER 'dsa_app_user'@'localhost' IDENTIFIED BY '<your password>';
--
-- Put that same password in dsa_server/.env (DB_PASSWORD). Never write it in
-- this file — it is checked in alongside the code.
--
-- WHY PER TABLE, NEVER "ON dsa_db.*"
-- MySQL privileges add up. A single database-wide grant would override the
-- narrower payment_transactions grant below and hand the app DELETE on its own
-- money log, which is the one table that must only ever be appended to. That
-- is exactly how this was left open once before.
--
-- A NEW TABLE NEEDS ITS OWN GRANT LINE, or the app fails with
-- "command denied to user 'dsa_app_user'".
-- =============================================================================

-- Accounts and sessions
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.users TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.auth_sessions TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.device_tokens TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.profile_photos TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.password_resets TO 'dsa_app_user'@'localhost';

-- People and groups
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.categories TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.players TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.player_awards TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.training_programs TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.training_program_categories TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.tournaments TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.tournament_players TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.tournament_opponents TO 'dsa_app_user'@'localhost';

-- Calendar and attendance
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.sessions TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.session_players TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.training_default_players TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.attendance TO 'dsa_app_user'@'localhost';

-- Money
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.fee_settings TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.fee_rates TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.training_fee_overrides TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.payments TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.order_items TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.orders TO 'dsa_app_user'@'localhost';

-- The money log: append-only. SELECT and INSERT deliberately, nothing else, so
-- a recorded payment can never be edited or erased — only corrected by adding
-- another row (a refund, a reversal, a waiver).
GRANT SELECT, INSERT ON dsa_db.payment_transactions TO 'dsa_app_user'@'localhost';

-- Announcements
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcements TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_categories TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_trainings TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_tournaments TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_reads TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_players TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_sessions TO 'dsa_app_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_users TO 'dsa_app_user'@'localhost';

-- Views are read-only by nature; SELECT is all the app needs.
GRANT SELECT ON dsa_db.v_player_month_attendance TO 'dsa_app_user'@'localhost';
GRANT SELECT ON dsa_db.v_player_attendance_rate TO 'dsa_app_user'@'localhost';
GRANT SELECT ON dsa_db.v_session_roster TO 'dsa_app_user'@'localhost';

FLUSH PRIVILEGES;

-- Check what the user ended up with:
--   SHOW GRANTS FOR 'dsa_app_user'@'localhost';
