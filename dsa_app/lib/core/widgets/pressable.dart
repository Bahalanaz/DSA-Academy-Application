import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

/// A gentle press-down on a tappable card or tile: it shrinks a little
/// while a finger is on it and springs back on release, so a tap feels
/// like it landed. Wrap the InkWell (or button) that handles the tap; this
/// only listens, so the tap, ripple and scrolling all work as before.
///
/// Starting to scroll releases it straight away, so a list doesn't shrink
/// the row the finger happened to land on.
class Pressable extends StatefulWidget {
  final Widget child;

  /// How small it gets while pressed (1 = not at all).
  final double scale;

  /// Off for something that can't be tapped right now.
  final bool enabled;

  const Pressable({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.enabled = true,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  Offset? _start;

  void _set(bool down) {
    if (_down == down || !mounted) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (!widget.enabled) return;
        _start = event.position;
        _set(true);
      },
      onPointerMove: (event) {
        final start = _start;
        if (start != null && (event.position - start).distance > kTouchSlop) {
          _start = null;
          _set(false);
        }
      },
      onPointerUp: (_) {
        _start = null;
        _set(false);
      },
      onPointerCancel: (_) {
        _start = null;
        _set(false);
      },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 90 : 160),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
