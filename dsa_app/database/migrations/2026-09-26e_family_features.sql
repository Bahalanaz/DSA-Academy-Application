-- =============================================================================
-- 2026-09-26 (e) — safety details, account deletion, payment reminders
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26e_family_features.sql
--
--   * players: an emergency contact (name + phone) and medical notes
--     (allergies, asthma, anything a coach should know at training). The
--     family fills them in; coaches see a medical flag on the attendance
--     roster.
--   * users.deleted_at: a parent can delete their own account (Google Play
--     requires this for apps with sign-up). The account is anonymised and
--     marked here, so it never shows as "deactivated" or gets reactivated.
--   * announcements.auto_kind 'payment_reminder': the private reminder each
--     family gets listing only what they owe.
--
-- Safe to run: new nullable columns and one more allowed value.
-- =============================================================================

ALTER TABLE players
  ADD COLUMN emergency_name  VARCHAR(120) NULL AFTER photo_url,
  ADD COLUMN emergency_phone VARCHAR(30)  NULL AFTER emergency_name,
  ADD COLUMN medical_notes   VARCHAR(500) NULL AFTER emergency_phone;

ALTER TABLE users
  ADD COLUMN deleted_at DATETIME NULL AFTER updated_at;

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed','payment_reminder') NULL;
