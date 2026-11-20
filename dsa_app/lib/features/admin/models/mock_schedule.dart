import '../../../core/utils/training_fee.dart';
import '../../../core/services/api_client.dart';
import 'mock_roster.dart';

/// Strips the time-of-day off a [DateTime] so it can be used as a
/// same-day comparison key.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class ScheduledSession {
  /// Database row id — needed to save attendance or edit the roster.
  final String id;
  final DateTime date;
  final String time;
  // Only meaningful for "Training" sessions — tournaments only track a
  // single start time.
  final String? timeEnd;
  final String type; // "Training" or "Tournament"
  final String category;
  final String location;
  final String? opponent;
  final String? trainingId;
  final String? tournamentId;

  /// Who is on this session's roster, by player ID — the key everything
  /// matches on. [playerNames] lines up with it index for index and is for
  /// display only: two players can share a name.
  final List<int> playerIds;
  final List<String> playerNames;

  /// How many players the roster holds in total. A parent is only sent
  /// their own children in [playerIds], so this is how they can still tell
  /// "nobody rostered yet" from "rostered, just not mine".
  final int rosterCount;

  /// How many of the roster have an attendance mark (admins only; 0 for
  /// parents).
  final int markedCount;

  ScheduledSession({
    this.id = '',
    required this.date,
    required this.time,
    this.timeEnd,
    required this.type,
    required this.category,
    required this.location,
    this.opponent,
    this.trainingId,
    this.tournamentId,
    List<int>? playerIds,
    List<String>? playerNames,
    int? rosterCount,
    this.markedCount = 0,
  }) : playerIds = playerIds ?? [],
       playerNames = playerNames ?? [],
       rosterCount = rosterCount ?? (playerIds?.length ?? 0);

  /// "5:00 PM – 6:00 PM" for trainings with an end time, otherwise just
  /// the start time.
  String get displayTime => timeEnd == null ? time : "$time – $timeEnd";
}

/// Shared with the Schedule screen, the Trainings screen and the parent-side
/// schedule. Backed by the `sessions` table.
final List<ScheduledSession> mockSchedule = [];

/// MySQL TIME columns come back as "17:00:00"; the UI wants "5:00 PM".
String formatSqlTime(String? sqlTime) {
  if (sqlTime == null || sqlTime.isEmpty) return '';
  final parts = sqlTime.split(':');
  if (parts.length < 2) return sqlTime;
  final hour = int.tryParse(parts[0]) ?? 0;
  final minute = parts[1];
  final suffix = hour >= 12 ? 'PM' : 'AM';
  final display = hour % 12 == 0 ? 12 : hour % 12;
  return '$display:$minute $suffix';
}

/// Minutes after midnight for "5:00 PM" or "17:00", or null when it isn't a
/// real time of day.
int? parseDisplayTime(String display) {
  final match = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s*$')
      .firstMatch(display);
  if (match == null) return null;
  var hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  final meridiem = match.group(3)?.toUpperCase();
  if (minute > 59) return null;
  if (meridiem == null) {
    if (hour > 23) return null;
  } else {
    if (hour < 1 || hour > 12) return null;
    if (meridiem == 'PM' && hour != 12) hour += 12;
    if (meridiem == 'AM' && hour == 12) hour = 0;
  }
  return hour * 60 + minute;
}

/// The inverse of [_formatTime], for sending back to the server.
///
/// Throws on anything that isn't a time. It used to fall back to midnight,
/// so a typo like "5pm" quietly scheduled the session at 12:00 AM.
String toSqlTime(String display) {
  final minutes = parseDisplayTime(display);
  if (minutes == null) {
    throw Exception('"$display" isn\'t a time. Enter it like 5:00 PM.');
  }
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute:00';
}

String toSqlDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

Future<void> loadSchedule() async {
  final rows = await ApiClient.getList('/sessions');
  mockSchedule
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        final isTraining = map['session_type'] == 'training';
        return ScheduledSession(
          id: '${map['id']}',
          date: DateTime.parse(map['session_date'] as String),
          time: formatSqlTime(map['start_time'] as String?),
          timeEnd: map['end_time'] == null
              ? null
              : formatSqlTime(map['end_time'] as String?),
          type: isTraining ? 'Training' : 'Tournament',
          category: (map['category_label'] as String?) ?? '',
          location: (map['location'] as String?) ?? '',
          opponent: map['opponent'] as String?,
          trainingId: map['training_program_id'] == null
              ? null
              : '${map['training_program_id']}',
          tournamentId: map['tournament_id'] == null
              ? null
              : '${map['tournament_id']}',
          playerIds: asIdList(map['player_ids']),
          playerNames: asCsvList(map['player_names']),
          rosterCount: asInt(map['roster_count']),
          markedCount: asInt(map['marked_count']),
        );
      }),
    );
}

Future<void> addSession({
  required String type, // "Training" or "Tournament"
  String? trainingId,
  String? tournamentId,
  required String categoryLabel,
  required DateTime date,
  required String startTime,
  String? endTime,
  String? location,
  String? opponent,
}) async {
  await ApiClient.post('/sessions', {
    'sessionType': type == 'Training' ? 'training' : 'tournament',
    'trainingProgramId': trainingId == null ? null : int.tryParse(trainingId),
    'tournamentId': tournamentId == null ? null : int.tryParse(tournamentId),
    'categoryLabel': categoryLabel,
    'sessionDate': toSqlDate(date),
    'startTime': toSqlTime(startTime),
    'endTime': endTime == null ? null : toSqlTime(endTime),
    'location': location,
    'opponent': opponent,
  });
  await loadSchedule();
}

/// Cancelled rather than hard-deleted server-side, so any attendance
/// already marked against the session survives.
Future<void> removeSession(ScheduledSession session) async {
  await ApiClient.delete('/sessions/${session.id}');
  mockSchedule.remove(session);
}

/// Changes a session's day, times, place or opponent. The server messages
/// the families of the players on it about what changed; returns whether a
/// message went out.
Future<bool> updateSession(
  ScheduledSession session, {
  required DateTime date,
  required String startTime,
  String? endTime,
  required String location,
  String? opponent,
}) async {
  final result = await ApiClient.put('/sessions/${session.id}', {
    'sessionDate': toSqlDate(date),
    'startTime': toSqlTime(startTime),
    if (session.type == 'Training')
      'endTime': endTime == null ? null : toSqlTime(endTime),
    'location': location,
    if (session.type == 'Tournament') 'opponent': opponent,
  });
  await loadSchedule();
  return result['notified'] == true;
}

/// Puts a cancelled session back on the schedule: the Undo after cancelling
/// one by mistake. A cancellation message sent moments ago is taken back.
Future<void> restoreSession(ScheduledSession session) async {
  await ApiClient.post('/sessions/${session.id}/restore');
  await loadSchedule();
}

Future<void> addPlayersToSessionById(
  String sessionId,
  List<int> playerIds,
) async {
  await ApiClient.post('/sessions/$sessionId/players', {
    'playerIds': playerIds,
  });
}

Future<void> removePlayerFromSessionById(String sessionId, int playerId) async {
  await ApiClient.delete('/sessions/$sessionId/players/$playerId');
}

/// A training session that has already happened but still has rostered
/// players with no attendance mark. Those players aren't charged for it
/// until someone marks them, and nothing used to point that out.
bool needsAttendance(ScheduledSession session) =>
    session.type == 'Training' &&
    dateOnly(session.date).isBefore(dateOnly(serverNow())) &&
    session.markedCount < session.rosterCount;

/// Display name for a player id, from the shared roster.
String playerNameFor(int playerId) {
  for (final player in mockRoster) {
    if (player.id == playerId) return player.name;
  }
  return 'Player #$playerId';
}

/// {playerId: 'present'|'absent'|'exempt'} for one session.
Future<Map<int, String>> loadAttendance(String sessionId) async {
  final map = await ApiClient.getMap('/sessions/$sessionId/attendance');
  return {
    for (final entry in map.entries)
      if (int.tryParse(entry.key) != null)
        int.parse(entry.key): '${entry.value}',
  };
}

/// Saves every mark for a session in one call — 'unmarked' entries are
/// deleted server-side rather than stored.
Future<void> saveAttendance(String sessionId, Map<int, String> marks) async {
  await ApiClient.put('/sessions/$sessionId/attendance', {
    'marks': {for (final e in marks.entries) '${e.key}': e.value},
  });
}
