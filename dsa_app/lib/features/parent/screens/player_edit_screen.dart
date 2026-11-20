import 'package:flutter/material.dart';

import '../../../core/utils/friendly_error.dart';

import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_schedule.dart';
import '../../admin/models/mock_trainings.dart';
import '../../admin/models/mock_tournaments.dart';
import '../../admin/models/player_awards.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_format.dart' show monthNames;
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/dialog_body.dart';
import '../../../core/services/session.dart';
import '../../../core/utils/jersey_number.dart';
import '../../../core/widgets/jersey_number_picker.dart';
import '../../../core/widgets/jersey_size_picker.dart';
import '../../../core/widgets/nickname_field.dart';
import '../../../core/widgets/profile_photo.dart';
import '../../../core/utils/training_fee.dart' show serverNow;
import '../../../core/utils/text_rules.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

class EditParentPlayer extends StatefulWidget {
  final AdminPlayer player;

  const EditParentPlayer({super.key, required this.player});

  @override
  State<EditParentPlayer> createState() => _EditParentPlayerState();
}

class _EditParentPlayerState extends State<EditParentPlayer> {
  bool _editing = false;
  DateTime? _birthday;

  /// Set once this screen starts closing, so a second back tap can't pop
  /// the screen underneath too.
  bool _leaving = false;
  late final TextEditingController _nameController;
  late final TextEditingController _nicknameController;

  /// Picked from the 0-99 grid, not typed. Null = no number.
  int? _jersey;

  /// What [_jersey] started as, to tell whether it was changed.
  int? _initialJersey;

  /// Another player already wears [_jersey], and the person agreed to it in
  /// the warning window (the admin shares it; a parent's waits for approval).
  bool _jerseyTaken = false;

  /// A number was chosen on the picker this visit.
  bool _jerseyPicked = false;

  bool get _isAdmin => Session.current?.isAdmin ?? false;

  /// Null for a player added before sizes existed, until one is picked.
  String? _jerseySize;

  /// Which list is under the details: ACTIVITY (false) or AWARDS (true).
  bool _showAwards = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.player.name);
    _nicknameController = TextEditingController(
      text: widget.player.nickname ?? '',
    );
    _jerseySize = widget.player.jerseySize;
    // Seeded from the player's own row, not placeholder values. A parent
    // whose request is still waiting sees the number they asked for (it's
    // what they want); going back to the one they wear withdraws it.
    final player = widget.player;
    final shown = !_isAdmin && player.hasPendingNumber
        ? player.jerseyRequest
        : player.jerseyNumber;
    _jersey = jerseyKey(shown);
    _initialJersey = _jersey;
    // Left empty when there isn't one, never guessed: a stand-in date got
    // saved on the way out and moved the child into a different category.
    _birthday = DateTime.tryParse(widget.player.birthday ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  /// Under the number: where a request for a taken number stands.
  String? get _jerseyNote {
    final player = widget.player;
    if (_jerseyPicked) {
      if (!_jerseyTaken) return null;
      return _isAdmin
          ? "Already worn by another player: both will have it"
          : "Already taken: the academy has to approve it";
    }
    final asked = player.jerseyRequest;
    if (player.hasPendingNumber) {
      return _isAdmin
          ? "Family asked for #$asked: see Player Validation"
          : "Waiting for the academy to approve #$asked";
    }
    if (player.hasDeclinedNumber) {
      return "#$asked was not approved. Please choose another number.";
    }
    return null;
  }

  Future<void> _pickJersey() async {
    final pick = await pickJerseyNumber(
      context,
      current: _jersey,
      exceptPlayerId: widget.player.id,
      forAdmin: _isAdmin,
    );
    if (pick == null || !mounted) return;
    setState(() {
      _jersey = pick.number;
      _jerseyTaken = pick.taken;
      _jerseyPicked = true;
    });
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  /// Only the fields this form actually owns are changed — category,
  /// attendance and the monthly counts stay exactly as the admin side left
  /// them, since a parent editing a name must never reset any of that.
  AdminPlayer get _currentPlayer => AdminPlayer(
    id: widget.player.id,
    name: _nameController.text.trim().isEmpty
        ? widget.player.name
        : _nameController.text.trim(),
    nickname: nicknameFrom(_nicknameController),
    categories: widget.player.categories,
    parentName: widget.player.parentName,
    parentPhone: widget.player.parentPhone,
    parentId: widget.player.parentId,
    attendanceRate: widget.player.attendanceRate,
    jerseyNumber: _jersey == null ? '' : jerseyText(_jersey!),
    isApproved: widget.player.isApproved,
    jerseyRequest: widget.player.jerseyRequest,
    jerseyRequestStatus: widget.player.jerseyRequestStatus,
    confirmedTakenNumber: _jerseyTaken,
    jerseySize: _jerseySize,
    birthday: _birthday == null ? null : toSqlDate(_birthday!),
    monthlyPresent: widget.player.monthlyPresent,
    monthlyAbsent: widget.player.monthlyAbsent,
    monthlyExempt: widget.player.monthlyExempt,
  );

  /// Whether anything on the form differs from what's saved.
  bool get _changed {
    final saved = widget.player;
    final current = _currentPlayer;
    return current.name != saved.name ||
        current.nickname != saved.nickname ||
        _jersey != _initialJersey ||
        // Picking again after a "no" saves even the same number: that's
        // how a family clears a declined request.
        (_jerseyPicked && saved.jerseyRequestStatus != null) ||
        current.jerseySize != saved.jerseySize ||
        current.birthday != saved.birthday;
  }

  /// Hands the edited player back only if something changed. Every visit
  /// used to save on the way out, even just opening the profile to look.
  /// Leaving with changes asks first: SAVE, DISCARD, or tap outside to stay
  /// and keep editing. It used to save on the way out without asking, so a
  /// number tapped by mistake was quietly saved.
  Future<void> _goBack() async {
    if (_leaving) return;
    if (!_changed) {
      _leaving = true;
      Navigator.pop(context);
      return;
    }
    final choice = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => const _SaveChangesDialog(),
    );
    if (choice == null || !mounted || _leaving) return; // stay
    _leaving = true;
    Navigator.pop(context, choice ? _currentPlayer : null);
  }

  Future<void> _pickBirthday() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(DateTime.now().year - 10),
      // Players are 3 to 21, the same range the server accepts.
      firstDate: DateTime(DateTime.now().year - 22),
      lastDate: DateTime(DateTime.now().year - 3, DateTime.now().month),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _accent,
              onPrimary: Colors.white,
              surface: _card,
              onSurface: Colors.white,
            ),
            dialogTheme: const DialogThemeData(backgroundColor: _bg),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _birthday = picked);
    }
  }

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

  String _formatDate(DateTime d) =>
      "${_months[d.month - 1]} ${d.day}, ${d.year}";

  int _calculateAge(DateTime birthday) {
    final now = DateTime.now();
    int age = now.year - birthday.year;
    final beforeBirthdayThisYear =
        now.month < birthday.month ||
        (now.month == birthday.month && now.day < birthday.day);
    if (beforeBirthdayThisYear) age--;
    return age;
  }

  /// Take Photo / Choose from Gallery / Remove photo for this child. Saved
  /// straight away (not with the rest of the form), and shown on My
  /// Players, Players and the attendance roster.
  Future<void> _showPhotoOptions() async {
    final url = await changePhoto(
      context,
      kind: 'player',
      id: widget.player.id,
      hasPhoto: widget.player.photoUrl != null,
    );
    if (url == null || !mounted) return;
    setState(() => widget.player.photoUrl = url.isEmpty ? null : url);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          elevation: 0,
          leading: IconButton(
            onPressed: _goBack,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          centerTitle: true,
          title: const Text(
            "PLAYER PROFILE",
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          actions: [
            IconButton(
              onPressed: _toggleEditing,
              icon: Icon(
                _editing ? Icons.check : Icons.edit,
                color: _accent,
                size: 20,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ProfilePhoto(url: widget.player.photoUrl, radius: 40),
                        Positioned(
                          bottom: -2,
                          left: -2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: _bg, width: 2),
                            ),
                            child: Text(
                              _jersey == null
                                  ? "#--"
                                  : "#${jerseyText(_jersey!)}",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: -2,
                          right: -2,
                          child: GestureDetector(
                            onTap: _showPhotoOptions,
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: _accent,
                                shape: BoxShape.circle,
                                border: Border.all(color: _bg, width: 2),
                              ),
                              child: const Icon(
                                Icons.add_a_photo,
                                color: Colors.white,
                                size: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _editing
                          ? _HeaderField(
                              controller: _nameController,
                              hint: "Player name",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : Text(
                              _nameController.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 6),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      // The academy sets it; a family sees it once it's
                      // there.
                      if (_isAdmin ||
                          nicknameFrom(_nicknameController) != null) ...[
                        _InfoRow(
                          icon: Icons.badge_outlined,
                          label: "Nickname",
                          value: nicknameFrom(_nicknameController) ?? "None",
                          editor: _editing && _isAdmin
                              ? NicknameField(controller: _nicknameController)
                              : null,
                        ),
                        const SizedBox(height: 16),
                      ],
                      _InfoRow(
                        icon: Icons.cake_outlined,
                        label: "Birthday",
                        value: _birthday == null
                            ? "Not set"
                            : _formatDate(_birthday!),
                        onTap: _pickBirthday,
                        editing: _editing,
                        topLabel: "Age",
                        topValue: _birthday == null
                            ? "—"
                            : "${_calculateAge(_birthday!)} yrs",
                      ),
                      const SizedBox(height: 16),
                      _InfoRow(
                        icon: Icons.numbers,
                        label: "Jersey Number",
                        value: _jersey == null
                            ? "None"
                            : "#${jerseyText(_jersey!)}",
                        subvalue: _jerseyNote,
                        editor: _editing
                            ? JerseyNumberField(
                                value: _jersey,
                                onTap: _pickJersey,
                              )
                            : null,
                      ),
                      const SizedBox(height: 16),
                      _InfoRow(
                        icon: Icons.checkroom_outlined,
                        label: "Jersey Size",
                        value: _jerseySize ?? "Not set",
                        editor: _editing
                            ? JerseySizePicker(
                                value: _jerseySize,
                                onChanged: (size) =>
                                    setState(() => _jerseySize = size),
                              )
                            : null,
                      ),
                      const SizedBox(height: 16),
                      // The guardian on the player's own record, not a
                      // global — this is the players.parent_id link.
                      _InfoRow(
                        icon: Icons.person_outline,
                        label: "Parent / Guardian",
                        value: widget.player.parentName,
                        subvalue: widget.player.parentPhone,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Not a player until the academy approves their number: no
              // trainings, tournaments or awards to show yet.
              if (!widget.player.isApproved)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _WaitingForApproval(
                        declined: widget.player.hasDeclinedNumber,
                        number: widget.player.jerseyRequest,
                      ),
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      _SectionTab(
                        label: "ACTIVITY",
                        selected: !_showAwards,
                        onTap: () => setState(() => _showAwards = false),
                      ),
                      const SizedBox(width: 20),
                      _SectionTab(
                        label: "AWARDS",
                        selected: _showAwards,
                        onTap: () => setState(() => _showAwards = true),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                Expanded(
                  child: _showAwards
                      ? _AwardsTab(player: widget.player)
                      : _ActivityTab(player: widget.player),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextStyle style;

  const _HeaderField({
    required this.controller,
    required this.hint,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      inputFormatters: [personNameChars],
      style: style,
      cursorColor: _accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: _card,
        hintText: hint,
        hintStyle: style.copyWith(color: Colors.white38),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _accent, width: 1.5),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;
  final bool editing;
  final String? subvalue;
  final String? topLabel;
  final String? topValue;

  /// Shown instead of the value when set (the jersey size chips).
  final Widget? editor;

  const _InfoRow({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.editing = false,
    this.subvalue,
    this.topLabel,
    this.topValue,
    this.editor,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDateEditable = editing && onTap != null;
    final valueStyle = const TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white54, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (topLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    "$topLabel: $topValue",
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 3),
              if (editor != null)
                Padding(padding: const EdgeInsets.only(top: 3), child: editor!)
              else if (isDateEditable)
                InkWell(
                  onTap: onTap,
                  child: Row(
                    children: [
                      Text(value ?? "", style: valueStyle),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.calendar_today,
                        color: _accent,
                        size: 13,
                      ),
                    ],
                  ),
                )
              else
                Text(value ?? "", style: valueStyle),
              if (subvalue != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subvalue!,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Save changes?" when leaving the profile after editing. Pops true for
/// SAVE, false for DISCARD; tapping outside pops null (stay on the page).
class _SaveChangesDialog extends StatelessWidget {
  const _SaveChangesDialog();

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
            const Text(
              "Save changes?",
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "You changed this player's details. Save them, or discard "
              "the changes?",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "DISCARD",
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      "SAVE",
                      style: TextStyle(fontWeight: FontWeight.bold),
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

/// Shown instead of Activity and Awards for a child whose number is waiting
/// for (or was refused by) the academy.
class _WaitingForApproval extends StatelessWidget {
  final bool declined;
  final String? number;

  const _WaitingForApproval({required this.declined, required this.number});

  @override
  Widget build(BuildContext context) {
    final color = declined ? Colors.redAccent : Colors.amber;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            declined ? Icons.error_outline : Icons.hourglass_top_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              declined
                  ? "The academy didn't approve jersey #$number. Tap the edit "
                        "icon, choose another number, then go back and tap SAVE."
                  : "Jersey #$number is already worn by another player, so "
                        "the academy has to approve it. This player will be "
                        "added once it's approved.",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityEntry {
  final IconData icon;
  final String title;
  final String subtitle;

  const _ActivityEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}

class _ActivityTab extends StatefulWidget {
  final AdminPlayer player;

  const _ActivityTab({required this.player});

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  // The startup warm-up never loads tournaments, and trainings may be
  // stale, so fetch both fresh rather than trusting whatever's cached.
  Future<void> _refresh() async {
    await Future.wait([loadTrainings(), loadTournaments(), loadSchedule()]);
    if (mounted) setState(() => _loading = false);
  }

  /// What this player is currently in, not when — the batch's category
  /// (shown at Home / Schedule already) and any tournament they've been
  /// entered into.
  List<_ActivityEntry> get _entries {
    final player = widget.player;
    final today = dateOnly(serverNow());
    bool stillAhead(ScheduledSession s) => !dateOnly(s.date).isBefore(today);
    // A training they're actually on, with a session today or later. One
    // that has finished, or been deleted (its upcoming sessions are
    // cancelled with it), drops off.
    final trainings = mockTrainings.where(
      (t) => mockSchedule.any(
        (s) =>
            s.trainingId == t.id &&
            s.playerIds.contains(player.id) &&
            stillAhead(s),
      ),
    );
    // A tournament still to be played: a deleted one never comes back from
    // the server, and one whose games are all over has finished. One with
    // no games scheduled yet is still to come. Not one the family declined.
    final tournaments = mockTournaments.where((t) {
      if (!t.playerIds.contains(player.id)) return false;
      if (t.consentOf(player.id) == 'declined') return false;
      final games = mockSchedule.where((s) => s.tournamentId == t.id);
      return games.isEmpty || games.any(stillAhead);
    });
    return [
      ...trainings.map(
        (t) => _ActivityEntry(
          icon: Icons.sports_basketball,
          title: "Training",
          subtitle: t.categoryLabel,
        ),
      ),
      ...tournaments.map(
        (t) => _ActivityEntry(
          icon: Icons.emoji_events_outlined,
          title: t.name,
          subtitle: t.category,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    final entries = _entries;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          "No ongoing or upcoming activity.",
          style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(entry.icon, color: Colors.white54, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// ACTIVITY / AWARDS above the list: tap one to switch. The chosen one is
/// white with a green underline.
class _SectionTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SectionTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.45),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 2,
              width: 28,
              color: selected ? _accent : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Sep 12, 2026", the way the profile writes the birthday.
String _awardDay(String isoDate) {
  final date = DateTime.tryParse(isoDate);
  if (date == null) return isoDate;
  return "${monthNames[date.month - 1].substring(0, 3)} ${date.day}, "
      "${date.year}";
}

/// The player's awards, newest first. Anyone who can see the player adds
/// one with ADD AWARD (the admin, or the child's parent). Tapping one opens
/// it for editing when the one signed in may change it (the admin: any; a
/// parent: the ones they added), otherwise to read it in full.
class _AwardsTab extends StatefulWidget {
  final AdminPlayer player;

  const _AwardsTab({required this.player});

  @override
  State<_AwardsTab> createState() => _AwardsTabState();
}

class _AwardsTabState extends State<_AwardsTab> {
  List<PlayerAward>? _awards;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final awards = await loadAwards(widget.player.id);
      if (mounted) {
        setState(() {
          _awards = awards;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyError(e));
      }
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    final edit = await showDialog<_AwardEdit>(
      context: context,
      builder: (_) => _AwardDialog(playerName: widget.player.name),
    );
    if (edit == null) return;
    try {
      await addAward(
        widget.player.id,
        title: edit.title,
        league: edit.league,
        category: edit.category,
        date: edit.date,
      );
      await _load();
      _show("Award added");
    } catch (e) {
      _show(friendlyError(e));
    }
  }

  Future<void> _open(PlayerAward award) async {
    if (!award.canEdit) {
      await showDialog<void>(
        context: context,
        builder: (_) => _AwardDetails(award: award),
      );
      return;
    }
    final edit = await showDialog<_AwardEdit>(
      context: context,
      builder: (_) =>
          _AwardDialog(playerName: widget.player.name, award: award),
    );
    if (edit == null) return;
    try {
      if (edit.delete) {
        await deleteAward(award);
        _show("Award deleted");
      } else {
        await updateAward(
          award,
          title: edit.title,
          league: edit.league,
          category: edit.category,
          date: edit.date,
        );
        _show("Award saved");
      }
      await _load();
    } catch (e) {
      _show(friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final awards = _awards;
    if (awards == null && _error == null) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    final muted = TextStyle(color: Colors.white.withValues(alpha: 0.4));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add, color: _accent, size: 18),
              label: const Text(
                "ADD AWARD",
                style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _accent, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                )
              : awards!.isEmpty
              ? Center(
                  child: Text(
                    "No awards yet. Tap ADD AWARD to add one.",
                    style: muted,
                  ),
                )
              : RefreshIndicator(
                  color: _accent,
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: awards.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _AwardCard(
                      award: awards[index],
                      editable: awards[index].canEdit,
                      onTap: () => _open(awards[index]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _AwardCard extends StatelessWidget {
  final PlayerAward award;
  final bool editable;
  final VoidCallback onTap;

  const _AwardCard({
    required this.award,
    required this.editable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final league = award.league;
    final category = award.category;
    // "League: Jazzville · B2014", whichever of the two it has.
    final detail = [
      if (league != null && league.isNotEmpty) "League: $league",
      ?category,
    ].join(" · ");
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.emoji_events, color: Colors.amber, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      award.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _awardDay(award.date),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                editable ? Icons.edit_outlined : Icons.chevron_right,
                color: Colors.white38,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the award window hands back: the fields, or [delete].
class _AwardEdit {
  final String title;
  final String? league;
  final String? category;
  final String date;
  final bool delete;

  const _AwardEdit({
    this.title = '',
    this.league,
    this.category,
    this.date = '',
    this.delete = false,
  });
}

/// Add an award ([award] null), or edit / delete one: the admin any, a
/// parent the ones they added.
class _AwardDialog extends StatefulWidget {
  final String playerName;
  final PlayerAward? award;

  const _AwardDialog({required this.playerName, this.award});

  @override
  State<_AwardDialog> createState() => _AwardDialogState();
}

class _AwardDialogState extends State<_AwardDialog> {
  late final TextEditingController _title;
  late final TextEditingController _league;
  DateTime? _date;
  String? _error;

  /// No category buttons any more (families type it into League); an
  /// older award keeps whatever category it was saved with.
  String? _category;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.award?.title ?? '');
    _league = TextEditingController(text: widget.award?.league ?? '');
    final existing = widget.award;
    _date = existing == null ? null : DateTime.tryParse(existing.date);
    _category = existing?.category;
  }

  @override
  void dispose() {
    _title.dispose();
    _league.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = serverNow();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? today,
      firstDate: DateTime(2015),
      // An award is for something that already happened.
      lastDate: today,
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            onPrimary: Colors.white,
            surface: _card,
            onSurface: Colors.white,
          ),
          dialogTheme: const DialogThemeData(backgroundColor: _bg),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _error = null;
      });
    }
  }

  void _save() {
    final title = _title.text.trim();
    final date = _date;
    if (title.isEmpty) {
      setState(() => _error = "Enter the award title");
      return;
    }
    if (date == null) {
      setState(() => _error = "Choose the date of the award");
      return;
    }
    final league = _league.text.trim();
    Navigator.pop(
      context,
      _AwardEdit(
        title: title,
        league: league.isEmpty ? null : league,
        category: _category,
        date: toSqlDate(date),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showConfirmDialog(
      context,
      title: "Delete this award?",
      message:
          "\"${widget.award!.title}\" will be removed from "
          "${widget.playerName}'s profile.",
      confirmLabel: "DELETE",
      confirmColor: Colors.redAccent,
    );
    if (confirmed && mounted) {
      Navigator.pop(context, const _AwardEdit(delete: true));
    }
  }

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: _bg,
    counterStyle: const TextStyle(color: Colors.white38, fontSize: 11),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _accent, width: 1.5),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final editing = widget.award != null;
    final date = _date;
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              editing ? "Edit award" : "Add award",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.playerName,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            _label("Title"),
            TextField(
              controller: _title,
              maxLength: 120,
              inputFormatters: [noEmoji],
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Colors.white),
              cursorColor: _accent,
              decoration: _decoration("e.g. MVP, Victory Cup 2026"),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 4),
            _label("League"),
            TextField(
              controller: _league,
              maxLength: 120,
              inputFormatters: [noEmoji],
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white),
              cursorColor: _accent,
              decoration: _decoration("e.g. Dubai Youth League"),
            ),
            const SizedBox(height: 4),
            _label("Date"),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        date == null
                            ? "Tap to choose"
                            : _awardDay(toSqlDate(date)),
                        style: TextStyle(
                          color: date == null ? Colors.white38 : Colors.white,
                        ),
                      ),
                    ),
                    const Icon(Icons.calendar_today, color: _accent, size: 16),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (editing)
                  TextButton(
                    onPressed: _delete,
                    child: const Text(
                      "DELETE",
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "CANCEL",
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    "SAVE",
                    style: TextStyle(fontWeight: FontWeight.bold),
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

/// Reading one award in full: a parent opening one the academy gave.
class _AwardDetails extends StatelessWidget {
  final PlayerAward award;

  const _AwardDetails({required this.award});

  @override
  Widget build(BuildContext context) {
    final league = award.league;
    return Dialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: DialogBody(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emoji_events, color: Colors.amber, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    award.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _awardDay(award.date),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            if (league != null && league.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                "League: $league",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
            if (award.category != null) ...[
              const SizedBox(height: 6),
              Text(
                "Category: ${award.category}",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
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
