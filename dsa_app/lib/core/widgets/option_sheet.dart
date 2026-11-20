import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

const _card = AppColors.card;
const _accent = AppColors.accent;

/// A pick-one bottom sheet that can't overflow.
///
/// The old hand-rolled version laid its options out in a plain Column, so
/// it burst its bounds (the yellow-and-black stripes) as soon as there
/// were more options than fit — which happened the moment a sixth category
/// was added. This one scrolls, caps itself at 70% of the screen, keeps
/// the title pinned, and lets long labels wrap instead of clipping. Use it
/// for any "choose one of these" list rather than writing another Column.
Future<String?> showOptionSheet(
  BuildContext context, {
  required String title,
  required List<String> options,
  String? selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: _card,
    // Without this the sheet is capped at half the screen and the content
    // inside it has nowhere to go.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            // Flexible + a scrollable list is what makes this safe at any
            // option count: it takes only the room it needs, then scrolls.
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options[index];
                  final isSelected = option == selected;
                  return ListTile(
                    onTap: () => Navigator.pop(context, option),
                    title: Text(
                      option,
                      style: TextStyle(
                        color: isSelected ? _accent : Colors.white,
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: _accent, size: 20)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
