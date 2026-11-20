import 'package:flutter/material.dart';

import '../../../core/services/live_refresh.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../models/admin_player.dart';
import '../models/mock_roster.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// TOTAL PLAYERS on the admin Home, opened: how many players were born in
/// each year (their category), oldest year first, with the total on top.
/// Tapping a year lists who they are.
class AdminPlayersByYear extends StatefulWidget {
  const AdminPlayersByYear({super.key});

  @override
  State<AdminPlayersByYear> createState() => _AdminPlayersByYearState();
}

class _AdminPlayersByYearState extends State<AdminPlayersByYear>
    with LiveRefreshing<AdminPlayersByYear> {
  @override
  Future<void> reloadQuietly() => loadPlayers();

  bool _loading = true;

  /// The years opened to show their players.
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await loadPlayers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Players grouped by birth year ("2013"), oldest year first; players
  /// with no birthday last, under "".
  List<MapEntry<String, List<AdminPlayer>>> get _byYear {
    final groups = <String, List<AdminPlayer>>{};
    for (final p in mockRoster) {
      groups.putIfAbsent(p.birthYear ?? '', () => []).add(p);
    }
    for (final players in groups.values) {
      players.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }
    return groups.entries.toList()..sort((a, b) {
      if (a.key.isEmpty || b.key.isEmpty) return a.key.isEmpty ? 1 : -1;
      return a.key.compareTo(b.key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = _byYear;
    final total = mockRoster.length;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "PLAYERS BY YEAR",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _accent))
            : RefreshIndicator(
                onRefresh: _refresh,
                color: _accent,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _TotalCard(total: total),
                    const SizedBox(height: 14),
                    if (groups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 60),
                        child: Center(
                          child: Text(
                            "No players yet.",
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    for (final (i, group) in groups.indexed)
                      FadeSlideIn(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _YearCard(
                            year: group.key,
                            players: group.value,
                            open: _open.contains(group.key),
                            onTap: () => setState(() {
                              if (!_open.remove(group.key)) {
                                _open.add(group.key);
                              }
                            }),
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

class _TotalCard extends StatelessWidget {
  final int total;
  const _TotalCard({required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.groups, color: Colors.blue, size: 26),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              "TOTAL PLAYERS",
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            "$total",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _YearCard extends StatelessWidget {
  /// "2013", or "" for players with no birthday.
  final String year;
  final List<AdminPlayer> players;

  final bool open;
  final VoidCallback onTap;

  const _YearCard({
    required this.year,
    required this.players,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = players.length;
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      year.isEmpty ? "No birthday yet" : "B$year",
                      style: const TextStyle(
                        color: _accent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    "$count ${count == 1 ? 'player' : 'players'}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              if (open) ...[
                const SizedBox(height: 10),
                for (final p in players)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.person_outline,
                          color: Colors.white38,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            p.name,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if ((p.jerseyNumber ?? '').isNotEmpty)
                          Text(
                            "#${p.jerseyNumber}",
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
