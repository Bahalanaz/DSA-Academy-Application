import '../../../core/services/api_client.dart';
import '../../../core/utils/jersey_number.dart';
import 'admin_player.dart';

/// The club roster — one shared list every player-facing screen reads
/// (admin Players, the add-players picker, attendance rosters, the parent
/// side's My Players). Backed by the `players` table via dsa_server.
///
/// Screens read this synchronously exactly as they did when it was hard-
/// coded; [loadPlayers] is what keeps it in step with the database, and
/// the write helpers below go to the server first so a failed request
/// never leaves the list showing something that wasn't actually saved.
final List<AdminPlayer> mockRoster = [];

AdminPlayer _fromRow(Map<String, dynamic> row) => AdminPlayer(
  id: asInt(row['id']),
  name: row['full_name'] as String,
  nickname: row['nickname'] as String?,
  categories: asCsvList(row['categories']),
  parentName: (row['parent_name'] as String?) ?? '',
  parentPhone: (row['parent_phone'] as String?) ?? '',
  parentId: asInt(row['parent_id']),
  attendanceRate: asInt(row['attendance_rate']),
  jerseyNumber: row['jersey_number'] as String?,
  jerseySize: row['jersey_size'] as String?,
  birthday: row['birthday'] as String?,
  photoUrl: row['photo_url'] as String?,
  // Missing from a server older than Player Validation: approved, then.
  isApproved: '${row['is_approved'] ?? 1}' == '1',
  jerseyRequest: row['jersey_request'] as String?,
  jerseyRequestStatus: row['jersey_request_status'] as String?,
  monthlyPresent: asInt(row['monthly_present']),
  monthlyAbsent: asInt(row['monthly_absent']),
  monthlyExempt: asInt(row['monthly_exempt']),
  monthlyScheduled: asInt(row['monthly_scheduled']),
  monthlyCharges: asDouble(row['monthly_charges']),
  monthlyCoachFee: asDouble(row['monthly_coach_fee']),
  monthlyCoachFeeFull: asDouble(row['monthly_coach_fee_full']),
);

/// Where a player's photo loads from, by id; null if none (or unknown).
String? photoUrlOf(int playerId) {
  for (final p in mockRoster) {
    if (p.id == playerId) return p.photoUrl;
  }
  return null;
}

Future<void> loadPlayers() async {
  final rows = await ApiClient.getList('/players');
  mockRoster
    ..clear()
    ..addAll(rows.map((row) => _fromRow(row as Map<String, dynamic>)));
}

/// Creates a player under [parentId] (the logged-in parent, or an admin
/// acting on their behalf), then reloads so the new row arrives with its
/// server-assigned id and joined parent details already filled in.
/// Adds a player and returns their id (a photo picked on the form is
/// uploaded against it straight after), and whether they're waiting on
/// Player Validation because their number is already worn.
///
/// [allowTaken]: the person agreed, in the warning window, to a number
/// another player has. Without it the server refuses a taken number.
Future<({int id, bool pending})> addPlayer({
  required String fullName,
  required int parentId,
  String? nickname,
  String? jerseyNumber,
  String? jerseySize,
  String? birthday,
  bool allowTaken = false,
}) async {
  final created = await ApiClient.post('/players', {
    'fullName': fullName,
    'nickname': ?nickname,
    'parentId': parentId,
    'jerseyNumber': jerseyNumber,
    'jerseySize': jerseySize,
    'birthday': birthday,
    'allowTaken': allowTaken,
  });
  await loadPlayers();
  return (id: asInt(created['id']), pending: created['pending'] == true);
}

/// Saves a player's details. Returns true when their (new) number is
/// waiting on Player Validation.
///
/// [setNickname]: the admin's save, which also sets [nickname] (null
/// clears it). Only the academy changes a nickname once the child exists.
Future<bool> updatePlayer(
  AdminPlayer player, {
  required String fullName,
  String? jerseyNumber,
  String? jerseySize,
  String? birthday,
  bool setNickname = false,
  String? nickname,
  bool allowTaken = false,
}) async {
  final saved = await ApiClient.put('/players/${player.id}', {
    'fullName': fullName,
    if (setNickname) 'nickname': nickname,
    'jerseyNumber': jerseyNumber,
    'jerseySize': jerseySize,
    'birthday': birthday,
    'allowTaken': allowTaken,
  });
  await loadPlayers();
  return saved['pending'] == true;
}

/// The jersey numbers other players already wear, for the 0-99 picker.
/// [exceptPlayerId] leaves out the player being edited. [holders] says who
/// wears each one ("carl (B2019)"), and is only ever filled in for the
/// admin: a parent gets the numbers alone.
Future<({Set<int> taken, Map<int, List<String>> holders})>
loadTakenJerseyNumbers({int? exceptPlayerId}) async {
  final query = exceptPlayerId == null ? '' : '?except=$exceptPlayerId';
  final body = await ApiClient.getMap('/jersey-numbers$query');
  final holders = body['holders'] as Map<String, dynamic>? ?? const {};
  return (
    taken: {
      for (final n in body['taken'] as List) asInt(n),
      // "00" comes separately (a server from before it doesn't send it).
      if (body['doubleZeroTaken'] == true) doubleZero,
    },
    holders: {
      for (final e in holders.entries)
        ?jerseyKey(e.key): [for (final name in e.value as List) '$name'],
    },
  );
}

/// A family asking for a number another player already wears, waiting on
/// the admin's Player Validation screen.
class JerseyRequest {
  final int playerId;
  final String playerName;
  final String? birthYear;
  final String? photoUrl;
  final String parentName;
  final String parentPhone;

  /// The number asked for, and the one they wear now (null for a new child).
  final String requested;
  final String? current;

  /// A new child (not a player until approved) rather than a change.
  final bool isNewPlayer;

  /// Who already wears the number: "Ana Cruz (B2013), ...". Admin only.
  final String? wornBy;
  final DateTime? requestedAt;

  /// The number the admin chose instead of [requested], on this screen,
  /// before approving. [finalChosen] false = still the one asked for.
  int? finalNumber;
  bool finalChosen = false;

  /// Who wears [finalNumber], from the picker (empty = nobody).
  List<String> finalWornBy = const [];

  /// What the child gets on APPROVE, as shown ("#21" or "no number").
  String get finalLabel => !finalChosen
      ? '#$requested'
      : finalNumber == null
      ? 'no number'
      : '#${jerseyText(finalNumber!)}';

  JerseyRequest({
    required this.playerId,
    required this.playerName,
    required this.birthYear,
    required this.photoUrl,
    required this.parentName,
    required this.parentPhone,
    required this.requested,
    required this.current,
    required this.isNewPlayer,
    required this.wornBy,
    required this.requestedAt,
  });
}

final List<JerseyRequest> jerseyRequests = [];

Future<void> loadJerseyRequests() async {
  final rows = await ApiClient.getList('/player-validation');
  // A number the admin chose with CHANGE NUMBER but hasn't approved yet
  // lives only on this phone. The screen reloads every few seconds, which
  // used to quietly put it back to the number asked for.
  final chosen = {
    for (final r in jerseyRequests)
      if (r.finalChosen) r.playerId: r,
  };
  jerseyRequests
    ..clear()
    ..addAll(
      rows.map((r) {
        final row = r as Map<String, dynamic>;
        final previous = chosen[asInt(row['id'])];
        return JerseyRequest(
            playerId: asInt(row['id']),
            playerName: '${row['full_name']}',
            birthYear: row['birth_year']?.toString(),
            photoUrl: row['photo_url'] as String?,
            parentName: '${row['parent_name'] ?? ''}',
            parentPhone: '${row['parent_phone'] ?? ''}',
            requested: '${row['jersey_request']}',
            current: row['jersey_number'] as String?,
            isNewPlayer: '${row['is_approved']}' != '1',
            wornBy: row['worn_by'] as String?,
            requestedAt: asDate(row['jersey_requested_at']),
          )
          ..finalChosen = previous?.finalChosen ?? false
          ..finalNumber = previous?.finalNumber
          ..finalWornBy = previous?.finalWornBy ?? const [];
      }),
    );
}

/// The admin agrees: the child gets the number they asked for (shared), or
/// the one the admin chose instead, and a new child becomes a player.
Future<void> approveJerseyRequest(JerseyRequest request) async {
  await ApiClient.post('/player-validation/${request.playerId}/approve', {
    // "00" as text; any other number as a number, as before.
    if (request.finalChosen)
      'jerseyNumber': request.finalNumber == doubleZero
          ? '00'
          : request.finalNumber,
  });
  jerseyRequests.remove(request);
}

/// The admin says no: the family is asked to pick another number.
Future<void> declineJerseyRequest(JerseyRequest request) async {
  await ApiClient.post('/player-validation/${request.playerId}/decline');
  jerseyRequests.remove(request);
}

/// Removes a player from every roster view. Server-side this is a soft
/// delete, so their attendance history survives.
///
/// Refused (an ApiException with status 409) while the player still owes
/// money. An admin can pass [waive] to write that balance off and remove
/// them in one step.
Future<void> removePlayer(AdminPlayer player, {bool waive = false}) async {
  await ApiClient.delete('/players/${player.id}${waive ? '?waive=true' : ''}');
  mockRoster.remove(player);
}

// A player's category isn't set by anyone — it's their birth year
// (B2013 = born 2013), derived on the server from players.birthday. Change
// the birthday and the category follows; there's nothing to assign.

/// Just the count, for the Home dashboard's Player Validation card.
Future<int> fetchJerseyRequestCount() async {
  await loadJerseyRequests();
  return jerseyRequests.length;
}
