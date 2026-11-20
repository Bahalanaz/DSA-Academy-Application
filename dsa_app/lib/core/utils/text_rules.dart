import 'package:flutter/services.dart';

/// Keeps text in the app formal: no emoji anywhere, and people's names made
/// of letters only. The server enforces the same rules (dsa_server
/// lib/text_rules.dart); these just stop them being typed in the first place.

/// Emoji and the invisible pieces they're built from: flags, skin tones, the
/// variation selector, the joiner in combined emoji, and the keycap mark.
final emojiPattern = RegExp(
  // The lint's checker doesn't know \p{Extended_Pictographic}; Dart itself
  // does (checked against emoji, flags, skin tones, accented/Arabic names).
  // ignore: valid_regexps
  r'[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}'
  r'\u{FE0F}\u{200D}\u{20E3}]',
  unicode: true,
);

/// Removes emoji as they're typed or pasted. For any free-text field.
final noEmoji = FilteringTextInputFormatter.deny(emojiPattern);

/// For phone numbers: digits and + ( ) - and spaces.
final phoneChars = FilteringTextInputFormatter.allow(RegExp(r'[0-9+() -]'));

/// For people's names: letters from any alphabet, spaces, and . ' -
final personNameChars = FilteringTextInputFormatter.allow(
  RegExp(r"[\p{L}\p{M} .'’-]", unicode: true),
);

final _personName = RegExp(
  r"^[\p{L}\p{M}]+(?:[ .'’-]+[\p{L}\p{M}]*)*$",
  unicode: true,
);

/// What's wrong with a person's name, or null if it's fine (an empty name is
/// left to the caller).
String? personNameError(String name, {String label = 'Name'}) {
  if (name.isEmpty || _personName.hasMatch(name)) return null;
  return "$label can only contain letters, spaces, and . ' -";
}
