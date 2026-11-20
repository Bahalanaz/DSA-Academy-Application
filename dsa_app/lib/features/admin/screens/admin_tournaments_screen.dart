import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/widgets/profile_photo.dart';

import 'package:flutter/services.dart';

import '../../../core/utils/jersey_number.dart';

import '../../../core/widgets/pressable.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_categories.dart';
import '../models/mock_roster.dart';
import '../models/mock_tournaments.dart';
import '../models/payment_record.dart';
import 'add_players_screen.dart';
import 'tournament_standings_screen.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// Tournaments the admin has set up, each with its own assigned roster
/// of players. Mirrors the Messages screen's list + compose pattern.
class AdminTournaments extends StatefulWidget {
  const AdminTournaments({super.key});

  @override
  State<AdminTournaments> createState() => _AdminTournamentsState();
}

class _AdminTournamentsState extends State<AdminTournaments>
    with LiveRefreshing<AdminTournaments> {
  @override
  Future<void> reloadQuietly() async {
    await loadTournaments();
    // Players' jersey numbers decide the "Jersey number conflicts" line.
    await loadPlayers();
    // The fees sent decide each card's paid / requested counts.
    await loadPayments();
  }

  List<Tournament> get _tournaments => mockTournaments;
  bool _loading = true;
  bool _deleteMode = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadTournaments();
      await loadCategories();
      await loadPlayers();
      await loadPayments();
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

  void _compose() {
    // The sheet preselects the first category, so with none it crashed.
    if (mockCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Add a category first, from Home > Categories."),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ComposeTournamentSheet(
        categories: mockCategories,
        onCreate: (tournament) async {
          try {
            await addTournament(
              name: tournament.name,
              category: tournament.category,
              location: tournament.location,
            );
            if (mounted) setState(() {});
          } catch (e) {
            _showError(e);
          }
        },
      ),
    );
  }

  Future<void> _openTournament(Tournament tournament) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournament: tournament),
      ),
    );
    setState(() {});
  }

  void _toggleDeleteMode() {
    setState(() => _deleteMode = !_deleteMode);
  }

  Future<void> _confirmDelete(Tournament tournament) async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Delete this tournament?",
      message:
          "This removes \"${tournament.name}\" from Tournaments. Unpaid "
          "fees for it are withdrawn and its upcoming games are cancelled. "
          "Paid fees, past games and messages already sent are kept.\n\n"
          "Every family on it gets a message saying it's cancelled.",
      confirmLabel: "DELETE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;
    try {
      await removeTournament(tournament);
      if (mounted) setState(() {});
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      _deleteMode
                          ? "TAP A TOURNAMENT TO DELETE"
                          : "TOURNAMENTS",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleDeleteMode,
                    tooltip: "Delete a tournament",
                    icon: Icon(
                      _deleteMode ? Icons.close : Icons.delete_outline,
                      color: _deleteMode ? Colors.redAccent : Colors.white,
                      size: 22,
                    ),
                  ),
                  IconButton(
                    onPressed: _compose,
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
                  : _tournaments.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.emoji_events_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No tournaments yet.\nTap + to add one.",
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
                      itemCount: _tournaments.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final tournament = _tournaments[index];
                        return FadeSlideIn(
                          index: index,
                          child: _TournamentTile(
                            tournament: tournament,
                            deleteMode: _deleteMode,
                            onTap: () => _deleteMode
                                ? _confirmDelete(tournament)
                                : _openTournament(tournament),
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

class _TournamentTile extends StatelessWidget {
  final Tournament tournament;
  final bool deleteMode;
  final VoidCallback onTap;

  const _TournamentTile({
    required this.tournament,
    this.deleteMode = false,
    required this.onTap,
  });

  /// Two lines under the name: the families' answers, then the fees, each
  /// counted "out of" the players still going (declined ones aren't).
  ///   Accepted 2/3 · Pending 1/3 · 1 declined
  ///   Paid 1/3 · Requested 1/3 · Not sent 1/3
  List<Widget> _summaryLines(
    ({
      int accepted,
      int pending,
      int declined,
      int going,
      int paid,
      int requested,
      int notSent,
    })
    s,
  ) {
    final of = s.going;
    return [
      _SummaryLine(
        icon: Icons.how_to_reg_outlined,
        parts: [
          ("Accepted ${s.accepted}/$of", Colors.green, s.accepted == 0),
          ("Pending ${s.pending}/$of", Colors.amber, s.pending == 0),
          if (s.declined > 0)
            ("${s.declined} declined", Colors.redAccent, false),
        ],
      ),
      if (of > 0)
        _SummaryLine(
          icon: Icons.payments_outlined,
          parts: [
            ("Paid ${s.paid}/$of", Colors.green, s.paid == 0),
            ("Requested ${s.requested}/$of", Colors.amber, s.requested == 0),
            ("Not sent ${s.notSent}/$of", Colors.white54, s.notSent == 0),
          ],
        ),
    ];
  }

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
            border: deleteMode
                ? Border.all(color: Colors.redAccent.withValues(alpha: 0.5))
                : null,
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
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: deleteMode
                      ? Colors.redAccent.withValues(alpha: 0.15)
                      : Colors.white12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  deleteMode
                      ? Icons.delete_outline
                      : Icons.emoji_events_outlined,
                  color: deleteMode ? Colors.redAccent : _accent,
                  size: 20,
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
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${tournament.category} · "
                      "${tournament.playerNames.length} player"
                      "${tournament.playerNames.length == 1 ? '' : 's'}",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                    if (tournament.playerIds.isNotEmpty)
                      ..._summaryLines(tournament.summary),
                    if (tournament.tooOldIds.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          "Player category mismatch",
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (tournament.jerseyConflicts.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          "Jersey number conflicts",
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                deleteMode ? Icons.close : Icons.chevron_right,
                color: deleteMode ? Colors.redAccent : Colors.white38,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposeTournamentSheet extends StatefulWidget {
  final List<String> categories;
  final ValueChanged<Tournament> onCreate;

  const _ComposeTournamentSheet({
    required this.categories,
    required this.onCreate,
  });

  @override
  State<_ComposeTournamentSheet> createState() =>
      _ComposeTournamentSheetState();
}

class _ComposeTournamentSheetState extends State<_ComposeTournamentSheet> {
  late String _category;
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _category = widget.categories.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Please enter a name")));
      return;
    }
    widget.onCreate(
      Tournament(
        name: _nameController.text.trim(),
        category: _category,
        location: "",
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "NEW TOURNAMENT",
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          _SheetLabel("Category"),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: widget.categories.map((c) {
              final isSelected = _category == c;
              return ChoiceChip(
                label: Text(c),
                selected: isSelected,
                onSelected: (_) => setState(() => _category = c),
                backgroundColor: _bg,
                selectedColor: _accent,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(color: isSelected ? _accent : Colors.white24),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _SheetField(
            label: "Tournament Name",
            controller: _nameController,
            hint: "e.g. Victory Cup",
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                "CREATE TOURNAMENT",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;

  const _SheetField({required this.label, required this.controller, this.hint});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SheetLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          inputFormatters: [noEmoji],
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white38),
            isDense: true,
            filled: true,
            fillColor: _bg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single tournament: its info plus the players assigned to compete —
/// this is where those players "live" under the tournament.
class TournamentDetailScreen extends StatefulWidget {
  final Tournament tournament;

  const TournamentDetailScreen({super.key, required this.tournament});

  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen>
    with LiveRefreshing<TournamentDetailScreen> {
  @override
  Future<void> reloadQuietly() async {
    await loadPayments();
    await _reloadAnswers();
  }

  @override
  bool get canReloadNow =>
      !_editMode &&
      !_paymentEditMode &&
      !_renaming &&
      !_categoryEditMode &&
      !_sending;

  bool _editMode = false;
  bool _paymentEditMode = false;
  bool _renaming = false;
  bool _categoryEditMode = false;
  bool _sending = false;

  /// Players ticked to receive a payment request. Only players who can be
  /// billed (accepted, priced, not billed yet) can be ticked; everyone who
  /// becomes billable starts ticked, so one tap still bills them all — but
  /// unticking someone sticks until they stop being billable.
  final Set<int> _selected = {};
  final Set<int> _seenReady = {};
  late final TextEditingController _paymentController;
  late final TextEditingController _nameController;
  late String _selectedCategory = widget.tournament.category;
  final Map<int, TextEditingController> _amountControllers = {};

  @override
  void initState() {
    super.initState();
    _paymentController = TextEditingController(
      text: widget.tournament.paymentInfo,
    );
    _nameController = TextEditingController(text: widget.tournament.name);
    // Who has already paid is a fact on the server, not local state.
    _loadPayments();
  }

  /// Lists the players too old for this tournament's category, from the
  /// red "Player category mismatch" banner's VIEW.
  Future<void> _showCategoryMismatch() async {
    final tournament = widget.tournament;
    final ids = tournament.tooOldIds;
    if (!mounted || ids.isEmpty) return;
    final lines = [
      for (final id in ids)
        "• ${tournament.nameOf(id)}  ·  Born "
            "${mockRoster.where((p) => p.id == id).firstOrNull?.birthYear ?? '?'}",
    ];
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Dialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Player category mismatch",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                "${tournament.name} is ${tournament.category}, but "
                "${ids.length == 1 ? 'this player is' : 'these players are'} "
                "older than that category allows:\n\n${lines.join('\n')}\n\n"
                "Take them off this tournament, or change its category back.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    "OK",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Lists the players on this roster who share a jersey number. Only when
  /// the red banner's VIEW is tapped: the banner itself is the heads-up.
  Future<void> _warnJerseyConflicts() async {
    final conflicts = widget.tournament.jerseyConflicts;
    if (!mounted || conflicts.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _JerseyConflictDialog(
        tournament: widget.tournament,
        conflicts: conflicts,
      ),
    );
  }

  Future<void> _loadPayments() async {
    try {
      await loadPayments();
      // Fresh jersey numbers, so a number changed elsewhere clears a
      // conflict here.
      await loadPlayers();
      await _reloadAnswers();
      if (mounted) setState(() {});
    } catch (_) {
      // The roster still works without it; the paid badges just won't show.
    }
  }

  /// Families answer from their own phones, and another admin (or this
  /// account on another phone) can change the roster, so what's on screen
  /// can be out of date. Pulls the latest roster, amounts and answers into
  /// this tournament. Not while amounts are being edited: see canReloadNow.
  Future<void> _reloadAnswers() async {
    await loadTournaments();
    final fresh = mockTournaments
        .where((t) => t.id == widget.tournament.id)
        .firstOrNull;
    if (fresh == null) return;
    final tournament = widget.tournament;
    tournament.playerIds
      ..clear()
      ..addAll(fresh.playerIds);
    tournament.playerNames
      ..clear()
      ..addAll(fresh.playerNames);
    tournament.playerPayments
      ..clear()
      ..addAll(fresh.playerPayments);
    tournament.playerConsents
      ..clear()
      ..addAll(fresh.playerConsents);
  }

  @override
  void dispose() {
    _paymentController.dispose();
    _nameController.dispose();
    for (final controller in _amountControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _toggleRenaming() {
    if (_renaming) {
      _applyRename();
    } else {
      setState(() => _renaming = true);
    }
  }

  Future<void> _applyRename() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || name == widget.tournament.name) {
      setState(() => _renaming = false);
      return;
    }
    try {
      await renameTournament(widget.tournament, name);
      if (mounted) setState(() => _renaming = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _toggleCategoryEdit() {
    if (_categoryEditMode) {
      _applyCategoryChange();
    } else {
      setState(() {
        _selectedCategory = widget.tournament.category;
        _categoryEditMode = true;
      });
    }
  }

  Future<void> _applyCategoryChange() async {
    if (_selectedCategory == widget.tournament.category) {
      setState(() => _categoryEditMode = false);
      return;
    }
    try {
      await setTournamentCategory(widget.tournament, _selectedCategory);
      if (mounted) setState(() => _categoryEditMode = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  double get _baseAmount => _baseAmountFrom(widget.tournament.paymentInfo);

  TextEditingController _amountControllerFor(int playerId) {
    return _amountControllers.putIfAbsent(
      playerId,
      () => TextEditingController(
        text: (widget.tournament.playerPayments[playerId] ?? 0).toStringAsFixed(
          0,
        ),
      ),
    );
  }

  /// Leaving manage mode is what commits the per-player amounts — saving
  /// on every keystroke would be a write per digit typed.
  Future<void> _toggleEditMode() async {
    if (!_editMode) {
      setState(() => _editMode = true);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final alreadyPaid = await saveTournamentAmounts(widget.tournament);
      if (!mounted) return;
      setState(() => _editMode = false);
      _warnAboutAlreadyPaid(messenger, alreadyPaid);
    } catch (e) {
      _showError(e);
    }
  }

  /// A price change can't move money that's already been taken, so say so
  /// plainly rather than letting the roster imply everyone is on the new
  /// figure.
  void _warnAboutAlreadyPaid(
    ScaffoldMessengerState messenger,
    List<String> names,
  ) {
    if (names.isEmpty) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          names.length == 1
              ? "${names.first} already paid, so their amount wasn't changed."
              : "${names.length} players already paid, so their amounts "
                    "weren't changed.",
        ),
      ),
    );
  }

  void _togglePaymentEdit() {
    setState(() => _paymentEditMode = !_paymentEditMode);
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  /// A player's ACCEPTED / PENDING / DECLINED chip tapped: who answered,
  /// when, the family's reason for a decline, and buttons for the academy
  /// to answer for the family (say they're away and can't log in). The
  /// answer can't change once the fee has been sent.
  Future<void> _showConsent(int playerId) async {
    final tournament = widget.tournament;
    final action = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _ConsentDialog(
        tournament: tournament,
        playerId: playerId,
        billed: _tournamentRecordFor(playerId) != null,
      ),
    );
    if (action == null || !mounted) return;
    final name = tournament.nameOf(playerId);
    String? reason;
    if (!action) {
      final typed = await showDialog<String>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => _AcademyDeclineDialog(name: name),
      );
      if (typed == null || !mounted) return;
      reason = typed.isEmpty ? null : typed;
    }
    try {
      await answerTournamentInvite(
        tournament,
        playerId,
        accept: action,
        reason: reason,
      );
      if (!mounted) return;
      setState(_syncSelection);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action
                ? "$name is marked as accepted."
                : "$name is marked as declined.",
          ),
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  /// Reminds families who haven't answered yet to accept or decline: one
  /// child's family ([playerId]) or everyone still waiting.
  Future<void> _remind({int? playerId}) async {
    final tournament = widget.tournament;
    final waiting = playerId == null ? tournament.awaitingIds : [playerId];
    if (waiting.isEmpty) return;
    final many = waiting.length != 1;
    final confirmed = await showConfirmDialog(
      context,
      title: playerId == null
          ? "Remind ${waiting.length} ${many ? 'families' : 'family'}?"
          : "Remind ${tournament.nameOf(playerId)}'s family?",
      message:
          "${many ? 'They' : 'The family'} will get a message and a "
          "notification asking them to accept or decline "
          "${tournament.name}.",
      confirmLabel: "SEND REMINDER",
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await remindTournamentInvite(
        tournament,
        playerIds: playerId == null ? null : [playerId],
      );
      if (!mounted) return;
      final sent = result.reminded;
      final text = sent == 0
          ? "Already reminded just now. Try again in a couple of minutes."
          : "Reminder sent to $sent ${sent == 1 ? 'family' : 'families'}."
                "${result.skipped > 0 ? ' ${result.skipped} reminded just now were skipped.' : ''}";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _applyPaymentChanges() async {
    final info = _paymentController.text.trim().isEmpty
        ? "Not set"
        : _paymentController.text.trim();
    setState(() {
      _paymentEditMode = false;
      // Auto-set every current player to the new base amount; admins can
      // still fine-tune individual amounts afterwards in manage mode.
      for (final playerId in widget.tournament.playerIds) {
        widget.tournament.playerPayments[playerId] = _baseAmountFrom(info);
        _amountControllers[playerId]?.text = _baseAmountFrom(info)
            .toStringAsFixed(0);
      }
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await saveTournamentPaymentInfo(widget.tournament, info);
      final alreadyPaid = await saveTournamentAmounts(widget.tournament);
      if (!mounted) return;
      setState(() {});
      _warnAboutAlreadyPaid(messenger, alreadyPaid);
    } catch (e) {
      _showError(e);
    }
  }

  /// The first amount in the payment line. Thousands separators are
  /// allowed: "AED 1,500 per player" used to be read as AED 1.
  double _baseAmountFrom(String info) {
    final match = RegExp(r'\d[\d,]*(\.\d+)?').firstMatch(info);
    if (match == null) return 0;
    return double.tryParse(match.group(0)!.replaceAll(',', '')) ?? 0;
  }

  int get _tournamentId => int.tryParse(widget.tournament.id) ?? 0;

  /// Matched on the tournament's id (renaming it would otherwise orphan
  /// every bill) and the player's id (two players can share a name). A
  /// refunded, waived or undone bill doesn't count, so the player can be
  /// billed again.
  PaymentRecord? _tournamentRecordFor(int playerId) {
    final matches = mockPayments.where(
      (r) =>
          r.type == PaymentType.tournament &&
          r.playerId == playerId &&
          r.tournamentId == _tournamentId &&
          (r.isOpen || r.paid),
    );
    return matches.isEmpty ? null : matches.first;
  }

  bool _isPaid(int playerId) => _tournamentRecordFor(playerId)?.paid ?? false;

  /// Accepted, priced, and not billed yet: the only players a payment
  /// request can go to. Nobody waits on anyone else any more — a family
  /// that hasn't answered only holds up their own child's bill.
  bool _billable(int playerId) =>
      widget.tournament.consentOf(playerId) == 'accepted' &&
      (widget.tournament.playerPayments[playerId] ?? 0) > 0 &&
      _tournamentRecordFor(playerId) == null;

  /// Keeps the ticks in step with who can be billed: newly billable players
  /// get ticked, anyone no longer billable is unticked.
  void _syncSelection() {
    final ready = widget.tournament.playerIds.where(_billable).toSet();
    _selected.removeWhere((id) => !ready.contains(id));
    _selected.addAll(ready.difference(_seenReady));
    _seenReady
      ..clear()
      ..addAll(ready);
  }

  Future<void> _sendPayments() async {
    final targets = _selected.where(_billable).toList();
    if (targets.isEmpty) {
      _showError("Tick the players to send the payment request to.");
      return;
    }
    // Guards against a second tap landing while the first round of requests
    // is still in flight — both would pass the "already sent?" check below
    // and bill the same players twice.
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    var sentCount = 0;
    var failed = 0;
    // Why the first refusal happened — a family who removed their child or
    // changed their answer a moment ago, say. A bare count said nothing.
    String? firstError;
    for (final playerId in targets) {
      final amount = widget.tournament.playerPayments[playerId] ?? 0;
      try {
        await addPayment(
          playerId: playerId,
          type: PaymentType.tournament,
          title: "${widget.tournament.name} Fee",
          amount: amount,
          tournamentId: _tournamentId,
        );
        sentCount++;
      } catch (e) {
        failed++;
        firstError ??= friendlyError(e);
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed > 0
              ? "$failed request${failed == 1 ? '' : 's'} couldn't be sent"
                    "${sentCount > 0 ? ' ($sentCount sent)' : ''}: $firstError"
              : sentCount == 0
              ? "All payment requests already sent."
              : "Payment request sent to $sentCount "
                    "player${sentCount == 1 ? '' : 's'}.",
        ),
      ),
    );
  }

  /// Takes the player off the roster; their unpaid bill is withdrawn by the
  /// server. If they had already paid, the refund is offered right here
  /// rather than left for someone to remember.
  Future<void> _removePlayer(int playerId) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = widget.tournament.nameOf(playerId);
    try {
      final outcome = await removePlayerFromTournament(
        widget.tournament,
        playerId,
      );
      if (!mounted) return;
      setState(() {});
      if (outcome.paid.isEmpty) {
        if (outcome.cancelled > 0) {
          messenger.showSnackBar(
            SnackBar(
              content: Text("$name removed — their unpaid fee was withdrawn."),
            ),
          );
        }
        return;
      }

      final totalPaid = outcome.paid.fold(
        0.0,
        (sum, bill) => sum + bill.amountPaid,
      );
      final refund = await showConfirmDialog(
        context,
        title: "Refund $name?",
        message:
            "$name had already paid AED ${totalPaid.toStringAsFixed(2)} for "
            "this tournament. Refund it now as cash? You can also do this "
            "later from Payments.",
        confirmLabel: "REFUND",
        confirmColor: Colors.redAccent,
      );
      if (!refund) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              "$name removed. Their payment is kept on record and can be "
              "refunded from Payments.",
            ),
          ),
        );
        return;
      }
      for (final bill in outcome.paid) {
        final record = mockPayments
            .where((r) => r.id == bill.paymentId)
            .firstOrNull;
        if (record == null) continue;
        await refundPayment(
          record,
          amount: bill.amountPaid,
          note: 'Removed from ${widget.tournament.name}',
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Refunded AED ${totalPaid.toStringAsFixed(2)} to $name.",
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _addPlayers() async {
    final added = await Navigator.push<List<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddPlayersScreen(
          categoryLabel: widget.tournament.category,
          categories: [widget.tournament.category],
          alreadyAdded: widget.tournament.playerIds,
          restrictOverage: true,
        ),
      ),
    );
    if (added == null || added.isEmpty) return;
    try {
      await addPlayersToTournament(widget.tournament, added);
      if (!mounted) return;
      setState(() {
        for (final playerId in added) {
          widget.tournament.playerPayments.putIfAbsent(
            playerId,
            () => _baseAmount,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tournament = widget.tournament;
    _syncSelection();
    final ticked = _selected.where(_billable).length;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: _renaming
            ? TextField(
                controller: _nameController,
                inputFormatters: [noEmoji],
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _applyRename(),
              )
            : Text(
                tournament.name.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
        actions: [
          IconButton(
            onPressed: _toggleRenaming,
            icon: Icon(
              _renaming ? Icons.check : Icons.edit_outlined,
              color: _renaming ? _accent : Colors.white70,
              size: 20,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TapToEditRow(
                      icon: Icons.person_outline,
                      text: tournament.category,
                      editing: _categoryEditMode,
                      onTap: _toggleCategoryEdit,
                    ),
                    if (_categoryEditMode) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: mockCategories.map((c) {
                          final isSelected = _selectedCategory == c;
                          return ChoiceChip(
                            label: Text(c),
                            selected: isSelected,
                            onSelected: (_) =>
                                setState(() => _selectedCategory = c),
                            backgroundColor: _bg,
                            selectedColor: _accent,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                            side: BorderSide(
                              color: isSelected ? _accent : Colors.white24,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 42,
                        child: ElevatedButton(
                          onPressed: _applyCategoryChange,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            "APPLY CHANGES",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TapToEditRow(
                      icon: Icons.payments_outlined,
                      text: "Payment: ${tournament.paymentInfo}",
                      editing: _paymentEditMode,
                      onTap: _togglePaymentEdit,
                    ),
                    if (_paymentEditMode) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _paymentController,
                        inputFormatters: [noEmoji],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: "e.g. AED 500 per player",
                          hintStyle: const TextStyle(color: Colors.white38),
                          isDense: true,
                          filled: true,
                          fillColor: _bg,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: _accent,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 42,
                        child: ElevatedButton(
                          onPressed: _applyPaymentChanges,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            "APPLY CHANGES",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Material(
                color: _card,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TournamentStandingsScreen(tournament: tournament),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: _InfoLine(
                      icon: Icons.leaderboard_outlined,
                      text: "Standings",
                    ),
                  ),
                ),
              ),
            ),

            if (tournament.playerIds.isNotEmpty &&
                !tournament.everyoneAccepted) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ConsentBanner(
                  tournament: tournament,
                  onRefresh: _loadPayments,
                  onRemindAll: () => _remind(),
                ),
              ),
            ],

            if (tournament.jerseyConflicts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _JerseyConflictBanner(
                  text:
                      "Jersey number conflicts: ${tournament.jerseyConflicts.length} "
                      "number${tournament.jerseyConflicts.length == 1 ? '' : 's'} "
                      "shared on this roster.",
                  onTap: _warnJerseyConflicts,
                ),
              ),
            ],

            // Players older than the category (it was changed after they
            // were added): the same rule that refuses adding them.
            if (tournament.tooOldIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _JerseyConflictBanner(
                  text:
                      "Player category mismatch: "
                      "${tournament.tooOldIds.length} player"
                      "${tournament.tooOldIds.length == 1 ? ' is' : 's are'} "
                      "too old for ${tournament.category}.",
                  onTap: _showCategoryMismatch,
                ),
              ),
            ],

            const SizedBox(height: 20),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // Expanded, not Flexible + Spacer: those two split the free
                  // space evenly, which parked the add button mid-row.
                  Expanded(
                    child: Text(
                      "PLAYERS (${tournament.playerNames.length})",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _addPlayers,
                    icon: const Icon(
                      Icons.person_add_alt_1,
                      color: Colors.white54,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            Expanded(
              child: tournament.playerNames.isEmpty
                  ? Center(
                      child: Text(
                        "No players added yet.",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      itemCount: tournament.playerIds.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final playerId = tournament.playerIds[index];
                        final name = tournament.nameOf(playerId);
                        final matches = mockRoster.where(
                          (p) => p.id == playerId,
                        );
                        final jersey = matches.isEmpty
                            ? null
                            : matches.first.jerseyNumber;
                        final born = matches.isEmpty
                            ? null
                            : matches.first.birthYear;
                        // "Born 2014 · Jersey Number 13": the year shows
                        // who fits the tournament's category.
                        final details = [
                          if (born != null) "Born $born",
                          if (jersey != null && jersey.isNotEmpty)
                            "Jersey Number $jersey",
                        ].join(" · ");
                        final tooOld = tournament.tooOldIds.contains(playerId);
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              ProfilePhoto(
                                url: photoUrlOf(playerId),
                                radius: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        _ConsentChip(
                                          consent: tournament.consentOf(
                                            playerId,
                                          ),
                                          byAcademy: tournament
                                              .answeredByAcademy
                                              .contains(playerId),
                                          // Who answered, when, why (for a
                                          // decline), and answering for the
                                          // family.
                                          onTap: _editMode
                                              ? null
                                              : () => _showConsent(playerId),
                                        ),
                                      ],
                                    ),
                                    if (details.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          details,
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.35,
                                            ),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    // Older than the category allows: same
                                    // rule as adding players.
                                    if (tooOld)
                                      const Padding(
                                        padding: EdgeInsets.only(top: 2),
                                        child: Text(
                                          "Too old for this category",
                                          style: TextStyle(
                                            color: Colors.redAccent,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    if (tournament.playerPayments.containsKey(
                                      playerId,
                                    )) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          _editMode
                                              ? SizedBox(
                                                  width: 110,
                                                  height: 30,
                                                  child: TextField(
                                                    controller:
                                                        _amountControllerFor(
                                                          playerId,
                                                        ),
                                                    keyboardType:
                                                        TextInputType.number,
                                                    inputFormatters: [
                                                      FilteringTextInputFormatter
                                                          .digitsOnly,
                                                    ],
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                    ),
                                                    onChanged: (v) {
                                                      tournament
                                                              .playerPayments[playerId] =
                                                          double.tryParse(v) ??
                                                          0;
                                                    },
                                                    decoration: InputDecoration(
                                                      prefixText: "AED ",
                                                      prefixStyle:
                                                          const TextStyle(
                                                            color:
                                                                Colors.white70,
                                                            fontSize: 12,
                                                          ),
                                                      isDense: true,
                                                      filled: true,
                                                      fillColor: _bg,
                                                      contentPadding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 6,
                                                          ),
                                                      border: OutlineInputBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        borderSide:
                                                            BorderSide.none,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                              : Flexible(
                                                  child: Text(
                                                    "AED ${tournament.playerPayments[playerId]!.toStringAsFixed(0)}",
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                          if (_tournamentRecordFor(playerId) !=
                                              null) ...[
                                            const SizedBox(width: 8),
                                            _isPaid(playerId)
                                                ? const _BillChip(
                                                    "PAID",
                                                    Colors.green,
                                                  )
                                                : const _BillChip(
                                                    "REQUESTED",
                                                    Colors.amber,
                                                  ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              // Hasn't answered yet: remind this family.
                              if (!_editMode &&
                                  tournament.consentOf(playerId) == 'pending')
                                IconButton(
                                  onPressed: () => _remind(playerId: playerId),
                                  tooltip: "Remind family",
                                  icon: const Icon(
                                    Icons.notifications_active_outlined,
                                    color: Colors.amber,
                                    size: 20,
                                  ),
                                ),
                              if (!_editMode && _billable(playerId))
                                Checkbox(
                                  value: _selected.contains(playerId),
                                  activeColor: _accent,
                                  side: const BorderSide(color: Colors.white38),
                                  onChanged: (ticked) => setState(() {
                                    if (ticked == true) {
                                      _selected.add(playerId);
                                    } else {
                                      _selected.remove(playerId);
                                    }
                                  }),
                                ),
                              if (_editMode)
                                _StatusCircleButton(
                                  icon: Icons.close,
                                  color: Colors.redAccent,
                                  filled: false,
                                  onTap: () => _removePlayer(playerId),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _toggleEditMode,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: _accent),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: Icon(
                        _editMode
                            ? Icons.check
                            : Icons.manage_accounts_outlined,
                        color: _accent,
                        size: 18,
                      ),
                      label: Text(
                        _editMode ? "APPLY CHANGES" : "MANAGE PLAYERS",
                        style: const TextStyle(
                          color: _accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      // Not while amounts are being edited: the bill would go
                      // out at a figure that isn't saved, and the two would
                      // disagree.
                      onPressed: ticked == 0 || _sending || _editMode
                          ? null
                          : _sendPayments,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        disabledBackgroundColor: Colors.white12,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        _editMode
                            ? "APPLY CHANGES FIRST"
                            : ticked == 0
                            ? "SEND PAYMENTS"
                            : "SEND TO $ticked PLAYER${ticked == 1 ? '' : 'S'}",
                        style: TextStyle(
                          color: ticked == 0 || _editMode
                              ? Colors.white38
                              : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while some families haven't accepted: who, and that it only holds
/// up their own child's bill.
class _ConsentBanner extends StatelessWidget {
  final Tournament tournament;
  final VoidCallback onRefresh;

  /// Reminds every family still waiting to answer.
  final VoidCallback onRemindAll;

  const _ConsentBanner({
    required this.tournament,
    required this.onRefresh,
    required this.onRemindAll,
  });

  @override
  Widget build(BuildContext context) {
    final declined = tournament.declinedIds;
    final waiting = tournament.awaitingIds;
    final color = declined.isNotEmpty ? Colors.redAccent : Colors.amber;
    final lines = [
      if (waiting.isNotEmpty)
        "Waiting for ${waiting.length} "
            "${waiting.length == 1 ? 'family' : 'families'} to accept.",
      if (declined.isNotEmpty)
        "${declined.map(tournament.nameOf).join(', ')} declined.",
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  "Players who have accepted can be billed now; the others "
                  "once they accept.",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                  ),
                ),
                if (waiting.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onRemindAll,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.only(top: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(
                        Icons.notifications_active_outlined,
                        color: Colors.amber,
                        size: 16,
                      ),
                      label: Text(
                        waiting.length == 1
                            ? "REMIND FAMILY"
                            : "REMIND ALL ${waiting.length}",
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            tooltip: "Check for answers",
            icon: const Icon(Icons.refresh, color: Colors.white54, size: 20),
          ),
        ],
      ),
    );
  }
}

/// Red, under the consent banner, while players on the roster share a
/// jersey number. Tapping it lists them again.
class _JerseyConflictBanner extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _JerseyConflictBanner({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.redAccent.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.redAccent,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Text(
                "VIEW",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The heads-up window: each shared number and who on this roster has it.
/// Sorted by changing a player's number (their profile) or taking one of
/// them off the roster.
class _JerseyConflictDialog extends StatelessWidget {
  final Tournament tournament;
  final Map<int, List<int>> conflicts;

  const _JerseyConflictDialog({
    required this.tournament,
    required this.conflicts,
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
            const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.redAccent,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Jersey number conflicts",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "These players in ${tournament.name} have the same number:",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in conflicts.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "#${jerseyText(entry.key)}",
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            for (final id in entry.value)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 4,
                                      height: 4,
                                      margin: const EdgeInsets.only(right: 8),
                                      decoration: const BoxDecoration(
                                        color: Colors.white38,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        tournament.nameOf(id),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Text(
              "Change a player's number from their profile, or take one off "
              "this tournament.",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  "OK",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of counts on a tournament card, each part in its own colour:
/// a count of zero is dimmed so the ones that matter stand out.
class _SummaryLine extends StatelessWidget {
  final IconData icon;
  final List<(String, Color, bool)> parts;

  const _SummaryLine({required this.icon, required this.parts});

  @override
  Widget build(BuildContext context) {
    final dim = Colors.white.withValues(alpha: 0.3);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 12, color: Colors.white38),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    if (i > 0)
                      TextSpan(
                        text: "  ·  ",
                        style: TextStyle(color: dim),
                      ),
                    TextSpan(
                      text: parts[i].$1,
                      style: TextStyle(color: parts[i].$3 ? dim : parts[i].$2),
                    ),
                  ],
                ],
              ),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// PAID / REQUESTED under a player's amount.
class _BillChip extends StatelessWidget {
  final String label;
  final Color color;

  const _BillChip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// How a family's answer is written and coloured.
(String, Color) _consentLabel(String consent) => switch (consent) {
  'accepted' => ("ACCEPTED", Colors.green),
  'declined' => ("DECLINED", Colors.redAccent),
  _ => ("PENDING", Colors.amber),
};

/// A player's answer, opened from their chip: who answered and when, the
/// reason for a decline, and MARK AS ACCEPTED / MARK AS DECLINED for the
/// academy to answer for the family. Pops true (accept), false (decline)
/// or null (close).
class _ConsentDialog extends StatelessWidget {
  final Tournament tournament;
  final int playerId;

  /// The fee has been sent: the answer can't be changed any more.
  final bool billed;

  const _ConsentDialog({
    required this.tournament,
    required this.playerId,
    required this.billed,
  });

  @override
  Widget build(BuildContext context) {
    final consent = tournament.consentOf(playerId);
    final (label, color) = _consentLabel(consent);
    final name = tournament.nameOf(playerId);
    final when = tournament.playerRespondedAt[playerId];
    final reason = tournament.playerDeclineReasons[playerId];
    final byAcademy = tournament.answeredByAcademy.contains(playerId);
    final who = consent == 'pending'
        ? "The family hasn't answered yet"
        : byAcademy
        ? "Answered by the academy"
        : "Answered by the family";

    Widget button(String text, Color colour, bool value, IconData icon) =>
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, value),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: colour),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: Icon(icon, color: colour, size: 16),
            label: Text(
              text,
              style: TextStyle(color: colour, fontWeight: FontWeight.bold),
            ),
          ),
        );

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
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ConsentChip(consent: consent, byAcademy: byAcademy),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [tournament.name, if (consent != 'pending') ?when].join(" · "),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            Text(who, style: TextStyle(color: color, fontSize: 12)),
            if (consent == 'declined') ...[
              const SizedBox(height: 14),
              const Text(
                "REASON",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  reason ??
                      "No reason given. It was declined before reasons "
                          "were asked for, or by the academy.",
                  style: TextStyle(
                    color: reason == null ? Colors.white54 : Colors.white,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            if (billed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  "The fee has been sent, so this answer can't be changed.",
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              )
            else ...[
              Text(
                "Family can't answer (away, or can't log in)? Answer for them:",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              if (consent != 'accepted') ...[
                button(
                  "MARK AS ACCEPTED",
                  Colors.green,
                  true,
                  Icons.check_circle_outline,
                ),
                const SizedBox(height: 8),
              ],
              if (consent != 'declined') ...[
                button(
                  "MARK AS DECLINED",
                  Colors.redAccent,
                  false,
                  Icons.cancel_outlined,
                ),
                const SizedBox(height: 8),
              ],
            ],
            SizedBox(
              width: double.infinity,
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
                  "CLOSE",
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
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

/// The academy declining for a family: the reason is optional here (the
/// academy already knows it). Pops the reason ('' for none), or null.
class _AcademyDeclineDialog extends StatefulWidget {
  final String name;

  const _AcademyDeclineDialog({required this.name});

  @override
  State<_AcademyDeclineDialog> createState() => _AcademyDeclineDialogState();
}

class _AcademyDeclineDialogState extends State<_AcademyDeclineDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

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
            Text(
              "Decline for ${widget.name}?",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "${widget.name} won't be going. You can note why (optional).",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLength: 300,
              maxLines: 3,
              minLines: 2,
              inputFormatters: [noEmoji],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: _accent,
              decoration: InputDecoration(
                hintText: "Reason, like \"Family on vacation\"",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: _bg,
                counterStyle: const TextStyle(color: Colors.white38),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
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
                      "CANCEL",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _reason.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "DECLINE",
                      style: TextStyle(
                        color: Colors.redAccent,
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

/// ACCEPTED / PENDING / DECLINED beside a player's name.
class _ConsentChip extends StatelessWidget {
  final String consent;

  /// Opens the details behind it (the reason, for DECLINED); null when
  /// there's nothing more to show.
  final VoidCallback? onTap;

  /// The academy gave this answer for the family: a small badge says so.
  final bool byAcademy;

  const _ConsentChip({
    required this.consent,
    this.onTap,
    this.byAcademy = false,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = _consentLabel(consent);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (byAcademy && consent != 'pending') ...[
            Icon(Icons.support_agent, color: color, size: 11),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 3),
            Icon(Icons.info_outline, color: color, size: 11),
          ],
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return chip;
    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(20),
      child: chip,
    );
  }
}

class _StatusCircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool filled;
  final VoidCallback onTap;

  const _StatusCircleButton({
    required this.icon,
    required this.color,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color.withValues(alpha: 0.2) : Colors.transparent,
            border: Border.all(color: color, width: 1.5),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
      ),
    );
  }
}

/// A detail line (category, payment) that opens its editor when tapped,
/// with no pencil, so the screen stays clean. While the editor is open a
/// small check shows where to tap to close it.
class _TapToEditRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool editing;
  final VoidCallback onTap;

  const _TapToEditRow({
    required this.icon,
    required this.text,
    required this.editing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      hint: editing ? "Close" : "Edit",
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Expanded(
              child: _InfoLine(icon: icon, text: text),
            ),
            if (editing) const Icon(Icons.check, color: _accent, size: 18),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 16),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
