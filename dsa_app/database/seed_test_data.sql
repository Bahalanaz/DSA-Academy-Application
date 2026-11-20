-- =============================================================================
-- DSA Elite — test data
--
-- Realistic data to click around with: one admin, ten parent families, and
-- fifteen players between them. Safe to re-run — it wipes everything except
-- the schema first, so you always land in a known state.
--
-- Run it in MySQL Workbench (Execute All, the ⚡ button).
--
-- LOGINS (every account's password is the same, for testing only: admin123)
--   admin   -> coach
--   parents -> rlopez, mtan, jcruz, dsantos, akhan, pgomez,
--              ynakamura, ffarouk, bocampo, lmendoza
--   pending -> newparent   (can't log in until you approve it in
--              Admin > Account Validation — that's the point of leaving one)
--
-- DATES are all relative to CURDATE(), so the current month always has
-- attendance in it and training fees are never zero just because time passed.
--
-- CATEGORIES ARE NOT ASSIGNED HERE. A player's category is their birth year
-- (B2013 = born 2013), derived from players.birthday — so the birthdays below
-- are what put each player in a bracket.
-- =============================================================================

USE dsa_db;

-- -----------------------------------------------------------------------------
-- Wipe (children first, so foreign keys never block the delete)
-- -----------------------------------------------------------------------------
DELETE FROM attendance;
DELETE FROM session_players;
DELETE FROM sessions;
DELETE FROM tournament_players;
DELETE FROM tournaments;
DELETE FROM training_program_categories;
DELETE FROM training_programs;
DELETE FROM announcement_reads;
DELETE FROM announcement_categories;
DELETE FROM announcements;
DELETE FROM orders;
DELETE FROM order_items;          -- after orders: they reference an item
DELETE FROM training_fee_overrides;
DELETE FROM payment_transactions;   -- before payments: history blocks deleting a bill
DELETE FROM payments;
DELETE FROM players;
DELETE FROM password_resets;
DELETE FROM auth_sessions;
DELETE FROM users;
DELETE FROM categories;

ALTER TABLE users             AUTO_INCREMENT = 1;
ALTER TABLE players           AUTO_INCREMENT = 1;
ALTER TABLE categories        AUTO_INCREMENT = 1;
ALTER TABLE training_programs AUTO_INCREMENT = 1;
ALTER TABLE sessions          AUTO_INCREMENT = 1;
ALTER TABLE tournaments       AUTO_INCREMENT = 1;
ALTER TABLE announcements     AUTO_INCREMENT = 1;
ALTER TABLE orders            AUTO_INCREMENT = 1;
ALTER TABLE order_items       AUTO_INCREMENT = 1;
ALTER TABLE payments          AUTO_INCREMENT = 1;

-- Config, not test data: re-assert prices in case they were edited while
-- clicking around.
INSERT INTO fee_settings (id, coach_fee, per_session_rate, currency)
VALUES (1, 100.00, 31.25, 'AED')
ON DUPLICATE KEY UPDATE
  coach_fee = VALUES(coach_fee),
  per_session_rate = VALUES(per_session_rate);

INSERT INTO order_items (code, label, price, misc_type, sort_order) VALUES
  ('league_uniform',   'League Uniform',   130.00, 'uniform', 1),
  ('training_uniform', 'Training Uniform', 100.00, 'uniform', 2),
  ('dsa_shirt',        'DSA Shirt',         50.00, 'merch',   3);


-- -----------------------------------------------------------------------------
-- Categories (birth-year based; a LARGER year means a YOUNGER player)
-- -----------------------------------------------------------------------------
INSERT INTO categories (code, birth_year, label) VALUES
  ('B2010', 2010, 'Born 2010'),
  ('B2011', 2011, 'Born 2011'),
  ('B2012', 2012, 'Born 2012'),
  ('B2013', 2013, 'Born 2013'),
  ('B2014', 2014, 'Born 2014'),
  ('B2015', 2015, 'Born 2015');


-- -----------------------------------------------------------------------------
-- Accounts: one admin, ten approved parents, one still awaiting approval
-- -----------------------------------------------------------------------------
-- The hash below is a real bcrypt of 'admin123' — dev only.
SET @pw = '$2a$10$5Fr5qZMieFq5bKBo..Ofc.ur7/5Rj0vIQm7XQaQntbZiroON3dnom';

INSERT INTO users (role, full_name, username, email, phone, password_hash, status)
VALUES
  ('admin',  'Coach Ramon',    'coach',      'coach@example.com',    '+971 50 000 0001', @pw, 'approved'),
  ('parent', 'Rosa Lopez',     'rlopez',     'rosa@example.com',      '+971 50 222 3344', @pw, 'approved'),
  ('parent', 'Michael Tan',    'mtan',       'michael@example.com',   '+971 50 333 4455', @pw, 'approved'),
  ('parent', 'Jenny Cruz',     'jcruz',      'jenny@example.com',     '+971 50 444 5566', @pw, 'approved'),
  ('parent', 'Danilo Santos',  'dsantos',    'danilo@example.com',    '+971 50 555 6677', @pw, 'approved'),
  ('parent', 'Amira Khan',     'akhan',      'amira@example.com',     '+971 50 666 7788', @pw, 'approved'),
  ('parent', 'Paolo Gomez',    'pgomez',     'paolo@example.com',     '+971 50 777 8899', @pw, 'approved'),
  ('parent', 'Yuki Nakamura',  'ynakamura',  'yuki@example.com',      '+971 50 888 9900', @pw, 'approved'),
  ('parent', 'Fatima Farouk',  'ffarouk',    'fatima@example.com',    '+971 50 999 0011', @pw, 'approved'),
  ('parent', 'Beth Ocampo',    'bocampo',    'beth@example.com',      '+971 50 111 2233', @pw, 'approved'),
  ('parent', 'Luis Mendoza',   'lmendoza',   'luis@example.com',      '+971 50 121 3141', @pw, 'approved'),
  ('parent', 'Nadia Reyes',    'newparent',  'nadia@example.com',     '+971 50 151 6171', @pw, 'pending');

SET @admin    = (SELECT id FROM users WHERE username = 'coach');
SET @p_lopez  = (SELECT id FROM users WHERE username = 'rlopez');
SET @p_tan    = (SELECT id FROM users WHERE username = 'mtan');
SET @p_cruz   = (SELECT id FROM users WHERE username = 'jcruz');
SET @p_santos = (SELECT id FROM users WHERE username = 'dsantos');
SET @p_khan   = (SELECT id FROM users WHERE username = 'akhan');
SET @p_gomez  = (SELECT id FROM users WHERE username = 'pgomez');
SET @p_naka   = (SELECT id FROM users WHERE username = 'ynakamura');
SET @p_farouk = (SELECT id FROM users WHERE username = 'ffarouk');
SET @p_ocampo = (SELECT id FROM users WHERE username = 'bocampo');
SET @p_mendoza= (SELECT id FROM users WHERE username = 'lmendoza');


-- -----------------------------------------------------------------------------
-- Players — the birthday is what decides the category, so these span B2010-B2015
-- -----------------------------------------------------------------------------
INSERT INTO players (parent_id, full_name, birthday, jersey_number) VALUES
  (@p_lopez,   'Ana Lopez',      '2013-04-12', '7'),
  (@p_lopez,   'Diego Lopez',    '2011-09-03', '15'),
  (@p_tan,     'Isla Tan',       '2012-01-22', '3'),
  (@p_tan,     'Noah Tan',       '2014-06-30', '11'),
  (@p_cruz,    'Mia Cruz',       '2013-11-08', '23'),
  (@p_cruz,    'Ethan Cruz',     '2010-02-14', '5'),
  (@p_santos,  'Liam Santos',    '2012-07-19', '9'),
  (@p_khan,    'Zara Khan',      '2013-03-05', '12'),
  (@p_khan,    'Omar Khan',      '2015-10-27', '2'),
  (@p_gomez,   'Sofia Gomez',    '2014-05-16', '8'),
  (@p_naka,    'Kenji Nakamura', '2011-12-01', '21'),
  (@p_farouk,  'Leila Farouk',   '2013-08-23', '14'),
  (@p_farouk,  'Adam Farouk',    '2010-06-11', '6'),
  (@p_ocampo,  'Marco Ocampo',   '2012-10-09', '17'),
  (@p_mendoza, 'Elena Mendoza',  '2014-02-28', '4');

SET @ana    = (SELECT id FROM players WHERE full_name = 'Ana Lopez');
SET @diego  = (SELECT id FROM players WHERE full_name = 'Diego Lopez');
SET @isla   = (SELECT id FROM players WHERE full_name = 'Isla Tan');
SET @noah   = (SELECT id FROM players WHERE full_name = 'Noah Tan');
SET @mia    = (SELECT id FROM players WHERE full_name = 'Mia Cruz');
SET @ethan  = (SELECT id FROM players WHERE full_name = 'Ethan Cruz');
SET @liam   = (SELECT id FROM players WHERE full_name = 'Liam Santos');
SET @zara   = (SELECT id FROM players WHERE full_name = 'Zara Khan');
SET @omar   = (SELECT id FROM players WHERE full_name = 'Omar Khan');
SET @sofia  = (SELECT id FROM players WHERE full_name = 'Sofia Gomez');
SET @kenji  = (SELECT id FROM players WHERE full_name = 'Kenji Nakamura');
SET @leila  = (SELECT id FROM players WHERE full_name = 'Leila Farouk');
SET @adam   = (SELECT id FROM players WHERE full_name = 'Adam Farouk');
SET @marco  = (SELECT id FROM players WHERE full_name = 'Marco Ocampo');
SET @elena  = (SELECT id FROM players WHERE full_name = 'Elena Mendoza');


-- -----------------------------------------------------------------------------
-- Training programs — two batches, each spanning a few birth years
-- -----------------------------------------------------------------------------
INSERT INTO training_programs (name, created_by) VALUES
  ('Juniors batch', @admin),
  ('Seniors batch', @admin);

SET @juniors = (SELECT id FROM training_programs WHERE name = 'Juniors batch');
SET @seniors = (SELECT id FROM training_programs WHERE name = 'Seniors batch');

INSERT INTO training_program_categories (training_program_id, category_id)
SELECT @juniors, id FROM categories WHERE code IN ('B2013','B2014','B2015');
INSERT INTO training_program_categories (training_program_id, category_id)
SELECT @seniors, id FROM categories WHERE code IN ('B2010','B2011','B2012');


-- -----------------------------------------------------------------------------
-- Sessions THIS MONTH, so training fees actually have something to bill on.
-- Kept in the past so attendance can already be marked against them.
-- -----------------------------------------------------------------------------
INSERT INTO sessions
  (session_type, training_program_id, category_label, session_date,
   start_time, end_time, location, created_by)
VALUES
  ('training', @juniors, 'B2013, B2014, B2015',
   DATE_SUB(CURDATE(), INTERVAL 10 DAY), '17:00:00', '18:30:00', 'DSA Gym', @admin),
  ('training', @juniors, 'B2013, B2014, B2015',
   DATE_SUB(CURDATE(), INTERVAL 3 DAY),  '17:00:00', '18:30:00', 'DSA Gym', @admin),
  ('training', @seniors, 'B2010, B2011, B2012',
   DATE_SUB(CURDATE(), INTERVAL 8 DAY),  '18:30:00', '20:00:00', 'DSA Gym', @admin),
  ('training', @seniors, 'B2010, B2011, B2012',
   DATE_SUB(CURDATE(), INTERVAL 2 DAY),  '18:30:00', '20:00:00', 'DSA Gym', @admin),
  -- One still to come, so the Schedule screen has something upcoming.
  ('training', @juniors, 'B2013, B2014, B2015',
   DATE_ADD(CURDATE(), INTERVAL 4 DAY),  '17:00:00', '18:30:00', 'DSA Gym', @admin);

SET @jun1 = (SELECT id FROM sessions WHERE training_program_id = @juniors
             ORDER BY session_date LIMIT 1);
SET @jun2 = (SELECT id FROM sessions WHERE training_program_id = @juniors
             AND session_date < CURDATE() ORDER BY session_date DESC LIMIT 1);
SET @sen1 = (SELECT id FROM sessions WHERE training_program_id = @seniors
             ORDER BY session_date LIMIT 1);
SET @sen2 = (SELECT id FROM sessions WHERE training_program_id = @seniors
             ORDER BY session_date DESC LIMIT 1);
SET @jun3 = (SELECT id FROM sessions WHERE training_program_id = @juniors
             AND session_date > CURDATE() LIMIT 1);

-- Rosters: who was actually called to each session
INSERT INTO session_players (session_id, player_id, added_by) VALUES
  (@jun1, @ana, @admin), (@jun1, @mia, @admin), (@jun1, @noah, @admin),
  (@jun1, @zara, @admin), (@jun1, @sofia, @admin), (@jun1, @leila, @admin),
  (@jun2, @ana, @admin), (@jun2, @mia, @admin), (@jun2, @noah, @admin),
  (@jun2, @zara, @admin), (@jun2, @omar, @admin), (@jun2, @elena, @admin),
  (@sen1, @diego, @admin), (@sen1, @isla, @admin), (@sen1, @ethan, @admin),
  (@sen1, @liam, @admin), (@sen1, @kenji, @admin), (@sen1, @adam, @admin),
  (@sen2, @diego, @admin), (@sen2, @isla, @admin), (@sen2, @ethan, @admin),
  (@sen2, @marco, @admin), (@sen2, @kenji, @admin),
  (@jun3, @ana, @admin), (@jun3, @mia, @admin), (@jun3, @zara, @admin);

-- Attendance: present and absent are both billable, exempt is free — the mix
-- below gives players different fees, so the Payments filters have variety.
INSERT INTO attendance (session_id, player_id, status, marked_by) VALUES
  (@jun1, @ana, 'present', @admin),
  (@jun1, @mia, 'present', @admin),
  (@jun1, @noah, 'absent',  @admin),
  (@jun1, @zara, 'present', @admin),
  (@jun1, @sofia,'exempt',  @admin),
  (@jun1, @leila,'present', @admin),
  (@jun2, @ana, 'present', @admin),
  (@jun2, @mia, 'absent',  @admin),
  (@jun2, @noah, 'present', @admin),
  (@jun2, @zara, 'present', @admin),
  (@jun2, @omar, 'present', @admin),
  (@jun2, @elena,'exempt',  @admin),
  (@sen1, @diego, 'present', @admin),
  (@sen1, @isla,  'present', @admin),
  (@sen1, @ethan, 'absent',  @admin),
  (@sen1, @liam,  'present', @admin),
  (@sen1, @kenji, 'present', @admin),
  (@sen1, @adam,  'exempt',  @admin),
  (@sen2, @diego, 'present', @admin),
  (@sen2, @isla,  'absent',  @admin),
  (@sen2, @ethan, 'present', @admin),
  (@sen2, @marco, 'present', @admin),
  (@sen2, @kenji, 'present', @admin);


-- -----------------------------------------------------------------------------
-- Tournaments
-- -----------------------------------------------------------------------------
INSERT INTO tournaments (category_id, name, location, payment_info, created_by)
SELECT id, 'Victory Cup', 'Main Court', 'AED 400 per player', @admin
FROM categories WHERE code = 'B2013';

INSERT INTO tournaments (category_id, name, location, payment_info, created_by)
SELECT id, 'Founders Shield', 'City Arena', 'AED 250 per player', @admin
FROM categories WHERE code = 'B2011';

SET @victory  = (SELECT id FROM tournaments WHERE name = 'Victory Cup');
SET @founders = (SELECT id FROM tournaments WHERE name = 'Founders Shield');

-- consent 'accepted': these families are billed below, and since 2026-09-23 a
-- tournament can't be billed until everyone on it has accepted. Left to the
-- column default ('pending') they'd be billed without having said yes, and
-- the admin couldn't change the fee.
INSERT INTO tournament_players (tournament_id, player_id, amount, consent) VALUES
  (@victory,  @ana,   400.00, 'accepted'),
  (@victory,  @mia,   400.00, 'accepted'),
  (@victory,  @zara,  400.00, 'accepted'),
  (@victory,  @leila, 400.00, 'accepted'),
  (@founders, @diego, 250.00, 'accepted'),
  (@founders, @kenji, 250.00, 'accepted'),
  (@founders, @isla,  250.00, 'accepted');


-- -----------------------------------------------------------------------------
-- Payments — a deliberate mix so every filter and state has something in it.
--   tournament : some requested, one already settled
--   misc       : one pending, one paid
--   training   : one month already settled for a single player
-- -----------------------------------------------------------------------------
-- amount_paid tracks part-payments, so it has to match the status: a
-- settled row has paid its full amount, a pending one has paid none of it.
-- Isla's is deliberately half-settled, to exercise the PART PAID state.
INSERT INTO payments
  (player_id, payment_type, title, misc_type, tournament_id, period_month,
   amount, amount_paid, status, paid_at, created_by)
VALUES
  -- Victory Cup requests: Ana has paid, the rest haven't.
  (@ana,   'tournament', 'Victory Cup Fee',    NULL, @victory,  NULL, 400.00, 400.00, 'paid',    NOW(), @admin),
  (@mia,   'tournament', 'Victory Cup Fee',    NULL, @victory,  NULL, 400.00,   0.00, 'pending', NULL,  @admin),
  (@zara,  'tournament', 'Victory Cup Fee',    NULL, @victory,  NULL, 400.00,   0.00, 'pending', NULL,  @admin),
  -- Founders Shield: Diego owes it all, Isla has paid half of hers.
  (@diego, 'tournament', 'Founders Shield Fee',NULL, @founders, NULL, 250.00,   0.00, 'pending', NULL,  @admin),
  (@isla,  'tournament', 'Founders Shield Fee',NULL, @founders, NULL, 250.00, 125.00, 'pending', NULL,  @admin),
  -- Misc requests
  (@noah,  'misc', 'Uniform', 'uniform', NULL, NULL, 130.00,   0.00, 'pending', NULL,  @admin),
  (@liam,  'misc', 'Merch',   'merch',   NULL, NULL,  80.00,  80.00, 'paid',    NOW(), @admin),
  -- A training fee already settled for last month, to prove month handling.
  (@kenji, 'training_fee',
   CONCAT(DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 1 MONTH), '%M %Y'), ' Training Fee'),
   NULL, NULL,
   DATE_SUB(DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY), INTERVAL 1 MONTH),
   225.00, 225.00, 'paid', NOW(), @admin);

-- Every seeded payment with money on it gets its matching transaction, so
-- amount_paid and the transaction log agree from the start.
INSERT INTO payment_transactions (payment_id, kind, amount, method, note, recorded_by)
SELECT id, 'payment', amount_paid, 'cash', 'Seed data', @admin
FROM payments WHERE amount_paid > 0;

-- A discount for one family, so the override path has something to show.
INSERT INTO training_fee_overrides (player_id, period_month, amount, note, set_by)
VALUES (@omar,
        DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY),
        75.00, 'Sibling discount', @admin);


-- -----------------------------------------------------------------------------
-- One order waiting on approval, so Order Validation isn't empty
-- -----------------------------------------------------------------------------
SET @item_league   := (SELECT id FROM order_items WHERE code = 'league_uniform');
SET @item_training := (SELECT id FROM order_items WHERE code = 'training_uniform');

INSERT INTO orders (player_id, order_item_id, amount, status, requested_by)
VALUES
  (@sofia, @item_league,   130.00, 'pending', @p_gomez),
  (@marco, @item_training, 100.00, 'pending', @p_ocampo);


-- -----------------------------------------------------------------------------
-- Announcements
-- -----------------------------------------------------------------------------
INSERT INTO announcements (title, body, is_everyone, sent_by) VALUES
  ('Welcome to the new season',
   'Training resumes this week. Please arrive 15 minutes early for warm-ups.',
   1, @admin),
  ('Victory Cup squad announced',
   'The B2013 squad for the Victory Cup has been posted. Fees are due before '
   'the first fixture.',
   0, @admin);

SET @ann2 = (SELECT id FROM announcements WHERE title = 'Victory Cup squad announced');
INSERT INTO announcement_categories (announcement_id, category_id)
SELECT @ann2, id FROM categories WHERE code = 'B2013';


-- -----------------------------------------------------------------------------
-- What you should see
-- -----------------------------------------------------------------------------
SELECT 'admins'   AS what, COUNT(*) AS n FROM users WHERE role = 'admin'
UNION ALL SELECT 'parents (approved)', COUNT(*) FROM users WHERE role = 'parent' AND status = 'approved'
UNION ALL SELECT 'parents (pending)',  COUNT(*) FROM users WHERE status = 'pending'
UNION ALL SELECT 'players',            COUNT(*) FROM players
UNION ALL SELECT 'sessions',           COUNT(*) FROM sessions
UNION ALL SELECT 'attendance marks',   COUNT(*) FROM attendance
UNION ALL SELECT 'tournaments',        COUNT(*) FROM tournaments
UNION ALL SELECT 'payments',           COUNT(*) FROM payments
UNION ALL SELECT 'orders pending',     COUNT(*) FROM orders WHERE status = 'pending';
