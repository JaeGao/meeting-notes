// Colours and the few shared controls: one button, one chip, one select, one note box.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic.dart';

class T {
  final bool dark;
  final Color bg, surface, sunk, ink, sub, line, accent, onAccent, danger, rec;
  final Color newBg, newInk, trBg, trInk, okBg, okInk, offBg, offInk, badBg, badInk, mark;
  const T({
    required this.dark,
    required this.bg,
    required this.surface,
    required this.sunk,
    required this.ink,
    required this.sub,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.danger,
    required this.rec,
    required this.newBg,
    required this.newInk,
    required this.trBg,
    required this.trInk,
    required this.okBg,
    required this.okInk,
    required this.offBg,
    required this.offInk,
    required this.badBg,
    required this.badInk,
    required this.mark,
  });

  static const light = T(
    dark: false,
    bg: Color(0xFFF5F4F1),
    surface: Color(0xFFFFFFFF),
    sunk: Color(0xFFEFEDE9),
    ink: Color(0xFF1C1B19),
    sub: Color(0xFF5A5752),
    line: Color(0xFFDCD9D3),
    accent: Color(0xFF1B58B8),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFA32222),
    rec: Color(0xFFD92D2D),
    newBg: Color(0xFFDFE9FB),
    newInk: Color(0xFF123F86),
    trBg: Color(0xFFFBECC8),
    trInk: Color(0xFF6E4300),
    okBg: Color(0xFFD9F0DE),
    okInk: Color(0xFF17512A),
    offBg: Color(0xFFE8E6E1),
    offInk: Color(0xFF55524D),
    badBg: Color(0xFFF9DEDE),
    badInk: Color(0xFF861B1B),
    mark: Color(0xFFFFE58A),
  );

  static const night = T(
    dark: true,
    bg: Color(0xFF161514),
    surface: Color(0xFF1F1E1C),
    sunk: Color(0xFF2A2826),
    ink: Color(0xFFECEBE8),
    sub: Color(0xFFAAA69F),
    line: Color(0xFF37342F),
    accent: Color(0xFF8AB6FF),
    onAccent: Color(0xFF0C1B33),
    danger: Color(0xFFFF8F8F),
    rec: Color(0xFFFF5C5C),
    newBg: Color(0xFF1C3050),
    newInk: Color(0xFFB9D3FF),
    trBg: Color(0xFF45340F),
    trInk: Color(0xFFF6D58A),
    okBg: Color(0xFF173A22),
    okInk: Color(0xFFA9E3B6),
    offBg: Color(0xFF302E2B),
    offInk: Color(0xFFB5B1AA),
    badBg: Color(0xFF4A1C1C),
    badInk: Color(0xFFFFB9B9),
    mark: Color(0xFF6B5600),
  );

  static T of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? night : light;

  TextStyle get body => TextStyle(fontSize: 14, height: 1.5, color: ink);
  TextStyle get hint => TextStyle(fontSize: 13, height: 1.45, color: sub);
  TextStyle get mono => const TextStyle(fontFamily: 'Menlo', fontSize: 12.5, height: 1.5);

  ThemeData theme() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: accent,
          onPrimary: onAccent,
          surface: surface,
          onSurface: ink,
          error: danger,
          outline: line,
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: NoSplash.splashFactory,
      dividerColor: line,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.28),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 600),
        textStyle: TextStyle(fontSize: 12, color: bg),
        decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(6)),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(8),
        thumbColor: WidgetStatePropertyAll(sub.withValues(alpha: 0.45)),
      ),
    );
  }
}

enum BtnKind { normal, primary, quiet }

/// The one button: 32 high, three weights (normal, primary, quiet), text and/or an icon.
class Btn extends StatelessWidget {
  final VoidCallback? onPressed;
  final String? label;
  final IconData? icon;
  final Widget? leading;
  final BtnKind kind;
  final bool danger, autofocus;
  final String? tooltip;
  final double size;
  final FocusNode? focusNode;

  const Btn({
    super.key,
    required this.onPressed,
    this.label,
    this.icon,
    this.leading,
    this.kind = BtnKind.normal,
    this.danger = false,
    this.autofocus = false,
    this.tooltip,
    this.size = 32,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final primary = kind == BtnKind.primary;
    final fg = primary ? t.onAccent : (danger ? t.danger : t.ink);
    final bg = primary ? t.accent : (kind == BtnKind.quiet ? Colors.transparent : t.surface);
    final iconOnly = label == null;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?leading,
        if (icon != null) Icon(icon, size: 17),
        if ((leading != null || icon != null) && !iconOnly) const SizedBox(width: 6),
        if (!iconOnly) Flexible(child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );
    Widget b = SizedBox(
      height: size,
      width: iconOnly ? size : null,
      child: TextButton(
        onPressed: onPressed,
        autofocus: autofocus,
        focusNode: focusNode,
        style: TextButton.styleFrom(
          foregroundColor: fg,
          backgroundColor: bg,
          disabledForegroundColor: fg.withValues(alpha: 0.5),
          disabledBackgroundColor: primary ? t.accent.withValues(alpha: 0.5) : bg,
          minimumSize: Size(size, size),
          padding: iconOnly ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: kind == BtnKind.normal ? t.line : Colors.transparent),
          ),
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        child: child,
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return Semantics(label: iconOnly ? tooltip : null, button: true, child: b);
  }
}

class StatusChip extends StatelessWidget {
  final ChipSpec spec;
  const StatusChip(this.spec, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final (bg, fg) = switch (spec.tone) {
      ChipTone.fresh => (t.newBg, t.newInk),
      ChipTone.transcript => (t.trBg, t.trInk),
      ChipTone.notes => (t.okBg, t.okInk),
      ChipTone.off => (t.offBg, t.offInk),
      ChipTone.bad => (t.badBg, t.badInk),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(
        spec.label,
        maxLines: 1,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg, height: 1.45),
      ),
    );
  }
}

/// A grey or red box for something the owner should know about this recording.
class NoteBox extends StatelessWidget {
  final String text;
  final bool bad;
  const NoteBox(this.text, {super.key, this.bad = false});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.22),
      decoration: BoxDecoration(
        color: bad ? t.badBg : t.offBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(fontSize: 14, height: 1.45, color: bad ? t.badInk : t.offInk),
        ),
      ),
    );
  }
}

/// A drop-down that looks like the buttons.
class Sel<V> extends StatelessWidget {
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V> onChanged;
  final bool expand, autofocus;
  final String? label;
  const Sel({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.expand = false,
    this.autofocus = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Semantics(
      label: label,
      child: Container(
        height: 32,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<V>(
            value: value,
            isDense: true,
            isExpanded: expand,
            autofocus: autofocus,
            focusColor: Colors.transparent,
            dropdownColor: t.surface,
            borderRadius: BorderRadius.circular(8),
            icon: Icon(Icons.expand_more, size: 18, color: t.sub),
            style: TextStyle(fontSize: 14, color: t.ink),
            items: [
              for (final (v, l) in options)
                DropdownMenuItem<V>(
                  value: v,
                  child: Text(l, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}

/// A text field used in place: Enter saves, Esc cancels, clicking away saves.
class InlineField extends StatefulWidget {
  final String initial, placeholder;
  final TextStyle style;
  final double height;
  final int? maxLength;
  final void Function(bool editing) onEditing;
  final void Function(bool save, String text) onDone;
  const InlineField({
    super.key,
    required this.initial,
    required this.placeholder,
    required this.style,
    required this.onEditing,
    required this.onDone,
    this.height = 32,
    this.maxLength,
  });

  @override
  State<InlineField> createState() => _InlineFieldState();
}

class _InlineFieldState extends State<InlineField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  final FocusNode _f = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.onEditing(true);
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    _f.addListener(() {
      if (!_f.hasFocus) _finish(true);
    });
  }

  void _finish(bool save) {
    if (_done) return;
    _done = true;
    widget.onEditing(false);
    widget.onDone(save, _c.text);
  }

  @override
  void dispose() {
    if (!_done) widget.onEditing(false);
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: BorderSide(color: t.accent),
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _finish(false)},
      child: SizedBox(
        height: widget.height,
        child: TextField(
          controller: _c,
          focusNode: _f,
          autofocus: true,
          maxLength: widget.maxLength,
          style: widget.style,
          cursorHeight: (widget.style.fontSize ?? 14) * 1.25,
          textAlignVertical: TextAlignVertical.center,
          onSubmitted: (_) => _finish(true),
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: widget.placeholder,
            hintStyle: widget.style.copyWith(color: t.sub, fontWeight: FontWeight.w400),
            filled: true,
            fillColor: t.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            border: border,
            enabledBorder: border,
            focusedBorder: border,
          ),
        ),
      ),
    );
  }
}
