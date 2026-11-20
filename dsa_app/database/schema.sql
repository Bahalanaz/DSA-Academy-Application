-- =============================================================================
-- DSA Elite — database schema (draft, not wired into the app yet)
-- Updated to match the app as it actually stands today.
--
-- Dialect: MySQL 8 (XAMPP / MariaDB friendly).
-- For PostgreSQL / Supabase instead:
--   BIGINT UNSIGNED AUTO_INCREMENT  ->  BIGSERIAL / GENERATED ALWAYS AS IDENTITY
--   ENUM('a','b')                   ->  TEXT + CHECK (col IN ('a','b'))
--   DATETIME                        ->  TIMESTAMPTZ
--   ON UPDATE CURRENT_TIMESTAMP     ->  a trigger, or handle it in app code
--
-- Naming: tables are plural, FKs are <singular_table>_id.
-- Every table the app writes to keeps created_at so history is traceable.
--
-- -----------------------------------------------------------------------------
-- WHAT CHANGED SINCE THE FIRST DRAFT (and why)
-- -----------------------------------------------------------------------------
--  1. Categories are birth-year based now ("B2013"), not "U13". Added an
--     explicit birth_year column so sorting and the tournament overage rule
--     are real comparisons instead of parsing digits out of a string.
--  2. A training program spans MANY categories (e.g. B2012 + B2013 train
--     together), so training_programs.category_id became a junction table.
--  3. Session rosters are explicit. The app no longer derives "who is in this
--     session" from category membership — an admin adds players to each
--     individual session, because attendance to a recurring training is not
--     the same group every week. Hence session_players.
--  4. Tournaments lost their date column (removed from the app) and gained
--     per-player amounts (tournament_players.amount).
--  5. Payments were rebuilt around the real fee logic:
--       training fee = coach_fee + (per_session_rate x billable sessions)
--       billable = present + absent; exempt sessions are not charged.
--     A training fee is COMPUTED LIVE from attendance and only becomes a
--     payments row once it is actually settled — so a player can have several
--     partial training-fee rows in one month, and the old
--     UNIQUE(player_id, period_start) had to go.
--  6. The two fee numbers are admin-editable in-app, so they live in
--     fee_settings rather than being hardcoded.
--  7. Announcements can target MULTIPLE categories at once (or everyone),
--     so audience_category_id became a junction table + an is_everyone flag.
--  8. Dropped player_stats and players.height_cm — both were removed from
--     the app (the parent-side Stats tab and height field no longer exist).
--  9. Orders: parents can now request a uniform/shirt from the parent-side
--     Orders screen, and an admin has to approve it before it becomes money
--     owed. That approval gate is the whole point — a parent could otherwise
--     invent a charge for someone else's child — so an order is its own row
--     with its own status, and only turns into a payments row once approved.
--  9b. player_categories is GONE. A category is a birth year, so a player's
--     category now comes from YEAR(players.birthday) rather than being
--     assigned by hand — two sources of truth for the same fact meant they
--     could disagree. Rosters (who trains/competes together) are assigned
--     per session and per tournament instead, which is the thing the admin
--     actually wanted control over.
-- 10. A training fee can be overridden per player, per month
--     (training_fee_overrides): the admin can type a custom total — a
--     discount, a special arrangement — instead of only being able to move
--     the shared coach_fee / per_session_rate numbers, which re-price
--     everybody. v_player_training_fee prefers the override when one exists.
-- =============================================================================

-- DATABASE NAME
-- Everything below runs inside dsa_db. It is named in exactly these two
-- statements, so rename it here (and nowhere else) if you want a different one.
--
-- RE-RUNNING THIS FILE?
-- CREATE TABLE fails if the table already exists, so running this a second
-- time errors out partway through. To start clean, uncomment the line below.
--
-- !! THIS DELETES THE DATABASE AND EVERYTHING IN IT. Only for development. !!
--
-- DROP DATABASE IF EXISTS dsa_db;

CREATE DATABASE IF NOT EXISTS dsa_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE dsa_db;


-- =============================================================================
-- 1. ACCOUNTS
-- =============================================================================

-- Every login: parents and admins/coaches alike.
-- `status` is the Account Validation screen — a new signup lands as 'pending'
-- and cannot log in until an admin approves it. That is the second gate that
-- keeps randoms out of the app.
-- The signup form collects: full name, email, phone, password.
CREATE TABLE users (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  role            ENUM('parent','admin') NOT NULL DEFAULT 'parent',
  full_name       VARCHAR(120)    NOT NULL,
  username        VARCHAR(60)     NOT NULL,
  email           VARCHAR(160)    NOT NULL,
  phone           VARCHAR(30)         NULL,   -- collected at signup
  password_hash   VARCHAR(255)    NOT NULL,   -- bcrypt/argon2 hash, never plaintext
  -- Set when an admin resets the password to a temporary one: the parent
  -- must choose their own at the next login before anything else works.
  must_change_password TINYINT(1) NOT NULL DEFAULT 0,
  photo_url       VARCHAR(255)        NULL,   -- account photo: /photos/user/<id>?v=..
  -- disabled: an approved account switched off by the admin (reversible).
  -- Only approved accounts get past the server's auth check.
  status          ENUM('pending','approved','rejected','disabled') NOT NULL DEFAULT 'pending',
  approved_by     BIGINT UNSIGNED     NULL,   -- which admin approved/rejected it
  approved_at     DATETIME            NULL,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                  ON UPDATE CURRENT_TIMESTAMP,
  -- A parent who deleted their own account (POST /auth/delete-account).
  -- The row is anonymised, not removed: the club's payment records stay
  -- linked to the children. Never listed or reactivated.
  deleted_at      DATETIME            NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_username (username),
  UNIQUE KEY uq_users_email    (email),
  KEY idx_users_status (status),
  CONSTRAINT fk_users_approved_by
    FOREIGN KEY (approved_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- Login sessions. /auth/login issues a random token, the app sends it as
-- "Authorization: Bearer <token>" on every request, and the server checks it
-- here. Only a SHA-256 hash is stored, so a copy of this table can't be
-- replayed as a login. Deleting a row logs that device out immediately.
CREATE TABLE auth_sessions (
  token_hash    CHAR(64)        NOT NULL,
  user_id       BIGINT UNSIGNED NOT NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at    DATETIME        NOT NULL,
  PRIMARY KEY (token_hash),
  KEY idx_auth_sessions_user (user_id),
  KEY idx_auth_sessions_expires (expires_at),
  CONSTRAINT fk_auth_sessions_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Profile photos for accounts and players ("Take Photo" / "Choose from
-- Gallery"), kept in the database so backups include them. The phone
-- shrinks them first. users.photo_url / players.photo_url hold the address
-- the app loads one from (with a version), NULL = no photo. Who may see
-- one is checked by the server (dsa_server/lib/photos_routes.dart).
CREATE TABLE profile_photos (
  kind        ENUM('user','player') NOT NULL,
  owner_id    BIGINT UNSIGNED       NOT NULL,   -- users.id or players.id
  image       MEDIUMBLOB            NOT NULL,
  mime        VARCHAR(20)           NOT NULL,   -- image/jpeg or image/png
  updated_at  DATETIME              NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, owner_id)
) ENGINE = InnoDB;


-- Where to send a phone's push notifications (Firebase Cloud Messaging).
-- Each row belongs to the login it was registered under, so logging out,
-- a password change, deactivating or deleting the account removes it.
CREATE TABLE device_tokens (
  token         VARCHAR(512)    NOT NULL,   -- the FCM registration token
  session_hash  CHAR(64)        NOT NULL,   -- auth_sessions.token_hash
  user_id       BIGINT UNSIGNED NOT NULL,
  platform      ENUM('android','ios','web') NOT NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (token),
  KEY idx_device_tokens_user (user_id),
  KEY idx_device_tokens_session (session_hash),
  CONSTRAINT fk_device_tokens_session
    FOREIGN KEY (session_hash) REFERENCES auth_sessions (token_hash)
    ON DELETE CASCADE,
  CONSTRAINT fk_device_tokens_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Password reset / "forgot password" flow.
CREATE TABLE password_resets (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id     BIGINT UNSIGNED NOT NULL,
  token_hash  VARCHAR(255)    NOT NULL,
  expires_at  DATETIME        NOT NULL,
  -- Wrong codes tried against this request: it stops working after 5.
  attempts    TINYINT UNSIGNED NOT NULL DEFAULT 0,
  used_at     DATETIME            NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_password_resets_user (user_id),
  CONSTRAINT fk_password_resets_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- =============================================================================
-- 2. CATEGORIES  (B2011, B2012, B2013 … one club split by birth year)
-- =============================================================================

-- Named by birth year: "B2013" = players born 2013. A LARGER year means a
-- YOUNGER player — that direction matters for the tournament overage rule
-- (a player born earlier than the bracket is too old to play down into it).
--
-- birth_year is stored rather than parsed out of the code, so ordering is a
-- plain ORDER BY and the overage check is a plain comparison.
--
-- Created only from the admin Categories screen (Home > Categories), which is
-- the single place new categories are added or removed app-wide.
--
-- "Removing" one sets is_active = 0 rather than deleting the row: a delete
-- cascaded through announcement_categories and made messages sent to that
-- birth year vanish for its parents. Adding the same code back reactivates it.
CREATE TABLE categories (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code        VARCHAR(20)     NOT NULL,          -- 'B2013'
  birth_year  SMALLINT UNSIGNED   NULL,          -- 2013 — drives sorting & age checks
  label       VARCHAR(60)         NULL,          -- optional long form, e.g. 'Born 2013'
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_categories_code (code),
  KEY idx_categories_birth_year (birth_year)
) ENGINE = InnoDB;


-- =============================================================================
-- 3. PLAYERS
-- =============================================================================

-- A player belongs to one parent account. Fields match the parent-side player
-- form: name, birthday, jersey number. Height, position, and the stats tab
-- were all removed from the app, so none of them are here.
--
-- THERE IS NO CATEGORY COLUMN, and no player_categories table any more. A
-- category IS a birth year (B2013 = born 2013), so a player's category is
-- derived by joining categories.birth_year to YEAR(players.birthday). That
-- removed a whole class of wrong: a player could previously sit in B2012
-- while being born in 2014, because the two were maintained separately.
--
-- Which players actually train or compete together is a different question,
-- and is answered per roster (session_players, tournament_players) — the
-- admin puts whoever they want in a session or tournament regardless of
-- birth year.
CREATE TABLE players (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  parent_id      BIGINT UNSIGNED NOT NULL,       -- the guardian's user account
  full_name      VARCHAR(120)    NOT NULL,
  -- What the team calls them ("Kiko"). Optional: the family can give one
  -- when adding the child; after that only the academy changes it.
  nickname       VARCHAR(30)         NULL,
  birthday       DATE                NULL,
  jersey_number  VARCHAR(10)         NULL,
  -- Shirt size for kit orders. NULL for players added before sizes existed.
  jersey_size    ENUM('3XS','2XS','XS','S','M','L','XL','2XL','3XL','9-10','11-12') NULL,
  -- A number is "taken" if any active, approved player in the academy wears
  -- it (07 and 7 are the same number). A family may still ask for a taken
  -- number: it waits here for the admin's Player Validation screen, and an
  -- approved duplicate is allowed — so there is no unique key on numbers.
  jersey_request VARCHAR(10)         NULL,   -- the taken number asked for
  jersey_request_status ENUM('pending','declined') NULL,
  jersey_requested_at   DATETIME     NULL,
  photo_url      VARCHAR(255)        NULL,
  is_active      TINYINT(1)      NOT NULL DEFAULT 1,
  -- 0 = a NEW player whose taken number is waiting for (or was refused by)
  -- the admin. Not a real player yet: kept off rosters, bills, orders and
  -- the admin's lists until approved.
  is_approved    TINYINT(1)      NOT NULL DEFAULT 1,
  created_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  -- One active child per name and birthday on an account. The server checks
  -- first; this stops the same child being added twice when the account is
  -- signed in on two phones and both save at once. NULL once removed.
  active_child_key VARCHAR(160) GENERATED ALWAYS AS (
    CASE WHEN is_active = 1
         THEN CONCAT(parent_id, '|', full_name, '|',
                     COALESCE(birthday, '')) END
  ) VIRTUAL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_players_active_child (active_child_key),
  KEY idx_players_parent (parent_id),
  KEY idx_players_jersey_request (jersey_request_status),
  CONSTRAINT fk_players_parent
    FOREIGN KEY (parent_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Awards a player has received (MVP, Most Improved ...), with the league.
-- The admin adds, edits and removes any; a parent adds them for their own
-- children and edits or removes only the ones they added (Player Profile >
-- AWARDS). Kept when a player is removed (the
-- player row is soft-deleted), gone only if the player row itself is.
CREATE TABLE player_awards (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  player_id    BIGINT UNSIGNED NOT NULL,
  title        VARCHAR(120)    NOT NULL,
  league       VARCHAR(120)        NULL,   -- the league it was won in
  category_id  BIGINT UNSIGNED     NULL,   -- which of the academy's categories
  award_date   DATE            NOT NULL,
  created_by   BIGINT UNSIGNED     NULL,   -- who added it (admin or parent)
  created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_player_awards_player (player_id, award_date),
  CONSTRAINT fk_player_awards_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_player_awards_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_player_awards_category
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE SET NULL,
  CONSTRAINT chk_player_awards_title CHECK (CHAR_LENGTH(TRIM(title)) > 0)
) ENGINE = InnoDB;


-- =============================================================================
-- 4. TRAINING PROGRAMS  &  TOURNAMENTS
-- =============================================================================

-- The recurring thing created on the Trainings screen. It spans one or more
-- categories, because the club trains in batches (e.g. B2012 and B2013 train
-- together). Scheduled sessions point back here by id — never by matching
-- category text — so renaming a category never orphans a session.
CREATE TABLE training_programs (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name        VARCHAR(120)        NULL,  -- optional; NULL shows as "<categories> Training"
  -- Deleting a training sets this to 0 and cancels only its sessions AFTER
  -- today. Sessions up to today stay, so fees they earned still stand.
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  created_by  BIGINT UNSIGNED     NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT fk_training_programs_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- Which categories a training program covers. The app builds its display
-- label by joining these ("B2013, B2012 Training").
CREATE TABLE training_program_categories (
  training_program_id  BIGINT UNSIGNED NOT NULL,
  category_id          BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (training_program_id, category_id),
  KEY idx_tpc_category (category_id),
  CONSTRAINT fk_tpc_program
    FOREIGN KEY (training_program_id) REFERENCES training_programs (id) ON DELETE CASCADE,
  CONSTRAINT fk_tpc_category
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE RESTRICT
) ENGINE = InnoDB;


-- A tournament the club enters, scoped to one category. No date column — the
-- app dropped it; a tournament's dates live on its schedule rows instead.
--
-- payment_info is the free-text line the admin types on the tournament screen
-- ("AED 500 per player"); the number parsed out of it seeds each player's
-- amount in tournament_players, which the admin can then fine-tune per player.
CREATE TABLE tournaments (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  category_id   BIGINT UNSIGNED NOT NULL,
  name          VARCHAR(120)    NOT NULL,     -- 'Victory Cup'
  location      VARCHAR(160)        NULL,
  payment_info  VARCHAR(160)        NULL,     -- 'AED 500 per player'
  created_by    BIGINT UNSIGNED     NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  -- Soft delete. A hard delete cascaded into sessions (every game, past ones
  -- and their attendance included) and announcement_tournaments (messages
  -- lost their audience). Deleting now withdraws unpaid bills, cancels games
  -- after today and sets this; nothing that already happened is erased.
  deleted_at    DATETIME            NULL,
  PRIMARY KEY (id),
  KEY idx_tournaments_category (category_id),
  KEY idx_tournaments_deleted (deleted_at),
  CONSTRAINT fk_tournaments_category
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE RESTRICT,
  CONSTRAINT fk_tournaments_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- The roster assigned to a tournament, with what each player owes for it.
-- amount starts at the tournament's base figure and can be overridden per
-- player in the app's manage mode.
--
-- Adding a player is an invitation: consent starts 'pending' and the family
-- accepts or declines from the app. The tournament can't be priced or billed
-- until every player on it has accepted (consentBlocker in
-- dsa_server/lib/tournaments_routes.dart). A declined player stays listed
-- until the admin takes them off, and is left off the game rosters.
CREATE TABLE tournament_players (
  tournament_id  BIGINT UNSIGNED NOT NULL,
  player_id      BIGINT UNSIGNED NOT NULL,
  amount         DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
  consent        ENUM('pending','accepted','declined') NOT NULL DEFAULT 'pending',
  decline_reason VARCHAR(300)        NULL,   -- why the family declined (their words)
  responded_at   DATETIME            NULL,
  responded_by   BIGINT UNSIGNED     NULL,
  added_at       DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- When the family's "tournament invitation" notification went out
  -- (dsa_server/lib/push.dart). NULL = not yet.
  pushed_at      DATETIME            NULL,
  PRIMARY KEY (tournament_id, player_id),
  KEY idx_tournament_players_player (player_id),
  KEY idx_tournament_players_push (pushed_at, added_at),
  CONSTRAINT fk_tournament_players_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE CASCADE,
  CONSTRAINT fk_tournament_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_tournament_players_responded_by
    FOREIGN KEY (responded_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;

-- A tournament's opposing teams (Standings screen). A scheduled game picks
-- its opponent from here (saved on the game as 'vs. <name>').
CREATE TABLE tournament_opponents (
  id             BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
  tournament_id  BIGINT UNSIGNED   NOT NULL,
  name           VARCHAR(40)       NOT NULL,
  created_at     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tournament_opponents_name (tournament_id, name),
  CONSTRAINT fk_tournament_opponents_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- =============================================================================
-- 5. SCHEDULE  (one table for both training and tournament sessions)
-- =============================================================================

-- Everything that lands on the calendar. A 'training' row links to a training
-- program (which carries its own categories); a 'tournament' row links to a
-- tournament (which carries one). end_time is only meaningful for trainings
-- (start + end = duration); tournaments carry an opponent instead.
--
-- category_label is denormalised display text only ("B2013 & B2012") — never
-- join on it; the real relationships go through the program/tournament.
CREATE TABLE sessions (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  session_type         ENUM('training','tournament') NOT NULL,
  training_program_id  BIGINT UNSIGNED     NULL,   -- required when type = 'training'
  tournament_id        BIGINT UNSIGNED     NULL,   -- required when type = 'tournament'
  category_label       VARCHAR(120)        NULL,   -- display only
  session_date         DATE            NOT NULL,
  start_time           TIME            NOT NULL,
  end_time             TIME                NULL,   -- trainings only
  location             VARCHAR(160)        NULL,
  opponent             VARCHAR(120)        NULL,   -- 'vs. Victory Hoops'
  -- A game's final score, entered after it's played (both NULL until then).
  -- The winner and the Standings are counted from these.
  dsa_score            SMALLINT UNSIGNED   NULL,
  opponent_score       SMALLINT UNSIGNED   NULL,
  notes                TEXT                NULL,
  is_cancelled         TINYINT(1)      NOT NULL DEFAULT 0,
  created_by           BIGINT UNSIGNED     NULL,
  created_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                       ON UPDATE CURRENT_TIMESTAMP,
  -- One live session per training (or tournament), day and start time. The
  -- server checks first; this stops a double save when two phones add or
  -- move a session at the same moment. NULL once cancelled.
  live_slot_key        VARCHAR(80) GENERATED ALWAYS AS (
    CASE WHEN is_cancelled = 0
         THEN CONCAT(session_type, '|',
                     COALESCE(training_program_id, tournament_id), '|',
                     session_date, '|', start_time) END
  ) VIRTUAL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_live_slot (live_slot_key),
  KEY idx_sessions_date       (session_date),
  KEY idx_sessions_program    (training_program_id, session_date),
  KEY idx_sessions_tournament (tournament_id),
  CONSTRAINT fk_sessions_program
    FOREIGN KEY (training_program_id) REFERENCES training_programs (id) ON DELETE CASCADE,
  CONSTRAINT fk_sessions_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE CASCADE,
  CONSTRAINT fk_sessions_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  -- A training session must point at a program, and a tournament game at a
  -- tournament: that is what the roster and the fees hang off. One-off
  -- fixtures with no tournament were allowed in an early draft, but the app
  -- has not offered them since (POST /sessions refuses one), and the live
  -- database has always carried this stricter rule.
  CONSTRAINT chk_sessions_link CHECK (
    (session_type = 'training'
       AND training_program_id IS NOT NULL AND tournament_id IS NULL)
    OR
    (session_type = 'tournament'
       AND tournament_id IS NOT NULL AND training_program_id IS NULL)
  )
) ENGINE = InnoDB;


-- A training's default players (Trainings > a training > settings): put on
-- every NEW session of that training automatically. Each training has its
-- own list; changing it never touches sessions already scheduled.
CREATE TABLE training_default_players (
  training_program_id  BIGINT UNSIGNED NOT NULL,
  player_id            BIGINT UNSIGNED NOT NULL,
  added_at             DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (training_program_id, player_id),
  KEY idx_training_default_players_player (player_id),
  CONSTRAINT fk_training_default_players_program
    FOREIGN KEY (training_program_id) REFERENCES training_programs (id)
    ON DELETE CASCADE,
  CONSTRAINT fk_training_default_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Who is on the roster for THIS specific session.
--
-- This is deliberately explicit rather than derived from category membership:
-- the app lets an admin add players to one session's roster at a time, because
-- "players will join those trainings but not all the time". The Add Players
-- screen offers players in the session's categories first, then everyone else.
CREATE TABLE session_players (
  session_id  BIGINT UNSIGNED NOT NULL,
  player_id   BIGINT UNSIGNED NOT NULL,
  added_by    BIGINT UNSIGNED     NULL,
  added_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (session_id, player_id),
  KEY idx_session_players_player (player_id),
  CONSTRAINT fk_session_players_session
    FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_session_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_session_players_added_by
    FOREIGN KEY (added_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- =============================================================================
-- 6. ATTENDANCE
-- =============================================================================

-- One row per player per session. No row = "unmarked", so the app's default
-- state needs no storage. Written when the admin confirms the roster edit.
--
-- This table is the ONLY input to a training fee: present and absent are both
-- billable, exempt is not. See v_player_month_attendance below.
CREATE TABLE attendance (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  session_id  BIGINT UNSIGNED NOT NULL,
  player_id   BIGINT UNSIGNED NOT NULL,
  status      ENUM('present','absent','exempt') NOT NULL,
  note        VARCHAR(255)        NULL,   -- e.g. reason for the exemption
  marked_by   BIGINT UNSIGNED     NULL,
  marked_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                              ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_attendance_session_player (session_id, player_id),
  KEY idx_attendance_player (player_id),
  CONSTRAINT fk_attendance_session
    FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_attendance_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_attendance_marked_by
    FOREIGN KEY (marked_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- =============================================================================
-- 7. FEE SETTINGS  (the two numbers every training fee is built from)
-- =============================================================================

-- Single-row config table, editable from the Training Fees screen's settings
-- icon. Kept as a table (not constants) because the club can change its rates.
--
--   monthly total = coach_fee + (per_session_rate x billable sessions)
--
-- coach_fee is flat and never reduced by attendance; per_session_rate is
-- charged for every present/absent session.
--
-- This table is only ever "the price TODAY" — what the settings dialog shows
-- and what a session booked from now on will cost. Nothing bills off it. The
-- history in fee_rates below is what billing reads.
CREATE TABLE fee_settings (
  id                 TINYINT UNSIGNED NOT NULL DEFAULT 1,
  coach_fee          DECIMAL(10,2) NOT NULL DEFAULT 100.00,
  per_session_rate   DECIMAL(10,2) NOT NULL DEFAULT 31.25,
  currency           CHAR(3)       NOT NULL DEFAULT 'AED',
  updated_by         BIGINT UNSIGNED   NULL,
  updated_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                   ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT chk_fee_settings_singleton CHECK (id = 1),
  CONSTRAINT fk_fee_settings_updated_by
    FOREIGN KEY (updated_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- When each price started applying. Every training fee is priced from here,
-- never from fee_settings.
--
-- Without this, changing a rate re-priced everything retroactively, and the
-- damage wasn't hypothetical: raising the per-session rate in September moved
-- a parent's already-issued August bill from 131.25 to 150, and raised a
-- brand-new 18.75 invoice against another parent who had already paid August
-- off in full. A price they were quoted and settled must stay settled.
--
-- How a month is priced:
--   * each session       -> the per_session_rate whose effective_from is the
--                           latest one on or before that session's date, so a
--                           month spanning a change bills each half correctly
--   * the flat coach fee -> the coach_fee in force on the FIRST of the month,
--                           because it's a charge for the month as a whole and
--                           the month is already under way when the admin
--                           changes it. A mid-month change lands next month.
--
-- A change is always recorded as effective from the day it's made, so it can
-- never reach backwards. Changing the rate twice in one day replaces that
-- day's row (hence the UNIQUE) rather than stacking another on top.
--
-- The 2000-01-01 seed row exists so there is always a rate to find for any
-- session date, however old; the lookups rely on never getting NULL back.
CREATE TABLE fee_rates (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  effective_from     DATE            NOT NULL,
  coach_fee          DECIMAL(10,2)   NOT NULL,
  per_session_rate   DECIMAL(10,2)   NOT NULL,
  set_by             BIGINT UNSIGNED     NULL,
  created_at         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_fee_rates_from (effective_from),
  CONSTRAINT fk_fee_rates_set_by
    FOREIGN KEY (set_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- A custom monthly total for ONE player, replacing the calculated fee for
-- that month only.
--
-- fee_settings above moves the numbers for the whole club; this is the
-- pencil on the player's fee breakdown — a discount, a family arrangement,
-- a one-off correction. It stores the final total, not an adjustment, so
-- what the admin typed is exactly what gets charged and later rate changes
-- can't quietly move it.
--
-- Deleting the row reverts that month to the calculated amount, which is
-- what the app's "Reset to calculated amount" does.
CREATE TABLE training_fee_overrides (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  player_id     BIGINT UNSIGNED NOT NULL,
  period_month  DATE            NOT NULL,   -- first day of the month it covers
  amount        DECIMAL(10,2)   NOT NULL,   -- the whole total, not a delta
  note          VARCHAR(255)        NULL,   -- why, e.g. 'sibling discount'
  set_by        BIGINT UNSIGNED     NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tfo_player_month (player_id, period_month),
  CONSTRAINT fk_tfo_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_tfo_set_by
    FOREIGN KEY (set_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- =============================================================================
-- 8. PAYMENTS
-- =============================================================================

-- One row per payment obligation, of three kinds:
--
--   'training_fee' — the monthly fee. NOT created upfront: it is computed live
--                    from attendance (see v_player_training_fee) and only
--                    written here once actually settled. Several partial rows
--                    can exist for the same player and month, so what is still
--                    owed = computed total - SUM(paid rows for that month).
--                    period_month holds the first day of the month it covers.
--
--   'tournament'   — created when the admin taps SEND PAYMENTS on a tournament.
--                    Links to the tournament so it is never matched by title.
--
--   'misc'         — one-off request (uniform, merch, other) sent from the Misc
--                    Payments screen, with a free-text description.
--
-- NOTE: there is deliberately NO unique key on (player_id, period_month).
-- The old draft had one; it is wrong now, because a month can legitimately
-- hold multiple settled training-fee rows.
CREATE TABLE payments (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  player_id      BIGINT UNSIGNED NOT NULL,
  payment_type   ENUM('training_fee','tournament','misc') NOT NULL,
  title          VARCHAR(160)    NOT NULL,   -- 'May 2025 Training Fee', 'Victory Cup Fee', 'Uniform'
  description    TEXT                NULL,   -- misc only: 'Away-kit jersey, size M'
  misc_type      ENUM('uniform','merch','others') NULL,   -- misc only
  tournament_id  BIGINT UNSIGNED     NULL,   -- tournament only
  period_month   DATE                NULL,   -- training_fee only: first day of the month
  amount         DECIMAL(10,2)   NOT NULL,
  -- How much of `amount` has actually been handed over. Parents can pay a
  -- request off in parts (owe 300, pay 200 now), so "paid or not" was too
  -- coarse: status only flips to 'paid' once amount_paid covers amount,
  -- and what's still owed is the difference.
  amount_paid    DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
  -- 'void' = a payment undone by an admin (recorded by mistake). Only a
  -- training fee is voided; its month is then recalculated.
  status         ENUM('pending','paid','waived','refunded','void') NOT NULL DEFAULT 'pending',
  -- How the latest payment arrived. 'online_test' is a parent's in-app
  -- payment before real card processing exists; Stripe replaces it.
  method         ENUM('cash','card','bank','online_test','stripe','other','credit') NULL,
  reference_no   VARCHAR(80)         NULL,   -- Stripe payment intent id, receipt no, etc.
  paid_at        DATETIME            NULL,
  created_by     BIGINT UNSIGNED     NULL,   -- admin who sent/recorded it
  created_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- When the family's "new payment request" notification went out
  -- (dsa_server/lib/push.dart). NULL = not yet.
  pushed_at      DATETIME            NULL,
  updated_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  -- At most one OPEN training-fee bill per player per month, and at most one
  -- live (pending or paid) fee per player per tournament. MySQL has no
  -- partial unique index, so each is a generated key that's NULL for every
  -- row the rule isn't about (a UNIQUE index ignores NULLs). The server
  -- checks both first for a readable message; these catch a race or a bug.
  open_training_key   VARCHAR(40) GENERATED ALWAYS AS (
    CASE WHEN payment_type = 'training_fee' AND status = 'pending'
         THEN CONCAT(player_id, '|', period_month) END
  ) VIRTUAL,
  live_tournament_key VARCHAR(40) GENERATED ALWAYS AS (
    CASE WHEN payment_type = 'tournament' AND tournament_id IS NOT NULL
              AND status IN ('pending','paid')
         THEN CONCAT(player_id, '|', tournament_id) END
  ) VIRTUAL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_payments_open_training   (open_training_key),
  UNIQUE KEY uq_payments_live_tournament (live_tournament_key),
  KEY idx_payments_player_status (player_id, status),
  KEY idx_payments_push          (pushed_at, created_at),
  KEY idx_payments_type          (payment_type),
  KEY idx_payments_period        (player_id, period_month),
  KEY idx_payments_tournament    (tournament_id),
  CONSTRAINT fk_payments_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_payments_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE SET NULL,
  CONSTRAINT fk_payments_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  -- period_month is present for exactly one kind: the monthly training fee.
  --
  -- This deliberately does NOT also check tournament_id. MySQL forbids a
  -- column from appearing in a CHECK when a foreign key on it uses
  -- ON DELETE SET NULL (error 3823), and keeping SET NULL is worth more:
  -- deleting a tournament should preserve its payment history rather than
  -- erase it, and the row still reads fine from its own title and amount.
  -- "only tournament payments carry a tournament_id" stays an app-level rule.
  CONSTRAINT chk_payments_shape CHECK (
    (payment_type =  'training_fee' AND period_month IS NOT NULL)
    OR
    (payment_type <> 'training_fee' AND period_month IS NULL)
  ),
  -- "paid" means paid in full. Every fee calculation sums amount_paid, so a
  -- row marked paid with amount_paid short of amount would still count as
  -- owed and get billed again at month close. That happened once (a fee
  -- created already-paid never had amount_paid set); this makes it
  -- impossible from any code path.
  CONSTRAINT chk_payments_paid_in_full CHECK (
    status <> 'paid' OR amount_paid >= amount
  )
) ENGINE = InnoDB;


-- Every money movement on a bill: payments in, refunds out, reversals of
-- payments recorded by mistake, and waivers (logged for the record, but not
-- money). payments.amount_paid is the running total of these, and the server
-- only ever changes the two together, in one transaction (dsa_server's
-- ledger.dart).
--
-- Append-only by design: the app's database user is granted SELECT and INSERT
-- here and nothing else, so history can be added to but never edited or
-- deleted. ON DELETE RESTRICT means a bill with history can't be deleted
-- either — refund, waive or undo it instead.
--
-- The Stripe ids are UNIQUE so a webhook delivered twice can't record the
-- same card payment twice.
CREATE TABLE payment_transactions (
  id                        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  payment_id                BIGINT UNSIGNED NOT NULL,
  kind                      ENUM('payment','refund','reversal','waiver') NOT NULL,
  amount                    DECIMAL(10,2)   NOT NULL,   -- signed: refunds/reversals negative
  method                    ENUM('cash','card','bank','online_test','stripe','other','credit') NULL,
  stripe_payment_intent_id  VARCHAR(100)        NULL,
  stripe_refund_id          VARCHAR(100)        NULL,
  note                      VARCHAR(255)        NULL,
  recorded_by               BIGINT UNSIGNED     NULL,
  created_at                DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_payment_transactions_payment (payment_id),
  -- A Stripe id once PER BILL, not once overall: one card payment can
  -- settle a month and add training credit (two rows), or pay several
  -- bills at once; one refund can span several receipts. Still stops a
  -- webhook delivered twice from recording the same payment twice.
  UNIQUE KEY uq_payment_transactions_intent (stripe_payment_intent_id, payment_id),
  UNIQUE KEY uq_payment_transactions_refund (stripe_refund_id, payment_id),
  CONSTRAINT fk_payment_transactions_payment
    FOREIGN KEY (payment_id) REFERENCES payments (id) ON DELETE RESTRICT,
  CONSTRAINT fk_payment_transactions_recorded_by
    FOREIGN KEY (recorded_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT chk_payment_transactions_sign CHECK (
    (kind = 'payment' AND amount > 0)
    OR (kind IN ('refund','reversal') AND amount < 0)
    OR (kind = 'waiver' AND amount >= 0)
  )
) ENGINE = InnoDB;

-- APP USER PRIVILEGES — grant PER TABLE, never on dsa_db.*.
-- MySQL privileges add up: a database-wide "GRANT ... ON dsa_db.*" overrides
-- the narrower grant below, and that is exactly how this log was left
-- editable until 2026-09-15. Run as root, for every table:
--   GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.<table> TO 'dsa_app_user'@'localhost';
-- except these:
--   GRANT SELECT, INSERT ON dsa_db.payment_transactions TO 'dsa_app_user'@'localhost';
--   GRANT SELECT ON dsa_db.<each v_ view> TO 'dsa_app_user'@'localhost';
-- A NEW TABLE needs its own grant, or the app gets "command denied".
-- The full, runnable list lives in app_user_grants.sql next to this file.


-- =============================================================================
-- 9. ORDERS  (parent requests kit -> admin approves -> it becomes a payment)
-- =============================================================================

-- What a parent can order, and what each one costs.
--
-- This was three columns on a one-row order_prices table, which meant the
-- three items were fixed in the database and the admin could never add a
-- fourth. Each item is a row now: the admin adds, renames, re-prices and
-- retires them from the Order Validation screen, and the parent's order sheet
-- is simply whatever is active here. The parent-side sheet still has no
-- amount field — the price always comes from this table.
CREATE TABLE order_items (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  -- Stable machine name, generated from the label ('league_uniform'). The
  -- original three items were matched by it, and a card processor will want
  -- something SKU-shaped later; the label is free to change without it.
  code        VARCHAR(40)     NOT NULL,
  label       VARCHAR(80)     NOT NULL,   -- what the parent reads
  price       DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
  -- Which bucket an approved order lands in on the payments side.
  misc_type   ENUM('uniform','merch','others') NOT NULL DEFAULT 'others',
  -- Soft delete, like everything else here: orders already placed still point
  -- at this row, so it has to survive being taken off the parent's list.
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  sort_order  INT             NOT NULL DEFAULT 0,
  created_by  BIGINT UNSIGNED     NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                              ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_order_items_code (code),
  -- One item per name: a retired item is restored, never duplicated.
  UNIQUE KEY uq_order_items_label (label),
  KEY idx_order_items_active (is_active, sort_order),
  CONSTRAINT fk_order_items_created_by
    FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT chk_order_items_price CHECK (price >= 0)
) ENGINE = InnoDB;



-- One order request, for one player, for one item.
--
-- WHY THIS ISN'T JUST A payments ROW: an order starts life on the parent's
-- phone, and nothing a parent creates may become money owed on its own. It
-- sits here as 'pending' until an admin approves it; only then is a misc
-- payments row written, and payment_id points at it so the two are linked by
-- id rather than by matching a title string.
--
-- amount is a snapshot, not a lookup into order_items: the admin can set a
-- custom price for one player's order (tapping the row on Order Validation),
-- and later preset changes must not silently re-price an order that has
-- already been placed or approved.
--
-- Declining sets 'rejected' (with reviewed_by/at) and keeps the row, so the
-- parent's list shows DECLINED. It used to delete the row, and the order just
-- vanished from the parent's screen. A removed player's PENDING orders are
-- deleted, since no one can act on them any more.
CREATE TABLE orders (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  player_id     BIGINT UNSIGNED NOT NULL,
  order_item_id BIGINT UNSIGNED NOT NULL,
  amount        DECIMAL(10,2)   NOT NULL,   -- priced when placed; admin may override
  -- 'rejected' means the admin declined it; the order stays so the parent
  -- sees DECLINED instead of it vanishing. A parent cancelling their own
  -- still-pending order DELETEs the row instead: nobody had acted on it, so
  -- there is no decision worth keeping.
  status        ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending',
  requested_by  BIGINT UNSIGNED     NULL,   -- the parent who placed it
  reviewed_by   BIGINT UNSIGNED     NULL,   -- the admin who approved/disapproved
  reviewed_at   DATETIME            NULL,
  payment_id    BIGINT UNSIGNED     NULL,   -- the misc payment approval created
  -- When the admin marked the kit as handed over to the family, and who.
  -- NULL = not given yet. Paid or not comes from the bill (payment_id).
  received_at   DATETIME            NULL,
  received_by   BIGINT UNSIGNED     NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_orders_status (status),
  KEY idx_orders_player (player_id),
  CONSTRAINT fk_orders_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE,
  CONSTRAINT fk_orders_requested_by
    FOREIGN KEY (requested_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_orders_reviewed_by
    FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_orders_received_by
    FOREIGN KEY (received_by) REFERENCES users (id) ON DELETE SET NULL,
  -- SET NULL, not CASCADE: if a payment row is ever removed, the order it
  -- came from is still a real thing that happened and should survive.
  CONSTRAINT fk_orders_payment
    FOREIGN KEY (payment_id) REFERENCES payments (id) ON DELETE SET NULL,
  -- RESTRICT, not CASCADE: deleting an item people had ordered would take
  -- their orders with it. Items are deactivated instead, never deleted.
  CONSTRAINT fk_orders_item
    FOREIGN KEY (order_item_id) REFERENCES order_items (id) ON DELETE RESTRICT
) ENGINE = InnoDB;


-- =============================================================================
-- 10. ANNOUNCEMENTS  (admin -> parents)
-- =============================================================================

-- is_everyone = 1 is a club-wide broadcast and has no audience rows.
-- Otherwise the announcement is scoped to one OR MORE categories — the compose
-- sheet lets an admin pick several (e.g. B2013 and B2012 together).
CREATE TABLE announcements (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  title         VARCHAR(160)    NOT NULL,
  body          TEXT            NOT NULL,
  is_everyone   TINYINT(1)      NOT NULL DEFAULT 0,
  -- Set on a notice the server sent by itself when something was cancelled,
  -- a session was changed, a session was added to a child's schedule, a
  -- jersey number request was answered or a kit order was handed over
  -- (dsa_server/lib/notices.dart); NULL for a message an admin wrote.
  auto_kind     ENUM('sessions_cancelled','tournament_cancelled',
                     'session_changed','sessions_added',
                     'jersey_number','order_given','payment_paid',
                     'tournament_reminder','tournament_declined',
                     'birthday') NULL,
  sent_by       BIGINT UNSIGNED     NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  deleted_at    DATETIME            NULL,   -- soft delete, keeps history
  -- When its push notification went out (dsa_server/lib/push.dart). NULL =
  -- not sent yet: the server picks those up every few seconds.
  pushed_at     DATETIME            NULL,
  PRIMARY KEY (id),
  KEY idx_announcements_created (created_at),
  KEY idx_announcements_push (pushed_at, created_at),
  -- "A recent automatic message of kind X": looked up on every session
  -- edit, cancellation and undo (dsa_server/lib/notices.dart).
  KEY idx_announcements_auto (auto_kind, created_at),
  CONSTRAINT fk_announcements_sent_by
    FOREIGN KEY (sent_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- Which categories an announcement went to. Empty when is_everyone = 1.
CREATE TABLE announcement_categories (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  category_id      BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, category_id),
  KEY idx_announcement_categories_category (category_id),
  CONSTRAINT fk_announcement_categories_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_categories_category
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Trainings and tournaments an announcement went to. Membership is resolved
-- when announcements are read, not copied at send time: a player later added
-- to the tournament (or rostered onto the training's sessions) sees messages
-- already sent to it. Training membership counts cancelled sessions too, so
-- deleting a training can't hide the "training cancelled" message from the
-- very players it was meant for.
--
-- training_programs and tournaments are both soft-deleted, so these rows
-- survive either being removed and old messages keep their audience.
CREATE TABLE announcement_trainings (
  announcement_id      BIGINT UNSIGNED NOT NULL,
  training_program_id  BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, training_program_id),
  KEY idx_announcement_trainings_program (training_program_id),
  CONSTRAINT fk_announcement_trainings_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_trainings_program
    FOREIGN KEY (training_program_id) REFERENCES training_programs (id) ON DELETE CASCADE
) ENGINE = InnoDB;

CREATE TABLE announcement_tournaments (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  tournament_id    BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, tournament_id),
  KEY idx_announcement_tournaments_tournament (tournament_id),
  CONSTRAINT fk_announcement_tournaments_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_tournaments_tournament
    FOREIGN KEY (tournament_id) REFERENCES tournaments (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Read receipts. A row is written when a parent opens a message
-- (POST /announcements/<id>/read); GET /announcements reports is_read from
-- this table, and editing a message deletes its rows so it shows as new again
-- for everyone it was sent to.
CREATE TABLE announcement_reads (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  user_id          BIGINT UNSIGNED NOT NULL,
  read_at          DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (announcement_id, user_id),
  CONSTRAINT fk_announcement_reads_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_reads_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;

-- Players a message was sent to by name: the automatic cancellation notices.
-- Frozen when sent, unlike the training/tournament audiences above (resolved
-- when read) — the families affected by a cancellation are the ones rostered
-- when it happened.
CREATE TABLE announcement_players (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  player_id        BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, player_id),
  KEY idx_announcement_players_player (player_id),
  CONSTRAINT fk_announcement_players_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_players_player
    FOREIGN KEY (player_id) REFERENCES players (id) ON DELETE CASCADE
) ENGINE = InnoDB;

-- A message to one parent account (Parent Accounts > Send message). It
-- reaches that account whether or not the family has children registered,
-- and nobody else.
CREATE TABLE announcement_users (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  user_id          BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (announcement_id, user_id),
  KEY idx_announcement_users_user (user_id),
  CONSTRAINT fk_announcement_users_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_users_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB;

-- The sessions a cancellation notice is about. Cancelling another session
-- for the same players within 30 minutes adds it here and rewrites the
-- notice, so cancelling the 13th, 14th and 15th one after another ends up as
-- one message listing all three.
CREATE TABLE announcement_sessions (
  announcement_id  BIGINT UNSIGNED NOT NULL,
  session_id       BIGINT UNSIGNED NOT NULL,
  -- On a "session changed" message only: the session as it was before the
  -- first edit, so later edits within 30 minutes rewrite the same message
  -- against it (dsa_server/lib/notices.dart). NULL everywhere else.
  was_json         TEXT                NULL,
  PRIMARY KEY (announcement_id, session_id),
  KEY idx_announcement_sessions_session (session_id),
  CONSTRAINT fk_announcement_sessions_announcement
    FOREIGN KEY (announcement_id) REFERENCES announcements (id) ON DELETE CASCADE,
  CONSTRAINT fk_announcement_sessions_session
    FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- =============================================================================
-- 11. VIEWS — the numbers the app shows, derived instead of stored
-- =============================================================================

-- Per player, per month: the present/absent/exempt counts the attendance stats
-- dialog shows, plus the billable count a training fee is charged on.
-- DATE_SUB(...) rather than DATE_FORMAT(...) on purpose: it yields a real DATE,
-- so period_month joins cleanly against payments.period_month instead of
-- relying on implicit string-to-date coercion.
--
-- Counts only what billing counts: training sessions (a tournament game is
-- paid by its tournament fee), players still on that session's roster, and
-- present/absent only once the day has come. Without those filters the
-- counts shown beside a fee disagreed with the fee itself.
CREATE OR REPLACE VIEW v_player_month_attendance AS
SELECT
  a.player_id,
  DATE_SUB(s.session_date, INTERVAL DAYOFMONTH(s.session_date) - 1 DAY) AS period_month,
  COUNT(CASE WHEN a.status = 'present' AND s.session_date <= CURRENT_DATE THEN 1 END) AS present_count,
  COUNT(CASE WHEN a.status = 'absent'  AND s.session_date <= CURRENT_DATE THEN 1 END) AS absent_count,
  COUNT(CASE WHEN a.status = 'exempt' THEN 1 END) AS exempt_count,
  COUNT(CASE WHEN a.status IN ('present','absent') AND s.session_date <= CURRENT_DATE THEN 1 END) AS billable_sessions
FROM attendance a
JOIN sessions s
  ON s.id = a.session_id AND s.is_cancelled = 0 AND s.session_type = 'training'
JOIN session_players sp
  ON sp.session_id = a.session_id AND sp.player_id = a.player_id
GROUP BY
  a.player_id,
  DATE_SUB(s.session_date, INTERVAL DAYOFMONTH(s.session_date) - 1 DAY);


-- v_player_training_fee and v_player_balance were DROPPED on 2026-09-15.
-- Both priced off fee_settings (today's rate, so past months moved whenever a
-- rate changed), summed `amount` instead of `amount_paid`, and ignored
-- proration — yet their comments claimed to drive the dashboard. Nothing read
-- them. The real calculation lives in dsa_server (billing.dart / fee_rates.dart).


-- Lifetime attendance rate per player (the "AVG. ATTENDANCE" stat). Exempt
-- sessions are excluded from the denominator so an excused player is not
-- punished for it. Training sessions only, not cancelled, and not a mark on a
-- session that hasn't happened yet.
CREATE OR REPLACE VIEW v_player_attendance_rate AS
SELECT
  p.id AS player_id,
  p.full_name,
  COUNT(CASE WHEN a.status = 'present' THEN 1 END) AS sessions_present,
  COUNT(CASE WHEN a.status IN ('present','absent') THEN 1 END) AS sessions_counted,
  ROUND(
    100.0 * COUNT(CASE WHEN a.status = 'present' THEN 1 END)
    / NULLIF(COUNT(CASE WHEN a.status IN ('present','absent') THEN 1 END), 0)
  ) AS attendance_rate
FROM players p
LEFT JOIN (
  attendance a
  JOIN sessions s
    ON s.id = a.session_id AND s.is_cancelled = 0
   AND s.session_type = 'training' AND s.session_date <= CURRENT_DATE
) ON a.player_id = p.id
GROUP BY p.id, p.full_name;


-- The roster the attendance screen loads for a session: exactly who was added
-- to that session, plus their mark if one exists yet.
--
-- Note this is driven by session_players, NOT by category membership or by
-- whether the player has paid — the earlier draft gated the roster on payment,
-- which would have quietly hidden players from attendance.
CREATE OR REPLACE VIEW v_session_roster AS
SELECT
  sp.session_id,
  sp.player_id,
  pl.full_name,
  a.status AS attendance_status
FROM session_players sp
JOIN players pl ON pl.id = sp.player_id AND pl.is_active = 1
LEFT JOIN attendance a
       ON a.session_id = sp.session_id
      AND a.player_id  = sp.player_id;


-- =============================================================================
-- 11b. CHECK CONSTRAINTS  (added 2026-09-15)
-- =============================================================================

-- Last line of defence: the database refuses impossible values whatever the
-- server code does. The server validates all of these first with friendly
-- messages; a violation reaching MySQL (error 3819) means a path was missed.
-- A month key that isn't the 1st was the real case — a custom total saved for
-- "2026-09-15" was stored and silently never billed.
ALTER TABLE payments
  ADD CONSTRAINT chk_payments_amounts
    CHECK (amount >= 0 AND amount_paid >= 0 AND amount_paid <= amount),
  ADD CONSTRAINT chk_payments_month_start
    CHECK (period_month IS NULL OR DAYOFMONTH(period_month) = 1),
  -- An open bill for 0.00 can never be paid or waived. 0.001 used to be
  -- accepted and stored as exactly that.
  ADD CONSTRAINT chk_payments_open_amount
    CHECK (status <> 'pending' OR amount > 0);
ALTER TABLE training_fee_overrides
  ADD CONSTRAINT chk_tfo_amount CHECK (amount >= 0),
  ADD CONSTRAINT chk_tfo_month_start CHECK (DAYOFMONTH(period_month) = 1);
ALTER TABLE orders
  ADD CONSTRAINT chk_orders_amount CHECK (amount >= 0);
ALTER TABLE tournament_players
  ADD CONSTRAINT chk_tournament_players_amount CHECK (amount >= 0);
ALTER TABLE fee_rates
  ADD CONSTRAINT chk_fee_rates_amounts
    CHECK (coach_fee >= 0 AND per_session_rate >= 0);
ALTER TABLE fee_settings
  ADD CONSTRAINT chk_fee_settings_amounts
    CHECK (coach_fee >= 0 AND per_session_rate >= 0);
ALTER TABLE sessions
  ADD CONSTRAINT chk_sessions_times
    CHECK (end_time IS NULL OR end_time > start_time);


-- =============================================================================
-- 12. SEED DATA (sample — safe to delete)
-- =============================================================================

INSERT INTO categories (code, birth_year, label) VALUES
  ('B2011', 2011, 'Born 2011'),
  ('B2012', 2012, 'Born 2012'),
  ('B2013', 2013, 'Born 2013'),
  ('B2014', 2014, 'Born 2014');

-- The two fee numbers the app starts with.
INSERT INTO fee_settings (id, coach_fee, per_session_rate, currency)
VALUES (1, 100.00, 31.25, 'AED');

-- The opening entry in the rate history, dated far enough back to cover any
-- session. Billing can't price anything without a row here, so this is config
-- rather than sample data — don't delete it with the seed data below.
INSERT INTO fee_rates (effective_from, coach_fee, per_session_rate)
VALUES ('2000-01-01', 100.00, 31.25);

-- The kit a parent can order to start with. Config the admin edits in-app,
-- not test data: with no rows here the parent's order sheet is empty.
INSERT INTO order_items (code, label, price, misc_type, sort_order) VALUES
  ('league_uniform',   'League Uniform',   130.00, 'uniform', 1),
  ('training_uniform', 'Training Uniform', 100.00, 'uniform', 2),
  ('dsa_shirt',        'DSA Shirt',         50.00, 'merch',   3);

-- A real bcrypt hash of 'admin123' — a dev-only login for testing before
-- real signups exist. Change this password (or delete the account) before
-- this ever points at anything but a local dev database.
INSERT INTO users (role, full_name, username, email, phone, password_hash, status)
VALUES ('admin', 'Demo Admin', 'admin', 'admin@example.com',
        '+971 50 000 0000',
        '$2a$10$5Fr5qZMieFq5bKBo..Ofc.ur7/5Rj0vIQm7XQaQntbZiroON3dnom',
        'approved');


-- =============================================================================
-- 13. THE APP'S DATABASE USER
-- =============================================================================
-- dsa_server connects as its own MySQL user, never as root. Create it with a
-- password of your own choosing (never one written into a file that lives
-- beside the code), then run app_user_grants.sql:
--
--   CREATE USER 'dsa_app_user'@'localhost' IDENTIFIED BY '<your password>';
--   SOURCE app_user_grants.sql;
--
-- The same password goes in dsa_server/.env as DB_PASSWORD.
--
-- Test data to click around with lives in seed_test_data.sql, which wipes
-- every table first, so it always leaves a known state.
