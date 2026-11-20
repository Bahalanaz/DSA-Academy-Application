import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/utils/training_fee.dart';
import '../../../core/widgets/pressable.dart';

import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/text_rules.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/fade_slide_in.dart';
import '../../../core/services/live_refresh.dart';
import '../models/mock_categories.dart';
import '../models/mock_roster.dart';
import '../models/mock_schedule.dart';
import '../models/mock_trainings.dart';
import 'add_players_screen.dart';
import 'admin_attendance_screen.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// training_programs.name is VARCHAR(120).
const _maxNameLength = 120;

/// Training programs the admin has set up. Tapping one shows the
/// sessions scheduled for it (from the Schedule screen, linked by id —
/// not by matching category text), and tapping a session opens
/// attendance for the players in that category.
class AdminTrainings extends StatefulWidget {
  const AdminTrainings({super.key});

  @override
  State<AdminTrainings> createState() => _AdminTrainingsState();
}

class _AdminTrainingsState extends State<AdminTrainings>
    with LiveRefreshing<AdminTrainings> {
  @override
  Future<void> reloadQuietly() async {
    await loadTrainings();
    await loadSchedule();
  }

  bool _loading = true;
  bool _deleteMode = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await loadTrainings();
      await loadSchedule();
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

  int _sessionCount(TrainingProgram training) =>
      mockSchedule.where((s) => s.trainingId == training.id).length;

  /// Two programs can share categories now that they have names (a
  /// shooting clinic and a conditioning block for the same age group), so
  /// only the same categories under the same name counts as a duplicate.
  bool _isDuplicate(List<String> categories, String? name) {
    final selected = categories.toSet();
    final candidate = TrainingProgram(
      id: '',
      categories: categories,
      name: name,
    ).displayName.toLowerCase();
    return mockTrainings.any(
      (t) =>
          selected.length == t.categories.length &&
          selected.containsAll(t.categories) &&
          t.displayName.toLowerCase() == candidate,
    );
  }

  void _compose() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ComposeTrainingSheet(
        categories: mockCategories,
        isDuplicate: _isDuplicate,
        onCreate: (categories, name) async {
          try {
            await addTraining(categories, name: name);
            if (mounted) setState(() {});
          } catch (e) {
            _showError(e);
          }
        },
      ),
    );
  }

  void _openTraining(TrainingProgram training) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrainingSessionsScreen(training: training),
      ),
    );
  }

  void _toggleDeleteMode() {
    setState(() => _deleteMode = !_deleteMode);
  }

  /// Spells out what deleting will actually do before it happens, using the
  /// same split the server applies: sessions after today are cancelled,
  /// sessions up to today are kept (so fees already earned still stand).
  Future<void> _confirmDelete(TrainingProgram training) async {
    if (_deleting) return;

    final now = serverNow();
    final today = DateTime(now.year, now.month, now.day);
    final sessions = mockSchedule.where((s) => s.trainingId == training.id);
    final upcoming = sessions
        .where(
          (s) => DateTime(s.date.year, s.date.month, s.date.day).isAfter(today),
        )
        .length;
    final kept = sessions.length - upcoming;

    String plural(int n, String word) => "$n $word${n == 1 ? '' : 's'}";
    final details = <String>[
      if (sessions.isEmpty) "It has no sessions scheduled.",
      if (upcoming > 0)
        "${plural(upcoming, 'upcoming session')} will be cancelled and "
            "removed from the schedule. Players only booked on those won't "
            "be charged for them, and their families get one message "
            "listing every cancelled date.",
      if (kept > 0)
        "${plural(kept, 'session')} up to today will be kept with their "
            "attendance, so fees those players already earned still stand.",
    ];

    final confirmed = await showConfirmDialog(
      context,
      title: "Delete this training?",
      message:
          "This removes \"${training.displayName}\" from Trainings.\n\n"
          "${details.join('\n\n')}",
      confirmLabel: "DELETE",
      confirmColor: Colors.redAccent,
    );
    if (!confirmed) return;

    setState(() => _deleting = true);
    try {
      final result = await removeTraining(training);
      // Cancelled sessions have to leave the shared schedule, and each
      // player's scheduled count (what starts their fee) may have dropped.
      await loadSchedule();
      await loadPlayers();
      if (!mounted) return;
      setState(() {
        if (mockTrainings.isEmpty) _deleteMode = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.cancelled > 0
                ? "Training deleted · ${plural(result.cancelled, 'upcoming session')} cancelled"
                : "Training deleted",
          ),
        ),
      );
    } catch (e) {
      _showError(e);
      await _refresh();
    } finally {
      if (mounted) setState(() => _deleting = false);
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
                      _deleteMode ? "TAP A TRAINING TO DELETE" : "TRAININGS",
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: mockTrainings.isEmpty && !_deleteMode
                        ? null
                        : _toggleDeleteMode,
                    tooltip: "Delete a training",
                    icon: Icon(
                      _deleteMode ? Icons.close : Icons.delete_outline,
                      color: _deleteMode
                          ? Colors.redAccent
                          : mockTrainings.isEmpty
                          ? Colors.white24
                          : Colors.white,
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
                  : mockTrainings.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.sports_basketball_outlined,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 44,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "No trainings yet.\nTap + to add one.",
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
                      itemCount: mockTrainings.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final training = mockTrainings[index];
                        return FadeSlideIn(
                          index: index,
                          child: _TrainingTile(
                            training: training,
                            sessionCount: _sessionCount(training),
                            deleteMode: _deleteMode,
                            onTap: () => _deleteMode
                                ? _confirmDelete(training)
                                : _openTraining(training),
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

class _TrainingTile extends StatelessWidget {
  final TrainingProgram training;
  final int sessionCount;
  final bool deleteMode;
  final VoidCallback onTap;

  const _TrainingTile({
    required this.training,
    required this.sessionCount,
    this.deleteMode = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A custom name says nothing about who trains, so the categories move
    // into the subtitle; an auto-named one already has them in the title.
    final hasCustomName = (training.name?.trim() ?? '').isNotEmpty;
    final sessions =
        "$sessionCount session${sessionCount == 1 ? '' : 's'} scheduled";

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
                      ? Colors.redAccent.withValues(alpha: 0.12)
                      : Colors.white12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  deleteMode
                      ? Icons.delete_outline
                      : Icons.sports_basketball_outlined,
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
                      training.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hasCustomName
                          ? "${training.categoryLabel} · $sessions"
                          : sessions,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
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

class _ComposeTrainingSheet extends StatefulWidget {
  final List<String> categories;
  final bool Function(List<String> categories, String? name) isDuplicate;
  final void Function(List<String> categories, String? name) onCreate;

  const _ComposeTrainingSheet({
    required this.categories,
    required this.isDuplicate,
    required this.onCreate,
  });

  @override
  State<_ComposeTrainingSheet> createState() => _ComposeTrainingSheetState();
}

class _ComposeTrainingSheetState extends State<_ComposeTrainingSheet> {
  final Set<String> _selected = {};
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  List<String> get _orderedSelection =>
      widget.categories.where(_selected.contains).toList();

  void _toggleCategory(String c) {
    setState(() {
      if (_selected.contains(c)) {
        _selected.remove(c);
      } else {
        _selected.add(c);
      }
    });
  }

  void _submit() {
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select at least one category")),
      );
      return;
    }
    final categories = _orderedSelection;
    final typed = _nameController.text.trim();
    final name = typed.isEmpty ? null : typed;
    if (widget.isDuplicate(categories, name)) {
      final label = TrainingProgram(
        id: '',
        categories: categories,
        name: name,
      ).displayName;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("\"$label\" already exists for those categories"),
        ),
      );
      return;
    }
    widget.onCreate(categories, name);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final autoName = _selected.isEmpty
        ? null
        : "${_orderedSelection.join(', ')} Training";

    // Scrollable and capped: six categories plus a name field plus the
    // keyboard is more than a short phone can show at once.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: media.viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "NEW TRAINING",
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 16),
            const _SheetLabel("Category"),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: widget.categories.map((c) {
                final isSelected = _selected.contains(c);
                return ChoiceChip(
                  label: Text(c),
                  selected: isSelected,
                  onSelected: (_) => _toggleCategory(c),
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
            const SizedBox(height: 16),
            const _SheetLabel("Training name"),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [
                LengthLimitingTextInputFormatter(_maxNameLength),
                noEmoji,
              ],
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _bg,
                // Blank is allowed: the hint shows exactly what it'll be
                // called instead, so leaving it empty isn't a guess.
                hintText: autoName == null
                    ? "e.g. Juniors Shooting Clinic"
                    : "Leave blank for \"$autoName\"",
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
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
              onSubmitted: (_) => _submit(),
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
                  "CREATE TRAINING",
                  style: TextStyle(
                    color: Colors.white,
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

/// The sessions scheduled for one training program — linked by the
/// session's trainingId, not by matching category text. Tapping a
/// session opens attendance for it; who actually showed up is set per
/// session from the roster screen, since it isn't the same group every time.
class TrainingSessionsScreen extends StatelessWidget {
  final TrainingProgram training;

  const TrainingSessionsScreen({super.key, required this.training});

  List<ScheduledSession> get _sessions {
    final sessions = mockSchedule
        .where((s) => s.trainingId == training.id)
        .toList();
    sessions.sort((a, b) => b.date.compareTo(a.date));
    return sessions;
  }

  /// Picks this training's default players: everyone ticked is put on each
  /// new session of it automatically.
  Future<void> _editDefaults(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final List<int> current;
    try {
      await loadPlayers();
      current = await loadTrainingDefaults(training);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    final picked = await navigator.push<List<int>>(
      MaterialPageRoute(
        builder: (_) => AddPlayersScreen(
          categoryLabel: training.categoryLabel,
          categories: training.categories,
          alreadyAdded: const [],
          defaults: current,
        ),
      ),
    );
    if (picked == null) return;
    try {
      await saveTrainingDefaults(training, picked);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            picked.isEmpty
                ? "${training.displayName} has no default players now."
                : "Saved. ${picked.length} player"
                      "${picked.length == 1 ? ' is' : 's are'} added to every "
                      "new session of ${training.displayName}.",
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        // This training's default players.
        actions: [
          IconButton(
            onPressed: () => _editDefaults(context),
            tooltip: "Default players",
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
          ),
        ],
        centerTitle: true,
        title: Text(
          training.displayName.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      body: SafeArea(
        child: sessions.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    "No sessions scheduled for ${training.displayName} yet.\n"
                    "Add one from the Schedule tab.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: sessions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) => FadeSlideIn(
                  index: index,
                  child: _SessionTile(
                    session: sessions[index],
                    categories: training.categories,
                  ),
                ),
              ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ScheduledSession session;
  final List<String> categories;

  const _SessionTile({required this.session, required this.categories});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AttendanceRosterScreen(
                session: TrainingSession(
                  id: session.id,
                  category: session.category,
                  categories: categories,
                  time: session.displayTime,
                  date: formatAdminDate(session.date),
                  location: session.location,
                  playerNames: session.playerNames,
                  sessionDate: session.date,
                  playerIds: session.playerIds,
                ),
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.event_available_outlined,
                  color: _accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatAdminDate(session.date),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${session.displayTime} · ${session.location}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                    if (needsAttendance(session))
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          "${session.markedCount} of ${session.rosterCount} "
                          "marked — the rest aren't charged for it yet",
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
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
