/// Keeps what's stored formal: no emoji in any text, and people's names made
/// of letters only.
library;

/// Emoji and the invisible pieces they're built from: flags (regional
/// indicators), skin tones, the variation selector that turns a symbol into
/// an emoji, the joiner in combined emoji, and the keycap mark.
final emojiPattern = RegExp(
  r'[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}'
  r'\u{FE0F}\u{200D}\u{20E3}]',
  unicode: true,
);

bool hasEmoji(String text) => emojiPattern.hasMatch(text);

/// Letters from any alphabet (so José, Nguyễn and محمد are fine), with the
/// spaces, dots, apostrophes and hyphens real names use. It must start with a
/// letter, so no digits, symbols or names like "--".
final _personName = RegExp(
  r"^[\p{L}\p{M}]+(?:[ .'’-]+[\p{L}\p{M}]*)*$",
  unicode: true,
);

/// What's wrong with a person's name, or null if it's fine. Emptiness and
/// length are checked by the caller, which knows its own wording.
String? personNameError(String name, {String label = 'Name'}) {
  if (_personName.hasMatch(name)) return null;
  return "$label can only contain letters, spaces, and . ' -";
}

/// Trims and collapses runs of spaces. "Ana  Lopez" used to be saved as
/// typed, and slipped past the check for adding the same child twice.
String normalizeSpaces(String text) =>
    text.trim().replaceAll(RegExp(r'\s+'), ' ');

/// A message naming the field when text is longer than its column allows.
/// The database's own "Data too long for column 'name'" used to reach the app.
String? lengthError(String label, Object? value, int max) {
  if (value is String && value.trim().length > max) {
    return '$label must be $max characters or fewer';
  }
  return null;
}

/// Digits with the usual + ( ) - and spaces, 7 to 15 digits in all. Any text
/// up to 30 characters used to be accepted ("call me" included). Empty is
/// fine: the phone number is optional.
String? phoneError(String phone) {
  if (phone.isEmpty) return null;
  final digits = phone.replaceAll(RegExp(r'\D'), '').length;
  if (!RegExp(r'^\+?[0-9 ()-]+$').hasMatch(phone) ||
      digits < 7 ||
      digits > 15) {
    return 'Enter a valid phone number, like +971 50 123 4567';
  }
  return null;
}

/// A real calendar date written as YYYY-MM-DD, or null. DateTime.tryParse
/// alone rolls "2026-02-30" over into March, and the database then refused
/// it with a server error.
DateTime? realDate(String text) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final roundTrip =
      '${parsed.year.toString().padLeft(4, '0')}-'
      '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.day.toString().padLeft(2, '0')}';
  return roundTrip == text ? parsed : null;
}
