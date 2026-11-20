-- =============================================================================
-- 2026-09-26 (c) — several quick edits to a session make ONE message
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26c_session_change_folding.sql
--
-- Editing a session messages its families with what changed. Fixing the
-- time and then fixing it again a minute later sent two messages, and
-- changing it and changing it straight back still sent one saying it had
-- changed. The "session changed" message now keeps the session as it was
-- before the FIRST edit (was_json); another edit within 30 minutes rewrites
-- that same message against it, and takes the message back if the session
-- ends up exactly as it was.
--
-- Safe to run: adds one nullable column; existing rows are untouched.
-- =============================================================================

ALTER TABLE announcement_sessions
  ADD COLUMN was_json TEXT NULL;
