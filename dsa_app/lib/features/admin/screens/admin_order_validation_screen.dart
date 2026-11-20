import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_orders.dart';
import '../models/order_stage_style.dart';
import '../models/mock_roster.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Orders a parent has placed (league uniform, training uniform, DSA
/// shirt) that need admin sign-off before they become a real payment
/// request — an order can't reach Payments, on either side, until it's
/// been approved here.
class AdminOrderValidation extends StatefulWidget {
  const AdminOrderValidation({super.key});

  @override
  State<AdminOrderValidation> createState() => _AdminOrderValidationState();
}

class _AdminOrderValidationState extends State<AdminOrderValidation>
    with LiveRefreshing<AdminOrderValidation> {
  @override
  Future<void> reloadQuietly() async {
    await loadOrders();
    await loadOrderItems();
    await loadPlayers();
  }

  bool _loading = true;

  List<Order> get _pending => pendingOrders;

  /// PENDING (needs a decision) or HISTORY (decided: followed until the kit
  /// is handed over, so no approved order is forgotten).
  bool _showHistory = false;
  _HistoryFilter _filter = _HistoryFilter.notGiven;

  List<Order> get _history {
    final all = reviewedOrders;
    return switch (_filter) {
      _HistoryFilter.all => all,
      _HistoryFilter.notGiven =>
        all
            .where(
              (o) => o.status == OrderStatus.approved && o.receivedDate == null,
            )
            .toList(),
      _HistoryFilter.given => all.where((o) => o.receivedDate != null).toList(),
      _HistoryFilter.declined =>
        all.where((o) => o.status == OrderStatus.rejected).toList(),
    };
  }

  /// A second tap on APPROVE while the first was still sending came back
  /// as "No pending order with that id".
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadOrders();
      await loadOrderItems();
      await loadPlayers();
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

  String? _phoneFor(int playerId) {
    final matches = mockRoster.where((p) => p.id == playerId);
    return matches.isEmpty ? null : matches.first.parentPhone;
  }

  /// "Born 2013 · Jersey #7 · Size M" for the player an order is for — what
  /// a kit order is made up from. A player added before sizes existed says
  /// "Size not set", so the admin knows to ask rather than guess.
  String? _kitFor(int playerId) {
    final matches = mockRoster.where((p) => p.id == playerId);
    if (matches.isEmpty) return null;
    final player = matches.first;
    final kit = player.kitLabel;
    if (player.jerseySize != null) return kit;
    return kit == null ? "Size not set" : "$kit · Size not set";
  }

  Future<void> _approve(Order order) async {
    if (_busy) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Approve this order?",
      message:
          "This sends a payment request of AED "
          "${order.amount.toStringAsFixed(2)} to ${order.playerName} for "
          "a ${order.itemLabel}.",
      confirmLabel: "YES, APPROVE",
    );
    if (!confirmed || _busy) return;
    _busy = true;
    try {
      await approveOrder(order);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _reject(Order order) async {
    if (_busy) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Disapprove this order?",
      message:
          "The ${order.itemLabel} order for ${order.playerName} will show "
          "as declined to the parent, and nothing is charged. They can "
          "place a new order if this was a mistake.",
      confirmLabel: "DISAPPROVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || _busy) return;
    _busy = true;
    try {
      await rejectOrder(order);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    } finally {
      _busy = false;
    }
  }

  /// The kit was handed over. Allowed before the bill is paid (the academy
  /// may give it first), but the admin is told so.
  Future<void> _markGiven(Order order) async {
    if (_busy) return;
    final unpaid = order.isUnpaid;
    final owed = order.amount - order.amountPaid;
    final confirmed = await showConfirmDialog(
      context,
      title: "Mark as given?",
      message:
          "The ${order.itemLabel} for ${order.playerName} was handed over. "
          "The parent will see it as RECEIVED."
          "${unpaid ? "\n\nNot paid yet: AED ${owed.toStringAsFixed(2)} still owed." : ""}",
      confirmLabel: "YES, GIVEN",
    );
    if (!confirmed || _busy) return;
    _busy = true;
    try {
      await markOrderReceived(order);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _undoGiven(Order order) async {
    if (_busy) return;
    final confirmed = await showConfirmDialog(
      context,
      title: "Undo given?",
      message:
          "The ${order.itemLabel} for ${order.playerName} goes back to not "
          "handed over yet.",
      confirmLabel: "UNDO",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || _busy) return;
    _busy = true;
    try {
      await unmarkOrderReceived(order);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    } finally {
      _busy = false;
    }
  }

  /// The item list itself: what a parent can order, and for how much.
  void _openItems() async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => const _OrderItemsDialog(),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editAmount(Order order) async {
    final amount = await showDialog<double>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _EditOrderAmountDialog(order: order),
    );
    if (amount == null) return;
    try {
      await setOrderAmount(order, amount);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  /// Decided orders, newest first, with a filter. Opens on NOT GIVEN YET:
  /// the approved kits still to hand over.
  Widget _buildHistory() {
    final orders = _history;
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              for (final f in _HistoryFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: _filter == f,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _filter = f),
                    // Lighter than the green switch above, so the two rows
                    // don't compete: tinted, not filled.
                    backgroundColor: _bg,
                    selectedColor: _accent.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: _filter == f ? _accent : Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    side: BorderSide(
                      color: _filter == f ? _accent : Colors.white24,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: orders.isEmpty
              ? Center(
                  child: Text(
                    _filter.empty,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: orders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final order = orders[index];
                    return FadeSlideIn(
                      index: index,
                      child: _HistoryOrderRow(
                        order: order,
                        kit: _kitFor(order.playerId),
                        onGiven: () => _markGiven(order),
                        onUndo: () => _undoGiven(order),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final orders = _pending;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  const Expanded(
                    child: Text(
                      "ORDER VALIDATION",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _openItems,
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    _SegmentTab(
                      label: "PENDING",
                      count: orders.length,
                      selected: !_showHistory,
                      onTap: () => setState(() => _showHistory = false),
                    ),
                    const SizedBox(width: 4),
                    _SegmentTab(
                      label: "HISTORY",
                      selected: _showHistory,
                      onTap: () => setState(() => _showHistory = true),
                    ),
                  ],
                ),
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : _showHistory
                  ? _buildHistory()
                  : orders.isEmpty
                  ? Center(
                      child: Text(
                        "No orders awaiting approval.",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: orders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final order = orders[index];
                        return FadeSlideIn(
                          index: index,
                          child: _PendingOrderRow(
                            order: order,
                            phone: _phoneFor(order.playerId),
                            kit: _kitFor(order.playerId),
                            onTap: () => _editAmount(order),
                            onApprove: () => _approve(order),
                            onReject: () => _reject(order),
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

class _PendingOrderRow extends StatelessWidget {
  final Order order;
  final String? phone;

  /// Birth year and jersey number, when known.
  final String? kit;
  final VoidCallback onTap;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _PendingOrderRow({
    required this.order,
    required this.phone,
    this.kit,
    required this.onTap,
    required this.onApprove,
    required this.onReject,
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
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.checkroom_outlined,
                  color: _accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Bounded so a long name ellipsises instead of
                        // pushing the status chip beside it off the card.
                        Flexible(
                          child: Text(
                            order.playerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.edit,
                          color: Colors.white.withValues(alpha: 0.35),
                          size: 12,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${order.itemLabel} · AED "
                      "${order.amount.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                    if (kit != null)
                      Text(
                        kit!,
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (phone != null && phone!.isNotEmpty)
                      Text(
                        phone!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActionButton(
                    label: "APPROVE",
                    color: _accent,
                    onTap: onApprove,
                  ),
                  const SizedBox(height: 6),
                  _ActionButton(
                    label: "DISAPPROVE",
                    color: Colors.redAccent,
                    onTap: onReject,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The HISTORY tab's filters.
enum _HistoryFilter {
  notGiven("NOT GIVEN YET", "Every approved order has been handed over."),
  given("GIVEN", "Nothing marked as given yet."),
  declined("DECLINED", "No declined orders."),
  all("ALL", "No approved or declined orders yet.");

  final String label;

  /// What the list says when nothing matches.
  final String empty;

  const _HistoryFilter(this.label, this.empty);
}

/// An order already decided: where it is now (paid? given?) and the button
/// to mark it handed over, or undo that.
class _HistoryOrderRow extends StatelessWidget {
  final Order order;
  final String? kit;
  final VoidCallback onGiven;
  final VoidCallback onUndo;

  const _HistoryOrderRow({
    required this.order,
    this.kit,
    required this.onGiven,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final (:label, :color, :note) = orderStageStyle(order);
    final reviewed = order.reviewedDate;
    final approved = order.status == OrderStatus.approved;
    final given = order.receivedDate != null;

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
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              given ? Icons.check_circle_outline : Icons.checkroom_outlined,
              color: _accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.playerName,
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
                  "${order.itemLabel} · AED "
                  "${order.amount.toStringAsFixed(2)}",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
                if (kit != null)
                  Text(
                    kit!,
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  "Ordered ${orderDay(order.createdDate)}"
                  "${reviewed == null ? '' : " · ${approved ? 'Approved' : 'Declined'} ${orderDay(reviewed)}"}",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              OrderStageChip(label: label, color: color),
              if (approved && !given) ...[
                const SizedBox(height: 8),
                _ActionButton(
                  label: "MARK AS GIVEN",
                  color: _accent,
                  onTap: onGiven,
                ),
              ],
              if (given)
                TextButton(
                  onPressed: onUndo,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.only(top: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    "UNDO",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
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

/// One half of the PENDING | HISTORY switch: a full-width segmented bar, the
/// chosen half filled green. PENDING carries a count badge while orders wait.
class _SegmentTab extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentTab({
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final waiting = count ?? 0;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 40,
          decoration: BoxDecoration(
            color: selected ? _accent : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              if (waiting > 0) ...[
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : Colors.amber,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    "$waiting",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected ? _accent : Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A per-order override — a discount, a size upcharge, whatever the admin
/// needs to change for this one player's order. Doesn't touch the shared
/// presets in [_OrderPresetSettingsDialog]; only this order's amount.
class _EditOrderAmountDialog extends StatefulWidget {
  final Order order;

  const _EditOrderAmountDialog({required this.order});

  @override
  State<_EditOrderAmountDialog> createState() => _EditOrderAmountDialogState();
}

class _EditOrderAmountDialogState extends State<_EditOrderAmountDialog> {
  late final _amountController = TextEditingController(
    text: widget.order.amount.toStringAsFixed(2),
  );

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _apply() {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Enter a valid amount")));
      return;
    }
    Navigator.pop(context, amount);
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "CUSTOM AMOUNT · ${order.playerName}".toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "${order.itemLabel} — the item costs AED "
              "${_itemPriceNow(order).toStringAsFixed(2)}",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountController,
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

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 96,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

/// What the item costs today. An order keeps the price it was placed at, so
/// these can differ — that's the point of showing both.
double _itemPriceNow(Order order) {
  final matches = mockOrderItems.where((i) => i.id == order.itemId);
  return matches.isEmpty ? order.amount : matches.first.price;
}

/// Admin-only: the list of things a parent can order, and what each costs.
///
/// There used to be exactly three, fixed in both the app and the database —
/// adding a fourth meant a code change and a migration. They're rows now, so
/// a hoodie or a bag is a minute's work here. Parents see whatever is active,
/// at the price set here; their order sheet still has no amount field.
class _OrderItemsDialog extends StatefulWidget {
  const _OrderItemsDialog();

  @override
  State<_OrderItemsDialog> createState() => _OrderItemsDialogState();
}

class _OrderItemsDialogState extends State<_OrderItemsDialog> {
  bool _busy = false;
  String? _error;

  /// One request at a time, with the reason shown inside the dialog — a
  /// SnackBar would sit behind it.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = friendlyError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit({OrderItemOption? item}) async {
    final draft = await showDialog<({String label, double price, String type})>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _ItemEditorDialog(item: item),
    );
    if (draft == null) return;
    await _run(
      () => item == null
          ? addOrderItem(
              label: draft.label,
              price: draft.price,
              miscType: draft.type,
            )
          : updateOrderItem(
              item,
              label: draft.label,
              price: draft.price,
              miscType: draft.type,
            ),
    );
  }

  Future<void> _retire(OrderItemOption item) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove ${item.label}?",
      message:
          "Parents won't see it on their order sheet any more. Orders already "
          "placed keep it, and you can add it back whenever you like.",
      confirmLabel: "REMOVE",
      cancelLabel: "KEEP IT",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    await _run(() => removeOrderItem(item));
  }

  @override
  Widget build(BuildContext context) {
    final active = mockOrderItems.where((i) => i.isActive).toList();
    final retired = mockOrderItems.where((i) => !i.isActive).toList();

    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "ORDER ITEMS",
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "What parents can order, and what each one costs.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),

            if (active.isEmpty)
              Text(
                "No items yet. Parents have nothing to order until you add "
                "one.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            for (final item in active)
              _ItemRow(
                item: item,
                onEdit: _busy ? null : () => _edit(item: item),
                onRetire: _busy ? null : () => _retire(item),
              ),

            if (retired.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                "REMOVED",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              for (final item in retired)
                _ItemRow(
                  item: item,
                  // Bringing one back is the same edit, with it switched on.
                  onRestore: _busy
                      ? null
                      : () => _run(() => updateOrderItem(item, isActive: true)),
                ),
            ],

            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _edit(),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accent, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.add, color: _accent, size: 18),
                label: const Text(
                  "ADD ITEM",
                  style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  "DONE",
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

class _ItemRow extends StatelessWidget {
  final OrderItemOption item;
  final VoidCallback? onEdit;
  final VoidCallback? onRetire;
  final VoidCallback? onRestore;

  const _ItemRow({
    required this.item,
    this.onEdit,
    this.onRetire,
    this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: item.isActive ? Colors.white : Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "AED ${item.price.toStringAsFixed(2)}",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (onRestore != null)
            TextButton(
              onPressed: onRestore,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                "RESTORE",
                style: TextStyle(
                  color: _accent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (onEdit != null)
            IconButton(
              onPressed: onEdit,
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.edit_outlined,
                color: Colors.white54,
                size: 18,
              ),
            ),
          if (onRetire != null)
            IconButton(
              onPressed: onRetire,
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}

/// Add or edit one item. Hands back what was typed; saving is the list's job,
/// so a failed save keeps the list on screen with the reason on it.
class _ItemEditorDialog extends StatefulWidget {
  final OrderItemOption? item;

  const _ItemEditorDialog({this.item});

  @override
  State<_ItemEditorDialog> createState() => _ItemEditorDialogState();
}

class _ItemEditorDialogState extends State<_ItemEditorDialog> {
  late final _label = TextEditingController(text: widget.item?.label ?? '');
  late final _price = TextEditingController(
    text: widget.item == null ? '' : widget.item!.price.toStringAsFixed(2),
  );
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _price.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    final price = double.tryParse(_price.text.trim());
    if (label.isEmpty) {
      setState(() => _error = "Enter a name for the item");
      return;
    }
    if (price == null || price < 0) {
      setState(() => _error = "Enter a price (0 or more)");
      return;
    }
    Navigator.pop(context, (
      label: label,
      price: price,
      // A new item files under "Others"; editing an existing one leaves it
      // wherever it already was, so renaming League Uniform doesn't quietly
      // move it out of Uniform.
      type: widget.item?.miscType ?? 'others',
    ));
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
              widget.item == null ? "NEW ITEM" : "EDIT ITEM",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 16),
            _FieldLabel("Name"),
            const SizedBox(height: 8),
            TextField(
              controller: _label,
              autofocus: widget.item == null,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [noEmoji, LengthLimitingTextInputFormatter(80)],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: _fieldDecoration(hint: "e.g. Team Hoodie"),
            ),
            const SizedBox(height: 14),
            _FieldLabel("Price"),
            const SizedBox(height: 8),
            TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: _fieldDecoration(prefix: "AED "),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
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
                      "SAVE",
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

InputDecoration _fieldDecoration({String? hint, String? prefix}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      prefixText: prefix,
      prefixStyle: const TextStyle(color: Colors.white70, fontSize: 14),
      isDense: true,
      filled: true,
      fillColor: _bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
    );

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
