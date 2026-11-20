import 'dart:convert';

import 'package:mysql_client/exception.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'db.dart';
import 'ledger.dart' show maxMoney, money, readMoney;
import 'text_rules.dart';

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

/// Which payments bucket an approved order lands in.
const _miscTypes = ['uniform', 'merch', 'others'];

/// Kit orders: a parent requests an item, an admin approves it, and only
/// then does it become money owed.
///
/// The price is looked up server-side from order_items rather than taken
/// from the request — the parent app has no amount field, and trusting a
/// client-sent price would let anyone bill themselves whatever they liked.
/// The admin can override it afterwards (PUT /orders/<id>).
Router buildOrdersRouter(Db db) {
  final router = Router();

  // ---------------------------------------------------------------------
  // The orderable items themselves — the admin adds, prices and retires them
  // ---------------------------------------------------------------------

  /// A parent sees what they can actually order; an admin sees retired items
  /// too, so they can bring one back.
  router.get('/order-items', (Request request) async {
    final user = userOf(request);
    final result = await db.execute(
      'SELECT id, code, label, price, misc_type, is_active, sort_order '
      'FROM order_items '
      '${user.isAdmin ? '' : 'WHERE is_active = 1 '}'
      'ORDER BY is_active DESC, sort_order, id',
    );
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.post('/order-items', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final label = normalizeSpaces(body['label'] as String? ?? '');
    final price = _asNum(body['price']);
    final miscType = (body['miscType'] as String? ?? 'others').trim();

    final invalid = _checkItem(label: label, price: price, miscType: miscType);
    if (invalid != null) return _json({'error': invalid}, status: 400);

    // An item retired under the same name comes back rather than colliding
    // with it: two identical-looking rows would be indistinguishable to the
    // admin, and one of them would be the dead one.
    final existing = await db.execute(
      'SELECT id, is_active FROM order_items WHERE label = :label',
      {'label': label},
    );
    // A live item with that name is a duplicate, not something to restore.
    // It used to be "restored" anyway, which quietly re-priced the item
    // every parent was already ordering.
    if (existing.rows.isNotEmpty &&
        existing.rows.first.assoc()['is_active'] == '1') {
      return _json({
        'error': 'There is already an item called "$label"',
      }, status: 409);
    }
    if (existing.rows.isNotEmpty) {
      final id = existing.rows.first.assoc()['id'];
      await db.execute(
        'UPDATE order_items SET price = :price, misc_type = :miscType, '
        'is_active = 1 WHERE id = :id',
        {'id': id, 'price': money(price!), 'miscType': miscType},
      );
      return _json({'id': int.parse('$id'), 'label': label, 'restored': true});
    }

    final result = await db.execute(
      'INSERT INTO order_items '
      '(code, label, price, misc_type, sort_order, created_by) '
      'VALUES (:code, :label, :price, :miscType, '
      ' (SELECT next_sort FROM '
      '   (SELECT COALESCE(MAX(sort_order), 0) + 1 AS next_sort '
      '    FROM order_items) AS s), '
      ' :createdBy)',
      {
        'code': await _uniqueCode(db, label),
        'label': label,
        'price': money(price!),
        'miscType': miscType,
        'createdBy': user.id,
      },
    );
    return _json({
      'id': result.lastInsertID.toInt(),
      'label': label,
    }, status: 201);
  });

  /// Renaming or re-pricing an item changes what parents see from now on.
  /// Orders already placed keep what they were priced at (orders.amount is a
  /// snapshot), so nobody's bill moves under them.
  router.put('/order-items/<id>', (Request request, String id) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final label = normalizeSpaces(body['label'] as String? ?? '');
    final price = _asNum(body['price']);
    final miscType = (body['miscType'] as String? ?? 'others').trim();

    final invalid = _checkItem(label: label, price: price, miscType: miscType);
    if (invalid != null) return _json({'error': invalid}, status: 400);

    final itemId = int.tryParse(id) ?? 0;
    final clash = await db.execute(
      'SELECT id FROM order_items WHERE label = :label AND id <> :id',
      {'label': label, 'id': itemId},
    );
    if (clash.rows.isNotEmpty) {
      return _json({
        'error': 'There is already an item called "$label"',
      }, status: 409);
    }

    final result = await db.execute(
      'UPDATE order_items SET label = :label, price = :price, '
      'misc_type = :miscType, is_active = :isActive WHERE id = :id',
      {
        'id': itemId,
        'label': label,
        'price': money(price!),
        'miscType': miscType,
        'isActive': body['isActive'] == false ? 0 : 1,
      },
    );
    if (result.affectedRows.toInt() == 0) {
      final exists = await db.execute(
        'SELECT id FROM order_items WHERE id = :id',
        {'id': itemId},
      );
      if (exists.rows.isEmpty) {
        return _json({'error': 'No item with that id'}, status: 404);
      }
      // Otherwise nothing actually changed, which isn't an error.
    }
    return _json({'id': itemId, 'label': label});
  });

  /// Takes an item off the parent's list without deleting it — orders already
  /// placed still point at it, and Payments still names it in their history.
  router.delete('/order-items/<id>', (Request request, String id) async {
    final result = await db.execute(
      'UPDATE order_items SET is_active = 0 WHERE id = :id AND is_active = 1',
      {'id': int.tryParse(id) ?? 0},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({'error': 'No item with that id'}, status: 404);
    }
    return _json({'id': int.parse(id), 'removed': true});
  });

  // ---------------------------------------------------------------------
  // The orders themselves
  // ---------------------------------------------------------------------

  /// A parent only sees orders for their own children.
  ///
  /// After approval an order is followed to the end: the state of its bill
  /// (`payment_status`, `amount_paid`) and when it was handed over
  /// (`received_at`), so neither side loses track of it.
  router.get('/orders', (Request request) async {
    final user = userOf(request);
    final scope = user.isAdmin ? '' : 'WHERE pl.parent_id = ${user.id}';
    final result = await db.execute('''
      SELECT
        o.id, o.player_id, pl.full_name AS player_name,
        o.order_item_id, i.label AS item_label,
        o.amount, o.status, o.payment_id, o.created_at,
        o.reviewed_at, o.received_at,
        pay.status AS payment_status, pay.amount_paid
      FROM orders o
      JOIN players pl ON pl.id = o.player_id
      JOIN order_items i ON i.id = o.order_item_id
      LEFT JOIN payments pay ON pay.id = o.payment_id
      $scope
      ORDER BY o.created_at DESC, o.id DESC
    ''');
    return _json(result.rows.map((row) => row.assoc()).toList());
  });

  router.post('/orders', (Request request) async {
    final user = userOf(request);
    final body = jsonDecode(await request.readAsString()) as Map;
    final playerId = body['playerId'];
    // By id, from GET /order-items. `item` is the old three-item code, still
    // accepted so an app built before custom items keeps working.
    final itemId = int.tryParse('${body['orderItemId']}');
    final code = (body['item'] as String? ?? '').trim();
    if (playerId == null || (itemId == null && code.isEmpty)) {
      return _json({'error': 'playerId and an item are required'}, status: 400);
    }
    // A parent can only order for their own child.
    if (!await canAccessPlayer(db, user, playerId)) {
      return _json({'error': 'No player with that id'}, status: 404);
    }

    // Price comes from the server's own table, never from the client.
    final priced = await db.execute(
      'SELECT id, price FROM order_items '
      'WHERE ${itemId == null ? 'code = :code' : 'id = :id'} AND is_active = 1',
      itemId == null ? {'code': code} : {'id': itemId},
    );
    if (priced.rows.isEmpty) {
      return _json({
        'error': "That item isn't available any more",
      }, status: 404);
    }
    final item = priced.rows.first.assoc();

    final result = await db.execute(
      'INSERT INTO orders (player_id, order_item_id, amount, requested_by) '
      'VALUES (:playerId, :itemId, :amount, :requestedBy)',
      {
        'playerId': playerId,
        'itemId': item['id'],
        'amount': item['price'],
        // Who's logged in, not whatever id the request claims.
        'requestedBy': user.id,
      },
    );
    return _json({
      'id': result.lastInsertID.toInt(),
      'amount': item['price'],
    }, status: 201);
  });

  // A custom price for this one order — a discount, a size upcharge. Only
  // meaningful while it's still pending; once approved the payment row has
  // already been written at the old amount.
  router.put('/orders/<id>', (Request request, String id) async {
    final body = jsonDecode(await request.readAsString()) as Map;
    final amount = _asNum(body['amount']);
    if (amount == null || amount < 0 || amount > maxMoney) {
      return _json({
        'error': 'Enter an amount from 0 to ${money(maxMoney)}',
      }, status: 400);
    }
    final result = await db.execute(
      "UPDATE orders SET amount = :amount "
      "WHERE id = :id AND status = 'pending'",
      {'id': id, 'amount': amount},
    );
    if (result.affectedRows.toInt() == 0) {
      final existing = await db.execute(
        'SELECT status FROM orders WHERE id = :id',
        {'id': id},
      );
      if (existing.rows.isEmpty) {
        return _json({'error': 'No order with that id'}, status: 404);
      }
      final status = existing.rows.first.assoc()['status'];
      if (status != 'pending') {
        return _json({
          'error': 'That order has already been reviewed',
        }, status: 409);
      }
      // Otherwise the amount simply didn't change, which isn't an error.
    }
    return _json({'id': int.parse(id), 'amount': amount});
  });

  /// Approving does two writes that must not come apart: the order becomes
  /// approved, and the payment request it turns into gets created. In one
  /// transaction so a crash can't leave an approved order nobody was ever
  /// billed for (or a charge for an order still showing as pending).
  router.post('/orders/<id>/approve', (Request request, String id) async {
    // The reviewer is whoever is logged in; nothing is read from the body.
    final reviewedBy = userOf(request).id;
    try {
      final outcome = await db.transaction((conn) async {
        final found = await conn.execute(
          'SELECT o.player_id, o.amount, p.is_active, i.label, i.misc_type '
          'FROM orders o '
          'JOIN players p ON p.id = o.player_id '
          'JOIN order_items i ON i.id = o.order_item_id '
          "WHERE o.id = :id AND o.status = 'pending' FOR UPDATE",
          {'id': id},
        );
        if (found.rows.isEmpty) {
          return (found: false, paymentId: null, error: null);
        }
        final order = found.rows.first.assoc();

        if (order['is_active'] != '1') {
          return (
            found: true,
            paymentId: null,
            error:
                'That player has been removed, so this order can\'t be '
                'approved. Decline it instead.',
          );
        }

        // A free item (price set to 0) is approved without a bill. It used
        // to create a pending AED 0.00 bill that could never be paid off.
        if ((num.tryParse('${order['amount']}') ?? 0) <= 0) {
          await conn.execute(
            "UPDATE orders SET status = 'approved', reviewed_at = NOW(), "
            'reviewed_by = :reviewedBy WHERE id = :id',
            {'id': id, 'reviewedBy': reviewedBy},
          );
          return (found: true, paymentId: null, error: null);
        }

        final payment = await conn.execute(
          'INSERT INTO payments '
          '(player_id, payment_type, title, misc_type, amount, status, '
          ' created_by) '
          "VALUES (:playerId, 'misc', :title, :miscType, :amount, "
          " 'pending', :createdBy)",
          {
            'playerId': order['player_id'],
            // The item's name as it reads today. Renaming an item renames
            // what new bills are called, not old ones.
            'title': order['label'],
            'miscType': order['misc_type'],
            'amount': order['amount'],
            'createdBy': reviewedBy,
          },
        );
        final newPaymentId = payment.lastInsertID.toInt();

        await conn.execute(
          "UPDATE orders SET status = 'approved', reviewed_at = NOW(), "
          "reviewed_by = :reviewedBy, payment_id = :paymentId "
          "WHERE id = :id",
          {'id': id, 'reviewedBy': reviewedBy, 'paymentId': newPaymentId},
        );
        return (found: true, paymentId: newPaymentId, error: null);
      });

      if (!outcome.found) {
        final reviewed = await db.execute(
          'SELECT status FROM orders WHERE id = :id',
          {'id': int.tryParse(id) ?? 0},
        );
        if (reviewed.rows.isNotEmpty) {
          return _json({
            'error':
                'This order has already been '
                '${reviewed.rows.first.assoc()['status']}.',
          }, status: 409);
        }
        return _json({'error': 'No order with that id'}, status: 404);
      }
      if (outcome.error != null) {
        return _json({'error': outcome.error}, status: 409);
      }
      return _json({'id': int.parse(id), 'paymentId': outcome.paymentId});
    } on MySQLServerException {
      rethrow;
    }
  });

  // Declining keeps the order, marked 'rejected', so the parent sees it was
  // declined. It used to be deleted, and the order simply vanished from the
  // parent's list with no explanation.
  router.delete('/orders/<id>', (Request request, String id) async {
    final result = await db.execute(
      "UPDATE orders SET status = 'rejected', reviewed_at = NOW(), "
      "reviewed_by = :reviewedBy WHERE id = :id AND status = 'pending'",
      {'id': id, 'reviewedBy': userOf(request).id},
    );
    if (result.affectedRows.toInt() == 0) {
      return _json({'error': 'No pending order with that id'}, status: 404);
    }
    return _json({'id': int.parse(id), 'declined': true});
  });

  /// The admin handing an approved order over to the family. Paid or not:
  /// the academy may give a kit before the bill is settled. Marking it
  /// twice keeps the first date. Admin only (not in auth.dart's parent list).
  /// No message to the family: the order simply shows RECEIVED under their
  /// My Orders (the academy's choice, 19 Oct 2026).
  router.post('/orders/<id>/received', (Request request, String id) async {
    final orderId = int.tryParse(id) ?? 0;
    await db.execute(
      'UPDATE orders SET received_at = NOW(), received_by = :by '
      "WHERE id = :id AND status = 'approved' AND received_at IS NULL",
      {'id': orderId, 'by': userOf(request).id},
    );
    return _receivedState(db, orderId);
  });

  /// Undo for a kit marked as given by mistake.
  router.delete('/orders/<id>/received', (Request request, String id) async {
    final orderId = int.tryParse(id) ?? 0;
    await db.execute(
      'UPDATE orders SET received_at = NULL, received_by = NULL '
      "WHERE id = :id AND status = 'approved'",
      {'id': orderId},
    );
    return _receivedState(db, orderId);
  });

  /// A parent withdrawing their own order before it's been reviewed. Removed
  /// outright: nothing was charged and nobody acted on it. A wrong item or
  /// child used to need the admin to decline it.
  router.post('/orders/<id>/cancel', (Request request, String id) async {
    final user = userOf(request);
    final orderId = int.tryParse(id) ?? 0;
    final scope = user.isAdmin ? '' : 'AND p.parent_id = ${user.id}';
    final result = await db.execute(
      'DELETE o FROM orders o JOIN players p ON p.id = o.player_id '
      "WHERE o.id = :id AND o.status = 'pending' $scope",
      {'id': orderId},
    );
    if (result.affectedRows.toInt() == 0) {
      final found = await db.execute(
        'SELECT o.id FROM orders o JOIN players p ON p.id = o.player_id '
        'WHERE o.id = :id $scope',
        {'id': orderId},
      );
      if (found.rows.isEmpty) {
        return _json({'error': 'No order with that id'}, status: 404);
      }
      return _json({
        'error':
            "This order has already been reviewed, so it can't be cancelled.",
      }, status: 409);
    }
    return _json({'id': orderId, 'cancelled': true});
  });

  return router;
}

/// What's wrong with an item the admin is adding or editing, or null.
String? _checkItem({
  required String label,
  required num? price,
  required String miscType,
}) {
  if (label.isEmpty) return 'Enter a name for the item';
  final tooLong = lengthError('Item name', label, 80);
  if (tooLong != null) return tooLong;
  if (price == null || price < 0 || price > maxMoney) {
    return 'Enter a price from 0 to ${money(maxMoney)}';
  }
  if (!_miscTypes.contains(miscType)) {
    return 'Unknown item type "$miscType"';
  }
  return null;
}

/// A machine name derived from the label ("Team Hoodie" -> "team_hoodie"),
/// numbered if that one is taken. The label is free to change later; this
/// isn't, which is what old orders and a future card processor match on.
Future<String> _uniqueCode(Db db, String label) async {
  final base = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final stem = base.isEmpty ? 'item' : base;
  final trimmed = stem.length > 36 ? stem.substring(0, 36) : stem;
  for (var suffix = 0; suffix < 100; suffix++) {
    final code = suffix == 0 ? trimmed : '${trimmed}_$suffix';
    final taken = await db.execute(
      'SELECT id FROM order_items WHERE code = :code',
      {'code': code},
    );
    if (taken.rows.isEmpty) return code;
  }
  return 'item_${DateTime.now().millisecondsSinceEpoch}';
}

num? _asNum(Object? value) => readMoney(value);

/// The order's handed-over date after a mark/undo, or why it can't have one.
Future<Response> _receivedState(Db db, int orderId) async {
  final found = await db.execute(
    'SELECT status, received_at FROM orders WHERE id = :id',
    {'id': orderId},
  );
  if (found.rows.isEmpty) {
    return _json({'error': 'No order with that id'}, status: 404);
  }
  final order = found.rows.first.assoc();
  if (order['status'] != 'approved') {
    return _json({
      'error': 'Only an approved order can be marked as given.',
    }, status: 409);
  }
  return _json({'id': orderId, 'received_at': order['received_at']});
}
