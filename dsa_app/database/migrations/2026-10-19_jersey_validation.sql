-- =============================================================================
-- 2026-10-19 — jersey numbers: one per academy, duplicates by approval
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-14_order_received.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-19_jersey_validation.sql
--
-- A number used to be unique per birth year, enforced by a unique key. Now a
-- number is "taken" if any active player in the academy wears it, and a
-- family may still ask for a taken number: the request waits on the admin's
-- Player Validation screen. Approved duplicates are allowed, so the unique
-- key goes.
--
--   is_approved            0 = a NEW player whose taken number is waiting for
--                          (or was refused by) the admin. Not a real player
--                          yet: kept off rosters, bills, orders and lists.
--   jersey_request         the taken number the family asked for
--   jersey_request_status  'pending' (on Player Validation) or 'declined'
--   jersey_requested_at    when it was asked for (oldest first on the screen)
--
-- Safe to run: existing players stay approved with their numbers.
-- =============================================================================

ALTER TABLE players
  DROP INDEX uq_players_jersey_per_year,
  DROP COLUMN jersey_key,
  ADD COLUMN is_approved TINYINT(1) NOT NULL DEFAULT 1 AFTER is_active,
  ADD COLUMN jersey_request VARCHAR(10) NULL AFTER jersey_size,
  ADD COLUMN jersey_request_status ENUM('pending','declined') NULL
    AFTER jersey_request,
  ADD COLUMN jersey_requested_at DATETIME NULL AFTER jersey_request_status,
  ADD KEY idx_players_jersey_request (jersey_request_status);
