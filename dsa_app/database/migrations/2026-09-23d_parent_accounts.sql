-- =============================================================================
-- 2026-09-23 (d) — parent accounts: deactivate, and admin password reset
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has all of this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-23d_parent_accounts.sql
--
-- 1. users.status 'disabled'
--    An approved account could never be switched off: a family that left, or
--    a login that shouldn't work any more, kept full access. 'disabled' is
--    reversible (reactivate) and keeps the family's children, bills and
--    history exactly as they are. The server only lets 'approved' accounts
--    through, so a disabled account's open sessions stop working at once.
--
-- 2. users.must_change_password
--    "Forgot password" had nothing behind it: no email service, and the admin
--    had no way to help either. The admin can now reset a parent's password
--    to a one-time temporary one; this flag makes the parent choose their own
--    at the next login before they can do anything else.
-- =============================================================================

ALTER TABLE users
  MODIFY status ENUM('pending','approved','rejected','disabled')
    NOT NULL DEFAULT 'pending',
  ADD COLUMN must_change_password TINYINT(1) NOT NULL DEFAULT 0 AFTER password_hash;
