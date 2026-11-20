-- =============================================================================
-- 2026-09-27b — tidy training default players
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place, after 2026-09-27. Safe to run twice.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-27b_tidy_default_players.sql
--
-- Removing a player, deleting a family's account and deleting a training now
-- take the matching rows out of training_default_players. This clears any
-- left from before that change, so healthcheck.sql reports 0 for them.
-- =============================================================================

DELETE d FROM training_default_players d
JOIN players p ON p.id = d.player_id
WHERE p.is_active = 0;

DELETE d FROM training_default_players d
JOIN training_programs tp ON tp.id = d.training_program_id
WHERE tp.is_active = 0;
