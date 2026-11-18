// The window: top bar, the recordings list, the chosen meeting, and messages.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'detail.dart';
import 'grip.dart';
import 'panels.dart';
import 'popover.dart';
import 'theme.dart';

/// The top bar's buttons, so a check can open their panels.
final recordButtonKey = GlobalKey();
final settingsButtonKey = GlobalKey();
final changeButtonKey = GlobalKey();

void openRecordPanel(BuildContext anchor, Store s) {
  s.loadSources();
  showPanel<void>(anchor, label: 'New recording', builder: (_) => RecordPanel(s));
}

/// While recording: choose another screen, window or area, or sound only.
void openSwitchPanel(BuildContext anchor, Store s) {
  s.loadSources();
  showPanel<void>(
    anchor,
    label: 'Change what is recorded',
    builder: (_) => RecordPanel(s, switching: true),
  );
}

void openSettingsPanel(BuildContext anchor, Store s) {
  showPanel<void>(anchor, label: 'Settings', builder: (_) => SettingsPanel(s));
}

class HomePage extends StatefulWidget {
  final Store store;
  const HomePage({super.key, required this.store});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchFocus = FocusNode();
  Store get s => widget.store;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _searchFocus.dispose();
    super.dispose();
  }

  /// Esc with no menu, panel or field open: clear the search, else close the meeting.
  bool _onKey(KeyEvent ev) {
    if (ev is! KeyDownEvent || ev.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true) || s.editing) return false;
    if (_searchFocus.hasFocus && s.search.isNotEmpty) {
      s.setSearch('');
      return true;
    }
    if (s.sel != null) {
      s.closeDetail();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: DefaultTextStyle(
        style: t.body,
        child: ListenableBuilder(
          listenable: s,
          builder: (context, _) => LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 820;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(store: s, compact: narrow),
                  if (s.rec?.failed ?? false) _RecBanner(store: s),
                  Expanded(child: _content(context, c.maxWidth, narrow)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, double width, bool narrow) {
    final t = T.of(context);
    if (s.boot == Boot.starting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.sub),
            ),
            const SizedBox(height: 12),
            Text('Starting…', style: TextStyle(color: t.sub)),
          ],
        ),
      );
    }
    if (s.boot == Boot.failed) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Meeting Notes could not start',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                NoteBox(s.bootError ?? '', bad: true),
                const SizedBox(height: 12),
                Text('Log: $logFile', style: t.hint, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Btn(label: 'Try again', kind: BtnKind.primary, onPressed: s.start),
              ],
            ),
          ),
        ),
      );
    }
    final list = _ListPane(store: s);
    final detail = DetailPane(
      store: s,
      showBack: narrow,
      windowWidth: width,
      searchFocus: _searchFocus,
    );
    if (narrow) {
      // One pane at a time: the list, or the meeting with a Back arrow.
      return s.current == null ? ColoredBox(color: t.surface, child: list) : detail;
    }
    final maxSide = (width * 0.5).clamp(220.0, 640.0);
    final side = (s.prefs.number('sideW') ?? 320).clamp(220.0, maxSide);
    return Stack(
      children: [
        Row(
          children: [
            Container(
              width: side,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(right: BorderSide(color: t.line)),
              ),
              child: list,
            ),
            Expanded(child: detail),
          ],
        ),
        Positioned(
          left: side - 5,
          top: 0,
          bottom: 0,
          child: Grip(
            label: 'Resize the recordings list',
            onDrag: (dx) => setState(() => s.prefs.set('sideW', (side + dx).clamp(220.0, maxSide))),
            onReset: () => setState(() => s.prefs.set('sideW', null)),
          ),
        ),
      ],
    );
  }
}

// ---------- top bar ----------

class _TopBar extends StatelessWidget {
  final Store store;
  final bool compact;
  const _TopBar({required this.store, required this.compact});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = store;
    final ready = s.boot == Boot.ready;
    final rec = s.rec;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 16, right: 14),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          const Text(
            'Meeting notes',
            maxLines: 1,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 16),
          if (ready && rec != null && rec.active) ...[
            // The dot and the words take what is left and stay against the buttons.
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PulseDot(color: t.rec),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(recordingLabel(rec), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              hms(rec.elapsed),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Builder(
              builder: (ctx) => Btn(
                key: changeButtonKey,
                label: 'Change…',
                tooltip: 'Record another screen, a window, or sound only',
                onPressed: rec.state == 'recording' ? () => openSwitchPanel(ctx, s) : null,
              ),
            ),
            const SizedBox(width: 8),
            Btn(label: 'Stop', onPressed: rec.state == 'recording' ? s.stopRecording : null),
          ] else ...[
            const Spacer(),
            Builder(
              builder: (ctx) => Btn(
                key: recordButtonKey,
                label: 'Record',
                leading: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: t.rec, shape: BoxShape.circle),
                ),
                onPressed: ready ? () => openRecordPanel(ctx, s) : null,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Builder(
            builder: (ctx) => Btn(
              key: settingsButtonKey,
              icon: Icons.settings_outlined,
              label: compact ? null : 'Settings',
              tooltip: compact ? 'Settings' : null,
              onPressed: ready && s.settings != null ? () => openSettingsPanel(ctx, s) : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Stay still when the Mac is set to reduce motion.
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 1.0, end: 0.3).animate(_c),
    child: Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

class _RecBanner extends StatelessWidget {
  final Store store;
  const _RecBanner({required this.store});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Container(
      color: t.badBg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              store.rec?.error ?? 'The recording failed.',
              style: TextStyle(color: t.badInk),
            ),
          ),
          const SizedBox(width: 12),
          Btn(label: 'Dismiss', onPressed: store.dismissRecordingError),
        ],
      ),
    );
  }
}

// ---------- recordings list ----------

class _ListPane extends StatelessWidget {
  final Store store;
  const _ListPane({required this.store});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'RECORDINGS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.sub,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Btn(
                kind: BtnKind.quiet,
                icon: Icons.refresh,
                tooltip: 'Look for new recordings',
                onPressed: s.refresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: s.entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No recordings yet. Press Record, or add a folder in Settings.',
                    style: TextStyle(color: t.sub),
                  ),
                )
              : ListView.builder(
                  itemCount: s.entries.length,
                  itemBuilder: (context, i) {
                    final e = s.entries[i];
                    return _RowTile(key: ValueKey(e.id), store: s, entry: e);
                  },
                ),
        ),
      ],
    );
  }
}

class _RowTile extends StatefulWidget {
  final Store store;
  final Entry entry;
  const _RowTile({super.key, required this.store, required this.entry});
  @override
  State<_RowTile> createState() => _RowTileState();
}

class _RowTileState extends State<_RowTile> {
  bool _hover = false, _focus = false, _menu = false;

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = widget.store;
    final e = widget.entry;
    final selected = s.sel == e.id;
    final showOptions = _hover || _focus || _menu || selected;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focus = f),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: selected || _hover || _menu ? t.sunk : Colors.transparent,
          child: Stack(
            children: [
              InkWell(
                onTap: () => s.select(e.id),
                hoverColor: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: t.line),
                      left: BorderSide(width: 3, color: selected ? t.accent : Colors.transparent),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(13, 10, 44, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName(e),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${shortWhen(e.recorded)} · ${shortDuration(e.duration)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: t.sub),
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusChip(chipFor(e)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 6,
                child: Opacity(
                  opacity: showOptions ? 1 : 0,
                  child: Builder(
                    builder: (ctx) => Btn(
                      kind: BtnKind.quiet,
                      icon: Icons.more_horiz,
                      size: 28,
                      tooltip: 'Options for ${displayName(e)}',
                      onPressed: () async {
                        setState(() => _menu = true);
                        await openMenu(ctx, s, e);
                        if (mounted) setState(() => _menu = false);
                      },
                    ),
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

// ---------- messages ----------

/// The short message at the bottom of the window, with Undo when there is something to undo.
class ToastLayer extends StatelessWidget {
  final Store store;
  const ToastLayer({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final toast = store.toast;
        if (toast == null) return const SizedBox.shrink();
        final t = T.of(context);
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Material(
                color: t.ink,
                elevation: 10,
                borderRadius: BorderRadius.circular(9),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(toast.text, style: TextStyle(fontSize: 14, color: t.bg)),
                        ),
                      ),
                      if (toast.action != null) ...[
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: () {
                            final run = toast.onAction;
                            store.dismissToast();
                            run?.call();
                          },
                          child: Text(
                            toast.action!,
                            style: TextStyle(
                              fontSize: 14,
                              color: t.bg,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                              decorationColor: t.bg,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
