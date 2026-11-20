import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart' show monthNames;
import '../../../core/utils/friendly_error.dart';
import '../../../core/utils/text_rules.dart';
import '../models/mock_schedule.dart' show formatSqlTime;
import '../models/mock_tournaments.dart';
import '../models/tournament_opponents.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// "Wed, Nov 12 · 5:00 PM".
String _when(TournamentGame game) {
  final d = game.date;
  final day =
      "${_weekdays[d.weekday - 1]}, ${monthNames[d.month - 1].substring(0, 3)} "
      "${d.day}";
  final time = formatSqlTime(game.startTime);
  return time.isEmpty ? day : "$day · $time";
}

/// A tournament's standings and games.
///
/// * The + at the top right adds an opposing team. Those teams are what a
///   game on the schedule picks its opponent from.
/// * STANDINGS: each team with games won by DSA and by them, counted from
///   the final scores (never typed).
/// * GAMES: the tournament's games on the schedule. Tapping a played one
///   enters its final score; whoever scored more won.
class TournamentStandingsScreen extends StatefulWidget {
  final Tournament tournament;

  /// For a family: they see the standings and results, nothing to add or
  /// enter.
  final bool readOnly;

  const TournamentStandingsScreen({
    super.key,
    required this.tournament,
    this.readOnly = false,
  });

  @override
  State<TournamentStandingsScreen> createState() =>
      _TournamentStandingsScreenState();
}

class _TournamentStandingsScreenState extends State<TournamentStandingsScreen> {
  List<TournamentOpponent>? _opponents;
  List<TournamentGame>? _games;
  String? _loadError;

  String get _tournamentId => widget.tournament.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final opponents = loadOpponents(_tournamentId);
      final games = loadGames(_tournamentId);
      final loadedOpponents = await opponents;
      final loadedGames = await games;
      if (!mounted) return;
      setState(() {
        _opponents = loadedOpponents;
        _games = loadedGames;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = friendlyError(e));
    }
  }

  /// Just the standings, after a result changes them.
  Future<void> _reloadStandings() async {
    try {
      final opponents = await loadOpponents(_tournamentId);
      if (mounted) setState(() => _opponents = opponents);
    } catch (_) {
      // Pulling down to refresh picks it up.
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _addOpponent() async {
    final opponents = _opponents;
    if (opponents == null) return;
    final added = await showDialog<TournamentOpponent>(
      context: context,
      builder: (_) => _OpponentNameDialog(
        tournamentId: _tournamentId,
        taken: [for (final o in opponents) o.name],
      ),
    );
    if (added == null || !mounted) return;
    setState(() => _opponents = [...?_opponents, added]);
    _say("${added.name} added");
  }

  Future<void> _openGame(TournamentGame game) async {
    if (game.teamName == null) {
      _say(
        "Pick who this game is against first: edit the game on the "
        "Schedule.",
      );
      return;
    }
    if (game.upcoming) {
      _say("This game hasn't been played yet.");
      return;
    }
    final saved = await showDialog<TournamentGame>(
      context: context,
      builder: (_) => _ResultDialog(tournamentId: _tournamentId, game: game),
    );
    if (saved == null || !mounted) return;
    setState(() {
      _games = [
        for (final g in _games ?? const <TournamentGame>[])
          g.id == saved.id ? saved : g,
      ];
    });
    final team = saved.teamName ?? "";
    _say(
      !saved.hasResult
          ? "Result cleared"
          : saved.dsaWon
          ? "Saved: DSA won ${saved.dsaScore} - ${saved.opponentScore}"
          : "Saved: $team won ${saved.opponentScore} - ${saved.dsaScore}",
    );
    _reloadStandings();
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    ),
  );

  Widget _note(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final opponents = _opponents;
    final games = _games;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          children: [
            const Text(
              "STANDINGS",
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              widget.tournament.name.toUpperCase(),
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (!widget.readOnly) ...[
            IconButton(
              tooltip: "Add opponent",
              onPressed: opponents == null ? null : _addOpponent,
              icon: const Icon(Icons.add, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: opponents == null || games == null
          ? Center(
              child: _loadError == null
                  ? const CircularProgressIndicator(color: _accent)
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _loadError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _load,
                            child: const Text(
                              "TRY AGAIN",
                              style: TextStyle(color: _accent),
                            ),
                          ),
                        ],
                      ),
                    ),
            )
          : RefreshIndicator(
              color: _accent,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _header("STANDINGS"),
                  if (opponents.isEmpty)
                    _note(
                      widget.readOnly
                          ? "No standings yet. They show here once the "
                                "academy adds the teams DSA plays."
                          : "No opponents yet. Tap + at the top right to add "
                                "the teams DSA plays.",
                    )
                  else
                    for (final opponent in opponents) ...[
                      _VersusRow(
                        name: opponent.name,
                        dsa: opponent.hasPlayed ? opponent.dsaWins : null,
                        them: opponent.hasPlayed ? opponent.opponentWins : null,
                      ),
                      const SizedBox(height: 10),
                    ],
                  const SizedBox(height: 14),
                  _header("GAMES (${games.length})"),
                  if (games.isEmpty)
                    _note(
                      widget.readOnly
                          ? "No games scheduled yet."
                          : "No games on the schedule yet. Add them on the "
                                "Schedule as a Tournament session for "
                                "${widget.tournament.name}.",
                    )
                  else
                    for (final game in games) ...[
                      _GameCard(
                        game: game,
                        readOnly: widget.readOnly,
                        onTap: widget.readOnly ? null : () => _openGame(game),
                      ),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
    );
  }
}

const _teamStyle = TextStyle(
  color: Colors.white,
  fontSize: 15,
  fontWeight: FontWeight.bold,
);

/// Green for the side that's ahead, red for the side behind, white when
/// level.
Color _colorFor(int mine, int theirs) => mine == theirs
    ? Colors.white
    : mine > theirs
    ? _accent
    : Colors.redAccent;

/// "DSA  2     vs     1  GRIND": each side's number beside its name, "vs"
/// in the middle. No numbers while [dsa] or [them] is null.
class _VersusRow extends StatelessWidget {
  final String name;
  final int? dsa;
  final int? them;
  final bool boxed;

  const _VersusRow({
    required this.name,
    required this.dsa,
    required this.them,
    this.boxed = true,
  });

  Widget _number(int value, Color color) => Text(
    "$value",
    style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold),
  );

  @override
  Widget build(BuildContext context) {
    final dsa = this.dsa;
    final them = this.them;
    final shown = dsa != null && them != null;
    final row = Row(
      children: [
        Expanded(
          child: Row(
            children: [
              const Text("DSA", style: _teamStyle),
              if (shown) ...[
                const SizedBox(width: 12),
                _number(dsa, _colorFor(dsa, them)),
              ],
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            "vs",
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (shown) ...[
                _number(them, _colorFor(them, dsa)),
                const SizedBox(width: 12),
              ],
              Flexible(
                child: Text(
                  name.toUpperCase(),
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  // Only as wide as its longest line: a name that wraps
                  // would otherwise fill the space and push its number away.
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: _teamStyle,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (!boxed) return row;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: row,
    );
  }
}

/// One scheduled game: when and where on top, the teams and final score in
/// the middle, and where it stands underneath (WON / LOST, or what's
/// still needed).
class _GameCard extends StatelessWidget {
  final TournamentGame game;
  final bool readOnly;

  /// Null for a family: they can't enter results.
  final VoidCallback? onTap;

  const _GameCard({
    required this.game,
    required this.readOnly,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final team = game.teamName;
    final (String status, Color color) = !game.hasResult
        ? team == null
              ? (
                  readOnly
                      ? "OPPONENT TO BE CONFIRMED"
                      : "NO OPPONENT PICKED YET",
                  Colors.white38,
                )
              : game.upcoming
              ? ("UPCOMING", Colors.white38)
              : readOnly
              ? ("RESULT COMING SOON", Colors.white38)
              : ("TAP TO ENTER THE FINAL SCORE", Colors.amber)
        : game.dsaWon
        ? ("WON", _accent)
        : ("LOST", Colors.redAccent);
    final location = game.location?.trim() ?? "";
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                location.isEmpty ? _when(game) : "${_when(game)} · $location",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 10),
              _VersusRow(
                name: team ?? "?",
                dsa: game.dsaScore,
                them: game.opponentScore,
                boxed: false,
              ),
              const SizedBox(height: 8),
              // Centred under the "vs"; WON / LOST a size up so the result
              // reads at a glance.
              SizedBox(
                width: double.infinity,
                child: Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: game.hasResult ? 14 : 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
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

InputDecoration _fieldDecoration(String label, {String? error}) =>
    InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      errorText: error,
      filled: true,
      fillColor: _bg,
      counterText: "",
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
    );

/// Asks for the opposing team's name and saves it. Pops the new opponent.
class _OpponentNameDialog extends StatefulWidget {
  final String tournamentId;
  final List<String> taken;

  const _OpponentNameDialog({required this.tournamentId, required this.taken});

  @override
  State<_OpponentNameDialog> createState() => _OpponentNameDialogState();
}

class _OpponentNameDialogState extends State<_OpponentNameDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _controller.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) {
      setState(() => _error = "Please enter the team's name");
      return;
    }
    final lower = name.toLowerCase();
    if (widget.taken.any((t) => t.toLowerCase() == lower)) {
      setState(() => _error = "$name is already on the list");
      return;
    }
    setState(() => _saving = true);
    try {
      final added = await addOpponent(widget.tournamentId, name);
      if (mounted) Navigator.pop(context, added);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        "Add opponent",
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: maxTeamNameLength,
        inputFormatters: [noEmoji],
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        style: const TextStyle(color: Colors.white),
        decoration: _fieldDecoration("Opponent team name", error: _error),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text("CANCEL", style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? "ADDING..." : "ADD",
            style: const TextStyle(color: _accent, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

/// A played game's final score. Underneath, it says who won as the scores
/// are typed, and refuses a tie. Pops the saved game.
class _ResultDialog extends StatefulWidget {
  final String tournamentId;
  final TournamentGame game;

  const _ResultDialog({required this.tournamentId, required this.game});

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  late final _dsaController = TextEditingController(
    text: widget.game.dsaScore?.toString() ?? "",
  );
  late final _themController = TextEditingController(
    text: widget.game.opponentScore?.toString() ?? "",
  );
  String? _error;
  bool _saving = false;

  String get _team => widget.game.teamName ?? "";

  @override
  void dispose() {
    _dsaController.dispose();
    _themController.dispose();
    super.dispose();
  }

  Future<void> _send({required int? dsa, required int? them}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await saveGameResult(
        widget.tournamentId,
        widget.game,
        dsaScore: dsa,
        opponentScore: them,
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  void _save() {
    if (_saving) return;
    final dsa = int.tryParse(_dsaController.text.trim());
    final them = int.tryParse(_themController.text.trim());
    if (dsa == null || them == null) {
      setState(() => _error = "Please enter both final scores");
      return;
    }
    if (dsa == them) {
      setState(
        () => _error =
            "A game can't end in a tie. Enter the score after overtime.",
      );
      return;
    }
    _send(dsa: dsa, them: them);
  }

  Widget _scoreField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: "$maxGameScore".length,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => setState(() => _error = null),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.bold,
        ),
        decoration: _fieldDecoration(label),
      );

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final dsa = int.tryParse(_dsaController.text.trim());
    final them = int.tryParse(_themController.text.trim());
    final (String, Color)? winner = dsa == null || them == null || dsa == them
        ? null
        : dsa > them
        ? ("DSA wins", _accent)
        : ("$_team wins", Colors.redAccent);
    return AlertDialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "DSA vs $_team",
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Final score · ${_when(game)}",
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _scoreField("DSA", _dsaController)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                child: Text(
                  "-",
                  style: TextStyle(color: Colors.white54, fontSize: 22),
                ),
              ),
              Expanded(child: _scoreField(_team, _themController)),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            )
          else if (winner != null)
            Text(
              winner.$1.toUpperCase(),
              style: TextStyle(
                color: winner.$2,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
        ],
      ),
      actions: [
        if (game.hasResult)
          TextButton(
            onPressed: _saving ? null : () => _send(dsa: null, them: null),
            child: const Text(
              "CLEAR",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text("CANCEL", style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? "SAVING..." : "SAVE",
            style: const TextStyle(color: _accent, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

/// The opponent field of a tournament game: a pick-list of the teams added
/// on that tournament's Standings screen, not free typing. [value] is what
/// the game has now ("vs. Lakers", or null for none); [onChanged] gets the
/// new one.
class OpponentPickerField extends StatefulWidget {
  final String? tournamentId;
  final String? value;
  final ValueChanged<String?> onChanged;

  const OpponentPickerField({
    super.key,
    required this.tournamentId,
    required this.value,
    required this.onChanged,
  });

  @override
  State<OpponentPickerField> createState() => _OpponentPickerFieldState();
}

class _OpponentPickerFieldState extends State<OpponentPickerField> {
  Future<List<TournamentOpponent>>? _opponents;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(OpponentPickerField old) {
    super.didUpdateWidget(old);
    if (old.tournamentId != widget.tournamentId) _fetch();
  }

  void _fetch() {
    final id = widget.tournamentId;
    _opponents = id == null || id.isEmpty ? null : loadOpponents(id);
  }

  Future<void> _pick() async {
    final future = _opponents;
    if (future == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a tournament first")),
      );
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: FutureBuilder<List<TournamentOpponent>>(
          future: future,
          builder: (context, snapshot) {
            Widget body;
            if (snapshot.hasError) {
              body = _note(friendlyError(snapshot.error!));
            } else if (!snapshot.hasData) {
              body = const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(color: _accent)),
              );
            } else if (snapshot.data!.isEmpty) {
              body = _note(
                "No opponents yet. Add them on this tournament's "
                "Standings screen first (Tournaments > the tournament > "
                "Standings).",
              );
            } else {
              body = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final o in snapshot.data!)
                    _choice(context, opponentLabel(o.name), o.name),
                  if (widget.value != null)
                    _choice(context, "", "No opponent", muted: true),
                ],
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "SELECT OPPONENT",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  body,
                ],
              ),
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    widget.onChanged(picked.isEmpty ? null : picked);
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Text(
      text,
      style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
    ),
  );

  Widget _choice(
    BuildContext context,
    String result,
    String text, {
    bool muted = false,
  }) {
    final selected = !muted && result == widget.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => Navigator.pop(context, result),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _accent : Colors.white12),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: muted ? Colors.white54 : Colors.white,
              fontSize: 14,
              fontWeight: muted ? FontWeight.normal : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final name = value == null ? null : opponentName(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Opponent",
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pick,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.groups_outlined,
                  color: name == null ? Colors.white38 : _accent,
                  size: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name ?? "Select an opponent",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: name == null ? Colors.white38 : Colors.white,
                      fontSize: 14,
                      fontWeight: name == null
                          ? FontWeight.normal
                          : FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.expand_more, color: Colors.white38, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
