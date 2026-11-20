import 'package:flutter/material.dart';

import '../../features/admin/models/admin_player.dart' show jerseySizes;
import '../theme/app_colors.dart';

/// The shirt-size choice on the add-player and edit-player forms: one chip
/// per size (3XS to 3XL, then the kids' 9-10 and 11-12), the chosen one green. Tapping the chosen
/// size again leaves it chosen; a size is changed, not cleared.
class JerseySizePicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String> onChanged;

  const JerseySizePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final size in jerseySizes)
          ChoiceChip(
            label: Text(size),
            selected: value == size,
            showCheckmark: false,
            onSelected: (_) => onChanged(size),
            backgroundColor: AppColors.background,
            selectedColor: AppColors.accent,
            labelStyle: TextStyle(
              color: value == size ? Colors.white : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
            side: BorderSide(
              color: value == size ? AppColors.accent : Colors.white24,
            ),
          ),
      ],
    );
  }
}
