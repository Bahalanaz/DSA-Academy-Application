-- =============================================================================
-- 2026-10-14 — orders: handed over to the family
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place (after 2026-10-09f_award_category.sql).
-- A fresh install from schema.sql already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-14_order_received.sql
--
-- After approval an order used to stop at APPROVED: nothing said whether the
-- kit was ever paid for or handed over. Paid comes from the order's bill;
-- this records when the admin marked it as given (and who did).
-- Safe to run: new columns only, empty for every order already placed.
-- =============================================================================

ALTER TABLE orders
  ADD COLUMN received_at DATETIME NULL AFTER payment_id,
  ADD COLUMN received_by BIGINT UNSIGNED NULL AFTER received_at,
  ADD CONSTRAINT fk_orders_received_by
    FOREIGN KEY (received_by) REFERENCES users (id) ON DELETE SET NULL;
