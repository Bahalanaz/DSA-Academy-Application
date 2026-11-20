-- =============================================================================
-- DSA Elite — test data for PAST months
-- =============================================================================
-- seed_test_data.sql fills the current month. This fills the five months
-- before it, so Transaction History's month picker has something to page
-- through and the Payments screens have history behind them.
--
-- Safe to re-run: every row it creates is stamped
-- reference_no = 'seed-past-months', and it deletes those first. It never
-- touches anything else, so your real (or seeded) current-month data stays.
--
-- Run as root — it deletes from payment_transactions, which the app's own
-- MySQL user is deliberately not allowed to do:
--   mysql -u root -p dsa_db < seed_past_months.sql
--
-- WHAT IT MAKES, per month
--   * a training-fee bill for every active player, raised on the 1st of the
--     following month at 00:17 the way the real month close does
--   * most of them paid a few days later (cash / bank / card / in-app),
--     one or two left unpaid, one part-paid, one waived, a couple refunded
--   * a tournament fee and a kit charge in some months, likewise paid
--
-- The ledger rule holds throughout: payments.amount_paid always equals the
-- sum of its payment/refund/reversal rows in payment_transactions. The
-- checks at the bottom prove it before the script exits.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Clear whatever a previous run of THIS script made
-- ---------------------------------------------------------------------------
DELETE FROM payment_transactions
WHERE payment_id IN (
  SELECT id FROM payments WHERE reference_no = 'seed-past-months'
);
DELETE FROM payments WHERE reference_no = 'seed-past-months';

SET @admin := (SELECT id FROM users WHERE role = 'admin' ORDER BY id LIMIT 1);

-- The five completed months before this one.
DROP TEMPORARY TABLE IF EXISTS seed_months;
CREATE TEMPORARY TABLE seed_months (month DATE NOT NULL, ago INT NOT NULL);
INSERT INTO seed_months (month, ago)
SELECT DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL k.ago MONTH), k.ago
FROM (
  SELECT 1 AS ago UNION ALL SELECT 2 UNION ALL SELECT 3
  UNION ALL SELECT 4 UNION ALL SELECT 5
) k;

-- ---------------------------------------------------------------------------
-- 1. Training fees: one bill per player per month
-- ---------------------------------------------------------------------------
-- Amount looks like a real month: the AED 100 coach fee plus four to eight
-- sessions at AED 31.25.
INSERT INTO payments
  (player_id, payment_type, title, period_month, amount, amount_paid,
   status, created_by, created_at, reference_no)
SELECT
  p.id,
  'training_fee',
  CONCAT(DATE_FORMAT(m.month, '%M %Y'), ' Training Fee'),
  m.month,
  100.00 + 31.25 * (4 + (p.id % 5)),
  0.00,
  'pending',
  @admin,
  -- Raised just after midnight on the 1st of the next month, like the close.
  TIMESTAMP(DATE_ADD(m.month, INTERVAL 1 MONTH), '00:17:00'),
  'seed-past-months'
FROM players p
CROSS JOIN seed_months m
WHERE p.is_active = 1
  -- Don't bill a month a player already has a training fee for. Without
  -- this, a player billed by seed_test_data.sql (or by a real month close)
  -- ends up with two bills for the same month, which is a state the app
  -- itself never produces: reconcilePastMonths only raises a bill when
  -- what's owed exceeds what's already been paid for that month.
  AND NOT EXISTS (
    SELECT 1 FROM payments existing
    WHERE existing.player_id = p.id
      AND existing.payment_type = 'training_fee'
      AND existing.period_month = m.month
  );

-- How each bill turned out. Deterministic, but varied enough per player and
-- month that no two months look alike: 0 = never paid, 1 = part paid,
-- 2 = waived, everything else = paid in full.
UPDATE payments
SET
  amount_paid = CASE (player_id * 7 + MONTH(period_month)) % 10
    WHEN 0 THEN 0.00
    WHEN 1 THEN ROUND(amount / 2, 2)
    WHEN 2 THEN 0.00
    ELSE amount
  END,
  status = CASE (player_id * 7 + MONTH(period_month)) % 10
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'pending'
    WHEN 2 THEN 'waived'
    ELSE 'paid'
  END,
  method = CASE (player_id * 7 + MONTH(period_month)) % 10
    WHEN 0 THEN NULL
    WHEN 2 THEN NULL
    ELSE ELT((player_id % 4) + 1, 'cash', 'bank', 'card', 'online_test')
  END,
  -- Paid a few days into the month the bill went out in.
  paid_at = CASE (player_id * 7 + MONTH(period_month)) % 10
    WHEN 0 THEN NULL
    WHEN 1 THEN NULL
    WHEN 2 THEN NULL
    ELSE TIMESTAMP(
      DATE_ADD(DATE(created_at), INTERVAL (player_id % 9) + 1 DAY),
      SEC_TO_TIME(((player_id * 137) % 28800) + 32400)
    )
  END
WHERE reference_no = 'seed-past-months';

-- ---------------------------------------------------------------------------
-- 2. Tournament fees and kit charges, so the type filters have history too
-- ---------------------------------------------------------------------------
-- Every third player, in the three most recent past months.
INSERT INTO payments
  (player_id, payment_type, title, misc_type, amount, amount_paid, status,
   method, paid_at, created_by, created_at, reference_no)
SELECT
  p.id,
  'tournament',
  CONCAT(DATE_FORMAT(m.month, '%M'), ' Cup Fee'),
  NULL,
  400.00,
  CASE WHEN (p.id + m.ago) % 4 = 0 THEN 0.00 ELSE 400.00 END,
  CASE WHEN (p.id + m.ago) % 4 = 0 THEN 'pending' ELSE 'paid' END,
  CASE WHEN (p.id + m.ago) % 4 = 0 THEN NULL ELSE 'bank' END,
  CASE WHEN (p.id + m.ago) % 4 = 0 THEN NULL
       ELSE TIMESTAMP(DATE_ADD(m.month, INTERVAL 12 DAY), '18:05:00') END,
  @admin,
  TIMESTAMP(DATE_ADD(m.month, INTERVAL 9 DAY), '10:20:00'),
  'seed-past-months'
FROM players p
CROSS JOIN seed_months m
WHERE p.is_active = 1 AND p.id % 3 = 0 AND m.ago <= 3;

-- Every fourth player, kit, in the two most recent past months.
INSERT INTO payments
  (player_id, payment_type, title, misc_type, amount, amount_paid, status,
   method, paid_at, created_by, created_at, reference_no)
SELECT
  p.id,
  'misc',
  ELT((p.id % 3) + 1, 'League Uniform', 'Training Uniform', 'DSA Shirt'),
  ELT((p.id % 3) + 1, 'uniform', 'uniform', 'merch'),
  ELT((p.id % 3) + 1, 130.00, 100.00, 50.00),
  ELT((p.id % 3) + 1, 130.00, 100.00, 50.00),
  'paid',
  'cash',
  TIMESTAMP(DATE_ADD(m.month, INTERVAL 20 DAY), '16:40:00'),
  @admin,
  TIMESTAMP(DATE_ADD(m.month, INTERVAL 18 DAY), '09:15:00'),
  'seed-past-months'
FROM players p
CROSS JOIN seed_months m
WHERE p.is_active = 1 AND p.id % 4 = 0 AND m.ago <= 2;

-- ---------------------------------------------------------------------------
-- 3. The money log: one row per movement, matching what the bills say
-- ---------------------------------------------------------------------------
-- Money received. amount_paid is what was handed over, so that is the row.
INSERT INTO payment_transactions
  (payment_id, kind, amount, method, note, recorded_by, created_at)
SELECT
  id,
  'payment',
  amount_paid,
  method,
  NULL,
  CASE WHEN method = 'online_test' THEN NULL ELSE @admin END,
  COALESCE(paid_at, TIMESTAMP(DATE(created_at) + INTERVAL 2 DAY, '11:00:00'))
FROM payments
WHERE reference_no = 'seed-past-months' AND amount_paid > 0;

-- Written off: the bill was forgiven, so nothing moved — the log still says
-- what was given up.
INSERT INTO payment_transactions
  (payment_id, kind, amount, method, note, recorded_by, created_at)
SELECT
  id,
  'waiver',
  amount,
  NULL,
  'Waived by admin',
  @admin,
  TIMESTAMP(DATE(created_at) + INTERVAL 6 DAY, '13:25:00')
FROM payments
WHERE reference_no = 'seed-past-months' AND status = 'waived';

-- ---------------------------------------------------------------------------
-- 4. A couple of refunds, so money goes back out as well as in
-- ---------------------------------------------------------------------------
-- A refund lowers what was charged AND what was paid by the same amount, so
-- the family owes nothing new — the same thing recordRefund does in code.
DROP TEMPORARY TABLE IF EXISTS seed_refunds;
CREATE TEMPORARY TABLE seed_refunds (payment_id BIGINT UNSIGNED PRIMARY KEY);
INSERT INTO seed_refunds (payment_id)
SELECT id FROM payments
WHERE reference_no = 'seed-past-months'
  AND payment_type = 'tournament'
  AND status = 'paid'
  AND player_id % 9 = 0;

INSERT INTO payment_transactions
  (payment_id, kind, amount, method, note, recorded_by, created_at)
SELECT
  p.id, 'refund', -75.00, 'bank', 'Withdrew from the tournament', @admin,
  TIMESTAMP(DATE(p.paid_at) + INTERVAL 3 DAY, '15:10:00')
FROM payments p
JOIN seed_refunds r ON r.payment_id = p.id;

UPDATE payments p
JOIN seed_refunds r ON r.payment_id = p.id
SET p.amount = p.amount - 75.00, p.amount_paid = p.amount_paid - 75.00;

-- ---------------------------------------------------------------------------
-- 5. Prove it hangs together before anyone trusts it
-- ---------------------------------------------------------------------------
SELECT 'months created' AS check_name,
       GROUP_CONCAT(DISTINCT DATE_FORMAT(created_at, '%Y-%m') ORDER BY 1
                    SEPARATOR ', ') AS result
FROM payments WHERE reference_no = 'seed-past-months'
UNION ALL
SELECT 'bills created', COUNT(*) FROM payments
WHERE reference_no = 'seed-past-months'
UNION ALL
SELECT 'log rows created', COUNT(*) FROM payment_transactions t
JOIN payments p ON p.id = t.payment_id
WHERE p.reference_no = 'seed-past-months'
UNION ALL
-- The one that matters: every bill's amount_paid equals the sum of its
-- payment, refund and reversal rows. A waiver forgives, it doesn't move money.
SELECT 'bills whose log disagrees (must be 0)', COUNT(*) FROM (
  SELECT p.id
  FROM payments p
  LEFT JOIN payment_transactions t
    ON t.payment_id = p.id AND t.kind IN ('payment','refund','reversal')
  WHERE p.reference_no = 'seed-past-months'
  GROUP BY p.id, p.amount_paid
  HAVING ROUND(COALESCE(SUM(t.amount), 0), 2) <> ROUND(p.amount_paid, 2)
) bad
UNION ALL
SELECT 'bills paid over their amount (must be 0)', COUNT(*) FROM payments
WHERE reference_no = 'seed-past-months' AND amount_paid > amount
UNION ALL
-- Two training fees for one player in one month is something the app can't
-- do, so the test data mustn't either.
SELECT 'players billed twice for a month (must be 0)', COUNT(*) FROM (
  SELECT player_id, period_month FROM payments
  WHERE payment_type = 'training_fee' AND period_month IS NOT NULL
  GROUP BY player_id, period_month HAVING COUNT(*) > 1
) dupes;

DROP TEMPORARY TABLE IF EXISTS seed_months;
DROP TEMPORARY TABLE IF EXISTS seed_refunds;
