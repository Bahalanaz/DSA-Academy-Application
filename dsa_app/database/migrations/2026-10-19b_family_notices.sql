-- =============================================================================
-- 2026-10-19b — automatic messages: jersey number decisions, kit handed over
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-19_jersey_validation.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-19b_family_notices.sql
--
-- Families used to find out only by opening the app. Now the server sends a
-- message (and a push notification) when:
--   jersey_number  the admin approves or declines a jersey number they asked for
--   order_given    the admin marks an order as handed over
-- Safe to run: two new values on the end of the list.
-- =============================================================================

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed','sessions_added',
                        'jersey_number','order_given') NULL;
