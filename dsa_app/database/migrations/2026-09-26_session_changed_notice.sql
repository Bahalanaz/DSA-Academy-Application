-- =============================================================================
-- 2026-09-26 — automatic "session changed" messages
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26_session_changed_notice.sql
--
-- When the admin edits a session (date, time, location, opponent), the server
-- messages the families of the players on it with what changed
-- (dsa_server/lib/notices.dart). Those messages are marked with a new
-- auto_kind, 'session_changed'.
--
-- Safe to run: it only adds a value to the list; existing rows are untouched.
-- =============================================================================

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed') NULL;
