-- =============================================================================
-- 2026-10-09f — awards: a category
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-09d_award_league.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09f_award_category.sql
--
-- An award can name one of the academy's categories (B2013 ...), picked from
-- buttons under League. Optional; awards already given have none.
-- Safe to run: a new column only.
-- =============================================================================

ALTER TABLE player_awards
  ADD COLUMN category_id BIGINT UNSIGNED NULL AFTER league,
  ADD CONSTRAINT fk_player_awards_category
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE SET NULL;
