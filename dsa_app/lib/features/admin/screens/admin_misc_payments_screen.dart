import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import 'package:flutter/services.dart';

import '../../../core/widgets/pressable.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/category_filter_button.dart';
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

/// Placeholder for one-off / miscellaneous payments (kit fees, late fees,
/// etc.) not tied to a training or tournament roster. Mirrors the Players
/// screen's GUI for now until the actual misc-payments flow is designed.
class AdminMiscPayments extends StatefulWidget {
  const AdminMiscPayments({super.key});

  @override
  State<AdminMiscPayments> createState() => _AdminMiscPaymentsState();
}

class _AdminMiscPaymentsState extends State<AdminMiscPayments>
    with LiveRefreshing<AdminMiscPayments> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadCategories();
  }

  String _categoryFilter = "All";
  String _query = "";

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// This screen used to show only what the login warm-up had loaded, so a
  /// player added since then couldn't be sent a request.
  Future<void> _refresh() async {
    try {
      await loadPlayers();
      await loadCategories();
    } catch (_) {
      // Keeps showing whatever is already loaded.
    }
    if (mounted) setState(() {});
  }

  List<AdminPlayer> get _filtered {
    return mockRoster.where((p) {
      final matchesCategory =
          _categoryFilter == "All" || p.categories.contains(_categoryFilter);
      final matchesQuery = p.matchesSearch(_query);
      return matchesCategory && matchesQuery;
    }).toList();
  }

  void _openPlayer(AdminPlayer player) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _SendPaymentRequestDialog(player: player),
    );
  }

  @override
  Widget build(BuildContext context) {
    final players = _filtered;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "MISC PAYMENTS",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
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
              child: players.isEmpty
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
                      itemBuilder: (context, index) => FadeSlideIn(
                        index: index,
                        child: _MiscPaymentTile(
                          player: players[index],
                          onTap: () => _openPlayer(players[index]),
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

class _MiscPaymentTile extends StatelessWidget {
  final AdminPlayer player;
  final VoidCallback onTap;

  const _MiscPaymentTile({required this.player, required this.onTap});

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
              ProfilePhoto(url: player.photoUrl, radius: 24),
              const SizedBox(width: 14),
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
                    if (player.kitLabel != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        player.kitLabel!,
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      player.parentPhone,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendPaymentRequestDialog extends StatefulWidget {
  final AdminPlayer player;

  const _SendPaymentRequestDialog({required this.player});

  @override
  State<_SendPaymentRequestDialog> createState() =>
      _SendPaymentRequestDialogState();
}

class _SendPaymentRequestDialogState extends State<_SendPaymentRequestDialog> {
  static const _types = ["Uniform", "Merch", "Others"];

  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _type = _types.first;

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickType() async {
    final picked = await showOptionSheet(
      context,
      title: "TYPE",
      options: _types,
      selected: _type,
    );
    if (picked != null) setState(() => _type = picked);
  }

  bool _sending = false;

  Future<void> _send() async {
    // A second tap while the first request was on its way billed twice.
    if (_sending) return;
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Please enter an amount")));
      return;
    }
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await addPayment(
        playerId: widget.player.id,
        type: PaymentType.misc,
        title: _type,
        miscType: _type.toLowerCase(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        amount: amount,
      );
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Payment request of AED ${amount.toStringAsFixed(2)} sent to "
            "${widget.player.name}.",
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _sending = false);
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
            Row(
              children: [
                ProfilePhoto(url: widget.player.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.player.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // On the request itself, so the kit gets made in the
                      // right squad's colours with the right number on it.
                      if (widget.player.kitLabel != null)
                        Text(
                          widget.player.kitLabel!,
                          style: const TextStyle(
                            color: _accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // This screen only sends requests. What's already outstanding
            // (and settling it) lives on the Payments screen, which shows
            // every kind in one place instead of just misc.
            const SizedBox(height: 18),
            _FieldLabel("Amount (AED)"),
            const SizedBox(height: 8),
            TextField(
              controller: _amountController,
              // Decimals allowed: whole numbers only meant AED 49.50 couldn't
              // be billed.
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
                hintText: "e.g. 150",
                hintStyle: const TextStyle(color: Colors.white38),
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
            const SizedBox(height: 16),
            _FieldLabel("Type"),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickType,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _type,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white54,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _FieldLabel("Description"),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              inputFormatters: [noEmoji],
              minLines: 2,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: "e.g. Away-kit jersey, size M",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: _bg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
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
              height: 48,
              child: ElevatedButton(
                onPressed: _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  "SEND PAYMENT REQUEST",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
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
