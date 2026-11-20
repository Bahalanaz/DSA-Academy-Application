import '../../../core/services/api_client.dart';
import '../../../core/utils/date_format.dart';
import 'payment_record.dart';

/// One line in the club's money history: either a bill being raised, or
/// money actually moving against one.
///
/// The per-bill history dialog (loadPaymentHistory) shows this for a single
/// payment; this is the same material for every family at once, which is
/// what the Transaction History screen lists.
class MoneyEvent {
  /// 'request' (a bill was raised), or how money moved: 'payment',
  /// 'refund', 'reversal', 'waiver'.
  final String kind;
  final int paymentId;
  final DateTime? at;

  /// Signed the way the ledger signs it: refunds and reversals are negative.
  final double amount;
  final String? method;
  final String? note;

  /// The admin who recorded it. Null for a parent's own in-app payment and
  /// for bills the month close raised on its own.
  final String? recordedBy;
  final PaymentType type;
  final String title;

  /// What the bill looks like now — not what it was at the time.
  final String status;
  final int playerId;
  final String playerName;

  const MoneyEvent({
    required this.kind,
    required this.paymentId,
    required this.at,
    required this.amount,
    required this.method,
    required this.note,
    required this.recordedBy,
    required this.type,
    required this.title,
    required this.status,
    required this.playerId,
    required this.playerName,
  });

  /// A bill going out, rather than money coming in.
  bool get isRequest => kind == 'request';

  /// Money that actually changed hands, in either direction. A waiver is a
  /// bill being forgiven, so nothing moved.
  bool get movedMoney =>
      kind == 'payment' || kind == 'refund' || kind == 'reversal';
}

const _kindFromSql = {
  'request': 'request',
  'payment': 'payment',
  'refund': 'refund',
  'reversal': 'reversal',
  'waiver': 'waiver',
};

/// Everything, newest first. Admin-only: it spans every family.
final List<MoneyEvent> mockTransactions = [];

/// A month that has something in it, with that month's takings — enough to
/// offer a month to jump to without loading its transactions.
typedef TransactionMonth = ({DateTime month, int entries, double collected});

/// Newest month first.
final List<TransactionMonth> mockTransactionMonths = [];

Future<void> loadTransactionMonths() async {
  final rows = await ApiClient.getList('/transactions/months');
  mockTransactionMonths
    ..clear()
    ..addAll([
      for (final row in rows.cast<Map<String, dynamic>>())
        if (asDate(row['month']) case final month?)
          (
            month: month,
            entries: asInt(row['entries']),
            collected: asDouble(row['collected']),
          ),
    ]);
}

/// One month's worth, or everything when [month] is null. The screen always
/// asks for a month: the whole history would grow without limit, and nobody
/// reconciles across years at once.
Future<void> loadTransactions({DateTime? month}) async {
  final rows = await ApiClient.getList(
    month == null
        ? '/transactions'
        : '/transactions?month=${toSqlMonth(month)}',
  );
  mockTransactions
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        return MoneyEvent(
          kind: _kindFromSql['${map['kind']}'] ?? '${map['kind']}',
          paymentId: asInt(map['payment_id']),
          at: asDate(map['at']),
          amount: asDouble(map['amount']),
          method: map['method'] as String?,
          note: map['note'] as String?,
          recordedBy: map['recorded_by'] as String?,
          type: paymentTypeFromSql(map['payment_type']),
          title: '${map['title']}',
          status: '${map['status']}',
          playerId: asInt(map['player_id']),
          playerName: '${map['player_name']}',
        );
      }),
    );
}

/// Net money actually collected across [events] — payments in, refunds and
/// reversals back out. Waivers and unpaid requests aren't money.
double collectedFrom(Iterable<MoneyEvent> events) =>
    events.where((e) => e.movedMoney).fold(0.0, (sum, e) => sum + e.amount);
