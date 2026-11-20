import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart' show serverNow;
import '../../../core/widgets/month_picker_sheet.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_transactions.dart';
import '../models/payment_record.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Every payment request the club has raised and every movement of money
/// against one, a month at a time, newest first.
///
/// Payments answers "who owes what right now", player by player. This
/// answers "what happened", in order — the trail you follow when a parent
/// says they already paid, or when the month's takings don't look right.
/// Both read the same rows; nothing here is a separate tally that could
/// drift out of step with the bills themselves.
///
/// A month is the unit because that is how the club already works: fees are
/// billed monthly, and "what came in during September" is the question people
/// actually ask. It keeps the screen honest as the years pile up, too — only
/// the month on show is fetched.
class AdminTransactions extends StatefulWidget {
  const AdminTransactions({super.key});

  @override
  State<AdminTransactions> createState() => _AdminTransactionsState();
}

class _AdminTransactionsState extends State<AdminTransactions>
    with LiveRefreshing<AdminTransactions> {
  @override
  Future<void> reloadQuietly() async {
    await loadTransactionMonths();
    await loadTransactions(month: _month);
  }

  /// null = every kind at once. Same four choices as Payments, so the two
  /// screens filter the same way.
  PaymentType? _filter;

  /// The month on show, always the 1st of it. Null until the first load
  /// picks one.
  DateTime? _month;
  bool _loading = true;

  static const _filters = <(String, PaymentType?)>[
    ("All", null),
    ("Training", PaymentType.trainingFee),
    ("Tournament", PaymentType.tournament),
    ("Others", PaymentType.misc),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// The server's month, not the phone's — the same clock the fees bill on.
  DateTime get _thisMonth {
    final now = serverNow();
    return DateTime(now.year, now.month);
  }

  /// Nothing was recorded before the club's first entry, so there is nothing
  /// to page back to.
  DateTime get _earliest => mockTransactionMonths.isEmpty
      ? _thisMonth
      : mockTransactionMonths.last.month;

  bool get _canGoBack => _month != null && _month!.isAfter(_earliest);

  /// Money can't move in a month that hasn't happened yet, so forward stops
  /// at the current one.
  bool get _canGoForward => _month != null && _month!.isBefore(_thisMonth);

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadTransactionMonths();
      // Open on the most recent month that has anything in it: a club that
      // hasn't billed yet this month shouldn't land on an empty screen.
      _month ??= mockTransactionMonths.isEmpty
          ? _thisMonth
          : mockTransactionMonths.first.month;
      await loadTransactions(month: _month);
    } catch (e) {
      _showError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _showMonth(DateTime month) async {
    setState(() {
      _month = DateTime(month.year, month.month);
      _loading = true;
    });
    try {
      await loadTransactions(month: _month);
    } catch (e) {
      _showError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  void _step(int months) {
    final month = _month;
    if (month == null) return;
    _showMonth(DateTime(month.year, month.month + months));
  }

  /// Jumping straight to a month instead of stepping back one at a time.
  /// A year of months at once, each carrying its takings — which stays the
  /// same size whether the club is one season old or ten.
  Future<void> _pickMonth() async {
    final month = _month;
    if (month == null) return;
    final picked = await showMonthPicker(
      context,
      selected: month,
      earliest: _earliest,
      latest: _thisMonth,
      totals: {
        for (final entry in mockTransactionMonths) entry.month: entry.collected,
      },
    );
    if (picked != null) await _showMonth(picked);
  }

  String _monthLabel(DateTime month) =>
      "${monthNames[month.month - 1]} ${month.year}";

  List<MoneyEvent> get _visible => _filter == null
      ? mockTransactions
      : mockTransactions.where((e) => e.type == _filter).toList();

  /// Newest day first, and within a day newest first — the order the server
  /// already returns them in, just cut into date groups.
  Map<DateTime, List<MoneyEvent>> _byDay(List<MoneyEvent> events) {
    final map = <DateTime, List<MoneyEvent>>{};
    for (final event in events) {
      final at = event.at;
      if (at == null) continue;
      map.putIfAbsent(DateTime(at.year, at.month, at.day), () => []).add(event);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final events = _visible;
    final days = _byDay(events);
    final dayKeys = days.keys.toList()..sort((a, b) => b.compareTo(a));
    final collected = collectedFrom(events);
    final requests = events.where((e) => e.isRequest).length;
    final filterLabel = _filters
        .firstWhere((f) => f.$2 == _filter)
        .$1
        .toUpperCase();
    final month = _month;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "TRANSACTION HISTORY",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: _accent,
          backgroundColor: _card,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _canGoBack ? () => _step(-1) : null,
                      icon: const Icon(Icons.chevron_left),
                      color: Colors.white70,
                      disabledColor: Colors.white24,
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: _pickMonth,
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            children: [
                              Text(
                                month == null
                                    ? "—"
                                    : _monthLabel(month).toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "Tap to jump to another month",
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _canGoForward ? () => _step(1) : null,
                      icon: const Icon(Icons.chevron_right),
                      color: Colors.white70,
                      disabledColor: Colors.white24,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

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
                          ? "COLLECTED THIS MONTH"
                          : "COLLECTED · $filterLabel",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "AED ${collected.toStringAsFixed(2)}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // Money in, minus anything handed back or undone. The
                      // requests count is what was asked for, paid or not.
                      "$requests request${requests == 1 ? '' : 's'} · "
                      "${events.length} entr${events.length == 1 ? 'y' : 'ies'}",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
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

              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(
                    child: CircularProgressIndicator(color: _accent),
                  ),
                )
              else if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Center(
                    child: Text(
                      month == null
                          ? "Nothing has been billed or paid yet."
                          : _filter == null
                          ? "Nothing was billed or paid in "
                                "${_monthLabel(month)}."
                          : "No ${filterLabel.toLowerCase()} entries in "
                                "${_monthLabel(month)}.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 13,
                      ),
                    ),
                  ),
                )
              else
                for (final day in dayKeys) ...[
                  _DayHeader(day: day, events: days[day]!),
                  const SizedBox(height: 10),
                  for (final event in days[day]!)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _EventTile(event: event),
                    ),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The date, and what actually came in that day — so scrolling the list
/// answers "how much did we take on Saturday" without any adding up.
class _DayHeader extends StatelessWidget {
  final DateTime day;
  final List<MoneyEvent> events;

  const _DayHeader({required this.day, required this.events});

  @override
  Widget build(BuildContext context) {
    final collected = collectedFrom(events);
    return Row(
      children: [
        Expanded(
          child: Text(
            formatAdminDate(day).toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (collected != 0)
          Text(
            "${collected < 0 ? '−' : '+'}AED "
            "${collected.abs().toStringAsFixed(2)}",
            style: TextStyle(
              color: collected < 0 ? Colors.orangeAccent : _accent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    );
  }
}

/// How each kind of entry reads, and the colour that carries it: green for
/// money in, amber for a bill going out, orange for money handed back, grey
/// for the corrections that move no money at all.
///
/// Training credit moving on to the next fee is logged as a refund out of
/// one bill and a payment into the next (method 'credit'). Nothing left the
/// club and nothing new came in, so it gets its own grey look instead of
/// reading as money handed back and money received.
({String label, Color color, IconData icon}) _style(MoneyEvent event) =>
    switch (event.kind) {
      'refund' when event.method == 'credit' => (
        label: "CREDIT MOVED ON",
        color: Colors.white54,
        icon: Icons.swap_horiz,
      ),
      'payment' when event.method == 'credit' => (
        label: "PAID FROM CREDIT",
        color: Colors.white54,
        icon: Icons.swap_horiz,
      ),
      'payment' => (label: "PAYMENT", color: _accent, icon: Icons.south_west),
      'refund' => (
        label: "REFUND",
        color: Colors.orangeAccent,
        icon: Icons.north_east,
      ),
      'reversal' => (label: "UNDONE", color: Colors.white54, icon: Icons.undo),
      'waiver' => (label: "WAIVED", color: Colors.white54, icon: Icons.block),
      _ => (
        label: "REQUESTED",
        color: Colors.amber,
        icon: Icons.receipt_long_outlined,
      ),
    };

const _typeLabels = {
  PaymentType.trainingFee: "Training",
  PaymentType.tournament: "Tournament",
  PaymentType.misc: "Other",
};

class _EventTile extends StatelessWidget {
  final MoneyEvent event;

  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final style = _style(event);
    final at = event.at;
    final time = at == null
        ? null
        : "${at.hour % 12 == 0 ? 12 : at.hour % 12}:"
              "${at.minute.toString().padLeft(2, '0')} "
              "${at.hour >= 12 ? 'PM' : 'AM'}";
    // Everything that says who and how, on one line, skipping whatever
    // doesn't apply to this kind of entry.
    final meta = [
      ?time,
      _typeLabels[event.type] ?? "Other",
      if (event.method != null)
        paymentMethodLabels[event.method] ?? event.method!,
      if (event.recordedBy != null) "by ${event.recordedBy}",
      if (event.note != null) event.note!,
    ].join(" · ");

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(style.icon, color: style.color, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.playerName,
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
                  event.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                // A request is what was asked for; the rest is money moving,
                // so it carries the direction it moved in.
                event.isRequest
                    ? "AED ${event.amount.abs().toStringAsFixed(2)}"
                    : "${event.amount < 0 ? '−' : '+'}AED "
                          "${event.amount.abs().toStringAsFixed(2)}",
                style: TextStyle(
                  color: event.isRequest ? Colors.white : style.color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: style.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: style.color, width: 1),
                ),
                child: Text(
                  style.label,
                  style: TextStyle(
                    color: style.color,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
