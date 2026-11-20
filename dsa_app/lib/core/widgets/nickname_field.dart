import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/text_rules.dart';

/// Longest nickname the server keeps (players.nickname).
const maxNicknameLength = 30;

/// The optional nickname box on the player forms ("Kiko", "CR7"). Letters,
/// digits and spaces are all fine; emoji aren't, like everywhere else.
class NicknameField extends StatelessWidget {
  final TextEditingController controller;

  const NicknameField({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: maxNicknameLength,
      inputFormatters: [noEmoji],
      textCapitalization: TextCapitalization.words,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.background,
        hintText: "Optional, like \"Kiko\"",
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
    );
  }
}

/// What's typed, tidied: spaces collapsed, null when empty.
String? nicknameFrom(TextEditingController controller) {
  final text = controller.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? null : text;
}
