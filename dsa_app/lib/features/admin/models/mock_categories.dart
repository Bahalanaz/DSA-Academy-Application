import '../../../core/services/api_client.dart';
import '../../../core/utils/category_age.dart';

/// The club's age categories — one shared list backing every category
/// picker in the admin side (Players filter, Schedule, Trainings,
/// Tournaments, and Messages "Send to"). Adding a category from any one
/// of those screens makes it available in all the others immediately.
///
/// Categories are named by birth year ("B2012" = players born 2012),
/// kept sorted ascending so they always read oldest-born to youngest.
///
/// Backed by the `categories` table in dsa_db via dsa_server. Every other
/// screen just reads this list synchronously; [loadCategories] is what keeps
/// it in sync with the server.
///
/// These go through ApiClient like everything else. They used to call the
/// server directly without the login token, so once logins were required
/// every one of them was refused: the list came back empty, no training
/// could be created, and adding a tournament crashed.
final List<String> mockCategories = [];

void _sortCategories() {
  mockCategories.sort((a, b) {
    final yearA = categoryBirthYear(a);
    final yearB = categoryBirthYear(b);
    if (yearA == null && yearB == null) return a.compareTo(b);
    if (yearA == null) return 1;
    if (yearB == null) return -1;
    return yearA.compareTo(yearB);
  });
}

/// Fetches the current category list from the server and replaces
/// [mockCategories] with it.
Future<void> loadCategories() async {
  final rows = await ApiClient.getList('/categories');
  mockCategories
    ..clear()
    ..addAll(
      rows.map((row) => (row as Map<String, dynamic>)['code'] as String),
    );
  _sortCategories();
}

/// Creates the category on the server, then reflects it locally once the
/// server confirms it — so a failed request (offline, duplicate, etc.)
/// never leaves the local list showing something that isn't actually saved.
Future<void> addMockCategory(String category) async {
  if (category.isEmpty || mockCategories.contains(category)) return;
  await ApiClient.post('/categories', {
    'code': category,
    'birthYear': categoryBirthYear(category),
  });
  mockCategories.add(category);
  _sortCategories();
}

/// Removes the category on the server, then locally. The server refuses
/// (409) while an active training or tournament still uses it, and that
/// message reaches the screen as the error.
Future<void> removeMockCategory(String category) async {
  await ApiClient.delete('/categories/$category');
  mockCategories.remove(category);
}
