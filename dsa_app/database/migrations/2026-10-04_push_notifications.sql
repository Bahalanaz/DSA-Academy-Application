-- =============================================================================
-- 2026-10-04 — push notifications (Firebase Cloud Messaging)
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-04_push_notifications.sql
--
-- device_tokens: where to send a phone's notifications. Each row belongs to
-- the LOGIN it was registered under (auth_sessions), so logging out,
-- changing the password (other phones), deactivating or deleting the
-- account removes it automatically: nobody keeps getting a family's
-- notifications after they've left the account.
--
-- announcements.pushed_at: when the server sent the notification for a
-- message. NULL = not sent yet; the server picks those up every few seconds
-- (dsa_server/lib/push.dart), after the message is safely saved. Every
-- message that already exists is marked as sent, so turning notifications on
-- doesn't send families a burst of old news.
-- =============================================================================

CREATE TABLE device_tokens (
  token         VARCHAR(512)    NOT NULL,   -- the FCM registration token
  session_hash  CHAR(64)        NOT NULL,   -- auth_sessions.token_hash
  user_id       BIGINT UNSIGNED NOT NULL,
  platform      ENUM('android','ios','web') NOT NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (token),
  KEY idx_device_tokens_user (user_id),
  KEY idx_device_tokens_session (session_hash),
  CONSTRAINT fk_device_tokens_session
    FOREIGN KEY (session_hash) REFERENCES auth_sessions (token_hash)
    ON DELETE CASCADE,
  CONSTRAINT fk_device_tokens_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;

ALTER TABLE announcements
  ADD COLUMN pushed_at DATETIME NULL AFTER deleted_at,
  ADD KEY idx_announcements_push (pushed_at, created_at);

UPDATE announcements SET pushed_at = NOW() WHERE pushed_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.device_tokens
  TO 'dsa_app_user'@'localhost';
