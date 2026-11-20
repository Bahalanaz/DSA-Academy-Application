-- =============================================================================
-- 2026-09-23 — training credit, tournament consent, cancellation notices
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or
-- a restore from dsa_db_dump.sql already has all of this.
--
-- Run as root:  mysql -u root -p dsa_db < 2026-09-23_credit_consent_notices.sql
--
-- 1. method 'credit'
--    Money paid beyond what a month's training fee came to is carried to the
--    next training fee automatically. It moves as a pair of ledger rows — out
--    of the month it was overpaid in, into the one it pays — both marked
--    method 'credit', so the log still accounts for every fil and
--    payments.amount_paid still equals the sum of each bill's rows.
--
-- 2. tournament_players.consent
--    Adding a child to a tournament is now an invitation. The parent accepts
--    or declines from the app, and the tournament can't be priced or billed
--    until every player on it has accepted. Rows that already exist are
--    marked accepted: those families were billed under the old flow.
--
-- 3. announcement_players
--    Cancelling sessions or a tournament messages exactly the players who
--    were on them. A frozen recipient list, unlike the training/tournament
--    audiences (which are resolved when read): the people affected by a
--    cancellation are the ones rostered when it happened.
-- =============================================================================

ALTER TABLE payments
  MODIFY method ENUM('cash','card','bank','online_test','stripe','other','credit') NULL;

ALTER TABLE payment_transactions
  MODIFY method ENUM('cash','card','bank','online_test','stripe','other','credit') NULL;

ALTER TABLE tournament_players
  ADD COLUMN consent ENUM('pending','accepted','declined') NOT NULL DEFAULT 'pending'
    AFTER amount,
  ADD COLUMN responded_at DATETIME NULL AFTER consent,
  ADD COLUMN responded_by BIGINT UNSIGNED NULL AFTER responded_at,
  ADD CONSTRAINT fk_tournament_players_responded_by
    FOREIGN KEY (responded_by) REFERENCES users (id) ON DELETE SET NULL;

UPDATE tournament_players SET consent = 'accepted', responded_at = added_at;

CREATE TABLE announcement_players (
  announcement_id BIGINT UNSIGNED NOT NULL,
  player_id       BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, player_id),
  KEY idx_announcement_players_player (player_id),
  CONSTRAINT fk_announcement_players_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A new table needs its own grant (see app_user_grants.sql).
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_players
  TO 'dsa_app_user'@'localhost';

-- 4. What an automatic notice is about, so later cancellations can be folded
--    into it instead of sending one message per session: cancelling the
--    13th, 14th and 15th one after another ends up as one message listing
--    all three.
ALTER TABLE announcements
  ADD COLUMN auto_kind ENUM('sessions_cancelled','tournament_cancelled') NULL
    AFTER is_everyone;

CREATE TABLE announcement_sessions (
  announcement_id BIGINT UNSIGNED NOT NULL,
  session_id      BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, session_id),
  KEY idx_announcement_sessions_session (session_id),
  CONSTRAINT fk_announcement_sessions_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_sessions_session
    FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_sessions
  TO 'dsa_app_user'@'localhost';

SELECT 'tournament rows marked accepted' AS check_name, COUNT(*) AS result
FROM tournament_players WHERE consent = 'accepted'
UNION ALL
SELECT 'announcement_players exists', COUNT(*) FROM information_schema.tables
WHERE table_schema = 'dsa_db' AND table_name = 'announcement_players';
