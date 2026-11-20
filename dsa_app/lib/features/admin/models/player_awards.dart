import '../../../core/services/api_client.dart';

/// An award a player received (MVP, Most Improved ...). Backed by the
/// `player_awards` table. The admin adds, edits and removes any; a parent
/// adds awards for their own children and changes only the ones they added
/// ([canEdit]). Shown on the Player Profile's AWARDS tab.
class PlayerAward {
  final int id;
  final String title;
  final String? league;

  /// One of the academy's category codes ("B2013"), or null.
  final String? category;

  /// "YYYY-MM-DD".
  final String date;

  /// Whether whoever is signed in may edit or delete it.
  final bool canEdit;

  const PlayerAward({
    required this.id,
    required this.title,
    required this.league,
    required this.category,
    required this.date,
    required this.canEdit,
  });

  factory PlayerAward.fromJson(Map<String, dynamic> row) => PlayerAward(
    id: asInt(row['id']),
    title: row['title'] as String,
    league: row['league'] as String?,
    category: row['category'] as String?,
    date: row['award_date'] as String,
    canEdit: '${row['can_edit']}' == '1',
  );
}

/// A player's awards, newest first.
Future<List<PlayerAward>> loadAwards(int playerId) async {
  final rows = await ApiClient.getList('/players/$playerId/awards');
  return [
    for (final row in rows) PlayerAward.fromJson(row as Map<String, dynamic>),
  ];
}

Future<void> addAward(
  int playerId, {
  required String title,
  String? league,
  String? category,
  required String date,
}) => ApiClient.post('/players/$playerId/awards', {
  'title': title,
  'league': league,
  'category': category,
  'date': date,
});

Future<void> updateAward(
  PlayerAward award, {
  required String title,
  String? league,
  String? category,
  required String date,
}) => ApiClient.put('/awards/${award.id}', {
  'title': title,
  'league': league,
  'category': category,
  'date': date,
});

Future<void> deleteAward(PlayerAward award) =>
    ApiClient.delete('/awards/${award.id}');
