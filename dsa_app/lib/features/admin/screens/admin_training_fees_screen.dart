import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/category_filter_button.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/widgets/option_sheet.dart';
import '../../../core/services/live_refresh.dart';
import '../models/admin_player.dart';
import '../models/mock_categories.dart';
import '../models/mock_roster.dart';
import '../models/payment_record.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// The monthly training-fee ledger view: coaches' fee (fixed) + per-
/// session charge (present/absent both billable, exempt nets to zero) —
/// see [trainingFeeOwed]. Draws on the same attendance data the roster
/// stats dialog uses, so this and that dialog always agree.
class AdminTrainingFees extends StatefulWidget {
  const AdminTrainingFees({super.key});

  @override
  State<AdminTrainingFees> createState() => _AdminTrainingFeesState();
}

class _AdminTrainingFeesState extends State<AdminTrainingFees>
    with LiveRefreshing<AdminTrainingFees> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadFeeSettings();
    await loadPayments();
    await loadTrainingFeeOverrides();
    await loadMonthAttendance(_selectedMonth);
  }

  static const _monthNames = [
    "JANUARY",
    "FEBRUARY",
    "MARCH",
    "APRIL",
    "MAY",
    "JUNE",
    "JULY",
    "AUGUST",
    "SEPTEMBER",
    "OCTOBER",
    "NOVEMBER",
    "DECEMBER",
  ];

  String _categoryFilter = "All";
  String _query = "";
  late DateTime _selectedMonth = kCurrentMonth;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Everything a fee is made of comes from the server: the attendance
  /// counts on each player, the two rates, the settled payments, and any
  /// per-player override.
  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadPlayers();
      await loadFeeSettings();
      await closeDueTrainingFees();
      await loadPayments();
      await loadTrainingFeeOverrides();
      await loadMonthAttendance(_selectedMonth);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Each month has its own attendance, and that's what the fee is built
  /// from — so changing month has to fetch it, not just relabel the header.
  Future<void> _showMonth(DateTime month) async {
    setState(() {
      _selectedMonth = month;
      _loading = true;
    });
    try {
      await loadMonthAttendance(month);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _goToPreviousMonth() {
    _showMonth(DateTime(_selectedMonth.year, _selectedMonth.month - 1));
  }

  void _goToNextMonth() {
    _showMonth(DateTime(_selectedMonth.year, _selectedMonth.month + 1));
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _accent,
              onPrimary: Colors.white,
              surface: _card,
              onSurface: Colors.white,
            ),
            dialogTheme: const DialogThemeData(backgroundColor: _bg),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      await _showMonth(DateTime(picked.year, picked.month));
    }
  }

  List<AdminPlayer> get _filtered {
    return mockRoster.where((p) {
      final matchesCategory =
          _categoryFilter == "All" || p.categories.contains(_categoryFilter);
      final matchesQuery = p.matchesSearch(_query);
      return matchesCategory && matchesQuery;
    }).toList();
  }

  void _openFeeSettings() async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => const _FeeSettingsDialog(),
    );
    setState(() {});
  }

  void _openPlayer(AdminPlayer player) async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) =>
          _FeeBreakdownDialog(player: player, month: _selectedMonth),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final players = _filtered;
    final monthLabel =
        "${_monthNames[_selectedMonth.month - 1]} ${_selectedMonth.year}";

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "TRAINING FEES",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _openFeeSettings,
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _goToPreviousMonth,
                    icon: const Icon(Icons.chevron_left, color: Colors.white54),
                  ),
                  Text(
                    monthLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _pickMonth,
                    icon: const Icon(
                      Icons.calendar_today_outlined,
                      color: Colors.white54,
                      size: 17,
                    ),
                  ),
                  IconButton(
                    onPressed: _goToNextMonth,
                    icon: const Icon(
                      Icons.chevron_right,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Search players...",
                  hintStyle: const TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Colors.white38,
                    size: 20,
                  ),
                  filled: true,
                  fillColor: _card,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: CategoryFilterButton(
                  categories: mockCategories,
                  selected: _categoryFilter,
                  onChanged: (category) =>
                      setState(() => _categoryFilter = category),
                ),
              ),
            ),

            const SizedBox(height: 10),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : players.isEmpty
                  ? const Center(
                      child: Text(
                        "No players match.",
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: players.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final player = players[index];
                        final owed = unpaidTrainingFee(player, _selectedMonth);
                        // A month that hasn't started has nothing owed yet,
                        // so show what it's shaping up to be instead.
                        final upcoming = isFutureMonth(_selectedMonth);
                        final estimate = upcoming
                            ? (trainingFeeOverride(player, _selectedMonth) ??
                                  trainingFeeOwed(
                                    monthlyAttendanceCounts(
                                      player,
                                      _selectedMonth,
                                    ),
                                  ))
                            : 0.0;
                        final notTraining =
                            !upcoming &&
                            owed <= 0 &&
                            monthlyAttendanceCounts(
                                  player,
                                  _selectedMonth,
                                ).scheduled ==
                                0 &&
                            trainingFeePaidFor(player, _selectedMonth) <= 0;
                        return FadeSlideIn(
                          index: index,
                          child: _FeeTile(
                            player: player,
                            owed: owed,
                            upcoming: upcoming,
                            estimate: estimate,
                            notTraining: notTraining,
                            onTap: () => _openPlayer(player),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeeTile extends StatelessWidget {
  final AdminPlayer player;
  final double owed;

  /// The month shown hasn't started: no check marks (nothing has been
  /// paid), just the estimated fee in grey, or a dash if not training.
  final bool upcoming;
  final double estimate;

  /// Not on a single session that month and nothing paid for it.
  final bool notTraining;
  final VoidCallback onTap;

  const _FeeTile({
    required this.player,
    required this.owed,
    this.upcoming = false,
    this.estimate = 0,
    this.notTraining = false,
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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
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
              // No chevron — the whole tile is the tap target. Plain Text for
              // the amount: the name column is Expanded and absorbs any squeeze.
              upcoming
                  ? Text(
                      estimate > 0 ? "AED ${estimate.toStringAsFixed(2)}" : "—",
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  // A dash, not a check mark: someone who wasn't training
                  // that month owes nothing, but hasn't "paid" either.
                  : notTraining
                  ? const Text(
                      "—",
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : owed <= 0
                  ? const Icon(Icons.check_circle, color: _accent, size: 20)
                  : Text(
                      "AED ${owed.toStringAsFixed(2)}",
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeeBreakdownDialog extends StatefulWidget {
  final AdminPlayer player;
  final DateTime month;

  const _FeeBreakdownDialog({required this.player, required this.month});

  @override
  State<_FeeBreakdownDialog> createState() => _FeeBreakdownDialogState();
}

class _FeeBreakdownDialogState extends State<_FeeBreakdownDialog> {
  bool _editingTotal = false;
  late final TextEditingController _totalController;

  @override
  void initState() {
    super.initState();
    _totalController = TextEditingController();
  }

  @override
  void dispose() {
    _totalController.dispose();
    super.dispose();
  }

  /// "this month" only for the real current month — a past or future
  /// selection shows its actual name instead, since "this month" would be
  /// wrong once the calendar has moved on.
  String _monthLabel(DateTime month) {
    final current = kCurrentMonth;
    if (month.year == current.year && month.month == current.month) {
      return "this month";
    }
    final last = DateTime(current.year, current.month - 1);
    if (month.year == last.year && month.month == last.month) {
      return "last month";
    }
    return "${monthNames[month.month - 1]} ${month.year}";
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  static const _methodOptions = {
    'Cash': 'cash',
    'Bank transfer': 'bank',
    'Card': 'card',
  };

  Future<String?> _pickMethod(String title) async {
    final picked = await showOptionSheet(
      context,
      title: title,
      options: _methodOptions.keys.toList(),
    );
    return picked == null ? null : _methodOptions[picked];
  }

  String _methodWords(String method) =>
      (paymentMethodLabels[method] ?? method).toLowerCase();

  Future<void> _markPaid() async {
    final method = await _pickMethod("HOW WAS IT PAID?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Mark this fee as paid?",
      message:
          "This records ${widget.player.name}'s training fee for "
          "${_monthLabel(widget.month)} as paid by ${_methodWords(method)}.",
      confirmLabel: "YES, MARK PAID",
    );
    if (!confirmed) return;
    try {
      await markTrainingFeePaid(widget.player, widget.month, method: method);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  /// Hands back what was paid over the month's total — after attendance
  /// was corrected downwards, say. Only the overpaid part can be refunded.
  Future<void> _refundOverpaid(double overpaid) async {
    final method = await _pickMethod("HOW IS IT BEING REFUNDED?");
    if (method == null || !mounted) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Refund AED ${overpaid.toStringAsFixed(2)}?",
      message:
          "${widget.player.name} paid AED ${overpaid.toStringAsFixed(2)} more "
          "than their fee for ${_monthLabel(widget.month)} came to. This "
          "records it as refunded by ${_methodWords(method)}.",
      confirmLabel: "REFUND",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    try {
      await refundTrainingFeeOverpayment(
        widget.player,
        widget.month,
        amount: overpaid,
        method: method,
      );
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  /// A custom total for a month the player wasn't on a single session could
  /// be saved, but is never charged — so saving it only looked like it
  /// worked.
  void _explainNotTraining() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "${widget.player.name} isn't on any session ${_monthLabel(widget.month)}, "
          "so nothing is charged and there's no total to change.",
        ),
      ),
    );
  }

  void _startEditingTotal(double currentTotal) {
    _totalController.text = currentTotal.toStringAsFixed(2);
    setState(() => _editingTotal = true);
  }

  Future<void> _applyCustomTotal() async {
    final amount = double.tryParse(_totalController.text.trim());
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Enter a valid amount")));
      return;
    }
    try {
      await setTrainingFeeOverride(widget.player, widget.month, amount);
      if (mounted) setState(() => _editingTotal = false);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _resetToCalculated() async {
    try {
      await clearTrainingFeeOverride(widget.player, widget.month);
      if (mounted) setState(() => _editingTotal = false);
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final month = widget.month;
    final counts = monthlyAttendanceCounts(player, month);
    // Both totals come from the server, priced per session against the
    // rate history — NOT sessions x today's rate, which would misprice a
    // month that had a price change in the middle of it.
    final sessionCount = billableSessions(counts);
    final sessionsCost = counts.charges;
    final calculatedTotal = trainingFeeOwed(counts);
    final override = trainingFeeOverride(player, month);
    final total = override ?? calculatedTotal;
    // Grouped by the month a payment COVERS (periodMonth), not the day it
    // was made — September's fee settled on October 1 belongs to September.
    // amountPaid, so a part-payment counts for what was actually handed over.
    final paidThisMonth = trainingFeePaidFor(player, month);
    final remaining = unpaidTrainingFee(player, month);
    final overpaid = trainingFeeOverpaid(player, month);
    final upcoming = isFutureMonth(month);
    final billsOn = DateTime(month.year, month.month + 1);

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
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ProfilePhoto(url: player.photoUrl, radius: 22),
                    Positioned(
                      bottom: -2,
                      right: -2,
                      child: GestureDetector(
                        onTap: counts.scheduled <= 0
                            ? _explainNotTraining
                            : () => _editingTotal
                                  ? _applyCustomTotal()
                                  : _startEditingTotal(total),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: _card, width: 2),
                          ),
                          child: Icon(
                            _editingTotal ? Icons.check : Icons.edit,
                            color: Colors.white,
                            size: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    player.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              "BREAKDOWN",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 10),
            // This month's rates, not today's — they differ once the admin
            // has changed a rate, and what this month was charged is the
            // honest thing to show.
            // Reduced in the month a player joined, by the days left from
            // their first session — say so, or 43.33 looks like a typo.
            _BreakdownRow(
              label: isCoachFeeProrated(counts)
                  ? "Coaches' fee (joined mid-month, of "
                        "${counts.coachFeeFull.toStringAsFixed(2)})"
                  : "Coaches' fee",
              value: "AED ${counts.coachFee.toStringAsFixed(2)}",
            ),
            // No "x AED rate" here: the sessions in a month aren't
            // necessarily all at one rate, so the total is the only figure
            // that's always true.
            _BreakdownRow(
              label: "Sessions ($sessionCount)",
              value: "AED ${sessionsCost.toStringAsFixed(2)}",
            ),
            _BreakdownRow(
              label: "Exempt (${counts.exempt}) — no charge",
              value: "AED 0.00",
              muted: true,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(color: Colors.white12, height: 1),
            ),
            if (_editingTotal)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Total ${_monthLabel(month)}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      height: 34,
                      child: TextField(
                        controller: _totalController,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d{0,2}'),
                          ),
                        ],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          prefixText: "AED ",
                          prefixStyle: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: _bg,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: _accent,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              _BreakdownRow(
                label:
                    "${upcoming ? 'Estimated' : 'Total'} ${_monthLabel(month)}"
                    "${override != null ? ' (custom)' : ''}",
                value: "AED ${total.toStringAsFixed(2)}",
              ),
            if (_editingTotal) ...[
              SizedBox(
                width: double.infinity,
                height: 40,
                child: ElevatedButton(
                  onPressed: _applyCustomTotal,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    "APPLY CHANGES",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ] else if (override != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton(
                  onPressed: _resetToCalculated,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text(
                    "Reset to calculated amount",
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            if (paidThisMonth > 0)
              _BreakdownRow(
                label: "Already paid",
                value: "-AED ${paidThisMonth.toStringAsFixed(2)}",
                muted: true,
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(color: Colors.white12, height: 1),
            ),
            // A month that hasn't started owes nothing yet — saying
            // "Remaining owed 0.00" made it look already paid.
            upcoming
                ? _BreakdownRow(
                    label: "Not billed yet",
                    value:
                        "Sends ${monthNames[billsOn.month - 1]} 1"
                        "${billsOn.year != DateTime.now().year ? ', ${billsOn.year}' : ''}",
                    bold: true,
                  )
                : _BreakdownRow(
                    label: "Remaining owed",
                    value: "AED ${remaining.toStringAsFixed(2)}",
                    bold: true,
                  ),
            // Paid more than the month came to (attendance corrected after
            // paying, for example). Flagged with a refund, instead of the
            // extra quietly disappearing.
            if (overpaid > 0) ...[
              _BreakdownRow(
                label: "Overpaid",
                value: "AED ${overpaid.toStringAsFixed(2)}",
                bold: true,
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton(
                  onPressed: () => _refundOverpaid(overpaid),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.amber, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    "REFUND AED ${overpaid.toStringAsFixed(2)}",
                    style: const TextStyle(
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (remaining > 0 && !upcoming) ...[
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: _markPaid,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    "MARK AS PAID",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
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

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool muted;

  const _BreakdownRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: muted
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.7),
                fontSize: bold ? 14 : 12.5,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: muted
                  ? Colors.white.withValues(alpha: 0.35)
                  : (bold ? _accent : Colors.white),
              fontSize: bold ? 14 : 12.5,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the admin change the two numbers every fee calculation is built
/// on. A change applies from today: sessions already held keep their old
/// price, and a new coach fee starts with next month (see fee_rates).
class _FeeSettingsDialog extends StatefulWidget {
  const _FeeSettingsDialog();

  @override
  State<_FeeSettingsDialog> createState() => _FeeSettingsDialogState();
}

class _FeeSettingsDialogState extends State<_FeeSettingsDialog> {
  late final _coachFeeController = TextEditingController(
    text: kCoachFee.toStringAsFixed(2),
  );
  late final _perSessionController = TextEditingController(
    text: kPerSessionRate.toStringAsFixed(2),
  );

  @override
  void dispose() {
    _coachFeeController.dispose();
    _perSessionController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final coachFee = double.tryParse(_coachFeeController.text.trim());
    final perSession = double.tryParse(_perSessionController.text.trim());
    if (coachFee == null || perSession == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Enter valid numbers")));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await saveFeeSettings(coachFee: coachFee, perSessionRate: perSession);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
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
            const Text(
              "FEE SETTINGS",
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 18),
            _FeeSettingField(
              label: "Coaches' fee (AED, per month)",
              controller: _coachFeeController,
            ),
            const SizedBox(height: 16),
            _FeeSettingField(
              label: "Per-session rate (AED)",
              controller: _perSessionController,
            ),
            const SizedBox(height: 8),
            Text(
              // This used to say a change re-priced the whole month. Since
              // rates have a history, that's no longer what happens.
              "New rates apply from today. Sessions already held keep the "
              "rate they were charged at, and a new coaches' fee starts "
              "from next month.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  "APPLY",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeeSettingField extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _FeeSettingField({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            prefixText: "AED ",
            prefixStyle: const TextStyle(color: Colors.white70, fontSize: 14),
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
      ],
    );
  }
}
