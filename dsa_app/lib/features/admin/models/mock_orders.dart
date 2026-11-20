import '../../../core/services/api_client.dart';
import 'admin_player.dart';
import 'payment_record.dart';

/// One thing a parent can order, exactly as the admin set it up.
///
/// These used to be three values hardcoded in the app AND in the database, so
/// adding a fourth needed a code change. They are rows now (`order_items`),
/// added and priced from Order Validation's settings icon.
class OrderItemOption {
  final int id;

  /// Machine name the server generated from the label. Stable across renames.
  final String code;
  final String label;
  final double price;

  /// Which bucket an approved order bills into: 'uniform', 'merch', 'others'.
  final String miscType;

  /// A retired item stays here for the admin (so it can be brought back) but
  /// never reaches a parent's order sheet.
  final bool isActive;

  const OrderItemOption({
    required this.id,
    required this.code,
    required this.label,
    required this.price,
    required this.miscType,
    required this.isActive,
  });
}

/// What an approved order of this kind shows up as on the payments side.
const orderItemTypeLabels = {
  'uniform': 'Uniform',
  'merch': 'Merch',
  'others': 'Others',
};

/// Every item the admin has set up — active ones first. A parent's copy only
/// ever contains the active ones; the server decides that, not the app.
final List<OrderItemOption> mockOrderItems = [];

List<OrderItemOption> get activeOrderItems =>
    mockOrderItems.where((item) => item.isActive).toList();

Future<void> loadOrderItems() async {
  final rows = await ApiClient.getList('/order-items');
  mockOrderItems
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        return OrderItemOption(
          id: asInt(map['id']),
          code: '${map['code']}',
          label: map['label'] as String,
          price: asDouble(map['price']),
          miscType: '${map['misc_type']}',
          isActive: '${map['is_active']}' == '1',
        );
      }),
    );
}

/// Adds an item to what parents can order. Re-adding one that was retired
/// under the same name brings the original row back rather than making a
/// second one, so old orders keep pointing at something real.
Future<void> addOrderItem({
  required String label,
  required double price,
  String miscType = 'others',
}) async {
  await ApiClient.post('/order-items', {
    'label': label,
    'price': price,
    'miscType': miscType,
  });
  await loadOrderItems();
}

/// Renames, re-prices or re-buckets an item. Orders already placed keep the
/// amount they were priced at — the server stores that on the order itself.
Future<void> updateOrderItem(
  OrderItemOption item, {
  String? label,
  double? price,
  String? miscType,
  bool? isActive,
}) async {
  await ApiClient.put('/order-items/${item.id}', {
    'label': label ?? item.label,
    'price': price ?? item.price,
    'miscType': miscType ?? item.miscType,
    'isActive': isActive ?? item.isActive,
  });
  await loadOrderItems();
}

/// Takes an item off the parent's list. Not a delete: orders already placed
/// still point at it, and Payments still names it in their history.
Future<void> removeOrderItem(OrderItemOption item) async {
  await ApiClient.delete('/order-items/${item.id}');
  await loadOrderItems();
}

enum OrderStatus { pending, approved, rejected }

/// A uniform/merch order a parent has placed for one of their players.
/// Mirrors the misc-payment flow, but the request originates on the
/// parent side and has to clear admin approval before it becomes a real
/// payment obligation — an order a parent could invent for someone else's
/// child, or at a price they typed in themselves, would be a hole in the
/// payment system.
class Order {
  final String id;

  /// Matched on this, not [playerName] — two players can share a name.
  final int playerId;
  final String playerName;

  /// Which item was ordered, and what it was called when the list loaded.
  final int itemId;
  final String itemLabel;
  double amount;
  OrderStatus status;
  final DateTime createdDate;

  /// When the admin approved or declined it.
  final DateTime? reviewedDate;

  /// The bill approval created: 'pending', 'paid', 'waived', 'refunded' or
  /// 'void'. Null for a free item (no bill) or an order not approved yet.
  final String? paymentStatus;
  final double amountPaid;

  /// When the admin marked it as handed over. Null = not given yet.
  DateTime? receivedDate;

  Order({
    required this.id,
    this.playerId = 0,
    required this.playerName,
    required this.itemId,
    required this.itemLabel,
    required this.amount,
    this.status = OrderStatus.pending,
    required this.createdDate,
    this.reviewedDate,
    this.paymentStatus,
    this.amountPaid = 0,
    this.receivedDate,
  });

  /// Where the order is now, from placing it to the family holding the kit.
  OrderStage get stage {
    if (status == OrderStatus.pending) return OrderStage.pending;
    if (status == OrderStatus.rejected) return OrderStage.declined;
    if (receivedDate != null) return OrderStage.received;
    return switch (paymentStatus) {
      'pending' when amountPaid > 0 => OrderStage.partPaid,
      'pending' => OrderStage.unpaid,
      'refunded' || 'void' => OrderStage.billCancelled,
      // Paid, waived, or a free item that never had a bill.
      _ => OrderStage.paid,
    };
  }

  /// Approved but the bill isn't settled yet (shown even once it's given).
  bool get isUnpaid =>
      status == OrderStatus.approved && paymentStatus == 'pending';
}

/// The steps an order goes through, as both sides see them.
enum OrderStage {
  pending,
  unpaid,
  partPaid,
  paid,
  received,
  declined,
  billCancelled,
}

final List<Order> mockOrders = [];

Future<void> loadOrders() async {
  final rows = await ApiClient.getList('/orders');
  mockOrders
    ..clear()
    ..addAll(
      rows.map((row) {
        final map = row as Map<String, dynamic>;
        return Order(
          id: '${map['id']}',
          playerId: asInt(map['player_id']),
          playerName: map['player_name'] as String,
          itemId: asInt(map['order_item_id']),
          itemLabel: '${map['item_label']}',
          amount: asDouble(map['amount']),
          status: switch (map['status']) {
            'approved' => OrderStatus.approved,
            'rejected' => OrderStatus.rejected,
            _ => OrderStatus.pending,
          },
          createdDate: asDate(map['created_at']) ?? DateTime.now(),
          reviewedDate: asDate(map['reviewed_at']),
          paymentStatus: map['payment_status'] as String?,
          amountPaid: asDouble(map['amount_paid']),
          receivedDate: asDate(map['received_at']),
        );
      }),
    );
}

/// The price is deliberately not sent — the server reads it from the item
/// row, so a parent can't bill themselves whatever they like. Who placed it
/// is taken from the session token, not sent either.
Future<void> placeOrder({
  required AdminPlayer player,
  required OrderItemOption item,
}) async {
  await ApiClient.post('/orders', {
    'playerId': player.id,
    'orderItemId': item.id,
  });
  await loadOrders();
}

/// A parent withdrawing their own order before the admin has reviewed it.
Future<void> cancelOrder(Order order) async {
  await ApiClient.post('/orders/${order.id}/cancel');
  mockOrders.remove(order);
}

/// A one-off price for this order only — a discount, a size upcharge.
/// Leaves the item's own price alone.
Future<void> setOrderAmount(Order order, double amount) async {
  await ApiClient.put('/orders/${order.id}', {'amount': amount});
  order.amount = amount;
}

List<Order> get pendingOrders =>
    mockOrders.where((o) => o.status == OrderStatus.pending).toList();

/// Approving turns the order into a real misc payment request, the same
/// way an admin sending a misc payment does — so it shows up in Payments
/// (both sides) exactly like any other request from here on. The server
/// does both writes in one transaction.
/// The reviewer is recorded server-side from the session token.
Future<void> approveOrder(Order order) async {
  await ApiClient.post('/orders/${order.id}/approve');
  await loadOrders();
  await loadPayments();
}

/// Orders the admin has already decided on — the HISTORY tab.
List<Order> get reviewedOrders =>
    mockOrders.where((o) => o.status != OrderStatus.pending).toList();

/// The admin handing the kit over to the family. The parent's order then
/// reads RECEIVED.
Future<void> markOrderReceived(Order order) async {
  final body = await ApiClient.post('/orders/${order.id}/received');
  order.receivedDate = asDate(body['received_at']) ?? DateTime.now();
}

/// Undo for a kit marked as given by mistake.
Future<void> unmarkOrderReceived(Order order) async {
  await ApiClient.delete('/orders/${order.id}/received');
  order.receivedDate = null;
}

/// Declines an order. It stays on the parent's list marked DECLINED —
/// removing it outright left parents wondering where their order went.
Future<void> rejectOrder(Order order) async {
  await ApiClient.delete('/orders/${order.id}');
  order.status = OrderStatus.rejected;
}
