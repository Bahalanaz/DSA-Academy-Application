import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';
import '../../admin/models/mock_roster.dart' show photoUrlOf;

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../../admin/models/payment_record.dart';
import '../../admin/models/mock_tournaments.dart';
import '../../admin/screens/tournament_standings_screen.dart';
import '../models/mock_parent_players.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// One of this family's children invited to one tournament.
typedef TournamentInvite = ({Tournament tournament, int playerId});

/// Every invitation for this family's children. The server only sends a
/// parent their own children on each roster, so a tournament none of them is
/// on has an empty roster here.
List<TournamentInvite> get myTournamentInvites {
  final mine = {for (final p in myPlayers) p.id};
  return [
    for (final tournament in mockTournaments)
      for (final playerId in tournament.playerIds)
        if (mine.contains(playerId))
          (tournament: tournament, playerId: playerId),
  ];
}

/// How many invitations are still waiting for this family's answer.
int get unansweredTournamentInvites => myTournamentInvites
    .where((i) => i.tournament.consentOf(i.playerId) == 'pending')
    .length;

/// Where a family sees which tournaments their children have been put
/// forward for, says yes or no to each, and can remove an invitation
/// altogether.
///
/// One list, no section headings: the ones still waiting for an answer come
/// first and stand out, the rest follow.
class ParentTournaments extends StatefulWidget {
  const ParentTournaments({super.key});

  @override
  State<ParentTournaments> createState() => _ParentTournamentsState();
}

class _ParentTournamentsState extends State<ParentTournaments>
    with LiveRefreshing<ParentTournaments> {
  @override
  Future<void> reloadQuietly() async {
    await loadTournaments();
    await loadPayments();
  }

  bool _loading = true;

  /// Invitations with a request on its way, so a second tap can't send it
  /// twice.
  final Set<String> _working = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      await loadTournaments();
      await loadPayments();
    } catch (e) {
      _showMessage(friendlyError(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _key(TournamentInvite invite) =>
      "${invite.tournament.id}:${invite.playerId}";

  Future<void> _answer(TournamentInvite invite, {required bool accept}) async {
    final tournament = invite.tournament;
    final name = tournament.nameOf(invite.playerId);
    // Declining asks why: the academy is told, and it's the confirmation too.
    String? reason;
    if (accept) {
      final confirmed = await showConfirmDialog(
        context,
        title: "Accept for $name?",
        message:
            "$name will take part in ${tournament.name}. The academy will "
            "send you the fee when it's ready.",
        confirmLabel: "YES, ACCEPT",
        cancelLabel: "NOT NOW",
      );
      if (!confirmed) return;
    } else {
      reason = await showDialog<String>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) =>
            _DeclineReasonDialog(name: name, tournament: tournament.name),
      );
      if (reason == null) return;
    }
    if (!_working.add(_key(invite))) return;
    setState(() {});
    try {
      await answerTournamentInvite(
        tournament,
        invite.playerId,
        accept: accept,
        reason: reason,
      );
      _showMessage(
        accept ? "Accepted — $name is in for ${tournament.name}." : "Declined.",
      );
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      _working.remove(_key(invite));
      if (mounted) setState(() {});
    }
  }

  /// Takes the child off the tournament and the invitation off this screen.
  /// The server refuses once a fee has been sent: then it's for the club.
  Future<void> _remove(TournamentInvite invite) async {
    final tournament = invite.tournament;
    final name = tournament.nameOf(invite.playerId);
    final confirmed = await showConfirmDialog(
      context,
      title: "Remove this invitation?",
      message:
          "$name will be taken off ${tournament.name} and the invitation "
          "will disappear from this list. This can't be undone — the academy "
          "would have to invite $name again.",
      confirmLabel: "REMOVE",
      cancelLabel: "KEEP IT",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed || !_working.add(_key(invite))) return;
    setState(() {});
    try {
      await removePlayerFromTournament(tournament, invite.playerId);
      _showMessage("Invitation removed.");
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      _working.remove(_key(invite));
      if (mounted) setState(() {});
    }
  }

  /// Once the club has sent this child's fee, the answer is locked (the
  /// server refuses a change or a removal), so the card stops offering them.
  bool _billed(TournamentInvite invite) => mockPayments.any(
    (r) =>
        r.type == PaymentType.tournament &&
        r.playerId == invite.playerId &&
        '${r.tournamentId}' == invite.tournament.id &&
        (r.isOpen || r.paid),
  );

  @override
  Widget build(BuildContext context) {
    // Waiting for an answer first; otherwise in the order they came.
    final invites = [
      ...myTournamentInvites.where(
        (i) => i.tournament.consentOf(i.playerId) == 'pending',
      ),
      ...myTournamentInvites.where(
        (i) => i.tournament.consentOf(i.playerId) != 'pending',
      ),
    ];

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: const Text(
          "TOURNAMENTS",
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
                child: invites.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Icon(
                            Icons.emoji_events_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            "No tournament invitations yet.\nWhen the academy "
                            "puts your child forward for one, it shows up "
                            "here.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: invites.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final invite = invites[index];
                          return FadeSlideIn(
                            index: index,
                            child: _InviteCard(
                              invite: invite,
                              busy: _working.contains(_key(invite)),
                              billed: _billed(invite),
                              onAccept: () => _answer(invite, accept: true),
                              onDecline: () => _answer(invite, accept: false),
                              onRemove: () => _remove(invite),
                              onOpen: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TournamentStandingsScreen(
                                    tournament: invite.tournament,
                                    readOnly: true,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final TournamentInvite invite;
  final bool busy;

  /// The fee has been sent: nothing here can be changed any more.
  final bool billed;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onRemove;

  /// Tapping the card (above the buttons) opens the tournament's standings
  /// and games.
  final VoidCallback onOpen;

  const _InviteCard({
    required this.invite,
    required this.busy,
    required this.billed,
    required this.onAccept,
    required this.onDecline,
    required this.onRemove,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final tournament = invite.tournament;
    final consent = tournament.consentOf(invite.playerId);
    final pending = consent == 'pending';

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: pending
            ? Border.all(color: Colors.amber.withValues(alpha: 0.6))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // On a see-through Material so the tap ripple shows over the card.
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onOpen,
              borderRadius: billed
                  ? BorderRadius.circular(14)
                  : const BorderRadius.vertical(top: Radius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: _accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.emoji_events_outlined,
                            color: _accent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tournament.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              // Just the category: this card is the lineup
                              // confirmation. Where, when and the fee come
                              // separately (the fee as a payment request).
                              Text(
                                tournament.category,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _AnswerChip(consent: consent),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ProfilePhoto(
                          url: photoUrlOf(invite.playerId),
                          radius: 12,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tournament.nameOf(invite.playerId),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Once the fee has been sent there's nothing to change here, so
          // the card simply has no buttons.
          if (!billed) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: busy ? null : onRemove,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                    label: Text(
                      "REMOVE",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: _accent,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  else ...[
                    if (consent != 'declined')
                      TextButton(
                        onPressed: onDecline,
                        child: const Text(
                          "DECLINE",
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    if (consent != 'accepted')
                      Padding(
                        padding: const EdgeInsets.only(left: 4, right: 6),
                        child: ElevatedButton(
                          onPressed: onAccept,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            "ACCEPT",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnswerChip extends StatelessWidget {
  final String consent;

  const _AnswerChip({required this.consent});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (consent) {
      'accepted' => ("ACCEPTED", Colors.green),
      'declined' => ("DECLINED", Colors.redAccent),
      _ => ("AWAITING", Colors.amber),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Declining a tournament invitation: the family says why before it's sent.
/// The academy sees the reason. Returns it, or null if they went back.
class _DeclineReasonDialog extends StatefulWidget {
  final String name;
  final String tournament;

  const _DeclineReasonDialog({required this.name, required this.tournament});

  @override
  State<_DeclineReasonDialog> createState() => _DeclineReasonDialogState();
}

class _DeclineReasonDialogState extends State<_DeclineReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _reason => _controller.text.trim();

  @override
  Widget build(BuildContext context) {
    final ready = _reason.isNotEmpty;
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Decline for ${widget.name}?",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Please tell the academy why ${widget.name} can't join "
              "${widget.tournament}. You can change your answer until the fee "
              "has been sent.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              maxLength: 300,
              inputFormatters: [noEmoji],
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: _accent,
              decoration: InputDecoration(
                hintText: "e.g. We're travelling that weekend",
                hintStyle: const TextStyle(color: Colors.white38),
                counterStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: _bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "NOT NOW",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    // Only once a reason is written.
                    onPressed: ready
                        ? () => Navigator.pop(context, _reason)
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      disabledBackgroundColor: Colors.white12,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      "DECLINE",
                      style: TextStyle(
                        color: ready ? Colors.white : Colors.white38,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
