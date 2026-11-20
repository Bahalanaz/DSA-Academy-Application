-- November 2026 batch, part 3. Run AFTER 2026-11-11_nickname_birthday.sql.
-- Safe on a live database: only adds a table and two empty columns, and the
-- families' 1.0.23 app never reads any of them.
--
-- 1. A tournament's opposing teams, added by the academy on the tournament's
--    Standings screen. A game on the schedule picks its opponent from here
--    (saved on the game as 'vs. <name>', the same as before).
-- 2. A game's final score (DSA's points and the opponent's), entered after
--    it's played. The winner and each team's standing (games won by DSA and
--    by them) are counted from these, never typed.
--
-- Back up first, then:
--   sudo mysql --default-character-set=utf8mb4 dsa_db < 2026-11-11b_tournament_opponents.sql

CREATE TABLE tournament_opponents (
  id             BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  tournament_id  BIGINT UNSIGNED   NOT NULL,
  name           VARCHAR(40)       NOT NULL,
  created_at     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tournament_opponents_name (tournament_id, name),
  CONSTRAINT fk_tournament_opponents_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE CASCADE
) ENGINE = InnoDB;

ALTER TABLE sessions
  ADD COLUMN dsa_score      SMALLINT UNSIGNED NULL AFTER opponent,
  ADD COLUMN opponent_score SMALLINT UNSIGNED NULL AFTER dsa_score;

-- The server's own database login has rights table by table
-- (app_user_grants.sql), so a new table needs its own grant, or every
-- Standings screen fails with "SELECT command denied".
GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.tournament_opponents
  TO 'dsa_app_user'@'localhost';
