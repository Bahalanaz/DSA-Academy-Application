import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import 'mock_orders.dart';

/// How an order's step reads on both sides: the chip text, its colour, and
/// one plain line saying what happens next. Green means done.
({String label, Color color, String note}) orderStageStyle(Order order) {
  final received = order.receivedDate;
  return switch (order.stage) {
    OrderStage.pending => (
      label: "PENDING APPROVAL",
      color: Colors.amber,
      note: "Waiting for the academy to approve",
    ),
    OrderStage.unpaid => (
      label: "APPROVED · UNPAID",
      color: Colors.orangeAccent,
      note: "Approved. The bill is in Payments",
    ),
    OrderStage.partPaid => (
      label: "PART PAID",
      color: Colors.orangeAccent,
      note:
          "AED ${(order.amount - order.amountPaid).toStringAsFixed(2)} "
          "still to pay",
    ),
    OrderStage.paid => (
      label: "PAID",
      color: Colors.lightBlueAccent,
      note: "Paid. Waiting to be handed over",
    ),
    OrderStage.received => (
      label: "RECEIVED",
      color: AppColors.accent,
      note:
          "Received ${received == null ? '' : orderDay(received)}"
          "${order.isUnpaid ? ' · not paid yet' : ''}",
    ),
    OrderStage.declined => (
      label: "DECLINED",
      color: Colors.redAccent,
      note: "Declined by the academy",
    ),
    OrderStage.billCancelled => (
      label: "BILL CANCELLED",
      color: Colors.white54,
      note: "The bill for this order was cancelled",
    ),
  };
}

/// "14 Oct 2026".
String orderDay(DateTime date) =>
    "${date.day} ${monthNames[date.month - 1].substring(0, 3)} ${date.year}";

/// The small rounded status label used on order cards.
class OrderStageChip extends StatelessWidget {
  final String label;
  final Color color;

  const OrderStageChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
