-- =============================================================================
-- 2026-09-26 (d) — an index for the automatic-message lookups
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26d_notice_lookup_index.sql
--
-- Every session edit, cancellation and undo now looks for a recent automatic
-- message of one kind ("sent in the last 30 minutes, of kind X") to update
-- instead of sending another. Without this index each of those scanned every
-- message the club has ever sent.
--
-- Safe to run: adds an index only.
-- =============================================================================

CREATE INDEX idx_announcements_auto ON announcements (auto_kind, created_at);
