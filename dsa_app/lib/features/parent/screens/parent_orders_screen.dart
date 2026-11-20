import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/widgets/profile_photo.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_orders.dart';
import '../../admin/models/order_stage_style.dart';
import '../models/mock_parent_players.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Uniform / merch orders this parent has placed for their players.
/// Mirrors the My Players screen's list + "+" pattern — an order sits
/// here as pending until the admin approves it (see Order Validation on
/// the admin side), at which point it becomes a real payment request.
class ParentOrders extends StatefulWidget {
  const ParentOrders({super.key});

  @override
  State<ParentOrders> createState() => _ParentOrdersState();
}

class _ParentOrdersState extends State<ParentOrders>
    with LiveRefreshing<ParentOrders> {
  @override
  Future<void> reloadQuietly() async {
    await loadOrders();
    await loadOrderItems();
  }

  bool _loading = true;

  List<Order> get _orders =>
      mockOrders.where((o) => myPlayerIds.contains(o.playerId)).toList()
        ..sort((a, b) => b.createdDate.compareTo(a.createdDate));

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadOrders();
      // What can be ordered, and for how much, is whatever the admin has
      // set up right now — not a list baked into the app.
      await loadOrderItems();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Withdraws an order the admin hasn't looked at yet. A wrong item or
  /// the wrong child could only be fixed by asking the admin to decline it.
  Future<void> _cancel(Order order) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Cancel this order?",
      message:
          "The ${order.itemLabel} order for ${order.playerName} will be "
          "withdrawn. Nothing is charged.",
      confirmLabel: "CANCEL ORDER",
      // Not the default "CANCEL", which would read as the same action.
      cancelLabel: "KEEP ORDER",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await cancelOrder(order);
      messenger.showSnackBar(const SnackBar(content: Text("Order cancelled.")));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
    await _refresh();
  }

  void _placeOrder() {
    if (myPlayers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Add a player before placing an order")),
      );
      return;
    }
    if (activeOrderItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Nothing to order yet. Ask the admin to add an item."),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _NewOrderSheet(
        players: myPlayers,
        items: activeOrderItems,
        onPlaced: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;

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
                      "ORDERS",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _placeOrder,
                    icon: const Icon(Icons.add, color: Colors.white, size: 26),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : orders.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.checkroom_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No orders yet.\nTap + to order a uniform or shirt.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: orders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => FadeSlideIn(
                        index: index,
                        child: _OrderTile(
                          order: orders[index],
                          onCancel: orders[index].status == OrderStatus.pending
                              ? () => _cancel(orders[index])
                              : null,
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

class _OrderTile extends StatelessWidget {
  final Order order;

  /// Only while the order is still waiting for the admin.
  final VoidCallback? onCancel;

  const _OrderTile({required this.order, this.onCancel});

  @override
  Widget build(BuildContext context) {
    // Followed past approval: unpaid, paid, then received.
    final (:label, :color, :note) = orderStageStyle(order);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.checkroom_outlined,
              color: _accent,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.itemLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  "${order.playerName} · AED "
                  "${order.amount.toStringAsFixed(2)}",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Ordered ${orderDay(order.createdDate)}",
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
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              OrderStageChip(label: label, color: color),
              if (onCancel != null)
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.only(top: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    "CANCEL",
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
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

class _NewOrderSheet extends StatefulWidget {
  final List<AdminPlayer> players;

  /// Whatever the admin currently offers. Never empty — the button that
  /// opens this sheet says so instead of opening an empty list.
  final List<OrderItemOption> items;
  final VoidCallback onPlaced;

  const _NewOrderSheet({
    required this.players,
    required this.items,
    required this.onPlaced,
  });

  @override
  State<_NewOrderSheet> createState() => _NewOrderSheetState();
}

class _NewOrderSheetState extends State<_NewOrderSheet> {
  late AdminPlayer _player = widget.players.first;
  late OrderItemOption _item = widget.items.first;
  bool _submitting = false;

  Future<void> _submit() async {
    // A second tap while the first was still sending placed the order twice.
    if (_submitting) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await placeOrder(player: _player, item: _item);
      widget.onPlaced();
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Order request sent for approval — "
            "${_item.label} for ${_player.name}.",
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _submitting = false);
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "NEW ORDER",
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          _SheetLabel("Player"),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.players.map((p) {
              // By id: two children with the same name were both highlighted.
              final isSelected = _player.id == p.id;
              return ChoiceChip(
                avatar: ProfilePhoto(url: p.photoUrl, radius: 10),
                showCheckmark: false,
                label: Text(p.name),
                selected: isSelected,
                onSelected: (_) => setState(() => _player = p),
                backgroundColor: _bg,
                selectedColor: _accent,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(color: isSelected ? _accent : Colors.white24),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _SheetLabel("Item"),
          const SizedBox(height: 8),
          Column(
            children: widget.items.map((item) {
              // By id: two items could be renamed to read alike.
              final isSelected = _item.id == item.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => setState(() => _item = item),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: _bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? _accent : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          color: isSelected ? _accent : Colors.white38,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // Plain Text: the label beside it is Expanded, so it
                        // already absorbs any squeeze and this stays flush right.
                        Text(
                          "AED ${_priceLabel(item.price)}",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                _submitting ? "SENDING..." : "PLACE ORDER",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _priceLabel(double price) => price == price.roundToDouble()
    ? price.toStringAsFixed(0)
    : price.toStringAsFixed(2);

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

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
