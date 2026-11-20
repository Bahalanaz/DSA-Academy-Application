-- =============================================================================
-- 2026-09-26 (f) — messages to one family's account; two features removed
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26f_direct_messages.sql
--
--   * announcement_users: a message addressed to one parent account (Parent
--     Accounts > Send message). It reaches that account whether or not the
--     family has children registered, and nobody else.
--   * Removed at the club's request, with their data (none had been
--     entered): the emergency contact / medical notes on players, and the
--     automatic payment reminders. Any reminder already sent stays as an
--     ordinary message.
--
-- The GRANT gives the server's MySQL user the same rights on the new table
-- as on the other message tables (app_user_grants.sql has it too).
-- =============================================================================

ALTER TABLE players
  DROP COLUMN emergency_name,
  DROP COLUMN emergency_phone,
  DROP COLUMN medical_notes;

UPDATE announcements SET auto_kind = NULL WHERE auto_kind = 'payment_reminder';
ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed') NULL;

CREATE TABLE announcement_users (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  user_id          BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, user_id),
  KEY idx_announcement_users_user (user_id),
  CONSTRAINT fk_announcement_users_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_users_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;

GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.announcement_users
  TO 'dsa_app_user'@'localhost';
