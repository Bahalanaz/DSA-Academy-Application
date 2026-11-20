-- November 2026 batch. Safe to run on a live database: nothing is lost, and
-- the families' 1.0.23 app keeps working (the server takes its "XXS" as 2XS).
--
-- 1. Jersey sizes become 3XS, 2XS, XS, S, M, L, XL, 2XL, 3XL, 9-10, 11-12.
--    XXS is renamed 2XS: every player who has XXS gets 2XS.
-- 2. A new kind of automatic message: "payment_paid", sent to the family
--    when the admin marks a bill (training fee, tournament fee, order or
--    other payment) as fully paid, and "tournament_reminder" when the admin
--    reminds families to answer a tournament invitation, and
--    "tournament_declined" (the admin is told a family declined, and why).
--
-- Back up first, then:
--   sudo mysql --default-character-set=utf8mb4 dsa_db < 2026-11-10_sizes_and_paid_notice.sql

-- Old and new sizes allowed together for a moment, so XXS can be renamed.
ALTER TABLE players
  MODIFY jersey_size ENUM('XXS','3XS','2XS','XS','S','M','L','XL','2XL','3XL',
                          '9-10','11-12') NULL;

UPDATE players SET jersey_size = '2XS' WHERE jersey_size = 'XXS';

-- The final list, without XXS.
ALTER TABLE players
  MODIFY jersey_size ENUM('3XS','2XS','XS','S','M','L','XL','2XL','3XL',
                          '9-10','11-12') NULL;

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed','sessions_added',
                        'jersey_number','order_given','payment_paid',
                        'tournament_reminder','tournament_declined') NULL;

-- 3. Why a family declined a tournament invitation (the app asks for it).
ALTER TABLE tournament_players
  ADD COLUMN decline_reason VARCHAR(300) NULL AFTER consent;
