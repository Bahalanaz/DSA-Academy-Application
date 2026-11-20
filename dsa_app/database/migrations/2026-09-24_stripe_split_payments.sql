-- =============================================================================
-- 2026-09-24 — let one Stripe charge (or refund) cover several bills
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql or a
-- restore from dsa_db_dump.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-09-24_stripe_split_payments.sql
--
-- payment_transactions had UNIQUE (stripe_payment_intent_id) and UNIQUE
-- (stripe_refund_id): one Stripe id could appear on ONE log row, ever. That
-- breaks the moment card payments go live, because one charge is often more
-- than one row:
--   * paying a training fee plus extra — the month gets one row and the
--     advance (training credit) another;
--   * a "pay all" — one charge settling several bills;
--   * a training refund — one Stripe refund spread over several receipts.
-- The rule becomes "a Stripe id once PER BILL": still enough to stop a
-- webhook that arrives twice from recording the same payment twice, without
-- refusing a legitimate split.
--
-- Safe to run: nothing has a Stripe id yet (no card payments exist).
-- =============================================================================

ALTER TABLE payment_transactions
  DROP INDEX uq_payment_transactions_intent,
  DROP INDEX uq_payment_transactions_refund,
  ADD UNIQUE KEY uq_payment_transactions_intent (stripe_payment_intent_id, payment_id),
  ADD UNIQUE KEY uq_payment_transactions_refund (stripe_refund_id, payment_id);
