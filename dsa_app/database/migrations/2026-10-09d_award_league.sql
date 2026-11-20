-- =============================================================================
-- 2026-10-09d — awards: "description" becomes "league"
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-09c_player_awards.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09d_award_league.sql
--
-- An award records the league it was won in instead of a free description.
-- The column is renamed, so anything already typed is kept as the league.
-- A description longer than 120 characters would stop this with an error
-- rather than be cut short: shorten it first.
-- =============================================================================

SELECT CONCAT('Awards with more than 120 characters (must be 0): ', COUNT(*))
         AS check_first
  FROM player_awards WHERE CHAR_LENGTH(description) > 120;

ALTER TABLE player_awards
  CHANGE COLUMN description league VARCHAR(120) NULL;
