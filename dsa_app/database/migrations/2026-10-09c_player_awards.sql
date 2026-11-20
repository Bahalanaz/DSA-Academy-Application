-- =============================================================================
-- 2026-10-09c — player awards
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql (and
-- app_user_grants.sql) already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09c_player_awards.sql
--
-- The admin can give a player awards (title, description, date) from the
-- Player Profile's AWARDS tab; parents see their own children's there.
-- Safe to run: a new table only, nothing existing is touched.
-- =============================================================================
-- Awards a player has received (MVP of a tournament, Most Improved ...).
-- The admin adds, edits and removes them; parents see their own children's
-- on the Player Profile's AWARDS tab. Kept when a player is removed (the
-- player row is soft-deleted), gone only if the player row itself is.
CREATE TABLE player_awards (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  player_id    BIGINT UNSIGNED NOT NULL,
  title        VARCHAR(120)    NOT NULL,
  description  VARCHAR(1000)       NULL,
  award_date   DATE            NOT NULL,
  created_by   BIGINT UNSIGNED     NULL,   -- the admin who added it
  created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_player_awards_player (player_id, award_date),
  CONSTRAINT fk_player_awards_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_player_awards_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT chk_player_awards_title CHECK (CHAR_LENGTH(TRIM(title)) > 0)
) ENGINE = InnoDB;

-- The app's database user needs its own grant for a new table.
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.player_awards TO 'dsa_app_user'@'localhost';
