import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/update_banner.dart';
import '../../../core/widgets/web_push_banner.dart';

import 'parent_my_players_screen.dart';
import 'parent_schedule_screen.dart';
import 'parent_messages_screen.dart';
import 'parent_payments_screen.dart';
import 'parent_orders_screen.dart';
import 'parent_tournaments_screen.dart';
import 'parent_account_screen.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/training_fee.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/mock_roster.dart';
import '../../admin/models/payment_record.dart';
import '../models/mock_parent_players.dart';
import '../../admin/models/mock_announcements.dart';
import '../../admin/models/mock_schedule.dart';
import '../../admin/models/mock_tournaments.dart';
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

class HomeParents extends StatefulWidget {
  const HomeParents({super.key});

  @override
  State<HomeParents> createState() => _HomeParentsState();
}

class _HomeParentsState extends State<HomeParents> {
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
        // Only the open tab is built, fresh each time it's opened, so it
        // reloads. Kept alive in an IndexedStack, the tabs loaded once at
        // login and never again: a session or message the admin added later
        // didn't show until the parent logged out and back in.
        body: switch (navIndex) {
          1 => const ParentPlayers(),
          2 => const ParentSchedule(),
          3 => ParentMessages(onChanged: _messagesChanged),
          4 => const ParentProfile(),
          _ => _DashboardTab(onChanged: _messagesChanged),
        },
        bottomNavigationBar: _BottomNav(
          currentIndex: navIndex,
          unreadMessages: _unreadMessages,
          onTap: (i) => setState(() => navIndex = i),
        ),
      ),
    );
  }

  void _messagesChanged() {
    if (mounted) setState(() {});
  }

  /// Messages this parent hasn't opened yet, for the badge on Messages.
  int get _unreadMessages {
    final categories = myPlayers.expand((p) => p.categories).toSet();
    return mockAnnouncements
        .where(
          (a) =>
              !a.isRead &&
              a.isVisibleTo(categories: categories, playerIds: myAllPlayerIds),
        )
        .length;
  }
}

class _DashboardTab extends StatefulWidget {
  /// Called after a reload or when a message is opened, so the unread badge
  /// on the bottom bar keeps up.
  final VoidCallback? onChanged;

  const _DashboardTab({this.onChanged});

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab>
    with LiveRefreshing<_DashboardTab> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadFeeSettings();
    await loadPayments();
    await loadTrainingFeeOverrides();
    await loadSchedule();
    await loadAnnouncements();
    await loadTournaments();
    widget.onChanged?.call();
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Re-reads everything the cards show: when the tab opens, after coming
  /// back from Payments or Orders, and on pull-to-refresh. The schedule and
  /// announcements weren't reloaded here before, so the next-training card
  /// and recent announcements stayed as they were at login.
  Future<void> _refresh() async {
    try {
      await loadPlayers();
      await loadFeeSettings();
      await closeDueTrainingFees();
      await loadPayments();
      await loadTrainingFeeOverrides();
      await loadSchedule();
      await loadAnnouncements();
      await loadTournaments();
    } catch (_) {
      // Best-effort: the cards fall back to whatever's already loaded.
    }
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) await _refresh();
  }

  // Same source of truth the Payments screen and admin side read from —
  // live training fee (this month, per player) plus any stored misc /
  // tournament records — so this card can't show a stale number.
  List<PaymentRecord> get _pendingRecords {
    final liveTrainingFees = myPlayers.map((player) {
      final owed = unpaidTrainingFee(player, kCurrentMonth);
      if (owed <= 0) return null;
      return PaymentRecord(
        id: "live_${player.id}",
        playerId: player.id,
        playerName: player.name,
        type: PaymentType.trainingFee,
        title: "Training Fee",
        amount: owed,
        createdDate: kCurrentMonth,
      );
    }).whereType<PaymentRecord>();
    final storedUnpaid = mockPayments.where(
      (r) => myPlayerIds.contains(r.playerId) && r.isOpen,
    );
    return [...liveTrainingFees, ...storedUnpaid];
  }

  /// The soonest upcoming session of [type] that concerns one of this
  /// parent's players. Null when there isn't one — the card then shows a
  /// "nothing scheduled" line rather than inventing a fixture.
  ScheduledSession? _nextSession(String type) {
    final myIds = myPlayerIds;
    final myCategories = myPlayers.expand((p) => p.categories).toSet();
    final now = serverNow();
    final today = dateOnly(now);
    final minutesNow = now.hour * 60 + now.minute;
    // A session earlier today that has already finished isn't upcoming; it
    // used to stay on this card until midnight. A game with no end time is
    // taken to last two hours.
    bool finishedToday(ScheduledSession s) {
      if (dateOnly(s.date) != today) return false;
      final end = s.timeEnd == null
          ? (parseDisplayTime(s.time) ?? 0) + 120
          : parseDisplayTime(s.timeEnd!) ?? 24 * 60;
      return end <= minutesNow;
    }

    final upcoming =
        mockSchedule
            .where(
              (s) =>
                  s.type == type &&
                  !dateOnly(s.date).isBefore(today) &&
                  !finishedToday(s) &&
                  (s.playerIds.any(myIds.contains) ||
                      (s.rosterCount == 0 &&
                          myCategories.any(s.category.contains))),
            )
            .toList()
          ..sort((a, b) {
            final byDay = a.date.compareTo(b.date);
            if (byDay != 0) return byDay;
            return (parseDisplayTime(a.time) ?? 0).compareTo(
              parseDisplayTime(b.time) ?? 0,
            );
          });
    return upcoming.isEmpty ? null : upcoming.first;
  }

  static const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  static const _months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];

  List<String> _sessionLines(ScheduledSession? session) {
    if (session == null) return ["Nothing scheduled", "—", ""];
    final date = session.date;
    final isToday = dateOnly(date) == dateOnly(serverNow());
    final when = isToday
        ? "Today, ${session.time}"
        : "${_weekdays[date.weekday - 1]}, "
              "${_months[date.month - 1]} ${date.day}";
    return [
      when,
      session.opponent ?? session.location,
      session.opponent != null ? "@ ${session.location}" : session.category,
    ];
  }

  /// Club-wide announcements plus any aimed at a category, training or
  /// tournament one of this parent's players is in — same rule the
  /// Messages tab uses (SentAnnouncement.isVisibleTo).
  List<SentAnnouncement> get _myAnnouncements {
    final myCategories = myPlayers.expand((p) => p.categories).toSet();
    return mockAnnouncements
        .where(
          (a) => a.isVisibleTo(
            categories: myCategories,
            playerIds: myAllPlayerIds,
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingRecords;
    final outstandingBalance = pending.fold(0.0, (sum, r) => sum + r.remaining);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        color: _accent,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // Only there when a newer app is out.
            const UpdateBanner(),
            // Web version only: asks for notifications from a tap.
            const WebPushBanner(),
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
                    child: _InfoCard(
                      icon: Icons.groups,
                      iconColor: Colors.blue,
                      title: "UPCOMING TRAINING",
                      lines: _sessionLines(_nextSession("Training")),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.sports_basketball,
                      iconColor: _accent,
                      title: "NEXT GAME",
                      lines: _sessionLines(_nextSession("Tournament")),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            FadeSlideIn(
              index: 2,
              child: _PaymentsSummaryCard(
                balance: outstandingBalance,
                pendingCount: pending.length,
                onTap: () => _open(const ParentPayments()),
              ),
            ),

            const SizedBox(height: 28),

            FadeSlideIn(index: 3, child: const _SectionTitle("TOURNAMENTS")),

            const SizedBox(height: 12),

            FadeSlideIn(
              index: 3,
              child: _TournamentInvitesCard(
                waiting: unansweredTournamentInvites,
                total: myTournamentInvites.length,
                onTap: () => _open(const ParentTournaments()),
              ),
            ),

            const SizedBox(height: 28),

            FadeSlideIn(index: 3, child: const _SectionTitle("ORDERS")),

            const SizedBox(height: 12),

            FadeSlideIn(
              index: 4,
              child: InkWell(
                onTap: () => _open(const ParentOrders()),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _cardShadow,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.checkroom_outlined,
                        color: _accent,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Order uniforms & merch",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              "League uniform, training uniform, DSA shirt",
                              style: TextStyle(
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
            ),

            const SizedBox(height: 28),

            FadeSlideIn(
              index: 5,
              child: const _SectionTitle("RECENT ANNOUNCEMENTS"),
            ),

            const SizedBox(height: 12),

            if (_myAnnouncements.isEmpty)
              Text(
                "No announcements yet.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              )
            else
              // Newest three only — the Messages tab has the full list.
              for (final (i, a) in _myAnnouncements.take(3).indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FadeSlideIn(
                    index: 6 + i,
                    child: _AnnouncementTile(
                      announcement: a,
                      onOpened: () {
                        setState(() {});
                        widget.onChanged?.call();
                      },
                    ),
                  ),
                ),

            const SizedBox(height: 18),

            // The last thing on Home: where families send ideas and feedback.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _card.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.chat_outlined,
                    color: Color(0xFF25D366),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "For suggestions and feedback, please contact us via "
                      "WhatsApp.",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

/// Opens Tournaments. Stands out while an invitation is waiting for an
/// answer — nothing can be priced until the family replies.
class _TournamentInvitesCard extends StatelessWidget {
  final int waiting;
  final int total;
  final VoidCallback onTap;

  const _TournamentInvitesCard({
    required this.waiting,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = waiting > 0
        ? "$waiting invitation${waiting == 1 ? '' : 's'} waiting for your "
              "answer"
        : total == 0
        ? "Invitations for your children appear here"
        : "All answered";
    return Pressable(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            boxShadow: _cardShadow,
            border: waiting > 0
                ? Border.all(color: Colors.amber.withValues(alpha: 0.6))
                : null,
          ),
          child: Row(
            children: [
              const Icon(Icons.emoji_events_outlined, color: _accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Tournament invitations",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: waiting > 0 ? Colors.amber : Colors.white54,
                        fontSize: 12,
                        fontWeight: waiting > 0
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              if (waiting > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "$waiting",
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the balance on the home card is hidden behind dashes. Kept for
/// the whole time the app is open, so it doesn't pop back on every visit to
/// Home (someone hides it because others can see their screen).
bool _balanceHidden = false;

class _PaymentsSummaryCard extends StatefulWidget {
  final double balance;
  final int pendingCount;
  final VoidCallback onTap;

  const _PaymentsSummaryCard({
    required this.balance,
    required this.pendingCount,
    required this.onTap,
  });

  @override
  State<_PaymentsSummaryCard> createState() => _PaymentsSummaryCardState();
}

class _PaymentsSummaryCardState extends State<_PaymentsSummaryCard> {
  @override
  Widget build(BuildContext context) {
    final balance = widget.balance;
    final pendingCount = widget.pendingCount;
    final onTap = widget.onTap;
    return InkWell(
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
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
                  if (_balanceHidden)
                    const Text(
                      "AED - - - - -",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: balance),
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => Text(
                        "AED ${value.toStringAsFixed(2)}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    "$pendingCount pending payment${pendingCount == 1 ? '' : 's'}",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                // VIEW, not PAY NOW: families pay the club directly and the
                // app only tracks it.
                ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: _accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text(
                    "VIEW",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 6),
                IconButton(
                  onPressed: () =>
                      setState(() => _balanceHidden = !_balanceHidden),
                  tooltip: _balanceHidden ? "Show balance" : "Hide balance",
                  icon: Icon(
                    _balanceHidden
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: Colors.white,
                    size: 22,
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

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final List<String> lines;

  const _InfoCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            lines.first,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          for (final line in lines.skip(1))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnnouncementTile extends StatelessWidget {
  final SentAnnouncement announcement;
  final VoidCallback onOpened;

  const _AnnouncementTile({required this.announcement, required this.onOpened});

  String get title => announcement.title;
  String get date => announcement.time;
  String get body => announcement.body;

  void _open(BuildContext context) {
    if (!announcement.isRead) {
      markAnnouncementRead(announcement);
      onOpened();
    }
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        // Scrolls: a long announcement used to run off the screen here
        // (the Messages tab already handled it).
        child: DialogBody(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
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
                    style: TextStyle(
                      color: _accent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            boxShadow: _cardShadow,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.campaign_outlined,
                  color: Colors.white70,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      date,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              // Only on messages not opened yet. It used to be on every tile,
              // so it said nothing.
              if (!announcement.isRead)
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final int unreadMessages;
  final ValueChanged<int> onTap;

  const _BottomNav({
    required this.currentIndex,
    required this.unreadMessages,
    required this.onTap,
  });

  static const _messagesIndex = 3;

  static const _items = [
    (Icons.home, "Home"),
    (Icons.groups_outlined, "Players"),
    (Icons.calendar_today_outlined, "Schedule"),
    (Icons.chat_bubble_outline, "Messages"),
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
                            child: Badge(
                              isLabelVisible:
                                  i == _messagesIndex && unreadMessages > 0,
                              label: Text('$unreadMessages'),
                              backgroundColor: Colors.redAccent,
                              child: Icon(
                                _items[i].$1,
                                color: i == currentIndex
                                    ? _accent
                                    : Colors.white54,
                                size: 22,
                              ),
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
