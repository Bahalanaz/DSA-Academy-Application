import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/date_format.dart';

const _bg = AppColors.background;
const _card = AppColors.card;
const _accent = AppColors.accent;

/// A filled/borderless field matching the app's dark input style that,
/// instead of a keyboard, opens a calendar date picker when tapped.
class DatePickerField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  const DatePickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  color: value == null ? Colors.white38 : _accent,
                  size: 16,
                ),
                const SizedBox(width: 10),
                Text(
                  value == null ? "Select a date" : formatAdminDate(value!),
                  style: TextStyle(
                    color: value == null ? Colors.white38 : Colors.white,
                    fontSize: 14,
                    fontWeight: value == null
                        ? FontWeight.normal
                        : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

Future<DateTime?> showAdminDatePicker(
  BuildContext context, {
  DateTime? initialDate,
}) {
  return showDatePicker(
    context: context,
    initialDate: initialDate ?? DateTime.now(),
    firstDate: DateTime(2020),
    lastDate: DateTime(2035),
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
}
