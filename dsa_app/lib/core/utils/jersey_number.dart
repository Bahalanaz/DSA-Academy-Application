/// Jersey numbers inside the app.
///
/// "07" and "7" are the same shirt, so numbers are compared as numbers.
/// "00" is the exception: a shirt of its own, not the same as "0". It's
/// kept as [doubleZero] wherever the app holds a number as an int, and
/// written back as "00" (the server does the same).
library;

/// The app's key for jersey "00".
const doubleZero = -1;

/// A stored or typed jersey number as a key: "00" -> [doubleZero], "07" ->
/// 7, anything that isn't a number -> null.
int? jerseyKey(String? text) {
  final trimmed = (text ?? '').trim();
  return trimmed == '00' ? doubleZero : int.tryParse(trimmed);
}

/// How a key is written: "00" for [doubleZero], otherwise the number.
String jerseyText(int number) => number == doubleZero ? '00' : '$number';
