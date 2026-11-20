-- =============================================================================
-- 2026-10-09 — players' jersey (shirt) size
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09_jersey_size.sql
--
-- Each player can have a shirt size, S, M, L, XL or XXL, chosen when the
-- player is added (or edited later). Order validation shows it next to the
-- player, so the admin knows which size to hand out. Players added before
-- this have none (NULL) until someone sets it.
--
-- Safe to run: it only adds a column; existing rows are untouched.
-- =============================================================================

ALTER TABLE players
  ADD COLUMN jersey_size ENUM('S','M','L','XL','XXL') NULL AFTER jersey_number;
