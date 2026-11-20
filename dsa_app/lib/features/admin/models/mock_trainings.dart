import '../../../core/services/api_client.dart';

/// A training program the admin has set up, spanning one or more
/// categories (e.g. "B2012" and "B2013" trained together).
///
/// Backed by `training_programs` + `training_program_categories`.
/// Scheduled sessions link back by [id] rather than matching on category
/// text, so renaming a category never mismatches a session.
class TrainingProgram {
  final String id;
  final List<String> categories;

  /// What the admin called it, or null if they left the name blank.
  final String? name;

  const TrainingProgram({
    required this.id,
    required this.categories,
    this.name,
  });

  String get categoryLabel => categories.join(", ");

  /// The name to show everywhere. Falls back to `<categories> Training`,
  /// which is what every training was called before names existed — so
  /// trainings created back then still read the same.
  String get displayName {
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? "$categoryLabel Training" : trimmed;
  }
}

/// Shared between the Trainings screen (where these are created) and the
/// Schedule screen (where sessions are linked to one).
final List<TrainingProgram> mockTrainings = [];

Future<void> loadTrainings() async {
  final rows = await ApiClient.getList('/trainings');
  mockTrainings
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        return TrainingProgram(
          id: '${map['id']}',
          categories: asCsvList(map['categories']),
          name: map['name'] as String?,
        );
      }),
    );
}

/// A training's default players: put on every new session of it
/// automatically. Changing them doesn't touch sessions already scheduled.
Future<List<int>> loadTrainingDefaults(TrainingProgram training) async {
  final result = await ApiClient.getMap('/trainings/${training.id}/defaults');
  return [for (final id in (result['playerIds'] as List? ?? [])) asInt(id)];
}

Future<void> saveTrainingDefaults(
  TrainingProgram training,
  List<int> playerIds,
) async {
  await ApiClient.put('/trainings/${training.id}/defaults', {
    'playerIds': playerIds,
  });
}

Future<void> addTraining(List<String> categories, {String? name}) async {
  await ApiClient.post('/trainings', {'categories': categories, 'name': name});
  await loadTrainings();
}

/// Soft-deleted server-side: sessions after today are cancelled, sessions
/// up to today are kept so the fees they earned still stand. Returns how
/// many of each, so the screen can say what actually happened.
Future<({int cancelled, int kept})> removeTraining(
  TrainingProgram training,
) async {
  final result = await ApiClient.deleteJson('/trainings/${training.id}');
  mockTrainings.remove(training);
  return (
    cancelled: asInt(result['cancelledSessions']),
    kept: asInt(result['keptSessions']),
  );
}
