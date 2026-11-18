// Menus and panels that open under the button that asked for them, and the one
// confirmation dialog. All of them close with Esc, a click outside, or their own button.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic.dart';
import 'theme.dart';

/// Opens [builder] as a panel anchored under [anchor]'s right edge.
/// Completes with what the panel popped, or null when it was dismissed.
Future<R?> showPanel<R>(BuildContext anchor, {required WidgetBuilder builder, String? label}) {
  final nav = Navigator.of(anchor, rootNavigator: true);
  final box = anchor.findRenderObject() as RenderBox;
  final overlay = nav.overlay!.context.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return nav.push(_PanelRoute<R>(rect, builder, label ?? 'Close'));
}

class _PanelRoute<R> extends PopupRoute<R> {
  final Rect anchor;
  final WidgetBuilder builder;
  final String label;
  _PanelRoute(this.anchor, this.builder, this.label);

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => label;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 90);

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) {
    final t = T.of(context);
    return CustomSingleChildLayout(
      delegate: _Place(anchor),
      child: Material(
        color: t.surface,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: t.dark ? 0.9 : 0.45),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.line),
        ),
        child: DefaultTextStyle(
          style: t.body,
          child: Builder(builder: builder),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> a,
    Animation<double> b,
    Widget child,
  ) => FadeTransition(opacity: a, child: child);
}

class _Place extends SingleChildLayoutDelegate {
  final Rect anchor;
  _Place(this.anchor);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - 16, c.maxHeight - 16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final maxLeft = size.width - child.width - 8;
    final left = (anchor.right - child.width).clamp(8.0, maxLeft < 8 ? 8.0 : maxLeft);
    var top = anchor.bottom + 6;
    if (top + child.height > size.height - 8) {
      final up = size.height - child.height - 8;
      top = up < 8 ? 8 : up;
    }
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_Place old) => old.anchor != anchor;
}

const menuIcons = <Act, IconData>{
  Act.stop: Icons.close,
  Act.transcribe: Icons.description_outlined,
  Act.transcribeAgain: Icons.replay,
  Act.writeNotes: Icons.edit_outlined,
  Act.rewriteNotes: Icons.replay,
  Act.identifySpeakers: Icons.record_voice_over_outlined,
  Act.rename: Icons.edit_outlined,
  Act.editNotes: Icons.edit_note,
  Act.openTranscript: Icons.description_outlined,
  Act.reveal: Icons.movie_outlined,
  Act.openFolder: Icons.folder_outlined,
  Act.remove: Icons.delete_outline,
};

/// The options of a recording. Pops the chosen [Act]. Up and Down move, Enter chooses.
class MenuList extends StatelessWidget {
  final List<MenuEntry?> items;
  const MenuList(this.items, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    var first = true;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 230),
          child: IntrinsicWidth(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final it in items)
                    if (it == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                        child: Divider(height: 1, thickness: 1, color: t.line),
                      )
                    else
                      _item(context, t, it, autofocus: first ? !(first = false) : false),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, T t, MenuEntry it, {required bool autofocus}) {
    final fg = it.danger ? t.danger : t.ink;
    return SizedBox(
      height: 32,
      child: TextButton(
        autofocus: autofocus,
        onPressed: () => Navigator.of(context).pop(it.act),
        style: TextButton.styleFrom(
          foregroundColor: fg,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        ),
        child: Row(
          children: [
            Icon(menuIcons[it.act], size: 17),
            const SizedBox(width: 9),
            Text(it.label, maxLines: 1),
          ],
        ),
      ),
    );
  }
}

/// A panel with a title and Close, a body, and a row of buttons at the bottom.
class PanelFrame extends StatelessWidget {
  final String title;
  final List<Widget> headerActions;
  final Widget body;
  final List<Widget> footer;
  final bool fillBody;
  const PanelFrame({
    super.key,
    required this.title,
    required this.body,
    required this.footer,
    this.headerActions = const [],
    this.fillBody = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Column(
      mainAxisSize: fillBody ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              ...headerActions,
              Btn(
                kind: BtnKind.quiet,
                icon: Icons.close,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        fillBody ? Expanded(child: body) : Flexible(child: body),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.line)),
          ),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: footer,
          ),
        ),
      ],
    );
  }
}

/// Asks before something that replaces or removes the owner's work. True when confirmed.
Future<bool> confirmBox(BuildContext context, String title, String text, String okLabel) async {
  final r = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) {
      final t = T.of(context);
      return Dialog(
        backgroundColor: t.surface,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.line),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: DefaultTextStyle(
              style: t.body,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(text),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Btn(
                        label: 'Cancel',
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                      const SizedBox(width: 8),
                      Btn(
                        label: okLabel,
                        danger: true,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  return r ?? false;
}
