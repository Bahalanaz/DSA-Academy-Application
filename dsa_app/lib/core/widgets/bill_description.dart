import 'package:flutter/material.dart';

/// What a bill was for, as the academy typed it when sending it ("Away-kit
/// jersey, size M"), shown under the bill's title. Mostly for "Others",
/// whose title alone says nothing. Takes no space when there's none.
///
/// Lists keep it to [maxLines]; where a bill is opened on its own, pass
/// null so a written-out breakdown ("350 - October Fees", ...) shows whole.
class BillDescription extends StatelessWidget {
  final String? text;
  final int? maxLines;

  const BillDescription(this.text, {super.key, this.maxLines = 3});

  @override
  Widget build(BuildContext context) {
    final description = text?.trim() ?? "";
    if (description.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        description,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}
