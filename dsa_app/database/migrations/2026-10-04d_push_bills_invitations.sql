-- =============================================================================
-- 2026-10-04d — notifications for new bills and tournament invitations
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-04d_push_bills_invitations.sql
--
-- Until now only messages buzzed a family's phone. A new bill (a tournament
-- fee, an approved order, the month's training fee, a request from the
-- admin) and a tournament invitation do too: the server's notification
-- sender (dsa_server/lib/push.dart) watches for them, the same way it
-- watches messages. pushed_at = when that notification went out (NULL = not
-- yet). Everything that already exists is marked as sent, so families don't
-- get a burst of old bills.
-- =============================================================================

ALTER TABLE payments
  ADD COLUMN pushed_at DATETIME NULL AFTER created_at,
  ADD KEY idx_payments_push (pushed_at, created_at);

ALTER TABLE tournament_players
  ADD COLUMN pushed_at DATETIME NULL AFTER added_at,
  ADD KEY idx_tournament_players_push (pushed_at, added_at);

UPDATE payments SET pushed_at = NOW() WHERE pushed_at IS NULL;
UPDATE tournament_players SET pushed_at = NOW() WHERE pushed_at IS NULL;
