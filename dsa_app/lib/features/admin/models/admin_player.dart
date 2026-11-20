/// A player as seen from the admin/coach side — includes the parent
/// contact info admins need but parents themselves don't edit here.
///
/// Backed by the `players` table (joined with `users` for the guardian
/// and the attendance views for the counts). [id] is the database row id,
/// which every write goes through — names are for display only.
class AdminPlayer {
  final int id;
  final String name;

  /// What the team calls them ("Kiko"), or null. Optional: a family can
  /// give one when adding the child, and the academy can change it.
  final String? nickname;
  final List<String> categories;
  final String parentName;
  final String parentPhone;
  final int parentId;
  final int attendanceRate; // percent, 0-100
  final String? jerseyNumber;

  /// Shirt size, one of [jerseySizes], or null if not set yet (players
  /// added before sizes existed).
  final String? jerseySize;
  final String? birthday;

  /// Where their photo loads from (`/photos/player/<id>?v=...`), or null.
  String? photoUrl;

  /// False for a NEW child whose jersey number another player already
  /// wears: they wait on the admin's Player Validation screen and aren't a
  /// player yet (no rosters, bills or orders). Only their parent sees them.
  final bool isApproved;

  /// The taken number the family asked for, and where that stands:
  /// 'pending' (waiting for the admin) or 'declined' (pick another one).
  /// Null when nothing was asked for.
  final String? jerseyRequest;
  final String? jerseyRequestStatus;

  /// Set by the edit form when the person agreed, in the warning window, to
  /// a number another player already wears. Sent with the save.
  final bool confirmedTakenNumber;

  bool get hasPendingNumber => jerseyRequestStatus == 'pending';
  bool get hasDeclinedNumber => jerseyRequestStatus == 'declined';

  // This month's training attendance, broken down by status. Derived from
  // the attendance table server-side, so these can't drift from reality.
  int monthlyPresent;
  int monthlyAbsent;
  int monthlyExempt;

  /// Sessions this player was put on this month. Zero means they aren't
  /// training, and nothing is billed to them — not even the coach fee.
  int monthlyScheduled;

  /// This month's session charges in money, already totalled by the server.
  ///
  /// Not a session count times a rate: sessions in one month can fall
  /// either side of a price change, and each is charged at the rate that
  /// applied on its own date. Only the server's rate history knows that,
  /// so the figure is computed there and carried here.
  double monthlyCharges;

  /// The flat coach fee for this month, at the rate in force on the 1st.
  /// The same for everyone from October 2026; before then it was prorated
  /// in the month the player joined.
  double monthlyCoachFee;

  /// The unprorated coach fee for this month, so screens can tell when
  /// [monthlyCoachFee] was reduced for a mid-month join.
  double monthlyCoachFeeFull;

  AdminPlayer({
    this.id = 0,
    required this.name,
    this.nickname,
    required this.categories,
    required this.parentName,
    required this.parentPhone,
    this.parentId = 0,
    required this.attendanceRate,
    this.jerseyNumber,
    this.jerseySize,
    this.birthday,
    this.photoUrl,
    this.isApproved = true,
    this.jerseyRequest,
    this.jerseyRequestStatus,
    this.confirmedTakenNumber = false,
    this.monthlyPresent = 0,
    this.monthlyAbsent = 0,
    this.monthlyExempt = 0,
    this.monthlyScheduled = 0,
    this.monthlyCharges = 0,
    this.monthlyCoachFee = 0,
    this.monthlyCoachFeeFull = 0,
  });

  /// What every player search uses: the name or the nickname contains
  /// [query] (any case). An empty search matches everyone.
  bool matchesSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        (nickname?.toLowerCase().contains(q) ?? false);
  }

  /// Found by [query] through the nickname alone, so a list can show the
  /// nickname to explain why this player is in the results.
  bool matchesNicknameOnly(String query) {
    final q = query.trim().toLowerCase();
    return q.isNotEmpty &&
        !name.toLowerCase().contains(q) &&
        (nickname?.toLowerCase().contains(q) ?? false);
  }

  /// The year from [birthday] ("2013-04-02" -> "2013"), or null.
  String? get birthYear {
    final raw = birthday;
    if (raw == null || raw.length < 4) return null;
    final year = raw.substring(0, 4);
    return int.tryParse(year) == null ? null : year;
  }

  /// "Born 2013 · Jersey #7 · Size M" — what a kit order is made up from:
  /// the year decides the squad's kit, the number goes on the shirt, and
  /// the size is the shirt to hand out. Parts that aren't known are left
  /// out; null when none is.
  String? get kitLabel {
    final jersey = jerseyNumber?.trim();
    final size = jerseySize?.trim();
    final parts = [
      if (birthYear != null) "Born $birthYear",
      if (jersey != null && jersey.isNotEmpty) "Jersey #$jersey",
      if (size != null && size.isNotEmpty) "Size $size",
    ];
    return parts.isEmpty ? null : parts.join(" · ");
  }
}

/// The shirt sizes a player can have, in the order they're offered. The server and the
/// database (players.jersey_size) accept exactly these.
const jerseySizes = [
  '3XS',
  '2XS',
  'XS',
  'S',
  'M',
  'L',
  'XL',
  '2XL',
  '3XL',
  '9-10',
  '11-12',
];
