import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsa_app/core/services/api_client.dart';
import 'package:dsa_app/core/utils/friendly_error.dart';
import 'package:dsa_app/core/utils/jersey_number.dart';
import 'package:dsa_app/core/utils/text_rules.dart';
import 'package:dsa_app/core/widgets/bill_description.dart';
import 'package:dsa_app/features/admin/models/admin_player.dart';
import 'package:dsa_app/features/admin/models/mock_orders.dart';
import 'package:dsa_app/features/admin/models/mock_roster.dart';
import 'package:dsa_app/features/admin/models/mock_tournaments.dart';
import 'package:dsa_app/features/admin/models/order_stage_style.dart';
import 'package:dsa_app/features/admin/models/tournament_opponents.dart';

void main() {
  group('error messages people see', () {
    test('a lost or slow connection gets the standard sentence', () {
      expect(friendlyError(const SocketException('x')), noConnectionMessage);
      expect(friendlyError(TimeoutException('x')), slowConnectionMessage);
    });

    test('bugs and bad data never show program details', () {
      expect(friendlyError(const FormatException('x')), somethingWrongMessage);
      expect(friendlyError(StateError('x')), somethingWrongMessage);
      expect(friendlyError(Object()), somethingWrongMessage);
    });

    test("the server's own sentences are kept", () {
      expect(
        friendlyError(const ApiException(409, 'Jersey #7 is already taken.')),
        'Jersey #7 is already taken.',
      );
      expect(
        friendlyError(Exception('Please choose a category')),
        'Please choose a category',
      );
      // A capital in the middle of a name is not a field name.
      expect(
        friendlyError(
          const ApiException(409, 'McArthur is already on this account'),
        ),
        'McArthur is already on this account',
      );
    });

    test('messages written for developers are reworded', () {
      expect(
        friendlyError(const ApiException(400, 'playerId is required')),
        checkEntryMessage,
      );
      expect(
        friendlyError(const ApiException(400, 'Use /training-fees instead')),
        checkEntryMessage,
      );
      expect(
        friendlyError(const ApiException(404, 'No order with that id')),
        'That order is no longer available. Please refresh and try again.',
      );
      expect(
        friendlyError(const ApiException(404, 'No photo here')),
        "There's no photo here yet.",
      );
      expect(
        friendlyError(const ApiException(500, '  ')),
        somethingWrongMessage,
      );
    });

    test('a wrong password says so, in plain words', () {
      expect(
        friendlyError(
          const ApiException(401, 'Invalid username/email or password'),
        ),
        'Wrong username, email or password. Please try again.',
      );
      expect(
        friendlyError(
          const ApiException(400, 'Username/email and password are required'),
        ),
        'Username or email and password are required',
      );
    });

    test('a sentence a screen wrote itself is shown as is', () {
      expect(
        friendlyError('Added, but the photo could not be saved.'),
        'Added, but the photo could not be saved.',
      );
    });
  });

  group('order stages', () {
    Order order({
      OrderStatus status = OrderStatus.approved,
      String? paymentStatus = 'pending',
      double amountPaid = 0,
      DateTime? receivedDate,
    }) => Order(
      id: '1',
      playerName: 'Ann Cruz',
      itemId: 1,
      itemLabel: 'League Uniform',
      amount: 130,
      status: status,
      createdDate: DateTime(2026, 10, 1),
      paymentStatus: paymentStatus,
      amountPaid: amountPaid,
      receivedDate: receivedDate,
    );

    test('from placing it to the family holding the kit', () {
      expect(order(status: OrderStatus.pending).stage, OrderStage.pending);
      expect(order().stage, OrderStage.unpaid);
      expect(order(amountPaid: 30).stage, OrderStage.partPaid);
      expect(order(paymentStatus: 'paid').stage, OrderStage.paid);
      expect(order(paymentStatus: 'waived').stage, OrderStage.paid);
      // A free item never had a bill.
      expect(order(paymentStatus: null).stage, OrderStage.paid);
      expect(order(paymentStatus: 'void').stage, OrderStage.billCancelled);
      expect(order(status: OrderStatus.rejected).stage, OrderStage.declined);
    });

    test('a kit can be handed over before it is paid', () {
      final given = order(receivedDate: DateTime(2026, 10, 14));
      expect(given.stage, OrderStage.received);
      final style = orderStageStyle(given);
      expect(style.label, 'RECEIVED');
      expect(style.note, 'Received 14 Oct 2026 · not paid yet');
    });

    test('part paid says what is still owed', () {
      expect(
        orderStageStyle(order(amountPaid: 30)).note,
        'AED 100.00 still to pay',
      );
    });

    testWidgets('the chip shows the stage', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: OrderStageChip(label: 'PAID', color: Colors.blue),
        ),
      );
      expect(find.text('PAID'), findsOneWidget);
    });
  });

  group('jersey numbers', () {
    test('"00" is its own key; "07" is 7', () {
      expect(jerseyKey('00'), doubleZero);
      expect(jerseyKey('0'), 0);
      expect(jerseyKey('07'), 7);
      expect(jerseyKey(' 13 '), 13);
      expect(jerseyKey(''), isNull);
      expect(jerseyKey(null), isNull);
      expect(jerseyKey('abc'), isNull);
    });

    test('keys are written back the way the shirt reads', () {
      expect(jerseyText(doubleZero), '00');
      expect(jerseyText(0), '0');
      expect(jerseyText(7), '7');
    });
  });

  group('tournament warnings', () {
    AdminPlayer player(int id, String born, String? jersey) => AdminPlayer(
      id: id,
      name: 'Player $id',
      categories: const [],
      parentName: 'Parent',
      parentPhone: '',
      attendanceRate: 0,
      birthday: '$born-01-01',
      jerseyNumber: jersey,
    );

    setUp(() {
      mockRoster
        ..clear()
        ..addAll([
          player(1, '2013', '7'),
          player(2, '2014', '07'), // the same shirt as "7"
          player(3, '2012', '9'), // too old for B2013
          player(4, '2011', '9'), // too old, but the family declined
          player(5, '2013', null), // no number
          player(6, '2013', '00'), // 00 is its own shirt
          player(7, '2014', '0'), // 0, not the same as 00
        ]);
    });

    tearDown(mockRoster.clear);

    Tournament tournament() => Tournament(
      name: 'Cup',
      category: 'B2013',
      location: 'Dubai',
      playerIds: [1, 2, 3, 4, 5, 6, 7],
      playerConsents: {4: 'declined'},
    );

    test(
      'shared numbers are found, "07" and "7" included, "00" and "0" not',
      () {
        expect(tournament().jerseyConflicts, {
          7: [1, 2],
        });
      },
    );

    test('only players older than the category are flagged', () {
      // Born 2014 playing up is fine; the declined player isn't going.
      expect(tournament().tooOldIds, [3]);
    });

    test('the card counts leave declined players out of the total', () {
      final cup = tournament()
        ..playerConsents.addAll({1: 'accepted', 2: 'accepted'});
      final s = cup.summary;
      // 7 invited, 1 declined: everything is "out of" 6.
      expect(s.going, 6);
      expect(s.accepted, 2);
      expect(s.pending, 4);
      expect(s.declined, 1);
      // No fees sent yet.
      expect((s.paid, s.requested, s.notSent), (0, 0, 6));
    });

    test('changing the category re-checks', () {
      final cup = tournament()..category = 'B2014';
      expect(cup.tooOldIds, [1, 3, 5, 6]);
    });
  });

  group('nickname search', () {
    final kiko = AdminPlayer(
      name: 'Francisco Reyes',
      nickname: 'Kiko',
      categories: const [],
      parentName: 'Parent',
      parentPhone: '',
      attendanceRate: 0,
    );
    final noNick = AdminPlayer(
      name: 'Ana Lopez',
      categories: const [],
      parentName: 'Parent',
      parentPhone: '',
      attendanceRate: 0,
    );

    test('a player is found by name or nickname, any case', () {
      expect(kiko.matchesSearch('fran'), isTrue);
      expect(kiko.matchesSearch(' KIK '), isTrue);
      expect(kiko.matchesSearch('zzz'), isFalse);
      expect(noNick.matchesSearch('ana'), isTrue);
      expect(noNick.matchesSearch(''), isTrue);
    });

    test('the nickname is shown only when it is why they matched', () {
      expect(kiko.matchesNicknameOnly('kiko'), isTrue);
      expect(kiko.matchesNicknameOnly('reyes'), isFalse);
      expect(kiko.matchesNicknameOnly(''), isFalse);
      expect(noNick.matchesNicknameOnly('ana'), isFalse);
    });
  });

  group('standings and games', () {
    test('a picked opponent is saved as "vs. Name" and read back', () {
      expect(opponentLabel('Desert Warriors'), 'vs. Desert Warriors');
      expect(opponentName('vs. Desert Warriors'), 'Desert Warriors');
      expect(opponentName('VS. Lakers'), 'Lakers');
      // One typed in before the pick-list existed.
      expect(opponentName('Victory Hoops'), 'Victory Hoops');
    });

    TournamentGame game({Object? dsa, Object? them, String? opponent}) =>
        TournamentGame.fromJson({
          'id': 1,
          'session_date': '2026-11-08',
          'start_time': '10:00',
          'location': 'DSA Gym',
          'opponent': opponent,
          'dsa_score': dsa,
          'opponent_score': them,
          'upcoming': false,
        });

    test('whoever scored more won', () {
      final won = game(dsa: 54, them: 48, opponent: 'vs. Grind');
      expect((won.hasResult, won.dsaWon, won.teamName), (true, true, 'Grind'));
      final lost = game(dsa: 9, them: 19, opponent: 'vs. Grind');
      expect((lost.hasResult, lost.dsaWon), (true, false));
    });

    test('no result until both scores are in; no opponent is null', () {
      expect(game(dsa: 54).hasResult, isFalse);
      expect(game().dsaWon, isFalse);
      expect(game(opponent: '  ').teamName, isNull);
      expect(game().teamName, isNull);
    });

    test('a standing with no games played shows no numbers', () {
      final fresh = TournamentOpponent.fromJson({
        'id': 1,
        'name': 'Knicks',
        'dsa_wins': 0,
        'opponent_wins': 0,
      });
      expect(fresh.hasPlayed, isFalse);
      final played = TournamentOpponent.fromJson({
        'id': 2,
        'name': 'Grind',
        'dsa_wins': 2,
        'opponent_wins': 1,
      });
      expect(
        (played.hasPlayed, played.dsaWins, played.opponentWins),
        (true, 2, 1),
      );
    });
  });

  group('bill descriptions', () {
    Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, child: child)),
      ),
    );

    const breakdown =
        "350 - October Fees\n400 - PEBA 2007\n55 - Previous Balance\n"
        "\nTOTAL 805\nPlease pay by Friday";

    testWidgets('what an Others bill is for shows under its title', (
      tester,
    ) async {
      await show(tester, const BillDescription("Team photo print, 8x10"));
      expect(find.text("Team photo print, 8x10"), findsOneWidget);
    });

    testWidgets('no description takes no space', (tester) async {
      for (final none in [null, "", "   "]) {
        await show(tester, BillDescription(none));
        expect(find.byType(Text), findsNothing);
      }
    });

    testWidgets('a list keeps a long breakdown to 3 lines', (tester) async {
      await show(tester, const BillDescription(breakdown));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('an opened bill shows the whole breakdown', (tester) async {
      await show(tester, const BillDescription(breakdown, maxLines: null));
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNull);
      // Every line is laid out: taller than 3 lines of 12px text.
      expect(tester.getSize(find.byType(Text)).height, greaterThan(70));
    });
  });

  group('names', () {
    test('any alphabet, but no digits or symbols', () {
      expect(personNameError('José Núñez'), isNull);
      expect(personNameError('محمد علي'), isNull);
      expect(personNameError(''), isNull);
      expect(personNameError('Ana2'), isNotNull);
    });
  });
}
