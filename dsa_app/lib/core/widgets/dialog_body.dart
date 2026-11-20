import 'package:flutter/material.dart';

/// The inside of a dialog, made impossible to overflow.
///
/// A `Dialog` sizes itself to its content and gets the whole screen to lay
/// out in, so a plain `Column` inside one has no upper bound: once the
/// content is taller than the screen it bursts into the yellow-and-black
/// stripes instead of scrolling. That happens more easily than it sounds —
/// a short phone, a large font size, a long list of payments, or simply
/// the keyboard opening and taking half the screen away.
///
/// This caps the height at what's actually visible (screen minus whatever
/// the keyboard covers) and scrolls within it. Drop it in wherever a
/// dialog would otherwise use `Padding` around its content column — it
/// takes a single `child` the same way, so it swaps in one-for-one.
class DialogBody extends StatelessWidget {
  final Widget child;

  /// Defaults to the 20pt inset every dialog in the app already used.
  final EdgeInsetsGeometry padding;

  /// Fraction of the usable height the dialog may grow to before it starts
  /// scrolling. Short of 1.0 so it still reads as a dialog floating over
  /// the screen rather than a full page.
  final double maxHeightFactor;

  const DialogBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.maxHeightFactor = 0.85,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // viewInsets.bottom is the keyboard. Subtracting it is what keeps an
    // input-bearing dialog usable while typing, instead of the field being
    // pushed under the keyboard or the dialog overflowing behind it.
    final usable = media.size.height - media.viewInsets.bottom;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: usable * maxHeightFactor),
      child: SingleChildScrollView(padding: padding, child: child),
    );
  }
}
