// The edge between two panes, side by side or one above the other: drag to resize,
// double-click to reset, arrow keys when focused.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class Grip extends StatefulWidget {
  final String label;
  final double width;

  /// True for the edge under a pane (drag up and down) instead of beside one.
  final bool horizontal;

  /// Called with how far the edge moved to the right (or down), in points.
  final void Function(double dx) onDrag;
  final VoidCallback onReset;
  const Grip({
    super.key,
    required this.label,
    required this.onDrag,
    required this.onReset,
    this.width = 9,
    this.horizontal = false,
  });

  @override
  State<Grip> createState() => _GripState();
}

class _GripState extends State<Grip> {
  bool _hover = false, _drag = false, _focus = false;

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final on = _hover || _drag || _focus;
    return Semantics(
      label: widget.label,
      child: Tooltip(
        message: 'Drag to resize. Double-click to reset.',
        waitDuration: const Duration(seconds: 1),
        child: Focus(
          onFocusChange: (f) => setState(() => _focus = f),
          onKeyEvent: (_, ev) {
            if (ev is KeyUpEvent) return KeyEventResult.ignored;
            if (ev.logicalKey ==
                (widget.horizontal
                    ? LogicalKeyboardKey.arrowDown
                    : LogicalKeyboardKey.arrowRight)) {
              widget.onDrag(24);
              return KeyEventResult.handled;
            }
            if (ev.logicalKey ==
                (widget.horizontal ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowLeft)) {
              widget.onDrag(-24);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: widget.horizontal
                ? SystemMouseCursors.resizeRow
                : SystemMouseCursors.resizeColumn,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: widget.horizontal ? null : (_) => setState(() => _drag = true),
              onHorizontalDragUpdate: widget.horizontal ? null : (d) => widget.onDrag(d.delta.dx),
              onHorizontalDragEnd: widget.horizontal ? null : (_) => setState(() => _drag = false),
              onHorizontalDragCancel: widget.horizontal
                  ? null
                  : () => setState(() => _drag = false),
              onVerticalDragStart: widget.horizontal ? (_) => setState(() => _drag = true) : null,
              onVerticalDragUpdate: widget.horizontal ? (d) => widget.onDrag(d.delta.dy) : null,
              onVerticalDragEnd: widget.horizontal ? (_) => setState(() => _drag = false) : null,
              onVerticalDragCancel: widget.horizontal ? () => setState(() => _drag = false) : null,
              onDoubleTap: widget.onReset,
              child: SizedBox(
                width: widget.horizontal ? double.infinity : widget.width,
                height: widget.horizontal ? widget.width : double.infinity,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: widget.horizontal ? (on ? 64 : 36) : (on ? 3 : 0),
                    height: widget.horizontal ? 3 : null,
                    decoration: BoxDecoration(
                      color: widget.horizontal && !on ? t.line : t.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
