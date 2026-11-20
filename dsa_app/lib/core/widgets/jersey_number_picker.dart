import 'package:flutter/material.dart';

import '../../features/admin/models/mock_roster.dart'
    show loadTakenJerseyNumbers;
import '../theme/app_colors.dart';
import '../utils/friendly_error.dart';
import '../utils/jersey_number.dart';
import 'confirm_dialog.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// The highest number on the picker.
const maxJerseyNumber = 99;

/// What was chosen: a number (null = no number) and whether another player
/// already wears it — in which case the person has agreed, in the warning
/// window, to send it for the academy's approval (or, for the admin, to
/// share it).
typedef JerseyPick = ({int? number, bool taken, List<String> wornBy});

/// The jersey number row on the add-player and edit-player forms: the
/// chosen number, tapped to open the 00 and 0-99 picker. Not typed any
/// more. [value] is a jersey key (see jersey_number.dart: "00" is
/// [doubleZero]).
class JerseyNumberField extends StatelessWidget {
  final int? value;
  final VoidCallback onTap;

  const JerseyNumberField({
    super.key,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value == null ? "Choose a number" : "#${jerseyText(value!)}",
              style: TextStyle(
                color: value == null ? Colors.white54 : Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.grid_view_rounded, color: _accent, size: 15),
          ],
        ),
      ),
    );
  }
}

/// Opens the 0-99 picker. Numbers other players wear are still shown and
/// can be picked, marked with a dot; picking one asks first ("already given
/// to another player — do you still want to proceed?").
///
/// [current] is the number chosen so far, [exceptPlayerId] the player being
/// edited (their own number isn't "taken"), [forAdmin] changes the warning:
/// the admin's choice is final, a family's waits for the admin.
/// Returns null if closed without choosing.
Future<JerseyPick?> pickJerseyNumber(
  BuildContext context, {
  int? current,
  int? exceptPlayerId,
  required bool forAdmin,
}) {
  return showModalBottomSheet<JerseyPick>(
    context: context,
    backgroundColor: _card,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _JerseyNumberSheet(
      current: current,
      exceptPlayerId: exceptPlayerId,
      forAdmin: forAdmin,
    ),
  );
}

class _JerseyNumberSheet extends StatefulWidget {
  final int? current;
  final int? exceptPlayerId;
  final bool forAdmin;

  const _JerseyNumberSheet({
    required this.current,
    required this.exceptPlayerId,
    required this.forAdmin,
  });

  @override
  State<_JerseyNumberSheet> createState() => _JerseyNumberSheetState();
}

class _JerseyNumberSheetState extends State<_JerseyNumberSheet> {
  Set<int>? _taken;

  /// Who wears each taken number ("carl (B2019)"). The admin only: the
  /// server never sends names to a parent.
  Map<int, List<String>> _holders = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final taken = await loadTakenJerseyNumbers(
        exceptPlayerId: widget.exceptPlayerId,
      );
      if (mounted) {
        setState(() {
          _taken = taken.taken;
          _holders = taken.holders;
        });
      }
    } catch (e) {
      // Still pickable: the server checks again when the player is saved.
      if (mounted) {
        setState(() {
          _taken = {};
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _choose(int? number) async {
    final taken = number != null && (_taken?.contains(number) ?? false);
    if (taken) {
      final wearers = _holders[number] ?? const [];
      final proceed = await showConfirmDialog(
        context,
        title: widget.forAdmin
            ? "Use jersey #${jerseyText(number)}?"
            : "Jersey #${jerseyText(number)} is already taken",
        message: widget.forAdmin
            ? "Jersey #${jerseyText(number)} is already used by:\n"
                  "${wearers.isEmpty ? '• another player' : wearers.map((w) => '• $w').join('\n')}"
                  "\n\nAre you sure you want to use this number?"
            : "This number has already been given to another player. Do you "
                  "still want to proceed?\n\nIf you continue, the academy has "
                  "to approve it first. Until then the player waits for "
                  "approval.",
        confirmLabel: widget.forAdmin ? "PROCEED" : "CONTINUE",
        cancelLabel: widget.forAdmin ? "BACK" : "CANCEL",
      );
      if (!proceed || !mounted) return;
    }
    Navigator.pop<JerseyPick>(context, (
      number: number,
      taken: taken,
      wornBy: number == null ? const <String>[] : _holders[number] ?? const [],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final taken = _taken;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                "CHOOSE JERSEY NUMBER",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.amber,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.forAdmin
                          ? "Taken by another player (can still be chosen)"
                          : "Taken by another player (needs the academy's "
                                "approval)",
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              // A number typed before the picker existed (100, say) isn't on
              // the grid. Closing the picker keeps it.
              if (widget.current != null && widget.current! > maxJerseyNumber)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    "Current number #${widget.current} isn't on this list. "
                    "Close this to keep it, or choose a new one.",
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (taken == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: CircularProgressIndicator(color: _accent),
                  ),
                )
              else
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    // "00" first, then 0 to 99: some players wear 00 or 0,
                    // and they're different shirts.
                    itemCount: maxJerseyNumber + 2,
                    itemBuilder: (context, index) {
                      final number = index == 0 ? doubleZero : index - 1;
                      return _NumberCell(
                        number: number,
                        selected: widget.current == number,
                        taken: taken.contains(number),
                        onTap: () => _choose(number),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: taken == null ? null : () => _choose(null),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: widget.current == null ? _accent : Colors.white24,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text(
                    "NO NUMBER",
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
      ),
    );
  }
}

class _NumberCell extends StatelessWidget {
  final int number;
  final bool selected;
  final bool taken;
  final VoidCallback onTap;

  const _NumberCell({
    required this.number,
    required this.selected,
    required this.taken,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _accent : _bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              jerseyText(number),
              style: TextStyle(
                color: selected
                    ? Colors.white
                    : taken
                    ? Colors.white38
                    : Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (taken)
              Positioned(
                bottom: 6,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : Colors.amber,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
