import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/update_banner.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_orders.dart';
import '../models/mock_roster.dart';
import '../models/mock_schedule.dart';
import '../models/payment_record.dart';
import 'admin_players_screen.dart';
import 'admin_players_by_year_screen.dart';
import 'admin_schedule_screen.dart';
import 'admin_messages_screen.dart';
import 'admin_payments_screen.dart';
import 'admin_account_validation_screen.dart';
import 'admin_player_validation_screen.dart';
import 'admin_parent_accounts_screen.dart';
import 'admin_order_validation_screen.dart';
import 'admin_tournaments_screen.dart';
import 'admin_trainings_screen.dart';
import 'admin_categories_screen.dart';
import 'admin_training_fees_screen.dart';
import 'admin_transactions_screen.dart';
import 'admin_misc_payments_screen.dart';
import 'admin_account_screen.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

List<BoxShadow> get _cardShadow => [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.25),
    blurRadius: 12,
    offset: const Offset(0, 4),
  ),
];

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int navIndex = 0;

  @override
  Widget build(BuildContext context) {
    // The phone's Back button: on another tab it goes to Home; on Home it
    // leaves the app (there's nothing underneath — never the login screen).
    return PopScope(
      canPop: navIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => navIndex = 0);
      },
      child: Scaffold(
        backgroundColor: _bg,
        // Only the open tab is built, fresh each time, so it reloads. In an
        // IndexedStack the tabs loaded once at login: a player a parent added
        // afterwards never showed on Players until the admin logged out.
        body: switch (navIndex) {
          1 => const AdminPlayers(),
          2 => const AdminSchedule(),
          3 => const AdminMessages(),
          4 => const AdminAccount(),
          _ => const _AdminDashboardTab(),
        },
        bottomNavigationBar: _AdminBottomNav(
          currentIndex: navIndex,
          onTap: (i) => setState(() => navIndex = i),
        ),
      ),
    );
  }
}

class _AdminDashboardTab extends StatefulWidget {
  const _AdminDashboardTab();

  @override
  State<_AdminDashboardTab> createState() => _AdminDashboardTabState();
}

class _AdminDashboardTabState extends State<_AdminDashboardTab>
    with LiveRefreshing<_AdminDashboardTab> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadPayments();
    await loadOrders();
    await loadSchedule();
  }

  int get _pendingCount => mockRoster.where(playerHasPendingPayment).length;

  double get _totalPending =>
      mockRoster.fold(0.0, (sum, p) => sum + totalPendingFor(p));

  @override
  void initState() {
    super.initState();
    // main.dart's startup warm-up doesn't cover orders (only the Order
    // Validation screen loaded them before), so this tab could otherwise
    // show "0 pending orders" on a fresh login even with real ones sitting
    // in the database.
    _refresh();
  }

  /// Past training sessions with players nobody marked.
  int get _unmarkedSessions => mockSchedule.where(needsAttendance).length;

  Future<void> _refresh() async {
    try {
      await loadPlayers();
      await loadPayments();
      await loadOrders();
      await loadSchedule();
    } catch (_) {
      // Best-effort — the warm-up already tried this once, and every card
      // below reloads its own data anyway when opened.
    }
    if (mounted) setState(() {});
  }

  /// Every card here opens a screen that can change what it's summarising
  /// (a payment gets settled, an order gets approved). This tab stays
  /// mounted the whole time (it's a tab inside an IndexedStack, not a
  /// route), so nothing else would ever tell it to re-read those numbers —
  /// awaiting the push and rebuilding on return is what keeps it live.
  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    // Reloaded, not just rebuilt: marking attendance or settling a bill on
    // that screen changes what these cards count.
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          // Only there when a newer app is out.
          const UpdateBanner(),
          FadeSlideIn(
            index: 0,
            child: const Center(
              child: Text(
                "OVERVIEW",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 1,
            child: Row(
              children: [
                Expanded(
                  child: _StatCard(
                    icon: Icons.groups,
                    iconColor: Colors.blue,
                    label: "TOTAL PLAYERS",
                    value: "${mockRoster.length}",
                    // How many were born in each year.
                    onTap: () => _open(const AdminPlayersByYear()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    icon: Icons.pending_actions_outlined,
                    iconColor: Colors.amber,
                    label: "TOTAL PENDING",
                    value: "AED ${_totalPending.toStringAsFixed(0)}",
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 2,
            child: _PendingPaymentsCard(
              count: _pendingCount,
              onTap: () => _open(const AdminPayments()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(index: 3, child: const _SectionTitle("TOURNAMENTS")),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 4,
            child: _ActionCard(
              icon: Icons.emoji_events_outlined,
              title: "Manage tournaments",
              subtitle: "Create tournaments & assign players",
              onTap: () => _open(const AdminTournaments()),
            ),
          ),

          const SizedBox(height: 28),

          if (_unmarkedSessions > 0) ...[
            InkWell(
              onTap: () => _open(const AdminTrainings()),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.fact_check_outlined,
                      color: Colors.amber,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "$_unmarkedSessions past session"
                            "${_unmarkedSessions == 1 ? '' : 's'} "
                            "still need attendance",
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            "Players with no mark aren't charged for those "
                            "sessions. Open Trainings to mark them.",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
          ],

          FadeSlideIn(index: 5, child: const _SectionTitle("TRAININGS")),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 6,
            child: _ActionCard(
              icon: Icons.sports_basketball_outlined,
              title: "Manage trainings",
              subtitle: "Create trainings & assign players",
              onTap: () => _open(const AdminTrainings()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(index: 7, child: const _SectionTitle("TRAINING FEES")),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 8,
            child: _ActionCard(
              icon: Icons.receipt_long_outlined,
              title: "Training fees",
              subtitle: "Monthly fee owed, based on attendance",
              onTap: () => _open(const AdminTrainingFees()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(index: 9, child: const _SectionTitle("MISC PAYMENTS")),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 10,
            child: _ActionCard(
              icon: Icons.payments_outlined,
              title: "Misc payments",
              subtitle: "One-off charges not tied to a roster",
              onTap: () => _open(const AdminMiscPayments()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(
            index: 11,
            child: const _SectionTitle("TRANSACTION HISTORY"),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 12,
            child: _ActionCard(
              icon: Icons.history,
              title: "Transaction history",
              subtitle: "Every request sent and every payment received",
              onTap: () => _open(const AdminTransactions()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(
            index: 13,
            child: const _SectionTitle("ORDER VALIDATION"),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 14,
            child: _ActionCard(
              icon: Icons.checkroom_outlined,
              title:
                  "${pendingOrders.length} pending order"
                  "${pendingOrders.length == 1 ? '' : 's'}",
              subtitle: "Uniform & merch orders awaiting approval",
              onTap: () => _open(const AdminOrderValidation()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(
            index: 15,
            child: const _SectionTitle("ACCOUNT VALIDATION"),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 16,
            child: _ActionCard(
              icon: Icons.how_to_reg_outlined,
              titleWidget: FutureBuilder<int>(
                future: fetchPendingAccountCount(),
                builder: (context, snapshot) {
                  final label = snapshot.hasError
                      ? "New accounts"
                      : !snapshot.hasData
                      ? "Loading..."
                      : "${snapshot.data} new account"
                            "${snapshot.data == 1 ? '' : 's'}";
                  return Text(label, style: _cardTitleStyle);
                },
              ),
              subtitle: "Awaiting approval",
              onTap: () => _open(const AdminAccountValidation()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(
            index: 16,
            child: const _SectionTitle("PLAYER VALIDATION"),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 16,
            child: _ActionCard(
              icon: Icons.numbers,
              titleWidget: FutureBuilder<int>(
                future: fetchJerseyRequestCount(),
                builder: (context, snapshot) {
                  final label = snapshot.hasError
                      ? "Jersey number requests"
                      : !snapshot.hasData
                      ? "Loading..."
                      : "${snapshot.data} player"
                            "${snapshot.data == 1 ? '' : 's'} to validate";
                  return Text(label, style: _cardTitleStyle);
                },
              ),
              subtitle: "Jersey numbers already worn by another player",
              onTap: () => _open(const AdminPlayerValidation()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(
            index: 16,
            child: const _SectionTitle("ACCOUNT MANAGEMENT"),
          ),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 16,
            child: _ActionCard(
              icon: Icons.manage_accounts_outlined,
              title: "Parent accounts",
              subtitle: "Deactivate or reactivate an account",
              onTap: () => _open(const AdminParentAccounts()),
            ),
          ),

          const SizedBox(height: 28),

          FadeSlideIn(index: 17, child: const _SectionTitle("CATEGORIES")),

          const SizedBox(height: 12),

          FadeSlideIn(
            index: 18,
            child: _ActionCard(
              icon: Icons.category_outlined,
              title: "Manage categories",
              subtitle: "Add birth-year categories like B2012, B2013",
              onTap: () => _open(const AdminCategoriesScreen()),
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// One row on the dashboard: an icon, a title, a line of explanation — and
/// the whole card opens the screen.
///
/// The tap used to live on a small "VIEW"/"REVIEW" label at the end of each
/// row, which was the only target and said nothing a parent-sized tap on the
/// card itself doesn't.
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String? title;

  /// For a title that isn't known yet — the pending-accounts count loads.
  final Widget? titleWidget;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    this.title,
    this.titleWidget,
    required this.subtitle,
    required this.onTap,
  }) : assert(title != null || titleWidget != null);

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            boxShadow: _cardShadow,
          ),
          child: Row(
            children: [
              Icon(icon, color: _accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleWidget ?? Text(title!, style: _cardTitleStyle),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _cardTitleStyle = TextStyle(
  color: Colors.white,
  fontSize: 14,
  fontWeight: FontWeight.bold,
);

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  /// Opens the detail behind the number; null for a card that's only a
  /// number.
  final VoidCallback? onTap;

  const _StatCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: _cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return card;
    return Pressable(
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(14),
        child: card,
      ),
    );
  }
}

class _PendingPaymentsCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _PendingPaymentsCard({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_accent, Colors.green.shade800],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          // No chevron — the whole card is the tap target, so the arrow was
          // only decoration. The Container's double.infinity width is what
          // keeps the card full-bleed now that nothing stretches the row.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "PENDING PAYMENTS",
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "$count player${count == 1 ? '' : 's'}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                "haven't settled this month's fees",
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 13,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _AdminBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _AdminBottomNav({required this.currentIndex, required this.onTap});

  static const _items = [
    (Icons.home, "Home"),
    (Icons.groups_outlined, "Players"),
    (Icons.calendar_today_outlined, "Schedule"),
    (Icons.campaign_outlined, "Messages"),
    (Icons.person_outline, "Account"),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _card,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (int i = 0; i < _items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () {
                    // A light tick, like the system tab bars.
                    if (i != currentIndex) HapticFeedback.selectionClick();
                    onTap(i);
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: i == currentIndex
                                ? _accent.withValues(alpha: 0.18)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: AnimatedScale(
                            scale: i == currentIndex ? 1.1 : 1.0,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            child: Icon(
                              _items[i].$1,
                              color: i == currentIndex
                                  ? _accent
                                  : Colors.white54,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 220),
                          style: TextStyle(
                            color: i == currentIndex ? _accent : Colors.white54,
                            fontSize: 11,
                            fontWeight: i == currentIndex
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          child: Text(_items[i].$2),
                        ),
                      ],
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
