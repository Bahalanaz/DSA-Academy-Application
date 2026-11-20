-- =============================================================================
-- 2026-09-27 — default players for each training
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-27_training_default_players.sql
--
-- Trainings > a training > settings (top right) picks the players who go on
-- every NEW session of that training automatically, so the admin doesn't add
-- the same group each time. Each training has its own list. Changing it
-- never touches sessions already scheduled.
--
-- The GRANT gives the server's MySQL user the same rights as on the other
-- roster tables (app_user_grants.sql has it too).
-- =============================================================================

CREATE TABLE training_default_players (
  training_program_id  BIGINT UNSIGNED NOT NULL,
  player_id            BIGINT UNSIGNED NOT NULL,
  added_at             DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (training_program_id, player_id),
  KEY idx_training_default_players_player (player_id),
  CONSTRAINT fk_training_default_players_program
    FOREIGN KEY (training_program_id) REFERENCES training_programs (id)
    ON DELETE CASCADE,
  CONSTRAINT fk_training_default_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
) ENGINE = InnoDB;

GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.training_default_players
  TO 'dsa_app_user'@'localhost';
