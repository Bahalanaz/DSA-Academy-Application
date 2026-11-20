-- =============================================================================
-- 2026-10-04c — password reset by email code
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-04c_password_reset_codes.sql
--
-- "Forgot Password?" emails a 6-digit code (dsa_server/lib/auth_routes.dart,
-- sent through Brevo). password_resets already held one row per request;
-- token_hash now stores the code's hash. This adds how many wrong codes
-- have been tried against a request: after 5 it stops working, so a
-- 6-digit code can't be guessed.
-- =============================================================================

ALTER TABLE password_resets
  ADD COLUMN attempts TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER expires_at;
