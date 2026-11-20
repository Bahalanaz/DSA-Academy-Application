/// Rate lookups against `fee_rates`, shared by every query that has to put
/// a price on a training session.
///
/// `fee_settings` holds one row: what a session costs *today*. That's the
/// right number for the settings dialog and for pricing something new, and
/// the wrong number for anything already in the past. Billing reads history
/// instead — otherwise raising the rate in September would quietly re-price
/// August, changing a bill a parent had already been sent (or raising a new
/// one against a month they'd already paid off).
///
/// Both helpers return a SQL scalar subquery, so they compose into a bigger
/// statement rather than costing an extra round trip.
library;

/// The per-session rate that was in force on [dateExpr] — a SQL expression
/// naming a date column, e.g. `'s.session_date'`.
///
/// Picks the `fee_rates` row that was current on the day in question: the
/// latest one that had already started by then. The seeded 2000-01-01 row
/// guarantees there's always one to find, so this never comes back NULL.
String sessionRateAt(String dateExpr) =>
    '(SELECT fr.per_session_rate FROM fee_rates fr '
    'WHERE fr.effective_from <= $dateExpr '
    'ORDER BY fr.effective_from DESC LIMIT 1)';

/// The monthly coach fee for the month starting at [monthExpr].
///
/// Pinned to the FIRST of the month, so a rate change part-way through a
/// month doesn't move that month's flat fee — it's a charge for the month
/// as a whole, already committed to by the time the change lands, so the new
/// figure starts applying from the next month instead. Per-session charges
/// don't work that way: those are priced individually, by session date.
String coachFeeAt(String monthExpr) =>
    '(SELECT fr.coach_fee FROM fee_rates fr '
    'WHERE fr.effective_from <= $monthExpr '
    'ORDER BY fr.effective_from DESC LIMIT 1)';

/// The first training session a player was ever booked on (cancelled ones
/// excluded). That's the day they joined, as far as billing is concerned —
/// a tournament game played earlier doesn't count as joining training.
String firstSessionOf(String playerIdExpr) =>
    '(SELECT MIN(fs.session_date) FROM session_players fsp '
    'JOIN sessions fs ON fs.id = fsp.session_id AND fs.is_cancelled = 0 '
    "AND fs.session_type = 'training' "
    'WHERE fsp.player_id = $playerIdExpr)';

/// The first month the coach fee is the same flat amount for everyone, a
/// child who joins on the 28th included (the club's rule from October
/// 2026). An admin can still set a different figure for one child's month
/// (training_fee_overrides).
const flatCoachFeeFrom = '2026-10-01';

/// The coach fee [playerIdExpr] owes for the month starting at [monthExpr].
///
/// From [flatCoachFeeFrom] on: the full fee in every month, the month they
/// joined included.
///
/// Before then, a player's first month was prorated by the days left from
/// their first session (first session Sep 28 = 3/30 of the fee). Those
/// months are already billed, and the month close re-checks every past
/// month, so they keep the rule they were billed under: dropping it for
/// them would raise new bills for months families have already settled.
String proratedCoachFeeAt(String playerIdExpr, String monthExpr) {
  final first = firstSessionOf(playerIdExpr);
  return 'ROUND(${coachFeeAt(monthExpr)} * CASE '
      "WHEN $monthExpr >= '$flatCoachFeeFrom' THEN 1 "
      'WHEN $first BETWEEN $monthExpr AND LAST_DAY($monthExpr) '
      'THEN (DAY(LAST_DAY($monthExpr)) - DAY($first) + 1) '
      '/ DAY(LAST_DAY($monthExpr)) '
      'ELSE 1 END, 2)';
}
