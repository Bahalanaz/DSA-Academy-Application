-- November 2026 batch, part 2. Run AFTER 2026-11-10_sizes_and_paid_notice.sql.
-- Safe on a live database: only adds things, and the families' 1.0.23 app
-- keeps working (it ignores the nickname, and shows a birthday message as a
-- normal message).
--
-- 1. Players get an optional nickname ("Kiko"). A family can give one when
--    adding a child; after that only the academy changes it.
-- 2. A new kind of automatic message, "birthday": the server wishes each
--    player a happy birthday on the day (from 7 am, once a year).
--
-- Back up first, then:
--   sudo mysql --default-character-set=utf8mb4 dsa_db < 2026-11-11_nickname_birthday.sql

ALTER TABLE players
  ADD COLUMN nickname VARCHAR(30) NULL AFTER full_name;

ALTER TABLE announcements
  MODIFY auto_kind ENUM('sessions_cancelled','tournament_cancelled',
                        'session_changed','sessions_added',
                        'jersey_number','order_given','payment_paid',
                        'tournament_reminder','tournament_declined',
                        'birthday') NULL;
