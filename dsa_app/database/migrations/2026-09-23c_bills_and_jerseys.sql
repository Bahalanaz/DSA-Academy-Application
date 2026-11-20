-- =============================================================================
-- 2026-09-23 (c) — no AED 0.00 open bills; one jersey number per birth year
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has all of this.
--
-- Run as root, with the UTF-8 flag (see 2026-09-23b for why):
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-23c_bills_and_jerseys.sql
--
-- Both are also checked in the server, which says why in words; these are
-- the net underneath.
--
-- Verify first (both must be 0):
--   SELECT COUNT(*) FROM payments WHERE status = 'pending' AND amount = 0;
--   SELECT COUNT(*) FROM (SELECT YEAR(birthday), CAST(jersey_number AS UNSIGNED)
--     FROM players WHERE is_active = 1 AND jersey_number REGEXP '^[0-9]+$'
--     GROUP BY 1, 2 HAVING COUNT(*) > 1) x;
-- =============================================================================

-- A bill still open for AED 0.00 can never be paid (a payment must be more
-- than zero) or waived (there's nothing left to waive), so it would sit on a
-- family's list forever. An amount like 0.001 used to be accepted, stored as
-- 0.00, and do exactly that.
ALTER TABLE payments
  ADD CONSTRAINT chk_payments_open_amount CHECK (status <> 'pending' OR amount > 0);

-- Two active players born the same year are in the same squad, and can't
-- share a shirt number (kit orders read "Born 2013 · Jersey #7"). Numbers
-- compare as numbers, so 07 and 7 are the same shirt. NULL — and so ignored
-- by the index — for removed players and players without a number.
ALTER TABLE players
  ADD COLUMN jersey_key VARCHAR(20) GENERATED ALWAYS AS (
    CASE WHEN is_active = 1 AND jersey_number REGEXP '^[0-9]+$'
         THEN CONCAT(YEAR(birthday), '|', CAST(jersey_number AS UNSIGNED)) END
  ) VIRTUAL,
  ADD UNIQUE KEY uq_players_jersey_per_year (jersey_key);
