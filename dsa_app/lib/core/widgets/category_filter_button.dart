import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'option_sheet.dart';
import 'pressable.dart';

const _card = AppColors.card;

/// A compact "Filter" button that opens a bottom sheet listing every
/// category (plus "All"). Replaces a horizontal row of chips, which
/// stops scaling once there are more categories than fit on one line.
class CategoryFilterButton extends StatelessWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onChanged;

  const CategoryFilterButton({
    super.key,
    required this.categories,
    required this.selected,
    required this.onChanged,
  });

  Future<void> _openPicker(BuildContext context) async {
    final picked = await showOptionSheet(
      context,
      title: "FILTER BY CATEGORY",
      options: ["All", ...categories],
      selected: selected,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      child: InkWell(
        onTap: () => _openPicker(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.filter_list, color: Colors.white70, size: 16),
              const SizedBox(width: 6),
              // Flexible even though the Row is mainAxisSize.min: the label
              // is whatever the filter is called, and a min-sized Row still
              // overflows its parent once the text is wider than the space
              // the chip actually has.
              Flexible(
                child: Text(
                  selected == "All" ? "Filter: All" : "Filter: $selected",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
