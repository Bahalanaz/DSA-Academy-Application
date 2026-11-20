/// Extracts the birth year from a category like "B2012" -> 2012. Returns
/// null for anything that doesn't follow that shape.
int? categoryBirthYear(String category) {
  final match = RegExp(r'(\d+)').firstMatch(category);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Age in whole years from a "YYYY-MM-DD" birthday, counting whether this
/// year's birthday has come yet. Null without a usable birthday.
///
/// Prefer this to [primaryAge], which is only the calendar year minus the
/// birth year — a year too old for anyone whose birthday is still to come.
int? ageFromBirthday(String? birthday) {
  final date = DateTime.tryParse(birthday ?? '');
  if (date == null) return null;
  final now = DateTime.now();
  var age = now.year - date.year;
  if (now.month < date.month ||
      (now.month == date.month && now.day < date.day)) {
    age--;
  }
  return age;
}

/// The player's current age, computed from the most recent (largest)
/// birth year among their categories — a player can play up into an
/// older, earlier-born bracket, but their real age matches the latest
/// birth year they're registered under.
int? primaryAge(List<String> categories) {
  final years = categories.map(categoryBirthYear).whereType<int>().toList();
  if (years.isEmpty) return null;
  final latestYear = years.reduce((a, b) => a > b ? a : b);
  return DateTime.now().year - latestYear;
}
