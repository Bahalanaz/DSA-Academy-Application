-- =============================================================================
-- 2026-10-05 — automatic "new training / new game" messages
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-05_sessions_added_notice.sql
--
-- When the admin schedules a session, or puts a child on one, the families
-- of the players on it get a message (and so a push notification) saying
-- when and where (dsa_server/lib/notices.dart). Those messages are marked
-- with a new auto_kind, 'sessions_added'.
--
-- Safe to run: it only adds a value to the list; existing rows are untouched.
-- =============================================================================

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed','sessions_added') NULL;
