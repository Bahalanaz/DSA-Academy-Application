import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_roster.dart';
import '../models/mock_parent_players.dart';
import 'player_form_screen.dart';
import 'player_edit_screen.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/live_refresh.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class ParentPlayers extends StatefulWidget {
  const ParentPlayers({super.key});

  @override
  State<ParentPlayers> createState() => _ParentPlayersState();
}

class _ParentPlayersState extends State<ParentPlayers>
    with LiveRefreshing<ParentPlayers> {
  @override
  Future<void> reloadQuietly() async {
    await loadPlayers();
  }

  // Read straight off the shared roster rather than a local copy, so a
  // player added here shows up on the admin side (and in this parent's
  // payments) immediately — one players table, exactly as the schema models.
  // Including children still waiting on the academy's approval of their
  // jersey number: they show here with their status, and nowhere else yet.
  List<AdminPlayer> get _players => myAllPlayers;
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

  Future<void> _addPlayer() async {
    final result = await Navigator.push<NewPlayer>(
      context,
      MaterialPageRoute(builder: (_) => const Profile(isNew: true)),
    );
    if (result == null) return;
    final player = result.player;
    try {
      final added = await addPlayer(
        fullName: player.name,
        parentId: player.parentId,
        nickname: player.nickname,
        jerseyNumber: player.jerseyNumber,
        jerseySize: player.jerseySize,
        birthday: player.birthday,
        allowTaken: result.allowTaken,
      );
      final id = added.id;
      if (added.pending) {
        _showError(
          "${player.name} is waiting for the academy to approve jersey "
          "#${player.jerseyNumber}.",
        );
      }
      final photo = result.photo;
      if (photo != null) {
        try {
          await uploadPhoto('player', id, photo);
          await loadPlayers();
        } catch (e) {
          // The child is added either way; the photo can be added again
          // from their profile.
          _showError(
            "${player.name} was added, but the photo couldn't be "
            "saved. Try again from their profile.",
          );
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  /// Asks first, then removes on the server BEFORE the tile goes away.
  ///
  /// The swipe used to delete straight away with no prompt, and the tile
  /// was already gone by the time the server said no (a player who still
  /// owes can't be removed) — so a refused removal looked like it worked.
  Future<bool> _confirmRemove(AdminPlayer player) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove ${player.name}?",
      message:
          "They'll be taken off your account and every training and "
          "tournament roster. Their attendance and payment history is kept.",
      confirmLabel: "REMOVE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return false;
    try {
      await removePlayer(player);
      return true;
    } catch (e) {
      _showError(e);
      return false;
    }
  }

  Future<void> _editPlayer(AdminPlayer player) async {
    final result = await Navigator.push<AdminPlayer>(
      context,
      MaterialPageRoute(builder: (_) => EditParentPlayer(player: player)),
    );
    if (result == null) return;
    try {
      final pending = await updatePlayer(
        player,
        fullName: result.name,
        jerseyNumber: result.jerseyNumber,
        jerseySize: result.jerseySize,
        birthday: result.birthday,
        allowTaken: result.confirmedTakenNumber,
      );
      if (pending && result.confirmedTakenNumber) {
        _showError(
          "Jersey #${result.jerseyNumber} is waiting for the academy's "
          "approval.",
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      "MY PLAYERS",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _addPlayer,
                    icon: const Icon(Icons.add, color: Colors.white, size: 26),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: _accent),
                    )
                  : _players.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.groups_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No players yet.\nTap + to add one.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: _players.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final player = _players[index];
                        return Dismissible(
                          key: ValueKey(player.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.delete_outline,
                              color: Colors.white,
                            ),
                          ),
                          confirmDismiss: (_) => _confirmRemove(player),
                          onDismissed: (_) => setState(() {}),
                          child: FadeSlideIn(
                            index: index,
                            child: _PlayerTile(
                              player: player,
                              onEdit: () => _editPlayer(player),
                              onDelete: () async {
                                if (await _confirmRemove(player) && mounted) {
                                  setState(() {});
                                }
                              },
                            ),
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

class _PlayerTile extends StatelessWidget {
  final AdminPlayer player;
  final VoidCallback onEdit;

  /// Removing a child was only possible by swiping the card left, which
  /// nothing on screen hinted at. The swipe still works; this is the button.
  final VoidCallback onDelete;

  const _PlayerTile({
    required this.player,
    required this.onEdit,
    required this.onDelete,
  });

  /// Where a request for a taken jersey number stands, or null if none.
  (String, Color)? get _status {
    final asked = player.jerseyRequest;
    if (player.hasPendingNumber) {
      return player.isApproved
          ? ("Jersey #$asked waiting for approval", Colors.amber)
          : ("Waiting for approval (jersey #$asked)", Colors.amber);
    }
    if (player.hasDeclinedNumber) {
      return (
        "Jersey #$asked not approved. Tap to choose another",
        Colors.redAccent,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        // Tapping anywhere on the tile opens edit, not just the arrow —
        // this also fixes a real gesture bug: without a tap recognizer
        // here, the enclosing Dismissible's horizontal-drag detector was
        // the only recognizer in play, so an ordinary tap could be
        // misread as a tiny swipe and trigger delete instead.
        onTap: onEdit,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
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
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _accent.withValues(alpha: 0.5)),
                ),
                child: ProfilePhoto(url: player.photoUrl, radius: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_status != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _status!.$1,
                        style: TextStyle(
                          color: _status!.$2,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: onDelete,
                tooltip: "Remove ${player.name}",
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
