import '../../../core/utils/jersey_number.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/session.dart';
import 'mock_roster.dart' show mockRoster;
import 'mock_schedule.dart';
import 'payment_record.dart';

/// A tournament the club enters, with the roster assigned to it.
///
/// The roster is keyed by player ID; [playerNames] lines up with
/// [playerIds] index for index and is only for display.
class Tournament {
  final String id;
  String name;
  String category;
  final String location;
  final List<int> playerIds;
  final List<String> playerNames;
  String paymentInfo;

  /// What each rostered player owes for it, by player ID.
  final Map<int, double> playerPayments;

  /// Each rostered player's family's answer, by player ID: 'pending',
  /// 'accepted' or 'declined'. Adding a player only invites them; the
  /// tournament can't be priced or billed until everyone has accepted.
  final Map<int, String> playerConsents;

  /// Why each family that declined did so, by player ID (only those who
  /// gave a reason), and when each family answered ("2026-11-10 14:05").
  final Map<int, String> playerDeclineReasons;
  final Map<int, String> playerRespondedAt;

  /// Players whose answer the academy gave for the family (say they
  /// couldn't log in), rather than the family themselves.
  final Set<int> answeredByAcademy;

  Tournament({
    this.id = '',
    required this.name,
    required this.category,
    required this.location,
    List<int>? playerIds,
    List<String>? playerNames,
    this.paymentInfo = "Not set",
    Map<int, double>? playerPayments,
    Map<int, String>? playerConsents,
    Map<int, String>? playerDeclineReasons,
    Map<int, String>? playerRespondedAt,
    Set<int>? answeredByAcademy,
  }) : playerIds = playerIds ?? [],
       playerNames = playerNames ?? [],
       playerPayments = playerPayments ?? {},
       playerConsents = playerConsents ?? {},
       playerDeclineReasons = playerDeclineReasons ?? {},
       playerRespondedAt = playerRespondedAt ?? {},
       answeredByAcademy = answeredByAcademy ?? {};

  String consentOf(int playerId) => playerConsents[playerId] ?? 'pending';

  /// The open or paid fee sent for [playerId] on this tournament, or null
  /// when none has been sent (read from the loaded payments).
  PaymentRecord? billFor(int playerId) => mockPayments
      .where(
        (r) =>
            r.type == PaymentType.tournament &&
            r.playerId == playerId &&
            '${r.tournamentId}' == id &&
            (r.isOpen || r.paid),
      )
      .firstOrNull;

  /// Where the families' answers and the fees stand, for the list card.
  /// Declined players aren't going, so [going] (the "out of") leaves them
  /// out: 10 invited with 1 declined reads "accepted 3/9".
  ({
    int accepted,
    int pending,
    int declined,
    int going,
    int paid,
    int requested,
    int notSent,
  })
  get summary {
    var accepted = 0, pending = 0, declined = 0;
    var paid = 0, requested = 0, notSent = 0;
    for (final id in playerIds) {
      switch (consentOf(id)) {
        case 'declined':
          declined++;
          continue;
        case 'accepted':
          accepted++;
        default:
          pending++;
      }
      final bill = billFor(id);
      if (bill == null) {
        notSent++;
      } else if (bill.paid) {
        paid++;
      } else {
        requested++;
      }
    }
    return (
      accepted: accepted,
      pending: pending,
      declined: declined,
      going: playerIds.length - declined,
      paid: paid,
      requested: requested,
      notSent: notSent,
    );
  }

  /// Players whose family hasn't answered yet.
  List<int> get awaitingIds =>
      playerIds.where((id) => consentOf(id) == 'pending').toList();

  /// Players whose family said no. They have to come off the roster before
  /// the tournament can be priced.
  List<int> get declinedIds =>
      playerIds.where((id) => consentOf(id) == 'declined').toList();

  /// Everyone on the roster has accepted, so the fee can be set and sent.
  bool get everyoneAccepted =>
      playerIds.every((id) => consentOf(id) == 'accepted');

  /// Players on this roster too OLD for its category: born before the
  /// category's year (B2013 = born 2013; someone born 2012 is too old).
  /// Younger players playing up are fine. Happens when the category is
  /// changed after players were added. Declined players don't count.
  List<int> get tooOldIds {
    final year = int.tryParse(category.replaceAll(RegExp(r'\D'), ''));
    if (year == null) return const [];
    return [
      for (final id in playerIds)
        if (consentOf(id) != 'declined')
          if (int.tryParse(
                mockRoster.where((p) => p.id == id).firstOrNull?.birthYear ??
                    '',
              )
              case final born? when born < year)
            id,
    ];
  }

  /// Jersey numbers two or more players on this roster share, each with
  /// those players (smallest number first). Players whose family declined
  /// aren't going, so they don't count; nor does a player with no number.
  /// "07" and "7" are the same shirt. Read from the roster's player list,
  /// so changing a player's number (or taking them off) clears it.
  Map<int, List<int>> get jerseyConflicts {
    final byNumber = <int, List<int>>{};
    for (final id in playerIds) {
      if (consentOf(id) == 'declined') continue;
      final player = mockRoster.where((p) => p.id == id).firstOrNull;
      final number = jerseyKey(player?.jerseyNumber);
      if (number == null) continue;
      byNumber.putIfAbsent(number, () => []).add(id);
    }
    final shared = byNumber.entries.where((e) => e.value.length > 1).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {for (final e in shared) e.key: e.value};
  }

  String nameOf(int playerId) {
    final index = playerIds.indexOf(playerId);
    return index >= 0 && index < playerNames.length
        ? playerNames[index]
        : playerNameFor(playerId);
  }
}

final List<Tournament> mockTournaments = [];

Future<void> loadTournaments() async {
  final rows = await ApiClient.getList('/tournaments');
  mockTournaments
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        // Ids, names and amounts are concatenated with the same ORDER BY,
        // so position i in each lines up.
        final ids = asIdList(map['player_ids']);
        final names = asCsvList(map['player_names']);
        final amounts = asCsvList(map['player_amounts']);
        final consents = asCsvList(map['player_consents']);
        // Lists with gaps (null where there's nothing), index for index. A
        // server from before these sends none.
        final reasons = map['player_decline_reasons'] as List? ?? const [];
        final answered = map['player_responded_at'] as List? ?? const [];
        final byAcademy =
            map['player_answered_by_academy'] as List? ?? const [];
        return Tournament(
          id: '${map['id']}',
          name: map['name'] as String,
          category: (map['category'] as String?) ?? '',
          location: (map['location'] as String?) ?? '',
          playerIds: ids,
          playerNames: names,
          paymentInfo: (map['payment_info'] as String?) ?? "Not set",
          playerPayments: {
            for (var i = 0; i < ids.length; i++)
              ids[i]: i < amounts.length
                  ? (double.tryParse(amounts[i]) ?? 0)
                  : 0,
          },
          playerConsents: {
            for (var i = 0; i < ids.length && i < consents.length; i++)
              ids[i]: consents[i],
          },
          playerDeclineReasons: {
            for (var i = 0; i < ids.length && i < reasons.length; i++)
              if (reasons[i] != null) ids[i]: '${reasons[i]}',
          },
          playerRespondedAt: {
            for (var i = 0; i < ids.length && i < answered.length; i++)
              if (answered[i] != null) ids[i]: '${answered[i]}',
          },
          answeredByAcademy: {
            for (var i = 0; i < ids.length && i < byAcademy.length; i++)
              if (byAcademy[i] == true) ids[i],
          },
        );
      }),
    );
}

Future<void> addTournament({
  required String name,
  required String category,
  String location = '',
}) async {
  await ApiClient.post('/tournaments', {
    'name': name,
    'category': category,
    'location': location,
  });
  await loadTournaments();
}

/// Also takes back the tournament's unpaid bills server-side.
Future<void> removeTournament(Tournament tournament) async {
  await ApiClient.delete('/tournaments/${tournament.id}');
  mockTournaments.remove(tournament);
  await loadPayments();
}

Future<void> renameTournament(Tournament tournament, String name) async {
  await ApiClient.put('/tournaments/${tournament.id}', {'name': name});
  tournament.name = name;
}

Future<void> saveTournamentPaymentInfo(
  Tournament tournament,
  String paymentInfo,
) async {
  await ApiClient.put('/tournaments/${tournament.id}', {
    'paymentInfo': paymentInfo,
  });
  tournament.paymentInfo = paymentInfo;
}

/// Saves every player's amount in one call ("APPLY CHANGES"). Bills sent
/// but not paid off are re-priced; players whose bills couldn't move (fully
/// paid, or already paid more than the new amount) come back by name.
Future<List<String>> saveTournamentAmounts(Tournament tournament) async {
  final result = await ApiClient.put('/tournaments/${tournament.id}/amounts', {
    'amounts': {
      for (final entry in tournament.playerPayments.entries)
        '${entry.key}': entry.value,
    },
  });
  await loadPayments();
  return ((result['alreadyPaid'] as List?) ?? const []).cast<String>();
}

Future<void> setTournamentCategory(
  Tournament tournament,
  String category,
) async {
  await ApiClient.put('/tournaments/${tournament.id}', {'category': category});
  tournament.category = category;
}

Future<void> addPlayersToTournament(
  Tournament tournament,
  List<int> playerIds,
) async {
  final result = await ApiClient.post('/tournaments/${tournament.id}/players', {
    'playerIds': playerIds,
  });
  // Only who the server actually put on, with the answer it holds: an
  // invitation is 'pending', but a child put back on with their fee still
  // paid comes back 'accepted'. Someone too old for the category isn't
  // added at all, and used to show on the roster anyway until a refresh.
  final consents = (result['consents'] as Map?) ?? const {};
  for (final id in playerIds) {
    final consent = consents['$id'];
    if (consent == null) continue;
    if (!tournament.playerIds.contains(id)) {
      tournament.playerIds.add(id);
      tournament.playerNames.add(playerNameFor(id));
    }
    tournament.playerConsents[id] = '$consent';
  }
}

/// A family's answer to a tournament invitation. A parent answers for their
/// own children; the server refuses a change once the fee has been sent.
/// Declining comes with the family's [reason], which the admin sees.
Future<void> answerTournamentInvite(
  Tournament tournament,
  int playerId, {
  required bool accept,
  String? reason,
}) async {
  final result = await ApiClient.post(
    '/tournaments/${tournament.id}/players/$playerId/consent',
    {'accept': accept, if (!accept) 'reason': ?reason},
  );
  tournament.playerConsents[playerId] =
      result['consent'] as String? ?? (accept ? 'accepted' : 'declined');
  if (Session.current?.isAdmin ?? false) {
    tournament.answeredByAcademy.add(playerId);
  } else {
    tournament.answeredByAcademy.remove(playerId);
  }
  if (accept || reason == null) {
    tournament.playerDeclineReasons.remove(playerId);
  } else {
    tournament.playerDeclineReasons[playerId] = reason;
  }
}

/// Admin: reminds families who haven't answered the invitation yet (a
/// message and a phone notification each). [playerIds] for those children
/// only; null for everyone still waiting. Families reminded in the last two
/// minutes are skipped, so a double tap doesn't send two.
Future<({int reminded, int skipped})> remindTournamentInvite(
  Tournament tournament, {
  List<int>? playerIds,
}) async {
  final result = await ApiClient.post('/tournaments/${tournament.id}/remind', {
    'playerIds': ?playerIds,
  });
  return (
    reminded: asInt(result['reminded']),
    skipped: asInt(result['skipped']),
  );
}

/// A bill that still had money on it when its player left the tournament.
typedef PaidTournamentBill = ({String paymentId, double amountPaid});

/// Removing a player takes back their unpaid bill. Bills they'd already
/// paid come back in `paid`, so the screen can offer a refund.
Future<({int cancelled, List<PaidTournamentBill> paid})>
removePlayerFromTournament(Tournament tournament, int playerId) async {
  final result = await ApiClient.deleteJson(
    '/tournaments/${tournament.id}/players/$playerId',
  );
  final index = tournament.playerIds.indexOf(playerId);
  if (index >= 0) {
    tournament.playerIds.removeAt(index);
    if (index < tournament.playerNames.length) {
      tournament.playerNames.removeAt(index);
    }
  }
  tournament.playerPayments.remove(playerId);
  tournament.playerConsents.remove(playerId);
  await loadPayments();
  return (
    cancelled: asInt(result['cancelledRequests']),
    paid: [
      for (final bill
          in (result['paidPayments'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
        (paymentId: '${bill['id']}', amountPaid: asDouble(bill['amountPaid'])),
    ],
  );
}
