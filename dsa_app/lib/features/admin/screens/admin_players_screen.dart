import 'package:flutter/material.dart';

import '../../../core/utils/jersey_number.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../../core/services/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/category_age.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../parent/screens/player_edit_screen.dart';
import '../../../core/widgets/category_filter_button.dart';
import '../../../core/widgets/option_pill.dart';
import '../../../core/widgets/option_sheet.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/admin_player.dart';
import '../models/mock_categories.dart';
import '../models/mock_roster.dart';
import '../models/payment_record.dart';
import '../../../core/widgets/pressable.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// From the real birthday when there is one; the category's birth year alone
/// made anyone whose birthday hadn't come yet a year too old.
int? _ageOf(AdminPlayer player) =>
    ageFromBirthday(player.birthday) ?? primaryAge(player.categories);

class AdminPlayers extends StatefulWidget {
  const AdminPlayers({super.key});

  @override
  State<AdminPlayers> createState() => _AdminPlayersState();
}

class _AdminPlayersState extends State<AdminPlayers>
    with LiveRefreshing<AdminPlayers> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
    await loadCategories();
  }

  String _categoryFilter = "All";
  String _query = "";
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
      await loadCategories();
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

  /// How the list is ordered, on top of the category filter and search.
  String _sort = _sortOptions.first;

  List<AdminPlayer> get _filtered {
    final list = mockRoster.where((p) {
      final matchesCategory =
          _categoryFilter == "All" || p.categories.contains(_categoryFilter);
      final matchesQuery = p.matchesSearch(_query);
      return matchesCategory && matchesQuery;
    }).toList();
    int byName(AdminPlayer a, AdminPlayer b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    // Missing birthdays and numbers go last, whichever way it's sorted.
    int born(AdminPlayer p) =>
        int.tryParse(p.birthday?.replaceAll('-', '') ?? '') ?? -1;
    int number(AdminPlayer p) => jerseyKey(p.jerseyNumber) ?? 1000000;
    // January to December, then by day: everyone with a birthday this
    // month together, whatever the year.
    int monthDay(AdminPlayer p) {
      final date = DateTime.tryParse(p.birthday ?? '');
      return date == null ? 10000 : date.month * 100 + date.day;
    }

    list.sort(switch (_sort) {
      "Name Z–A" => (a, b) => byName(b, a),
      "Oldest first" => (a, b) {
        final x = born(a), y = born(b);
        if (x != y) return x < 0 ? 1 : (y < 0 ? -1 : x.compareTo(y));
        return byName(a, b);
      },
      "Youngest first" => (a, b) {
        final x = born(a), y = born(b);
        if (x != y) return y.compareTo(x);
        return byName(a, b);
      },
      "Birth month" => (a, b) {
        final c = monthDay(a).compareTo(monthDay(b));
        return c != 0 ? c : byName(a, b);
      },
      "Jersey number" => (a, b) {
        final c = number(a).compareTo(number(b));
        return c != 0 ? c : byName(a, b);
      },
      // Nicknames A–Z; players without one after them, by name.
      "Nickname" => (a, b) {
        final x = a.nickname?.toLowerCase(), y = b.nickname?.toLowerCase();
        if (x == null || y == null) {
          if (x != y) return x == null ? 1 : -1;
          return byName(a, b);
        }
        final c = x.compareTo(y);
        return c != 0 ? c : byName(a, b);
      },
      _ => byName,
    });
    return list;
  }

  Future<void> _pickSort() async {
    final picked = await showOptionSheet(
      context,
      title: "SORT PLAYERS",
      options: _sortOptions,
      selected: _sort,
    );
    if (picked != null) setState(() => _sort = picked);
  }

  void _openPlayer(AdminPlayer player) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => _PlayerDetailDialog(
        player: player,
        onEdit: () {
          Navigator.pop(dialogContext);
          _editPlayer(player);
        },
        onRemove: () {
          Navigator.pop(dialogContext);
          _removePlayer(player);
        },
      ),
    );
  }

  /// The admin had no way to correct a child's details — a mistyped
  /// birthday (which decides the category) could only be fixed by the parent.
  Future<void> _editPlayer(AdminPlayer player) async {
    final result = await Navigator.push<AdminPlayer>(
      context,
      MaterialPageRoute(builder: (_) => EditParentPlayer(player: player)),
    );
    if (result == null) return;
    try {
      await updatePlayer(
        player,
        fullName: result.name,
        setNickname: true,
        nickname: result.nickname,
        jerseyNumber: result.jerseyNumber,
        jerseySize: result.jerseySize,
        birthday: result.birthday,
        // The admin agreed to share a taken number in the warning window.
        allowTaken: result.confirmedTakenNumber,
      );
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  /// Nor to remove a player. If they still owe, the server says how much and
  /// the admin can choose to write it off; each waived bill is logged.
  Future<void> _removePlayer(AdminPlayer player) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove ${player.name}?",
      message:
          "They'll be taken off every roster and hidden from the app. Their "
          "attendance and payment history is kept.",
      confirmLabel: "REMOVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    try {
      await removePlayer(player);
      if (mounted) setState(() {});
    } on ApiException catch (e) {
      if (e.statusCode != 409 || e.body['requiresWaiver'] != true) {
        _showError(e);
        return;
      }
      if (!mounted) return;
      final waive = await showConfirmDialog(
        context,
        title: "${player.name} still owes AED ${e.body['outstanding']}",
        message:
            "Removing them writes that balance off. Only do this if the "
            "family won't be paying it.",
        confirmLabel: "WAIVE & REMOVE",
        confirmColor: Colors.redAccent,
      );
      if (!waive) return;
      try {
        await removePlayer(player, waive: true);
        await loadPayments();
        if (mounted) setState(() {});
      } catch (e) {
        _showError(e);
      }
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final players = _filtered;

    return Container(
      color: _bg,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(width: 40),
                  const Expanded(
                    child: Text(
                      "PLAYERS",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),

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
              // Filter and sort side by side; they work together.
              child: Row(
                children: [
                  Flexible(
                    child: CategoryFilterButton(
                      categories: mockCategories,
                      selected: _categoryFilter,
                      onChanged: (category) =>
                          setState(() => _categoryFilter = category),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    // Beside the category filter and styled like it.
                    child: OptionPill(
                      icon: Icons.sort,
                      label: "Sort: $_sort",
                      onTap: _pickSort,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : players.isEmpty
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
                        child: _AdminPlayerTile(
                          player: players[index],
                          showNickname:
                              _sort == "Nickname" ||
                              players[index].matchesNicknameOnly(_query),
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

class _AdminPlayerTile extends StatelessWidget {
  final AdminPlayer player;
  final VoidCallback onTap;

  /// Shows the nickname beside the name: only when sorting by nickname,
  /// or when a search found the player by it.
  final bool showNickname;

  const _AdminPlayerTile({
    required this.player,
    required this.onTap,
    this.showNickname = false,
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
              ProfilePhoto(url: player.photoUrl, radius: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: player.name,
                        children: [
                          if (showNickname && player.nickname != null)
                            TextSpan(
                              text: "  \"${player.nickname}\"",
                              style: const TextStyle(
                                color: _accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (_ageOf(player) != null) "Age ${_ageOf(player)}",
                        player.categories.join(", "),
                        if (player.jerseyNumber != null &&
                            player.jerseyNumber!.isNotEmpty)
                          "#${player.jerseyNumber}",
                      ].join(" • "),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (playerHasPendingPayment(player))
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: const BoxDecoration(
                    color: Colors.amber,
                    shape: BoxShape.circle,
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

class _PlayerDetailDialog extends StatelessWidget {
  final AdminPlayer player;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _PlayerDetailDialog({
    required this.player,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Tap for a closer look at the photo.
                GestureDetector(
                  onTap: () => showPhotoViewer(
                    context,
                    url: player.photoUrl,
                    title: player.name,
                  ),
                  child: ProfilePhoto(url: player.photoUrl, radius: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_ageOf(player) != null)
              _DetailRow(label: "Age", value: "${_ageOf(player)}"),
            _DetailRow(
              label: "Category",
              value: player.categories.isEmpty
                  ? "None — set a birthday"
                  : player.categories.join(", "),
            ),
            _DetailRow(label: "Birthday", value: player.birthday ?? "Not set"),
            _DetailRow(
              label: "Jersey Size",
              value: player.jerseySize ?? "Not set",
            ),
            _DetailRow(label: "Attendance", value: "${player.attendanceRate}%"),
            _DetailRow(label: "Parent / Guardian", value: player.parentName),
            _DetailRow(label: "Contact Number", value: player.parentPhone),
            _DetailRow(
              label: "Payment Status",
              value: playerHasPendingPayment(player)
                  ? "Pending (AED ${totalPendingFor(player).toStringAsFixed(2)})"
                  : "Up to date",
              valueColor: playerHasPendingPayment(player)
                  ? Colors.amber
                  : _accent,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onEdit,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.edit_outlined,
                      color: Colors.white70,
                      size: 16,
                    ),
                    label: const Text(
                      "EDIT",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRemove,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.person_remove_outlined,
                      color: Colors.redAccent,
                      size: 16,
                    ),
                    label: const Text(
                      "REMOVE",
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Players list's orders. Name A–Z first (what the list always was).
const _sortOptions = [
  "Name A–Z",
  "Name Z–A",
  "Oldest first",
  "Youngest first",
  "Birth month",
  "Jersey number",
  "Nickname",
];
