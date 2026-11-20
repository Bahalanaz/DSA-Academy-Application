import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../admin/models/admin_player.dart';
import '../../admin/models/mock_schedule.dart' show toSqlDate;
import '../models/mock_parent_players.dart';
import '../../../core/services/session.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/utils/jersey_number.dart';
import '../../../core/widgets/jersey_number_picker.dart';
import '../../../core/widgets/jersey_size_picker.dart';
import '../../../core/widgets/nickname_field.dart';
import '../../../core/widgets/profile_photo.dart';
import '../../../core/utils/text_rules.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// What the add-player form hands back: the new player, and the photo
/// picked for them (uploaded as soon as they exist).
/// [allowTaken]: the parent agreed to a number another player already
/// wears, so the child waits for the academy's approval.
typedef NewPlayer = ({AdminPlayer player, Uint8List? photo, bool allowTaken});

class Profile extends StatefulWidget {
  final bool isNew;

  const Profile({super.key, this.isNew = false});

  @override
  State<Profile> createState() => _ProfileState();
}

class _ProfileState extends State<Profile> {
  late bool _editing;
  // No default. The birthday decides the player's category (born 2013 =
  // B2013), and a pre-filled date that a parent didn't change silently put
  // their child in the wrong group.
  DateTime? _birthday;

  /// Set once the form has been handed back, so a double tap on the tick
  /// can't pop a second time and close the screen underneath as well.
  bool _saved = false;

  /// The photo picked on the form. The child doesn't exist on the server
  /// yet, so it's sent once they're added.
  Uint8List? _photo;

  /// The child's given name and last name, in one field ("Given name +
  /// Last name"); a single word is asked to add the last name.
  late final TextEditingController _nameController;

  /// Optional: what the team calls them. The academy can change it later.
  final _nicknameController = TextEditingController();

  /// Picked from the 0-99 grid, not typed. Null = no number.
  int? _jersey;

  /// Another player already wears [_jersey], and the parent agreed to ask
  /// the academy for it anyway.
  bool _jerseyTaken = false;

  /// Shirt size (3XS to 3XL, or 9-10 / 11-12). No default, like the birthday: a guessed size
  /// that nobody changed would order the wrong shirt.
  String? _jerseySize;

  @override
  void initState() {
    super.initState();
    _editing = widget.isNew;
    _nameController = TextEditingController(
      text: widget.isNew ? "" : "KHEANNE M.",
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _pickJersey() async {
    final pick = await pickJerseyNumber(
      context,
      current: _jersey,
      forAdmin: false,
    );
    if (pick == null || !mounted) return;
    setState(() {
      _jersey = pick.number;
      _jerseyTaken = pick.taken;
    });
  }

  void _toggleEditing() {
    setState(() => _editing = !_editing);
  }

  Future<void> _saveNewPlayer() async {
    if (_saved) return;
    final name = _nameController.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final jersey = _jersey == null ? '' : jerseyText(_jersey!);
    final birthday = _birthday;
    final nickname = nicknameFrom(_nicknameController);
    String? problem;
    if (name.isEmpty) {
      problem = "Please enter the player's given name and last name";
    } else if (!name.contains(' ')) {
      // One word is a first name only: the last name goes on every roster.
      problem = "Please add the player's last name too, like \"Juan Cruz\"";
    } else if (name.length > 120) {
      problem = "Player name must be 120 characters or fewer";
    } else if (birthday == null) {
      problem =
          "Please choose the player's birthday — it decides their category";
    } else if (_jerseySize == null) {
      problem = "Please choose the player's jersey size";
    }
    if (problem != null || birthday == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem ?? '')));
      return;
    }
    if (!Session.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please log in again to add a player")),
      );
      return;
    }
    // A last look before the child is registered: the birthday sets their
    // category, and a typo in the name goes on every roster and bill.
    // "Go back" keeps everything typed so far.
    final confirmed = await showConfirmDialog(
      context,
      title: "Add $name?",
      message:
          "Name: $name\n"
          "${nickname == null ? '' : 'Nickname: $nickname\n'}"
          "Birthday: ${_formatDate(birthday)}\n"
          "Jersey number: ${jersey.isEmpty ? 'none' : '#$jersey'}"
          "${_jerseyTaken ? ' (already taken, needs the academy\'s approval)' : ''}\n"
          "Jersey size: $_jerseySize\n\n"
          "Please check these are correct. $name will be added to your "
          "account and the academy will see them.",
      confirmLabel: "YES, ADD PLAYER",
      cancelLabel: "GO BACK",
    );
    if (!confirmed || !mounted || _saved) return;
    _saved = true;
    Navigator.pop<NewPlayer>(context, (
      photo: _photo,
      allowTaken: _jerseyTaken,
      player: AdminPlayer(
        name: name,
        nickname: nickname,
        // Category is assigned by the admin (via Trainings), not the parent.
        categories: [],
        // The guardian is whoever is signed in — this is the link the
        // database models as players.parent_id.
        parentName: currentParentName,
        parentPhone: currentParentPhone,
        parentId: Session.requireUserId,
        jerseyNumber: jersey,
        jerseySize: _jerseySize,
        birthday: toSqlDate(birthday),
        // A brand-new player has no attendance history yet.
        attendanceRate: 0,
      ),
    ));
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

  /// Take Photo / Choose from Gallery / Remove photo. Kept on the form and
  /// sent once the child is added.
  Future<void> _showPhotoOptions() async {
    final choice = await showPhotoMenu(context, hasPhoto: _photo != null);
    if (choice == null || !mounted) return;
    if (choice == PhotoChoice.remove) {
      setState(() => _photo = null);
      return;
    }
    try {
      final bytes = await pickPhoto(choice);
      if (bytes != null && mounted) setState(() => _photo = bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't open the camera or photos. Please allow access in the "
            "phone's settings.",
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        centerTitle: true,
        title: Text(
          widget.isNew ? "ADD PLAYER" : "PLAYER PROFILE",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          IconButton(
            onPressed: widget.isNew ? _saveNewPlayer : _toggleEditing,
            icon: Icon(
              widget.isNew
                  ? Icons.check
                  : (_editing ? Icons.check : Icons.edit),
              color: _accent,
              size: 20,
            ),
          ),
        ],
      ),
      // Scrolls when the form is taller than the screen (a small phone, or
      // the keyboard open); otherwise the activity area fills what's left.
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
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
                            ProfilePhoto(preview: _photo, radius: 40),
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
                                  hint: "Given name + Last name",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
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
                          _InfoRow(
                            icon: Icons.badge_outlined,
                            label: "Nickname (optional)",
                            value: nicknameFrom(_nicknameController) ?? "None",
                            editor: _editing
                                ? NicknameField(controller: _nicknameController)
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _InfoRow(
                            icon: Icons.cake_outlined,
                            label: "Birthday",
                            value: _birthday == null
                                ? "Tap to choose"
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
                            subvalue: _jerseyTaken
                                ? "Already taken: the academy has to approve it"
                                : null,
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
                            value: _jerseySize ?? "—",
                            editor: _editing
                                ? JerseySizePicker(
                                    value: _jerseySize,
                                    onChanged: (size) =>
                                        setState(() => _jerseySize = size),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _InfoRow(
                            icon: Icons.person_outline,
                            label: "Parent / Guardian",
                            value: currentParentName,
                            subvalue: currentParentPhone,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Text(
                          "ACTIVITY",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  const Expanded(child: _ActivityTab()),
                ],
              ),
            ),
          ],
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

class _ActivityEntry {
  final IconData icon;
  final String title;
  final String date;
  final String status;
  final bool isUpcoming;

  const _ActivityEntry({
    required this.icon,
    required this.title,
    required this.date,
    required this.status,
    required this.isUpcoming,
  });
}

class _ActivityTab extends StatelessWidget {
  const _ActivityTab();

  // A player who doesn't exist yet can't have any activity — this list
  // only fills in on the edit screen, once there's a real roster row.
  static const _entries = <_ActivityEntry>[];

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          "No ongoing or upcoming activity.",
          style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _entries[index];
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
                      entry.date,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: entry.isUpcoming
                      ? Colors.amber.withValues(alpha: 0.15)
                      : _accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: entry.isUpcoming ? Colors.amber : _accent,
                    width: 1,
                  ),
                ),
                child: Text(
                  entry.status,
                  style: TextStyle(
                    color: entry.isUpcoming ? Colors.amber : _accent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
