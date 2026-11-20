// Unit tests for the server's pure rules: money arithmetic, billing months,
// and the checks on names, phones and dates. No database needed.

import 'package:dsa_server/billing.dart';
import 'package:dsa_server/ledger.dart';
import 'package:dsa_server/text_rules.dart';
import 'package:test/test.dart';

void main() {
  group('money', () {
    test('compares in whole fils, so float noise cannot settle a bill', () {
      expect(0.1 + 0.2, isNot(0.3));
      expect(cents(0.1 + 0.2), cents(0.3));
      expect(cents(31.25), 3125);
    });

    test('reads amounts the database sends as text', () {
      expect(asMoney('12.5'), 12.5);
      expect(asMoney(null), 0);
      expect(asMoney('not a number'), 0);
      expect(money(5), '5.00');
      expect(money(31.25), '31.25');
    });

    test('refuses amounts that are not real finite numbers', () {
      expect(readMoney('NaN'), isNull);
      expect(readMoney('Infinity'), isNull);
      expect(readMoney('abc'), isNull);
      expect(readMoney(7), 7);
      expect(readMoney('19.999'), 20);
    });

    test('only lets an admin record cash, card, bank or other by hand', () {
      for (final method in ['cash', 'card', 'bank', 'other']) {
        expect(normalizeMethod(method), method);
      }
      // Online methods are only ever set by the server itself.
      expect(normalizeMethod('stripe'), 'cash');
      expect(normalizeMethod('online_test'), 'cash');
      expect(normalizeMethod(null), 'cash');
    });

    test('a ledger error is a 400 unless it says otherwise', () {
      expect(const LedgerError('Nope').status, 400);
      expect(const LedgerError('Busy', 503).status, 503);
      expect(const LedgerError('Nope').toString(), 'Nope');
    });
  });

  group('billing months', () {
    test('a month is keyed by its first day', () {
      expect(monthKey(DateTime(2026, 9, 15)), '2026-09-01');
      expect(monthKey(DateTime(2026, 12, 31)), '2026-12-01');
    });

    test('only real months are accepted from the app', () {
      expect(monthPattern.hasMatch('2026-12-01'), isTrue);
      expect(monthPattern.hasMatch('2026-13-01'), isFalse);
      expect(monthPattern.hasMatch('2026-00-01'), isFalse);
      expect(monthPattern.hasMatch('2026-09-02'), isFalse);
    });

    test('bills are titled by month', () {
      expect(monthTitle('2026-09-01'), 'September 2026 Training Fee');
      expect(monthName('2026-08-01'), 'August 2026');
    });

    test("a month's fee is the coach fee plus sessions", () {
      expect(
        owedFrom({
          'override_amount': null,
          'coach_fee': '100.00',
          'session_charges': '62.50',
        }),
        162.5,
      );
    });

    test("an admin's override replaces the calculated fee", () {
      expect(
        owedFrom({
          'override_amount': '80.00',
          'coach_fee': '100.00',
          'session_charges': '62.50',
        }),
        80,
      );
    });
  });

  group('text rules', () {
    test('names in any alphabet are fine', () {
      for (final name in [
        'Juan Cruz',
        'José Núñez',
        'محمد علي',
        "O'Neil-Smith",
      ]) {
        expect(personNameError(name), isNull, reason: name);
      }
    });

    test('names with digits, symbols or emoji are refused', () {
      for (final name in ['Ana2', '--', 'Ana!', 'Ana ⚽']) {
        expect(personNameError(name), isNotNull, reason: name);
      }
      expect(hasEmoji('Great game ⚽'), isTrue);
      expect(hasEmoji('Great game'), isFalse);
    });

    test('runs of spaces are collapsed', () {
      expect(normalizeSpaces('  Ana   Lopez '), 'Ana Lopez');
    });

    test('too-long text names the field', () {
      expect(
        lengthError('Name', 'abc', 2),
        'Name must be 2 characters or fewer',
      );
      expect(lengthError('Name', 'ab', 2), isNull);
    });

    test('phone numbers: optional, but real when given', () {
      expect(phoneError(''), isNull);
      expect(phoneError('+971 50 123 4567'), isNull);
      expect(phoneError('(050) 123-4567'), isNull);
      expect(phoneError('call me'), isNotNull);
      expect(phoneError('123'), isNotNull);
      expect(phoneError('+1 234 567 890 123 456'), isNotNull);
    });

    test('dates must exist on the calendar', () {
      expect(realDate('2028-02-29'), DateTime(2028, 2, 29));
      // DateTime.tryParse alone would roll this over into March.
      expect(realDate('2026-02-30'), isNull);
      expect(realDate('2026-2-3'), isNull);
      expect(realDate('yesterday'), isNull);
    });
  });
}
