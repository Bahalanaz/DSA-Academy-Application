-- =============================================================================
-- 2026-10-01 — two views re-created as UTF-8
-- =============================================================================
-- Upgrades an EXISTING dsa_db in place. Safe to run twice. A fresh install
-- from schema.sql, or a restore from a dump taken after this ran, already has
-- it.
--
-- Run as root, with the UTF-8 flag (that flag IS the fix: a view remembers
-- the character set of the connection that created it):
--   mysql -u root -p --default-character-set=utf8mb4 dsa_db < 2026-10-01_views_utf8mb4.sql
--
-- v_player_month_attendance and v_player_attendance_rate had been created
-- from a Windows console without that flag, so they were stored as cp850.
-- Nothing in them is non-English today, but a name with an accent passing
-- through them could come out garbled, and a restored database didn't match
-- a fresh install from schema.sql. The definitions below are exactly the
-- ones in schema.sql; nothing about what they return changes. Privileges on
-- the views are kept (CREATE OR REPLACE doesn't drop them).
-- =============================================================================

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
