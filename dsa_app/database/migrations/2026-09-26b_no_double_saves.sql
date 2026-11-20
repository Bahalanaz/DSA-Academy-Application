-- =============================================================================
-- 2026-09-26 (b) — one account on two phones: no double saves
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag (the generated columns hold text):
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-26b_no_double_saves.sql
--
-- The server checks "is this already there?" and then saves, as two steps.
-- With the same admin (or parent) signed in on two phones, both could tap
-- Save at the same moment, both pass the check, and both save:
--   * the same session appeared on the schedule twice;
--   * the same child was added to the family twice.
-- These keys make the database itself refuse the second one; the server
-- turns the refusal into the same readable message as its own check.
--
-- Both are NULL (not counted) for cancelled sessions and removed players,
-- so cancelling a session and adding it again, or re-adding a removed
-- child, still works. Check before running that nothing already clashes:
--   SELECT session_type, training_program_id, tournament_id, session_date,
--          start_time, COUNT(*) FROM sessions WHERE is_cancelled = 0
--   GROUP BY 1,2,3,4,5 HAVING COUNT(*) > 1;
--   SELECT parent_id, full_name, birthday, COUNT(*) FROM players
--   WHERE is_active = 1 GROUP BY 1,2,3 HAVING COUNT(*) > 1;
-- =============================================================================

ALTER TABLE sessions
  ADD COLUMN live_slot_key VARCHAR(80) GENERATED ALWAYS AS (
    CASE WHEN is_cancelled = 0
         THEN CONCAT(session_type, '|',
                     COALESCE(training_program_id, tournament_id), '|',
                     session_date, '|', start_time) END
  ) VIRTUAL,
  ADD UNIQUE KEY uq_sessions_live_slot (live_slot_key);

ALTER TABLE players
  ADD COLUMN active_child_key VARCHAR(160) GENERATED ALWAYS AS (
    CASE WHEN is_active = 1
         THEN CONCAT(parent_id, '|', full_name, '|',
                     COALESCE(birthday, '')) END
  ) VIRTUAL,
  ADD UNIQUE KEY uq_players_active_child (active_child_key);
