import '../../../core/services/api_client.dart';

/// The longest team name the server accepts.
const maxTeamNameLength = 40;

/// The highest final score the server accepts for one side of a game.
const maxGameScore = 999;

/// How a game's opponent is saved on the schedule: "vs. Desert Warriors".
/// The families' app shows it exactly like this.
String opponentLabel(String teamName) => "vs. $teamName";

/// The team name from a saved opponent ("vs. Lakers" -> "Lakers").
String opponentName(String saved) {
  final text = saved.trim();
  return text.toLowerCase().startsWith("vs. ") ? text.substring(4) : text;
}

/// A team DSA plays at a tournament (the tournament's Standings screen),
/// with its standing: games won by DSA and by them, counted by the server
/// from the final scores of the games against them.
class TournamentOpponent {
  final int id;
  final String name;
  final int dsaWins;
  final int opponentWins;

  const TournamentOpponent({
    required this.id,
    required this.name,
    this.dsaWins = 0,
    this.opponentWins = 0,
  });

  bool get hasPlayed => dsaWins + opponentWins > 0;

  factory TournamentOpponent.fromJson(Map<String, dynamic> map) =>
      TournamentOpponent(
        id: map['id'] as int,
        name: map['name'] as String,
        dsaWins: map['dsa_wins'] as int? ?? 0,
        opponentWins: map['opponent_wins'] as int? ?? 0,
      );
}

/// One of a tournament's games on the schedule, with its final score once
/// the academy enters it. Whoever scored more won; there are no ties.
class TournamentGame {
  final int id;
  final DateTime date;

  /// "17:00", as the server sends it.
  final String startTime;
  final String? location;

  /// "vs. Lakers", or null when no opponent was picked.
  final String? opponent;
  final int? dsaScore;
  final int? opponentScore;

  /// Later than today, so it can't have a result yet.
  final bool upcoming;

  const TournamentGame({
    required this.id,
    required this.date,
    required this.startTime,
    this.location,
    this.opponent,
    this.dsaScore,
    this.opponentScore,
    this.upcoming = false,
  });

  bool get hasResult => dsaScore != null && opponentScore != null;
  bool get dsaWon => hasResult && dsaScore! > opponentScore!;

  /// The opposing team's name, or null when none was picked.
  String? get teamName {
    final saved = opponent?.trim() ?? "";
    return saved.isEmpty ? null : opponentName(saved);
  }

  factory TournamentGame.fromJson(Map<String, dynamic> map) => TournamentGame(
    id: map['id'] as int,
    date: DateTime.parse(map['session_date'] as String),
    startTime: map['start_time'] as String? ?? "",
    location: map['location'] as String?,
    opponent: map['opponent'] as String?,
    dsaScore: map['dsa_score'] as int?,
    opponentScore: map['opponent_score'] as int?,
    upcoming: map['upcoming'] as bool? ?? false,
  );
}

/// The opponents added to tournament [tournamentId], oldest first.
Future<List<TournamentOpponent>> loadOpponents(String tournamentId) async {
  final rows = await ApiClient.getList('/tournaments/$tournamentId/opponents');
  return [
    for (final row in rows)
      TournamentOpponent.fromJson(row as Map<String, dynamic>),
  ];
}

Future<TournamentOpponent> addOpponent(String tournamentId, String name) async {
  final row = await ApiClient.post('/tournaments/$tournamentId/opponents', {
    'name': name,
  });
  return TournamentOpponent.fromJson(row);
}

/// The tournament's games on the schedule (not cancelled), earliest first.
Future<List<TournamentGame>> loadGames(String tournamentId) async {
  final rows = await ApiClient.getList('/tournaments/$tournamentId/games');
  return [
    for (final row in rows)
      TournamentGame.fromJson(row as Map<String, dynamic>),
  ];
}

/// Saves a played game's final score; both null takes it back off.
Future<TournamentGame> saveGameResult(
  String tournamentId,
  TournamentGame game, {
  required int? dsaScore,
  required int? opponentScore,
}) async {
  final row = await ApiClient.put(
    '/tournaments/$tournamentId/games/${game.id}/result',
    {'dsaScore': dsaScore, 'opponentScore': opponentScore},
  );
  return TournamentGame.fromJson(row);
}
