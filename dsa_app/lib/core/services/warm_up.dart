import 'package:flutter/foundation.dart';

import '../../features/admin/models/mock_categories.dart';
import '../../features/admin/models/mock_orders.dart';
import '../../features/admin/models/mock_roster.dart';
import '../../features/admin/models/mock_schedule.dart';
import '../../features/admin/models/mock_trainings.dart';
import '../../features/admin/models/payment_record.dart';
import '../utils/training_fee.dart';

/// Best-effort load of the shared lists, so the home screens aren't empty on
/// first paint.
///
/// Runs right after login rather than at app start: every server call now
/// needs the session token, so loading before anyone has logged in would
/// only collect "please log in" errors. Nothing waits on it — each screen
/// also reloads what it needs when opened.
Future<void> warmUp() async {
  for (final load in [
    loadCategories,
    loadPlayers,
    loadTrainings,
    loadSchedule,
    loadFeeSettings,
    loadPayments,
    loadTrainingFeeOverrides,
    loadOrders,
    loadOrderItems,
  ]) {
    try {
      await load();
    } catch (e) {
      debugPrint('Warm-up load failed: $e');
    }
  }
}
