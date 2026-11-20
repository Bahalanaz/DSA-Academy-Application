import 'package:flutter/material.dart';

import '../../../core/widgets/bill_description.dart';
import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/training_fee.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_roster.dart';
import '../../admin/models/payment_record.dart';
import '../models/mock_parent_players.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;
const _pendingColor = Colors.amber;

class ParentPayments extends StatefulWidget {
  const ParentPayments({super.key});

  @override
  State<ParentPayments> createState() => _ParentPaymentsState();
}

/// A parent's view of what's owed and paid. The app is a tracker: families
/// pay the club directly and the admin records it, so there's nothing to
/// pay from here. (Card payments, when they come, go through Stripe.)
class _ParentPaymentsState extends State<ParentPayments>
    with LiveRefreshing<ParentPayments> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadFeeSettings();
    await loadPayments();
    await loadTrainingFeeOverrides();
  }

  /// null = all of this parent's players.
  int? _selectedPlayerId;
  int _selectedTab = 0; // 0 = All, 1 = Paid, 2 = Pending
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadPlayers();
      await loadFeeSettings();
      await closeDueTrainingFees();
      await loadPayments();
      await loadTrainingFeeOverrides();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  // myPlayers is already resolved by parent id off the session, so there's
  // no need to re-match it by name against the roster.
  List<AdminPlayer> get _myPlayers => myPlayers;

  // The only item that's never a stored record until it's paid — this
  // month's training fee, still accruing live off attendance. Synthesized
  // fresh every build so it always matches what Training Fees (admin)
  // and the attendance stats dialog show.
  List<PaymentRecord> get _liveTrainingFees {
    return _myPlayers
        .map((player) {
          final owed = unpaidTrainingFee(player, kCurrentMonth);
          if (owed <= 0) return null;
          return PaymentRecord(
            id: "live_${player.id}",
            playerId: player.id,
            playerName: player.name,
            type: PaymentType.trainingFee,
            title:
                "${monthNames[kCurrentMonth.month - 1]} "
                "${kCurrentMonth.year} Training Fee",
            amount: owed,
            createdDate: kCurrentMonth,
          );
        })
        .whereType<PaymentRecord>()
        .toList();
  }

  List<PaymentRecord> get _allRecords {
    final stored = mockPayments
        .where((r) => myPlayerIds.contains(r.playerId))
        .toList();
    // What's still owed first, then newest first. Oldest-first put long
    // settled bills above what's due now.
    return [..._liveTrainingFees, ...stored]..sort((a, b) {
      if (a.isOpen != b.isOpen) return a.isOpen ? -1 : 1;
      return b.createdDate.compareTo(a.createdDate);
    });
  }

  List<PaymentRecord> get _forSelectedPlayer => _selectedPlayerId == null
      ? _allRecords
      : _allRecords.where((r) => r.playerId == _selectedPlayerId).toList();

  List<PaymentRecord> get _visiblePayments {
    switch (_selectedTab) {
      case 1:
        return _forSelectedPlayer.where((r) => r.paid).toList();
      case 2:
        return _forSelectedPlayer.where((r) => r.isOpen).toList();
      default:
        return _forSelectedPlayer;
    }
  }

  /// Training money paid ahead (an advance, or what's left over after a
  /// month came to less than was paid), for the child chips' current
  /// filter. The club records it; the month close puts it towards the next
  /// training fee.
  double get _advancePaid => _myPlayers
      .where((p) => _selectedPlayerId == null || p.id == _selectedPlayerId)
      .fold(0.0, (sum, p) => sum + trainingFeeCredit(p));

  // `remaining`, not `amount`: a request that's been part-paid only still
  // owes the difference.
  double get _outstandingBalance => _forSelectedPlayer
      .where((r) => r.isOpen)
      .fold(0.0, (sum, r) => sum + r.remaining);

  // isOpen, not !paid: a waived or refunded bill is closed, not pending.
  int get _pendingCount => _forSelectedPlayer.where((r) => r.isOpen).length;

  @override
  Widget build(BuildContext context) {
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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "OUTSTANDING BALANCE",
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "AED ${_outstandingBalance.toStringAsFixed(2)}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_advancePaid > 0.004) ...[
                      const SizedBox(height: 4),
                      Text(
                        "Advance payment: AED ${_advancePaid.toStringAsFixed(2)}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      "$_pendingCount pending payment${_pendingCount == 1 ? '' : 's'}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _myPlayers.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final player = index == 0 ? null : _myPlayers[index - 1];
                  final label = player?.name ?? "All";
                  final isSelected = _selectedPlayerId == player?.id;
                  return ChoiceChip(
                    avatar: player == null
                        ? null
                        : ProfilePhoto(url: player.photoUrl, radius: 10),
                    showCheckmark: false,
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (_) =>
                        setState(() => _selectedPlayerId = player?.id),
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

            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _StatusTab(
                    label: "ALL",
                    selected: _selectedTab == 0,
                    onTap: () => setState(() => _selectedTab = 0),
                  ),
                  _StatusTab(
                    label: "PAID",
                    selected: _selectedTab == 1,
                    onTap: () => setState(() => _selectedTab = 1),
                  ),
                  _StatusTab(
                    label: "PENDING",
                    selected: _selectedTab == 2,
                    onTap: () => setState(() => _selectedTab = 2),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : _visiblePayments.isEmpty
                  ? const Center(
                      child: Text(
                        "No payments here.",
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: _visiblePayments.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final record = _visiblePayments[index];
                        // This month's running fee isn't a bill yet, so
                        // there's nothing recorded to show for it.
                        return _PaymentTile(
                          record: record,
                          onTap: record.id.startsWith("live_")
                              ? null
                              : () => showDialog(
                                  context: context,
                                  barrierColor: Colors.black54,
                                  builder: (_) =>
                                      _ReceiptDialog(record: record),
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

class _StatusTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StatusTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? _accent : Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 2,
              width: 28,
              color: selected ? _accent : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final PaymentRecord record;

  /// Opens what the club has recorded against this bill.
  final VoidCallback? onTap;

  const _PaymentTile({required this.record, this.onTap});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (record.status) {
      'paid' => _accent,
      'waived' || 'refunded' => Colors.white54,
      _ => record.partlyPaid ? Colors.orangeAccent : _pendingColor,
    };
    final statusLabel = switch (record.status) {
      'paid' => "PAID",
      'waived' => "WAIVED",
      'refunded' => "REFUNDED",
      _ => record.partlyPaid ? "PART PAID" : "PENDING",
    };
    final dateLabel = record.paid ? "Paid on" : "Requested";
    final dateText = formatAdminDate(record.paidDate ?? record.createdDate);

    return Pressable(
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    BillDescription(record.description),
                    const SizedBox(height: 3),
                    Text(
                      "$dateLabel: $dateText",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        record.playerName,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    "AED ${record.amount.toStringAsFixed(2)}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (record.partlyPaid)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        "AED ${record.remaining.toStringAsFixed(2)} left",
                        style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: statusColor, width: 1),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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

/// What the club has recorded against one bill: each payment, refund,
/// correction or write-off, with its date, how it was paid and its receipt
/// number. Families pay the club directly, so this is their record of it.
class _ReceiptDialog extends StatelessWidget {
  final PaymentRecord record;

  const _ReceiptDialog({required this.record});

  static String _what(PaymentHistoryEntry entry) {
    if (entry.method == 'credit') {
      return entry.kind == 'refund'
          ? "Moved on as training credit"
          : "Paid from training credit";
    }
    return switch (entry.kind) {
      'payment' => "Payment received",
      'refund' => "Refunded to you",
      'reversal' => "Payment entry corrected",
      'waiver' => "Written off by the academy",
      _ => entry.kind,
    };
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
              "PAYMENT RECORD",
              style: TextStyle(
                color: _accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              record.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            BillDescription(record.description, maxLines: null),
            const SizedBox(height: 2),
            Text(
              "${record.playerName} · AED ${record.amount.toStringAsFixed(2)}"
              " charged · AED ${record.amountPaid.toStringAsFixed(2)} paid",
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
                    "Nothing has been recorded against this yet.",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final entry in entries)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
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
                                    _what(entry),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      if (entry.at != null)
                                        formatAdminDate(entry.at!),
                                      if (entry.method != null &&
                                          entry.method != 'credit')
                                        paymentMethodLabels[entry.method] ??
                                            entry.method!,
                                    ].join(" · "),
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    "Receipt no. R-${entry.id.toString().padLeft(6, '0')}",
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.4,
                                      ),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              "${entry.amount < 0 ? '- ' : ''}AED "
                              "${entry.amount.abs().toStringAsFixed(2)}",
                              style: TextStyle(
                                color: entry.kind == 'payment'
                                    ? _accent
                                    : Colors.white70,
                                fontSize: 13,
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
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
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
