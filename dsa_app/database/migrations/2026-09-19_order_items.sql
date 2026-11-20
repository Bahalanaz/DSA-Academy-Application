-- =============================================================================
-- Orderable items become rows, not a hardcoded list of three
-- =============================================================================
-- Before this, the three items a parent could order were an ENUM on
-- orders.item, and their prices were three columns on order_prices. Adding a
-- fourth item (a hoodie, a bag) meant changing the database and the app, so
-- the admin could never do it. Now each item is a row the admin adds, prices
-- and renames in-app.
--
-- orders.item (the ENUM) is replaced by orders.order_item_id. Existing orders
-- keep pointing at the same three items, which are seeded below from whatever
-- prices order_prices held at the time.
--
-- Run once, against dsa_db, as root.

CREATE TABLE order_items (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  -- Stable machine name, generated from the label. Kept because the old three
  -- items were matched by it, and a future payment provider will want a SKU.
  code        VARCHAR(40)     NOT NULL,
  label       VARCHAR(80)     NOT NULL,     -- what the parent reads
  price       DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
  -- Which bucket an approved order lands in on the payments side.
  misc_type   ENUM('uniform','merch','others') NOT NULL DEFAULT 'others',
  -- Soft delete: orders already placed still point here, so the row has to
  -- survive being taken off the parent's list.
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  sort_order  INT             NOT NULL DEFAULT 0,
  created_by  BIGINT UNSIGNED     NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                              ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_order_items_code (code),
  KEY idx_order_items_active (is_active, sort_order),
  CONSTRAINT fk_order_items_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT chk_order_items_price CHECK (price >= 0)
) ENGINE = InnoDB;

INSERT INTO order_items (code, label, price, misc_type, sort_order)
SELECT 'league_uniform', 'League Uniform', league_uniform, 'uniform', 1
  FROM order_prices WHERE id = 1
UNION ALL
SELECT 'training_uniform', 'Training Uniform', training_uniform, 'uniform', 2
  FROM order_prices WHERE id = 1
UNION ALL
SELECT 'dsa_shirt', 'DSA Shirt', dsa_shirt, 'merch', 3
  FROM order_prices WHERE id = 1;

ALTER TABLE orders ADD COLUMN order_item_id BIGINT UNSIGNED NULL AFTER player_id;
UPDATE orders o JOIN order_items i ON i.code = o.item SET o.order_item_id = i.id;

ALTER TABLE orders
  MODIFY COLUMN order_item_id BIGINT UNSIGNED NOT NULL,
  -- RESTRICT, not CASCADE: deleting an item that people ordered would delete
  -- their orders with it. Items are deactivated instead, never deleted.
  ADD CONSTRAINT fk_orders_item
    FOREIGN KEY (order_item_id) REFERENCES order_items (id) ON DELETE RESTRICT,
  DROP COLUMN item;

-- order_prices held one row of three price columns; order_items holds the
-- prices now, one per item. Its currency column was never read by the app.
DROP TABLE order_prices;
