-- =============================================================================
-- 2026-10-09b — jersey sizes: XS added, XXL removed
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-09_jersey_size.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-09b_jersey_sizes_xs.sql
--
-- The club's sizes are XS, S, M, L and XL. A player still on XXL would stop
-- this with an error rather than lose their size, so it's checked first:
-- move them to XL (or another size) by hand, then run it again.
-- =============================================================================

SELECT CONCAT('Players on XXL (must be 0): ', COUNT(*)) AS check_first
  FROM players WHERE jersey_size = 'XXL';

ALTER TABLE players
  MODIFY jersey_size ENUM('XS','S','M','L','XL') NULL;
