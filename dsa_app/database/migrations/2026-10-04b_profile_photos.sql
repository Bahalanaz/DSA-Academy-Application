-- =============================================================================
-- 2026-10-04b — profile photos (accounts and players)
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. A fresh install from schema.sql
-- already has this.
--
-- Run as root, with the UTF-8 flag:
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-04b_profile_photos.sql
--
-- "Take Photo" / "Choose from Gallery" on the Account screens and on a
-- player. The picture itself lives here, in the database, so the nightly
-- database backup includes it and there is no separate folder of files to
-- copy or lose. The phone shrinks it first (about 600 px, tens of KB).
--
-- users.photo_url / players.photo_url (they already existed, unused) now
-- hold the address the app loads it from, with a version so a new photo
-- replaces the old one on every phone: '/photos/player/12?v=1728000000'.
-- NULL = no photo.
--
-- Who may see a photo is checked by the server (dsa_server/lib/
-- photos_routes.dart): an account's photo by that account and admins; a
-- child's photo by their own parent and admins.
-- =============================================================================

CREATE TABLE profile_photos (
  kind        ENUM('user','player') NOT NULL,
  owner_id    BIGINT UNSIGNED       NOT NULL,   -- users.id or players.id
  image       MEDIUMBLOB            NOT NULL,
  mime        VARCHAR(20)           NOT NULL,   -- image/jpeg or image/png
  updated_at  DATETIME              NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, owner_id)
) ENGINE = InnoDB;

GRANT SELECT, INSERT, UPDATE, DELETE ON dsa_db.profile_photos
  TO 'dsa_app_user'@'localhost';
