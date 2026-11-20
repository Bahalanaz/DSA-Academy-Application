import 'package:flutter/material.dart';

import '../../../core/widgets/bill_description.dart';
import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/option_sheet.dart';
import '../../../core/services/live_refresh.dart';
import '../models/admin_player.dart';
import '../models/mock_roster.dart';
import '../models/mock_tournaments.dart';
import '../models/payment_record.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// The consolidated pending-payments hub — pulls from [payment_record.dart]
/// (the shared source of truth every payment screen writes to), so a
/// player showing "up to date" here can never disagree with what Training
/// Fees, Tournaments, or Misc Payments individually think they owe.
class AdminPayments extends StatefulWidget {
  const AdminPayments({super.key});

  @override
  State<AdminPayments> createState() => _AdminPaymentsState();
}

class _AdminPaymentsState extends State<AdminPayments>
    with LiveRefreshing<AdminPayments> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadFeeSettings();
    await loadPayments();
    await loadTrainingFeeOverrides();
  }

  /// null = every kind at once.
  PaymentType? _filter;

  static const _filters = <(String, PaymentType?)>[
    ("All", null),
    ("Training", PaymentType.trainingFee),
    ("Tournament", PaymentType.tournament),
    ("Others", PaymentType.misc),
  ];

  /// What a player owes under the current filter — the whole balance when
  /// showing everything, otherwise just that one kind.
  double _owedBy(AdminPlayer player) => _filter == null
      ? totalPendingFor(player)
      : pendingForType(player, _filter!);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await loadPlayers();
      await loadFeeSettings();
      await closeDueTrainingFees();
      await loadPayments();
      await loadTrainingFeeOverrides();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _openPlayer(AdminPlayer player) async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) =>
          _PlayerPaymentsDialog(player: player, filter: _filter),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pending = mockRoster.where((p) => _owedBy(p) > 0).toList();
    final paid = mockRoster.where((p) => _owedBy(p) <= 0).toList();
    final total = mockRoster.fold(0.0, (sum, p) => sum + _owedBy(p));
    final filterLabel = _filters
        .firstWhere((f) => f.$2 == _filter)
        .$1
        .toUpperCase();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "PAYMENTS",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_accent, Colors.green.shade800],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _filter == null
                        ? "PENDING PAYMENTS"
                        : "PENDING · $filterLabel",
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "AED ${total.toStringAsFixed(2)}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "${pending.length} of ${mockRoster.length} players",
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final (label, type) = _filters[index];
                  final isSelected = _filter == type;
                  return ChoiceChip(
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (_) => setState(() => _filter = type),
                    backgroundColor: _card,
                    selectedColor: _accent,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    side: BorderSide(
                      color: isSelected ? _accent : Colors.white24,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 20),

            if (pending.isNotEmpty) ...[
              const _SectionTitle("PENDING"),
              const SizedBox(height: 10),
              ...pending.map(
                (p) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PaymentTile(
                    player: p,
                    amount: _owedBy(p),
                    isPending: true,
                    onTap: () => _openPlayer(p),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            if (paid.isNotEmpty) ...[
              _SectionTitle(
                _filter == null ? "UP TO DATE" : "NOTHING UNDER $filterLabel",
              ),
              const SizedBox(height: 10),
              ...paid.map(
                (p) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PaymentTile(
                    player: p,
                    amount: 0,
                    isPending: false,
                    onTap: () => _openPlayer(p),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final AdminPlayer player;
  final double amount;
  final bool isPending;
  final VoidCallback onTap;

  const _PaymentTile({
    required this.player,
    required this.amount,
    required this.isPending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              ProfilePhoto(url: player.photoUrl, radius: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      player.categories.join(", "),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (isPending)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber),
                  ),
                  child: Text(
                    "AED ${amount.toStringAsFixed(2)}",
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else
                const Icon(Icons.check_circle, color: _accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerPaymentsDialog extends StatefulWidget {
  final AdminPlayer player;

  /// Which kind of fee to show — null shows everything. Matches whatever
  /// filter chip was selected on the list this dialog was opened from.
  final PaymentType? filter;

  const _PlayerPaymentsDialog({required this.player, this.filter});

  @override
  State<_PlayerPaymentsDialog> createState() => _PlayerPaymentsDialogState();
}

class _PlayerPaymentsDialogState extends State<_PlayerPaymentsDialog>
    with LiveRefreshing<_PlayerPaymentsDialog> {
  @override
  Future<void> reloadQuietly() async {
    await loadPayments();
    await loadTrainingFeeOverrides();
  }

  bool _busy = false;

  /// Settled bills stay folded away. A family a season in has a dozen of
  /// them, and they pushed what's actually owed off the top of the dialog.
  bool _showClosed = false;

  static const _methodOptions = {
    'Cash': 'cash',
    'Bank transfer': 'bank',
    'Card': 'card',
  };

  String _filterLabel(PaymentType type) => switch (type) {
    PaymentType.trainingFee => "Training only",
    PaymentType.tournament => "Tournament only",
    PaymentType.misc => "Others only",
  };

  String _methodWords(String method) =>
      (paymentMethodLabels[method] ?? method).toLowerCase();

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs one money action with a guard against double taps, then rebuilds
  /// from the reloaded payments.
  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (done != null) _showMessage(done);
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _pickMethod(String title) async {
    final picked = await showOptionSheet(
      context,
      title: title,
      options: _methodOptions.keys.toList(),
    );
    return picked == null ? null : _methodOptions[picked];
  }

  Future<void> _markTrainingFeePaid(double owed) async {
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Mark this fee as paid?",
      message:
          "This records AED ${owed.toStringAsFixed(2)} for "
          "${widget.player.name}'s training fee this month, paid by "
          "${_methodWords(method)}.",
      confirmLabel: "YES, MARK PAID",
    );
    if (!confirmed) return;
    await _run(
      () => markTrainingFeePaid(widget.player, kCurrentMonth, method: method),
    );
  }

  Future<void> _markRecordPaid(PaymentRecord record) async {
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Mark this as paid?",
      message:
          "This records the AED ${record.remaining.toStringAsFixed(2)} left "
          "on \"${record.title}\" as paid by ${_methodWords(method)}.",
      confirmLabel: "YES, MARK PAID",
    );
    if (!confirmed) return;
    await _run(() => markPaymentPaid(record, method: method));
  }

  Future<void> _openActions(PaymentRecord record) async {
    const part = "Partial payment";
    const waive = "Waive what's left";
    const refund = "Refund";
    const undo = "Undo payment";
    const history = "Payment history";
    final picked = await showOptionSheet(
      context,
      title: record.title.toUpperCase(),
      options: [
        if (record.isOpen) part,
        if (record.isOpen) waive,
        // Training fees are refunded from Training Fees, and only for what
        // was overpaid — refunding a fee still owed would just re-bill it.
        if (record.amountPaid > 0 && record.type != PaymentType.trainingFee)
          refund,
        if (record.amountPaid > 0) undo,
        history,
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case part:
        await _recordPartPayment(record);
      case waive:
        await _waive(record);
      case refund:
        await _refund(record);
      case undo:
        await _undo(record);
      default:
        await showDialog(
          context: context,
          barrierColor: Colors.black54,
          builder: (_) => _HistoryDialog(record: record),
        );
    }
  }

  String get _monthName => monthNames[kCurrentMonth.month - 1];

  Future<double?> _askAmount({
    required String title,
    required String hint,
    required double initial,
    required double max,
    required String overMax,
  }) => showDialog<double>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _AmountDialog(
      title: title,
      hint: hint,
      initial: initial,
      max: max,
      overMax: overMax,
    ),
  );

  /// Some of a bill paid by hand. What's left stays owed on the same bill,
  /// which shows "AED x of y paid" and can still be waived later.
  Future<void> _recordPartPayment(PaymentRecord record) async {
    final owed = record.remaining;
    final amount = await _askAmount(
      title: "Partial payment on \"${record.title}\"",
      hint: "AED ${owed.toStringAsFixed(2)} is still owed on this",
      initial: owed,
      max: owed,
      overMax: "That's more than the AED ${owed.toStringAsFixed(2)} owed",
    );
    if (amount == null || !mounted) return;
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final left = owed - amount;
    final confirmed = await showConfirmDialog(
      context,
      title: "Record AED ${amount.toStringAsFixed(2)}?",
      message:
          "AED ${amount.toStringAsFixed(2)} paid by ${_methodWords(method)} "
          "towards \"${record.title}\".${left > 0.004 ? " AED ${left.toStringAsFixed(2)} will still be owed." : ""}",
      confirmLabel: "RECORD",
    );
    if (!confirmed) return;
    await _run(() async {
      await payTowards(record, amount, method: method);
      await loadPayments();
    }, done: "Recorded AED ${amount.toStringAsFixed(2)}.");
  }

  /// This month's training fee has no bill yet (it's still running), so it
  /// gets its own menu: part payment, advance, waive.
  Future<void> _openTrainingFeeActions(double owed) async {
    const part = "Partial payment";
    const advance = "Record advance payment";
    const waive = "Waive what's left";
    final picked = await showOptionSheet(
      context,
      title: "TRAINING FEE · ${_monthName.toUpperCase()}",
      options: [part, advance, waive],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case part:
        await _trainingFeePart(owed);
      case advance:
        await _trainingFeeAdvance(owed);
      default:
        await _waiveTrainingFee(owed);
    }
  }

  Future<void> _trainingFeePart(double owed) async {
    final amount = await _askAmount(
      title: "Partial payment · $_monthName training",
      hint: "AED ${owed.toStringAsFixed(2)} is owed so far this month",
      initial: owed,
      max: owed,
      overMax:
          "That's more than the AED ${owed.toStringAsFixed(2)} owed. To pay "
          "ahead, record an advance payment instead.",
    );
    if (amount == null || !mounted) return;
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Record AED ${amount.toStringAsFixed(2)}?",
      message:
          "AED ${amount.toStringAsFixed(2)} paid by ${_methodWords(method)} "
          "towards ${widget.player.name}'s $_monthName training fee.",
      confirmLabel: "RECORD",
    );
    if (!confirmed) return;
    await _run(
      () => markTrainingFeePaid(
        widget.player,
        kCurrentMonth,
        amount: amount,
        method: method,
      ),
      done: "Recorded AED ${amount.toStringAsFixed(2)}.",
    );
  }

  /// Money handed over ahead of time. Whatever's beyond this month's fee is
  /// kept as credit and goes towards the next training fee by itself at the
  /// month close — or can be refunded from here until then.
  Future<void> _trainingFeeAdvance(double owed) async {
    final amount = await _askAmount(
      title: "Advance payment · training",
      hint: owed > 0
          ? "AED ${owed.toStringAsFixed(2)} goes to $_monthName; anything "
                "more is credit for the next training fee"
          : "Kept as credit for the next training fee",
      initial: owed > 0 ? owed : 0,
      max: 99999999.99,
      overMax: "That amount is too large",
    );
    if (amount == null || !mounted) return;
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final credit = amount - owed;
    final confirmed = await showConfirmDialog(
      context,
      title: "Record AED ${amount.toStringAsFixed(2)} in advance?",
      message:
          "Paid by ${_methodWords(method)}."
          "${owed > 0 ? " AED ${(credit > 0 ? owed : amount).toStringAsFixed(2)} settles $_monthName." : ""}"
          "${credit > 0.004 ? " AED ${credit.toStringAsFixed(2)} is kept as credit and goes towards the next training fee automatically. It can be refunded until then." : ""}",
      confirmLabel: "RECORD",
    );
    if (!confirmed) return;
    await _run(
      () => markTrainingFeePaid(
        widget.player,
        kCurrentMonth,
        amount: amount,
        method: method,
        advance: true,
      ),
      done: "Recorded AED ${amount.toStringAsFixed(2)}.",
    );
  }

  Future<void> _waiveTrainingFee(double owed) async {
    final paid = trainingFeePaidFor(widget.player, kCurrentMonth);
    final confirmed = await showConfirmDialog(
      context,
      title: "Waive $_monthName's training fee?",
      message:
          "${widget.player.name} will no longer owe the AED "
          "${owed.toStringAsFixed(2)} left for $_monthName."
          "${paid > 0 ? " The AED ${paid.toStringAsFixed(2)} already paid stays on record." : ""}"
          " Sessions later this month won't be charged either.",
      confirmLabel: "WAIVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(
      () => waiveTrainingFee(widget.player, kCurrentMonth),
      done: "Waived.",
    );
  }

  Future<void> _refundCredit(double credit) async {
    final amount = await _askAmount(
      title: "Refund training credit",
      hint: "AED ${credit.toStringAsFixed(2)} is held as credit",
      initial: credit,
      max: credit,
      overMax: "Only AED ${credit.toStringAsFixed(2)} is held as credit",
    );
    if (amount == null || !mounted) return;
    final method = await _pickMethod("HOW IS IT BEING REFUNDED?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Refund AED ${amount.toStringAsFixed(2)}?",
      message:
          "This hands AED ${amount.toStringAsFixed(2)} of "
          "${widget.player.name}'s training credit back by "
          "${_methodWords(method)}, instead of using it for the next "
          "training fee.",
      confirmLabel: "REFUND",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(
      () => refundTrainingFeeOverpayment(
        widget.player,
        kCurrentMonth,
        amount: amount,
        method: method,
      ),
      done: "Refunded AED ${amount.toStringAsFixed(2)}.",
    );
  }

  Future<void> _waive(PaymentRecord record) async {
    final kept = record.amountPaid > 0
        ? " The AED ${record.amountPaid.toStringAsFixed(2)} already paid "
              "stays on record."
        : "";
    final confirmed = await showConfirmDialog(
      context,
      title: "Waive this?",
      message:
          "${widget.player.name} will no longer owe the AED "
          "${record.remaining.toStringAsFixed(2)} left on "
          "\"${record.title}\".$kept",
      confirmLabel: "WAIVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(() => waivePayment(record), done: "Waived.");
  }

  Future<void> _refund(PaymentRecord record) async {
    final amount = await showDialog<double>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _AmountDialog(
        title: "Refund \"${record.title}\"",
        hint: "AED ${record.amountPaid.toStringAsFixed(2)} was paid on this",
        initial: record.amountPaid,
        max: record.amountPaid,
      ),
    );
    if (amount == null || !mounted) return;
    final method = await _pickMethod("HOW IS IT BEING REFUNDED?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Refund AED ${amount.toStringAsFixed(2)}?",
      message:
          "This hands AED ${amount.toStringAsFixed(2)} back to "
          "${widget.player.name} by ${_methodWords(method)} and lowers the "
          "bill by the same amount, so nothing new becomes owed.",
      confirmLabel: "REFUND",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(
      () => refundPayment(record, amount: amount, method: method),
      done: "Refunded AED ${amount.toStringAsFixed(2)}.",
    );
  }

  Future<void> _undo(PaymentRecord record) async {
    var after = record.type == PaymentType.trainingFee
        ? "The month's fee will be worked out again."
        : "The bill goes back to being owed.";
    // A child since taken off the tournament, or one since deleted, owes
    // nothing for it: the server voids the bill instead of reopening it.
    final tournamentId = record.tournamentId;
    if (record.type == PaymentType.tournament && tournamentId != null) {
      try {
        await loadTournaments();
      } catch (_) {
        // Offline: keep the usual wording; the server still decides.
      }
      if (!mounted) return;
      final stillOn = mockTournaments.any(
        (t) => t.id == '$tournamentId' && t.playerIds.contains(record.playerId),
      );
      if (!stillOn) {
        after =
            "Nothing will be owed: ${widget.player.name} is no longer on "
            "this tournament.";
      }
    }
    final confirmed = await showConfirmDialog(
      context,
      title: "Undo this payment?",
      message:
          "Only use this if the AED ${record.amountPaid.toStringAsFixed(2)} "
          "was recorded by mistake and never actually received. $after "
          "If the money really was paid, refund it instead.",
      confirmLabel: "UNDO",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(() => markPaymentUnpaid(record), done: "Payment undone.");
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final filter = widget.filter;
    bool matchesFilter(PaymentRecord r) => filter == null || r.type == filter;

    final showTrainingFee = filter == null || filter == PaymentType.trainingFee;
    final trainingFeeOwedNow = showTrainingFee
        ? unpaidTrainingFee(player, kCurrentMonth)
        : 0.0;
    final open = unpaidRecordsFor(player).where(matchesFilter).toList();
    final closed =
        mockPayments
            .where(
              (r) =>
                  r.playerId == player.id &&
                  matchesFilter(r) &&
                  (r.paid || r.status == 'waived' || r.status == 'refunded'),
            )
            .toList()
          ..sort((a, b) => b.createdDate.compareTo(a.createdDate));
    final hasAnyPending = trainingFeeOwedNow > 0 || open.isNotEmpty;
    final paidThisMonth = showTrainingFee
        ? trainingFeePaidFor(player, kCurrentMonth)
        : 0.0;
    final credit = showTrainingFee ? trainingFeeCredit(player) : 0.0;

    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfilePhoto(url: player.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (filter != null)
                        Text(
                          _filterLabel(filter),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: _accent,
                      strokeWidth: 2,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            if (!hasAnyPending)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _accent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: _accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        filter == null
                            ? "All settled — nothing pending."
                            : "Nothing pending under ${_filterLabel(filter).replaceFirst(' only', '')}.",
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              if (trainingFeeOwedNow > 0)
                _PendingRow(
                  title: "Training Fee (this month)",
                  amount: trainingFeeOwedNow,
                  subtitle: paidThisMonth > 0
                      ? "AED ${paidThisMonth.toStringAsFixed(2)} of "
                            "${(paidThisMonth + trainingFeeOwedNow).toStringAsFixed(2)} paid"
                      : null,
                  enabled: !_busy,
                  onMarkPaid: () => _markTrainingFeePaid(trainingFeeOwedNow),
                  onMore: () => _openTrainingFeeActions(trainingFeeOwedNow),
                ),
              for (final record in open)
                _PendingRow(
                  title: record.title,
                  description: record.description,
                  amount: record.remaining,
                  subtitle: record.partlyPaid
                      ? "AED ${record.amountPaid.toStringAsFixed(2)} of "
                            "${record.amount.toStringAsFixed(2)} paid"
                      : null,
                  enabled: !_busy,
                  onMarkPaid: () => _markRecordPaid(record),
                  onMore: () => _openActions(record),
                ),
            ],
            if (credit > 0)
              _CreditRow(
                amount: credit,
                enabled: !_busy,
                onRefund: () => _refundCredit(credit),
              ),
            // With nothing owed this month the row above isn't there, so
            // an advance needs its own way in.
            if (showTrainingFee && trainingFeeOwedNow <= 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _trainingFeeAdvance(0),
                  icon: const Icon(Icons.add, color: _accent, size: 18),
                  label: const Text(
                    "RECORD ADVANCE PAYMENT",
                    style: TextStyle(
                      color: _accent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (closed.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _showClosed = !_showClosed),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      _SectionTitle("PAID & CLOSED (${closed.length})"),
                      const Spacer(),
                      Icon(
                        _showClosed ? Icons.expand_less : Icons.expand_more,
                        color: Colors.white54,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showClosed) ...[
                const SizedBox(height: 10),
                for (final record in closed)
                  _ClosedRow(
                    record: record,
                    enabled: !_busy,
                    onMore: () => _openActions(record),
                  ),
              ],
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accent, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  "CLOSE",
                  style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  final String title;

  /// What an "Others" (or uniform / merch) bill was for, as typed when it
  /// was sent. Null when none was given.
  final String? description;
  final double amount;
  final String? subtitle;
  final bool enabled;
  final VoidCallback onMarkPaid;

  /// Part payment / waive / undo / history — or, for this month's running
  /// training fee, part payment / advance / waive.
  final VoidCallback? onMore;

  const _PendingRow({
    required this.title,
    this.description,
    required this.amount,
    this.subtitle,
    this.enabled = true,
    required this.onMarkPaid,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                BillDescription(description, maxLines: null),
                const SizedBox(height: 3),
                Text(
                  "AED ${amount.toStringAsFixed(2)}",
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: enabled ? onMarkPaid : null,
            child: const Text(
              "MARK PAID",
              style: TextStyle(
                color: _accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (onMore != null)
            IconButton(
              onPressed: enabled ? onMore : null,
              icon: const Icon(Icons.more_vert, color: Colors.white54),
              tooltip: "More",
            ),
        ],
      ),
    );
  }
}

/// Training money held beyond what this month comes to: an advance, or
/// credit carried from an earlier month. Used for the next training fee at
/// the month close unless refunded first.
class _CreditRow extends StatelessWidget {
  final double amount;
  final bool enabled;
  final VoidCallback onRefund;

  const _CreditRow({
    required this.amount,
    required this.enabled,
    required this.onRefund,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.savings_outlined, color: _accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Training credit",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "AED ${amount.toStringAsFixed(2)}",
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  "Goes towards the next training fee automatically",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: enabled ? onRefund : null,
            child: const Text(
              "REFUND",
              style: TextStyle(
                color: Colors.redAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosedRow extends StatelessWidget {
  final PaymentRecord record;
  final bool enabled;
  final VoidCallback onMore;

  const _ClosedRow({
    required this.record,
    this.enabled = true,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (record.status) {
      'waived' => ("WAIVED", Colors.white54),
      'refunded' => ("REFUNDED", Colors.white54),
      _ => ("PAID", _accent),
    };
    final how = record.method == null
        ? ""
        : " · ${paymentMethodLabels[record.method] ?? record.method}";
    final when = record.paidDate == null
        ? ""
        : " · ${formatAdminDate(record.paidDate!)}";

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                BillDescription(record.description, maxLines: null),
                const SizedBox(height: 3),
                Text(
                  "AED ${record.amountPaid.toStringAsFixed(2)} paid$how$when",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            onPressed: enabled ? onMore : null,
            icon: const Icon(Icons.more_vert, color: Colors.white54),
            tooltip: "More",
          ),
        ],
      ),
    );
  }
}

/// Asks for an amount between zero and [max].
class _AmountDialog extends StatefulWidget {
  final String title;
  final String hint;
  final double initial;
  final double max;

  /// Said when the amount is above [max].
  final String? overMax;

  const _AmountDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.max,
    this.overMax,
  });

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _controller = TextEditingController(
    text: widget.initial.toStringAsFixed(2),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = double.tryParse(_controller.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Enter an amount")));
      return;
    }
    if (amount > widget.max + 0.004) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.overMax ??
                "That's more than the AED ${widget.max.toStringAsFixed(2)} paid",
          ),
        ),
      );
      return;
    }
    Navigator.pop(context, amount);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.hint,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                prefixText: "AED ",
                prefixStyle: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
                isDense: true,
                filled: true,
                fillColor: _bg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "CANCEL",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "NEXT",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Every money movement on one bill, from the server's transaction log.
class _HistoryDialog extends StatelessWidget {
  final PaymentRecord record;

  const _HistoryDialog({required this.record});

  static const _kindLabels = {
    'payment': 'Payment',
    'refund': 'Refund',
    'reversal': 'Undone',
    'waiver': 'Waived',
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              record.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Charged AED ${record.amount.toStringAsFixed(2)} · paid "
              "AED ${record.amountPaid.toStringAsFixed(2)}",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            FutureBuilder<List<PaymentHistoryEntry>>(
              future: loadPaymentHistory(record),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(
                      child: CircularProgressIndicator(color: _accent),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Text(
                    friendlyError(snapshot.error!),
                    style: const TextStyle(color: Colors.redAccent),
                  );
                }
                final entries = snapshot.data ?? const [];
                if (entries.isEmpty) {
                  return Text(
                    "No money has moved on this bill yet.",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final entry in entries)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    // A credit move isn't a refund or a new
                                    // payment: say what it actually was.
                                    entry.method == 'credit'
                                        ? (entry.kind == 'refund'
                                              ? "Credit moved to the next fee"
                                              : "Paid from training credit")
                                        : [
                                            _kindLabels[entry.kind] ??
                                                entry.kind,
                                            if (entry.method != null)
                                              paymentMethodLabels[entry
                                                      .method] ??
                                                  entry.method!,
                                          ].join(" · "),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (entry.at != null)
                                        formatAdminDate(entry.at!),
                                      if (entry.recordedBy != null)
                                        "by ${entry.recordedBy}",
                                      if (entry.note != null) entry.note!,
                                    ].join(" · "),
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "${entry.amount >= 0 ? '' : '−'}AED "
                              "${entry.amount.abs().toStringAsFixed(2)}",
                              style: TextStyle(
                                color: entry.kind == 'payment'
                                    ? _accent
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accent, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  "CLOSE",
                  style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
