-- Pre-demo integrity sweep over the WHOLE database, not just seeded rows.
-- Every line must report 0.

SELECT 'bills whose ledger disagrees' AS check_name, COUNT(*) AS must_be_zero FROM (
  SELECT p.id
  FROM payments p
  LEFT JOIN payment_transactions t
    ON t.payment_id = p.id AND t.kind IN ('payment','refund','reversal')
  GROUP BY p.id, p.amount_paid
  HAVING ROUND(COALESCE(SUM(t.amount),0),2) <> ROUND(p.amount_paid,2)
) x
UNION ALL
SELECT 'bills paid more than charged', COUNT(*) FROM payments WHERE amount_paid > amount
UNION ALL
SELECT 'negative amounts charged', COUNT(*) FROM payments WHERE amount < 0 OR amount_paid < 0
UNION ALL
SELECT 'paid bills with no paid_at', COUNT(*) FROM payments
  WHERE status = 'paid' AND paid_at IS NULL
UNION ALL
SELECT 'status says paid but ledger short', COUNT(*) FROM payments
  WHERE status = 'paid' AND ROUND(amount_paid,2) < ROUND(amount,2)
UNION ALL
SELECT 'orders pointing at a missing item', COUNT(*) FROM orders o
  LEFT JOIN order_items i ON i.id = o.order_item_id
  WHERE o.order_item_id IS NOT NULL AND i.id IS NULL
UNION ALL
SELECT 'order_items with duplicate labels', COUNT(*) FROM (
  SELECT LOWER(label) l FROM order_items WHERE is_active = 1
  GROUP BY l HAVING COUNT(*) > 1
) d
UNION ALL
SELECT 'players on a non-parent account', COUNT(*) FROM players pl
  JOIN users u ON u.id = pl.parent_id
  WHERE u.role <> 'parent' OR u.status NOT IN ('approved','disabled')
UNION ALL
SELECT 'bills for a missing player', COUNT(*) FROM payments p
  LEFT JOIN players pl ON pl.id = p.player_id WHERE pl.id IS NULL
UNION ALL
SELECT 'log rows for a missing bill', COUNT(*) FROM payment_transactions t
  LEFT JOIN payments p ON p.id = t.payment_id WHERE p.id IS NULL
UNION ALL
SELECT 'attendance for a missing session', COUNT(*) FROM attendance a
  LEFT JOIN sessions s ON s.id = a.session_id WHERE s.id IS NULL
UNION ALL
SELECT 'attendance for a player not on the session', COUNT(*) FROM attendance a
  LEFT JOIN session_players sp
    ON sp.session_id = a.session_id AND sp.player_id = a.player_id
  WHERE sp.session_id IS NULL
UNION ALL
-- One OPEN bill per player per month. Several rows for a month are normal:
-- each part payment on the running month is its own receipt, and waiving
-- or carrying credit adds rows too. Two bills still owed for one month is
-- not something the app does.
SELECT 'two open training fees for a month', COUNT(*) FROM (
  SELECT player_id, period_month FROM payments
  WHERE payment_type = 'training_fee' AND period_month IS NOT NULL
    AND status = 'pending'
  GROUP BY player_id, period_month HAVING COUNT(*) > 1
) d
UNION ALL
-- Credit moves are pairs (out of one training fee, into the next), so every
-- 'credit' row in the log nets to zero across the database.
SELECT 'credit moves that do not net to zero',
  CASE WHEN ROUND(COALESCE(SUM(amount), 0), 2) = 0 THEN 0 ELSE 1 END
  FROM payment_transactions WHERE method = 'credit'
UNION ALL
SELECT 'voided bills still holding money', COUNT(*) FROM payments
  WHERE status = 'void' AND amount_paid <> 0
UNION ALL
-- No tournament fee until the family has accepted the invitation.
SELECT 'tournament fees for players who have not accepted', COUNT(*)
  FROM payments p
  JOIN tournament_players tp
    ON tp.tournament_id = p.tournament_id AND tp.player_id = p.player_id
  WHERE p.payment_type = 'tournament' AND p.status IN ('pending','paid')
    AND tp.consent <> 'accepted'
UNION ALL
SELECT 'automatic notices sent to nobody', COUNT(*) FROM announcements a
  WHERE a.auto_kind IS NOT NULL AND a.deleted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM announcement_players ap
                    WHERE ap.announcement_id = a.id)
UNION ALL
-- Deleting a training or tournament cancels everything after today.
SELECT 'upcoming sessions of a deleted training or tournament', COUNT(*)
  FROM sessions s
  LEFT JOIN training_programs tp ON tp.id = s.training_program_id
  LEFT JOIN tournaments t ON t.id = s.tournament_id
  WHERE s.is_cancelled = 0 AND s.session_date > CURRENT_DATE
    AND ((s.training_program_id IS NOT NULL AND tp.is_active = 0)
      OR (s.tournament_id IS NOT NULL AND t.deleted_at IS NOT NULL))
UNION ALL
-- Removing a player settles or forgives what they owe first (or is refused).
SELECT 'bills still owed by removed players', COUNT(*)
  FROM payments p JOIN players pl ON pl.id = p.player_id
  WHERE p.status = 'pending' AND pl.is_active = 0
UNION ALL
-- A tournament fee is owed only while the child is on a live tournament:
-- taking them off, or deleting it, withdraws what's unpaid.
SELECT 'tournament fees owed for a tournament the child is not on', COUNT(*)
  FROM payments p
  LEFT JOIN tournament_players tp
    ON tp.tournament_id = p.tournament_id AND tp.player_id = p.player_id
  LEFT JOIN tournaments t ON t.id = p.tournament_id
  WHERE p.payment_type = 'tournament' AND p.status = 'pending'
    AND p.tournament_id IS NOT NULL
    AND (tp.player_id IS NULL OR t.deleted_at IS NOT NULL)
UNION ALL
SELECT 'orders waiting for a removed player', COUNT(*)
  FROM orders o JOIN players pl ON pl.id = o.player_id
  WHERE o.status = 'pending' AND pl.is_active = 0
UNION ALL
-- Withdrawing an order's bill declines the order.
SELECT 'approved orders with no bill', COUNT(*)
  FROM orders o LEFT JOIN payments p ON p.id = o.payment_id
  WHERE o.status = 'approved' AND p.id IS NULL
UNION ALL
-- The "before" snapshot belongs only on a session-changed message (one the
-- admin has since edited by hand has no kind, and keeps it harmlessly).
SELECT 'change snapshots on other kinds of message', COUNT(*)
  FROM announcement_sessions s JOIN announcements a ON a.id = s.announcement_id
  WHERE s.was_json IS NOT NULL
    AND a.auto_kind IS NOT NULL AND a.auto_kind <> 'session_changed'
UNION ALL
-- Deleting an account takes the family's children off the club's lists.
SELECT 'deleted accounts with active children', COUNT(*)
  FROM players p JOIN users u ON u.id = p.parent_id
  WHERE u.deleted_at IS NOT NULL AND p.is_active = 1
UNION ALL
-- ...and signs out every device.
SELECT 'deleted accounts still signed in', COUNT(*)
  FROM auth_sessions s JOIN users u ON u.id = s.user_id
  WHERE u.deleted_at IS NOT NULL
UNION ALL
-- A direct message goes to a parent account, never an admin.
SELECT 'direct messages addressed to a non-parent account', COUNT(*)
  FROM announcement_users au JOIN users u ON u.id = au.user_id
  WHERE u.role <> 'parent'
UNION ALL
-- A training's default players are put on its new sessions: only active
-- players, and only for a training that still exists.
SELECT 'training default players removed or on a deleted training', COUNT(*)
  FROM training_default_players d
  JOIN players p ON p.id = d.player_id
  JOIN training_programs tp ON tp.id = d.training_program_id
  WHERE p.is_active = 0 OR tp.is_active = 0
UNION ALL
-- Test runs use names starting "Zz" (and zz_ accounts) and clean up after
-- themselves. Anything left means a test was stopped halfway: never on the
-- live server.
SELECT 'test data left behind (Zz names, zz_ accounts)',
  (SELECT COUNT(*) FROM players WHERE full_name LIKE 'Zz %')
  + (SELECT COUNT(*) FROM users WHERE username LIKE 'zz!_%' ESCAPE '!' OR full_name LIKE 'Zz %')
  + (SELECT COUNT(*) FROM sessions WHERE location LIKE 'Zz%' OR notes LIKE 'ZZ%')
  + (SELECT COUNT(*) FROM tournaments WHERE name LIKE 'Zz %')
  + (SELECT COUNT(*) FROM training_programs WHERE name LIKE 'Zz %')
  + (SELECT COUNT(*) FROM announcements WHERE title LIKE 'Zz %')
  + (SELECT COUNT(*) FROM device_tokens WHERE token LIKE 'zz-%')
UNION ALL
-- A photo goes with a removed child or a deleted account (privacy).
SELECT 'photos kept for a removed player or deleted account', COUNT(*)
  FROM profile_photos ph
  LEFT JOIN players p ON ph.kind = 'player' AND p.id = ph.owner_id
  LEFT JOIN users u ON ph.kind = 'user' AND u.id = ph.owner_id
  WHERE (ph.kind = 'player' AND (p.id IS NULL OR p.is_active = 0))
     OR (ph.kind = 'user' AND (u.id IS NULL OR u.deleted_at IS NOT NULL))
UNION ALL
-- Billing's "today" is MySQL's clock: it must be UAE time (+04:00).
-- Fix with: SET PERSIST time_zone = '+04:00';
SELECT 'database clock is not on UAE time (+04:00)',
  TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW()) <> 240
UNION ALL
SELECT 'login tokens for a deleted user', COUNT(*) FROM auth_sessions s
  LEFT JOIN users u ON u.id = s.user_id WHERE u.id IS NULL
UNION ALL
SELECT 'emoji left in any name', COUNT(*) FROM (
  SELECT full_name AS t FROM players
  UNION ALL SELECT full_name FROM users
  UNION ALL SELECT label FROM order_items
  UNION ALL SELECT title FROM payments
) n WHERE t REGEXP '[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}]';
