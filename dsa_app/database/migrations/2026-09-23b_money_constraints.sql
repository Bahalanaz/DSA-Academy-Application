-- =============================================================================
-- 2026-09-23 (b) — make the database refuse what the app must never do
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has all of this.
--
-- Run as root, with the UTF-8 flag (without it the Windows client stores the
-- separator below as a cp850 literal, and schema.sql no longer matches):
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-23b_money_constraints.sql
--
-- Each rule below was only enforced by server code (check, then write). The
-- code checks stay, because they give a readable message; these are the net
-- underneath, for a race, a future bug, or a script run by hand. A violation
-- comes back as MySQL error 1062, which the server turns into a 409.
--
-- Verify there's nothing to trip over first (all three must be 0):
--   SELECT COUNT(*) FROM (SELECT label FROM order_items
--     GROUP BY label HAVING COUNT(*) > 1) x;
--   SELECT COUNT(*) FROM (SELECT player_id, period_month FROM payments
--     WHERE payment_type = 'training_fee' AND status = 'pending'
--     GROUP BY 1, 2 HAVING COUNT(*) > 1) x;
--   SELECT COUNT(*) FROM (SELECT player_id, tournament_id FROM payments
--     WHERE payment_type = 'tournament' AND tournament_id IS NOT NULL
--       AND status IN ('pending','paid')
--     GROUP BY 1, 2 HAVING COUNT(*) > 1) x;
-- =============================================================================

-- One item per name. A retired item keeps its row, and adding the same name
-- again restores it (POST /order-items), so names never need to repeat.
ALTER TABLE order_items
  ADD CONSTRAINT uq_order_items_label UNIQUE (label);

-- At most one OPEN training-fee bill per player per month, and at most one
-- live (pending or paid) fee per player per tournament.
--
-- MySQL has no partial unique index, so each rule is a generated column that
-- holds a key only for the rows the rule is about and NULL for every other
-- row — and a UNIQUE index ignores NULLs. Closed, waived, refunded and voided
-- bills are NULL, so a month can still have any number of paid receipts.
ALTER TABLE payments
  ADD COLUMN open_training_key VARCHAR(40) GENERATED ALWAYS AS (
    CASE WHEN payment_type = 'training_fee' AND status = 'pending'
         THEN CONCAT(player_id, '|', period_month) END
  ) VIRTUAL,
  ADD COLUMN live_tournament_key VARCHAR(40) GENERATED ALWAYS AS (
    CASE WHEN payment_type = 'tournament' AND tournament_id IS NOT NULL
              AND status IN ('pending','paid')
         THEN CONCAT(player_id, '|', tournament_id) END
  ) VIRTUAL,
  ADD UNIQUE KEY uq_payments_open_training (open_training_key),
  ADD UNIQUE KEY uq_payments_live_tournament (live_tournament_key);
