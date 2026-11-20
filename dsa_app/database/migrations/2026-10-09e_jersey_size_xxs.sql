-- =============================================================================
-- 2026-10-09e — jersey sizes: XXS added
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-09b_jersey_sizes_xs.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09e_jersey_size_xxs.sql
--
-- The academy's sizes are XXS, XS, S, M, L and XL. Safe to run: it only adds
-- a size to the list; sizes already set are untouched.
-- =============================================================================

ALTER TABLE players
  MODIFY jersey_size ENUM('XXS','XS','S','M','L','XL') NULL;
