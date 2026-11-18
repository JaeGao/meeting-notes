// One meeting: its header and actions, its notes and transcript, and the recording.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'grip.dart';
import 'panels.dart';
import 'theme.dart';
import 'video.dart';

/// The header's "More actions" button, so a check can open its menu.
final moreButtonKey = GlobalKey();

/// The recording's player, so a check can put it in full screen.
final videoPaneKey = GlobalKey<VideoPaneState>();

class DetailPane extends StatefulWidget {
  final Store store;
  final bool showBack;
  final double windowWidth;
  final FocusNode searchFocus;
  const DetailPane({
    super.key,
    required this.store,
    required this.showBack,
    required this.windowWidth,
    required this.searchFocus,
  });
  @override
  State<DetailPane> createState() => _DetailPaneState();
}

/// Where playback is in the meeting on screen. The recording's player sets it; a test can
/// set it too, to stand in for a recording being played.
ValueNotifier<Playhead?>? playheadOnScreen;

class _DetailPaneState extends State<DetailPane> {
  final _video = videoPaneKey;
  Store get s => widget.store;

  /// Where playback is, for the transcript to follow. Null until the recording is played
  /// or moved, so nothing is marked in a meeting that is only being read.
  final _playhead = ValueNotifier<Playhead?>(null);
  String? _playheadOf;

  @override
  void initState() {
    super.initState();
    playheadOnScreen = _playhead;
  }

  @override
  void dispose() {
    if (identical(playheadOnScreen, _playhead)) playheadOnScreen = null;
    _playhead.dispose();
    super.dispose();
  }

  void _seek(int seconds) => _video.currentState?.seekPlay(seconds);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final e = s.current;
    if (e == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            s.entries.isEmpty
                ? 'Press Record to record your first meeting.'
                : 'Choose a recording on the left, or press Record.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.sub),
          ),
        ),
      );
    }
    if (_playheadOf != e.id) {
      // Another meeting: its recording has not been played yet.
      _playheadOf = e.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _playheadOf == e.id) _playhead.value = null;
      });
    }
    final pad = widget.showBack ? 16.0 : 20.0;
    if (e.hasFolder) {
      // With a transcript, the title and its line sit under the recording and scroll away
      // with the text, so the recording and the text get the room.
      final lead = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(key: ValueKey('head-${e.id}'), store: s, entry: e, showBack: false, inText: true),
          _Meta(entry: e, pad: 0, inText: true),
          _Alerts(store: s, entry: e, pad: 0),
          const SizedBox(height: 6),
        ],
      );
      return _body(context, e, pad, lead);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(key: ValueKey('head-${e.id}'), store: s, entry: e, showBack: widget.showBack),
        _Meta(entry: e, pad: pad),
        _Alerts(store: s, entry: e, pad: pad),
        Expanded(child: _body(context, e, pad, null)),
      ],
    );
  }

  Widget _body(BuildContext context, Entry e, double pad, Widget? lead) {
    final sound = isSoundFile(e.path);
    final video = e.playable && e.exists
        ? VideoPane(
            key: _video,
            path: e.path,
            soundOnly: sound,
            prefs: s.prefs,
            onPosition: (at, playing) {
              if (_playheadOf == e.id) _playhead.value = Playhead(at, playing);
            },
          )
        : null;
    if (!e.hasFolder) {
      return Padding(
        padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: video ?? const SizedBox.shrink(),
          ),
        ),
      );
    }
    final main = _Main(
      store: s,
      entry: e,
      canSeek: video != null,
      onSeek: _seek,
      searchFocus: widget.searchFocus,
      playhead: _playhead,
      lead: lead,
      onBack: widget.showBack ? s.closeDetail : null,
    );
    if (video == null) {
      return Padding(padding: EdgeInsets.fromLTRB(pad, 12, pad, 0), child: main);
    }
    if (sound) {
      // No picture to show: the player is a slim bar above the text.
      return Padding(
        padding: EdgeInsets.fromLTRB(pad, 10, pad, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            video,
            const SizedBox(height: 4),
            Expanded(child: main),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        // The recording stays put above the text, which scrolls under it. It takes a little
        // under half of the room unless its lower edge has been dragged, and always leaves
        // some text showing.
        final room = c.maxHeight - 12 - 36;
        final most = math.max(150.0, room - 150);
        final height = (s.prefs.number('videoH') ?? room * 0.46).clamp(150.0, most);
        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 10, pad, 0),
          child: _Main(
            store: s,
            entry: e,
            canSeek: true,
            onSeek: _seek,
            searchFocus: widget.searchFocus,
            playhead: _playhead,
            lead: lead,
            onBack: widget.showBack ? s.closeDetail : null,
            header: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: height, child: video),
                Grip(
                  label: 'Resize the recording',
                  horizontal: true,
                  width: 11,
                  onDrag: (dy) =>
                      setState(() => s.prefs.set('videoH', (height + dy).clamp(150.0, most))),
                  onReset: () => setState(() => s.prefs.set('videoH', null)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------- header ----------

class _Header extends StatefulWidget {
  final Store store;
  final Entry entry;
  final bool showBack;

  /// True when the header is part of the scrolling text, which already has its margins.
  final bool inText;
  const _Header({
    super.key,
    required this.store,
    required this.entry,
    required this.showBack,
    this.inText = false,
  });
  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _editing = false;
  String _lang = 'auto';

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = widget.store;
    final e = widget.entry;
    if (s.renameRequested) {
      s.renameRequested = false;
      if (e.hasFolder && !_editing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _editing = true);
        });
      }
    }
    const titleStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3);
    Widget title;
    if (_editing) {
      title = InlineField(
        initial: editableTitle(e),
        placeholder: 'Meeting title, then Enter',
        style: titleStyle.copyWith(fontSize: 17, color: t.ink),
        onEditing: s.setEditing,
        onDone: (save, text) {
          setState(() => _editing = false);
          if (save) s.rename(e, text);
        },
      );
    } else if (e.hasFolder) {
      title = Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: 'Click to rename',
          child: InkWell(
            onTap: () => setState(() => _editing = true),
            borderRadius: BorderRadius.circular(5),
            hoverColor: t.sunk,
            mouseCursor: SystemMouseCursors.text,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Text(
                displayName(e),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
          ),
        ),
      );
    } else {
      title = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Text(
          displayName(e),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      );
    }

    final j = e.job;
    final actions = <Widget>[];
    if (e.busy && j != null) {
      final known = j.state == 'running' && j.kind != 'notes' && j.progress != null;
      actions.addAll([
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, minWidth: 120),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: known ? j.progress! / 100 : null,
                    minHeight: 6,
                    backgroundColor: t.sunk,
                    color: t.accent,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  progressLabel(j),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.sub, height: 1.3),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Btn(label: 'Stop', onPressed: () => s.stopJob(e)),
      ]);
    } else {
      if (e.status == 'new' && e.exists && e.audio) {
        actions.addAll([
          Sel<String>(
            value: _lang,
            options: languages,
            label: 'Language',
            onChanged: (v) => setState(() => _lang = v),
          ),
          const SizedBox(width: 8),
          Btn(label: 'Transcribe', kind: BtnKind.primary, onPressed: () => s.transcribe(e, _lang)),
          const SizedBox(width: 8),
        ]);
      }
      if (e.status == 'transcript') {
        actions.addAll([
          Btn(label: 'Write notes', kind: BtnKind.primary, onPressed: () => s.writeNotes(e)),
          const SizedBox(width: 8),
        ]);
      }
      actions.add(
        Builder(
          builder: (ctx) => Btn(
            key: moreButtonKey,
            icon: Icons.more_horiz,
            tooltip: 'More actions',
            onPressed: () => openMenu(ctx, s, e),
          ),
        ),
      );
    }

    return Padding(
      // In the text the title's own 5 of hover padding is pulled back so it lines up.
      padding: widget.inText
          ? const EdgeInsets.fromLTRB(0, 8, 12, 0)
          : EdgeInsets.fromLTRB(widget.showBack ? 8 : 15, 12, 16, 0),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            if (widget.showBack) ...[
              Btn(
                kind: BtnKind.quiet,
                icon: Icons.arrow_back_ios_new,
                tooltip: 'Back to recordings',
                onPressed: s.closeDetail,
              ),
              const SizedBox(width: 2),
            ],
            Expanded(
              child: widget.inText
                  ? Transform.translate(offset: const Offset(-5, 0), child: title)
                  : title,
            ),
            const SizedBox(width: 8),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final Entry entry;
  final double pad;
  final bool inText;
  const _Meta({required this.entry, required this.pad, this.inText = false});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final e = entry;
    final dot = Text('·', style: TextStyle(color: t.sub));
    return Container(
      padding: EdgeInsets.fromLTRB(pad, 2, pad, inText ? 4 : 10),
      decoration: BoxDecoration(
        border: inText ? null : Border(bottom: BorderSide(color: t.line)),
      ),
      child: DefaultTextStyle(
        style: TextStyle(fontSize: 13, color: t.sub, height: 1.4),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(longWhen(e.recorded)),
            dot,
            Text(e.duration),
            dot,
            StatusChip(chipFor(e)),
            dot,
            Tooltip(
              message: e.path,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: Text(e.file, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Alerts extends StatelessWidget {
  final Store store;
  final Entry entry;
  final double pad;
  const _Alerts({required this.store, required this.entry, required this.pad});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final j = e.job;
    final missing = store.settings?.missing ?? const [];
    final notes = <Widget>[
      if (!e.exists)
        NoteBox(
          'The recording file is no longer at ${e.path}. The transcript and notes are still here, '
          'but the video cannot be played or transcribed again.',
          bad: true,
        ),
      if (e.status == 'no-audio')
        const NoteBox(
          'This recording has no audio track, so there is nothing to transcribe. Recordings made '
          'with Record here always have sound.',
        ),
      if (e.stuck != null)
        NoteBox(
          'The transcriber got stuck and repeated one line ${e.stuck!.times} times from '
          '${e.stuck!.from}. That part of the transcript is not real. Use More actions, then '
          'Transcribe again.',
          bad: true,
        ),
      if (e.partial)
        const NoteBox(
          'This transcript covers only part of the recording. Use More actions, then Transcribe '
          'again, for the whole meeting.',
        ),
      if (j != null && j.state == 'error')
        NoteBox(
          '${switch (j.kind) {
            'notes' => 'Writing the notes',
            'speakers' => 'Identifying speakers',
            _ => 'Transcribing',
          }} failed:\n${j.message}',
          bad: true,
        ),
      if (j != null && j.state == 'stopped') NoteBox(j.message),
      if (missing.isNotEmpty && e.audio)
        NoteBox('Not installed: ${missing.join(', ')}. See the README for setup.', bad: true),
    ];
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(children: notes),
    );
  }
}

// ---------- notes and transcript ----------

class _Main extends StatelessWidget {
  final Store store;
  final Entry entry;
  final bool canSeek;
  final void Function(int seconds) onSeek;
  final FocusNode searchFocus;

  /// What stays put above everything: the recording.
  final Widget? header;

  /// What comes first in the scrolling text, above the tabs, and scrolls away: the title.
  final Widget? lead;

  /// Set in a narrow window: the tabs row then carries the way back to the list.
  final VoidCallback? onBack;

  /// Where playback is, for the transcript to follow.
  final ValueListenable<Playhead?>? playhead;
  const _Main({
    required this.store,
    required this.entry,
    required this.canSeek,
    required this.onSeek,
    required this.searchFocus,
    this.header,
    this.lead,
    this.onBack,
    this.playhead,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = store;
    final d = s.details[entry.id];
    // The tabs row stays in view while the title above it scrolls away.
    final tabs = Container(
      height: 37,
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            Btn(
              kind: BtnKind.quiet,
              icon: Icons.arrow_back_ios_new,
              tooltip: 'Back to recordings',
              onPressed: onBack,
            ),
            const SizedBox(width: 2),
          ],
          _Tab(label: 'Notes', on: s.tab == 'notes', onTap: () => s.setTab('notes')),
          _Tab(label: 'Transcript', on: s.tab == 'transcript', onTap: () => s.setTab('transcript')),
          Expanded(
            child: s.tab != 'transcript'
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: _SearchField(store: s, focus: searchFocus),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
    Widget frame(List<Widget> slivers, [ScrollController? controller]) => CustomScrollView(
      controller: controller,
      slivers: [
        if (lead != null) SliverToBoxAdapter(child: lead),
        SliverPersistentHeader(pinned: true, delegate: _Pinned(tabs, 37)),
        ...slivers,
      ],
    );
    Widget hint(String text) => frame([
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(text, style: t.hint),
        ),
      ),
    ]);
    Widget content;
    if (d == null) {
      content = hint('Loading…');
    } else if (s.tab == 'notes') {
      if (d.notes == null) {
        final writing = entry.busy && entry.job?.kind == 'notes';
        content = hint(
          writing
              ? 'No notes yet. Claude is writing them now.'
              : entry.status == 'transcript'
              ? 'No notes yet. Press Write notes. The transcript text is sent to Claude for this '
                    'step; the recording stays on this Mac.'
              : 'No notes yet.',
        );
      } else {
        content = _NotesView(
          key: ValueKey('notes-${entry.id}'),
          source: d.notes!,
          frame: frame,
          onSeek: canSeek ? onSeek : null,
        );
      }
    } else if (d.paragraphs.isEmpty) {
      content = hint('No speech was found in this recording.');
    } else {
      content = _TranscriptView(
        key: ValueKey('tr-${entry.id}'),
        store: s,
        entry: entry,
        detail: d,
        frame: frame,
        playhead: playhead,
        onSeek: canSeek ? onSeek : null,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?header,
        Expanded(child: content),
      ],
    );
  }
}

/// Builds the scrolling area around a view's own content: the title, the pinned tabs, then it.
typedef _Frame = Widget Function(List<Widget> slivers, [ScrollController? controller]);

/// Keeps one row in view at the top of the scrolling text.
class _Pinned extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  _Pinned(this.child, this.height);

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;
  @override
  bool shouldRebuild(_Pinned old) => true;
}

class _Tab extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Semantics(
      selected: on,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 2, color: on ? t.accent : Colors.transparent)),
          ),
          child: Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w600, color: on ? t.ink : t.sub),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  final Store store;
  final FocusNode focus;
  const _SearchField({required this.store, required this.focus});
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final _c = TextEditingController(text: widget.store.search);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    if (_c.text != widget.store.search) _c.text = widget.store.search; // cleared with Esc
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: BorderSide(color: c),
    );
    return SizedBox(
      height: 28,
      child: TextField(
        controller: _c,
        focusNode: widget.focus,
        onChanged: widget.store.setSearch,
        style: TextStyle(fontSize: 13.5, color: t.ink),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search the transcript',
          hintStyle: TextStyle(fontSize: 13.5, color: t.sub),
          filled: true,
          fillColor: t.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 9),
          border: border(t.line),
          enabledBorder: border(t.line),
          focusedBorder: border(t.accent),
        ),
      ),
    );
  }
}

/// A time that jumps the recording there when clicked (or plain text when it cannot play).
class _TimeChip extends StatelessWidget {
  final int seconds;
  final void Function(int)? onSeek;
  const _TimeChip(this.seconds, this.onSeek);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final text = Text(
      hms(seconds),
      style: TextStyle(
        fontFamily: 'Menlo',
        fontSize: 12,
        height: 1.4,
        color: onSeek != null ? t.accent : t.sub,
      ),
    );
    return Material(
      color: t.sunk,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSeek == null ? null : () => onSeek!(seconds),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: text,
        ),
      ),
    );
  }
}

class _NotesView extends StatelessWidget {
  final String source;
  final _Frame frame;
  final void Function(int)? onSeek;
  const _NotesView({super.key, required this.source, required this.frame, required this.onSeek});

  InlineSpan _span(T t, Span s) {
    if (s.seek != null) {
      return WidgetSpan(alignment: PlaceholderAlignment.middle, child: _TimeChip(s.seek!, onSeek));
    }
    return TextSpan(
      text: s.text,
      style: s.code
          ? TextStyle(
              fontFamily: 'Menlo',
              fontSize: 12.5,
              backgroundColor: t.sunk,
              fontWeight: s.bold ? FontWeight.w700 : null,
            )
          : (s.bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
    );
  }

  Widget _text(T t, List<Span> spans, {TextStyle? style}) =>
      Text.rich(TextSpan(children: [for (final s in spans) _span(t, s)]), style: style);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final blocks = parseNotes(source);
    final children = <Widget>[];
    for (final b in blocks) {
      switch (b) {
        case Heading():
          final size = const [18.0, 16.0, 14.0][b.level - 1];
          final top = children.isEmpty ? 0.0 : const [14.0, 20.0, 14.0][b.level - 1];
          children.add(
            Padding(
              padding: EdgeInsets.only(top: top, bottom: b.level == 3 ? 6 : 8),
              child: _text(
                t,
                b.spans,
                style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, height: 1.35),
              ),
            ),
          );
        case Para():
          children.add(
            Padding(padding: const EdgeInsets.only(bottom: 10), child: _text(t, b.spans)),
          );
        case ListBlock():
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, item) in b.items.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 22,
                            child: Text(
                              b.ordered ? '${i + 1}.' : '•',
                              textAlign: b.ordered ? TextAlign.left : TextAlign.center,
                              style: TextStyle(color: t.sub),
                            ),
                          ),
                          Expanded(child: _text(t, item)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        case TableBlock():
          final cols = b.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
          if (cols == 0) continue;
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Table(
                border: TableBorder.all(color: t.line),
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                children: [
                  for (final (n, row) in b.rows.indexed)
                    TableRow(
                      decoration: BoxDecoration(color: n == 0 ? t.sunk : null),
                      children: [
                        for (var c = 0; c < cols; c++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                            child: _text(
                              t,
                              c < row.length ? row[c] : const [],
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: n == 0 ? FontWeight.w600 : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          );
      }
    }
    return SelectionArea(
      child: frame([
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 12, 12, 24),
          sliver: SliverList.list(children: children),
        ),
      ]),
    );
  }
}

class _TranscriptView extends StatefulWidget {
  final Store store;
  final Entry entry;
  final Detail detail;
  final _Frame frame;
  final ValueListenable<Playhead?>? playhead;
  final void Function(int)? onSeek;
  const _TranscriptView({
    super.key,
    required this.store,
    required this.entry,
    required this.detail,
    required this.frame,
    required this.onSeek,
    this.playhead,
  });
  @override
  State<_TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<_TranscriptView> {
  /// Which speaker name is being edited: `who-N` in the top row, or `p-INDEX` on a passage.
  String? _editing;

  // Following the recording: the passage being spoken is marked and kept in view.
  final _scroll = ScrollController();
  final _rowKeys = <int, GlobalKey>{};
  late List<int> _starts = [for (final p in widget.detail.paragraphs) p.t];
  int? _active; // the passage being spoken
  bool _following = true; // false once the owner scrolls away by hand

  @override
  void initState() {
    super.initState();
    widget.playhead?.addListener(_played);
    WidgetsBinding.instance.addPostFrameCallback((_) => _played());
  }

  @override
  void didUpdateWidget(_TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.playhead, widget.playhead)) {
      oldWidget.playhead?.removeListener(_played);
      widget.playhead?.addListener(_played);
    }
    if (!identical(oldWidget.detail, widget.detail)) {
      _starts = [for (final p in widget.detail.paragraphs) p.t];
      _rowKeys.clear();
    }
  }

  @override
  void dispose() {
    widget.playhead?.removeListener(_played);
    _scroll.dispose();
    super.dispose();
  }

  bool get _searching => widget.store.search.trim().isNotEmpty;

  void _played() {
    if (!mounted) return;
    final at = widget.playhead?.value;
    final now = at == null ? null : activePassage(_starts, at.seconds);
    if (now == _active) return;
    setState(() => _active = now);
    if (now != null && _following && !_searching) _reveal(now);
  }

  /// Scrolls so that passage [index] shows near the top. Passages far away are not laid
  /// out yet, so this first jumps to about the right place and then looks again.
  void _reveal(int index, [int tries = 0]) {
    if (!mounted || !_scroll.hasClients) return;
    final row = _rowKeys[index]?.currentContext;
    if (row != null) {
      // Just under the pinned tabs, not behind them.
      final box = row.findRenderObject()!;
      final pos = _scroll.position;
      final to = (RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset - 46).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      if (tries == 0) {
        _scroll.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(to);
      }
      return;
    }
    if (tries >= 12) return;
    final pos = _scroll.position;
    // Measure the passages that are laid out: where the nearest one sits and how tall
    // they are on average, then step from it by that much per passage.
    int? near;
    var total = 0.0, count = 0;
    for (final e in _rowKeys.entries) {
      final box = e.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      total += box.size.height;
      count++;
      if (near == null || (e.key - index).abs() < (near - index).abs()) near = e.key;
    }
    double target;
    if (near == null) {
      target = pos.maxScrollExtent * index / math.max(1, _starts.length - 1);
    } else {
      final box = _rowKeys[near]!.currentContext!.findRenderObject()!;
      final at = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
      target = at + (index - near) * (total / count);
    }
    _scroll.jumpTo(target.clamp(0.0, pos.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(index, tries + 1));
  }

  void _follow() {
    setState(() => _following = true);
    if (_active != null) _reveal(_active!);
  }

  /// A clicked time plays from there, and the transcript follows again.
  void Function(int)? get _seekAndFollow => widget.onSeek == null
      ? null
      : (seconds) {
          if (!_following) setState(() => _following = true);
          widget.onSeek!(seconds);
        };

  Color _color(T t, int n) =>
      HSLColor.fromAHSL(1, speakerHue(n), t.dark ? 0.70 : 0.65, t.dark ? 0.78 : 0.30).toColor();

  Speaker? _speaker(int n) {
    for (final sp in widget.detail.speakers) {
      if (sp.n == n) return sp;
    }
    return null;
  }

  Widget _field(T t, Speaker sp) => SizedBox(
    width: 160,
    child: InlineField(
      initial: sp.name,
      placeholder: 'Name for Speaker ${sp.n}',
      height: 24,
      maxLength: 40,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ink),
      onEditing: widget.store.setEditing,
      onDone: (save, text) {
        setState(() => _editing = null);
        if (save) widget.store.renameSpeaker(widget.entry, sp, text);
      },
    ),
  );

  Widget _name(T t, String id, int n, String label, {Widget? trailing, bool pill = false}) {
    final sp = _speaker(n);
    if (_editing == id && sp != null) return _field(t, sp);
    final text = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: _color(t, n),
            height: 1.5,
          ),
        ),
        ?trailing,
      ],
    );
    return Tooltip(
      message: 'Rename this speaker',
      child: Material(
        color: Colors.transparent,
        shape: pill
            ? StadiumBorder(side: BorderSide(color: t.line))
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: sp == null ? null : () => setState(() => _editing = id),
          hoverColor: t.sunk,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: pill ? 8 : 6, vertical: pill ? 1 : 0),
            child: text,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final d = widget.detail;
    final q = widget.store.search.trim().toLowerCase();
    final rows = <(int, Paragraph)>[
      for (final (i, p) in d.paragraphs.indexed)
        if (q.isEmpty || p.text.toLowerCase().contains(q)) (i, p),
    ];
    final hint = q.isNotEmpty
        ? '${rows.length} of ${d.paragraphs.length} passages match.'
        : d.speakers.isNotEmpty
        ? 'Speakers are told apart by voice and can be wrong. Click a name to rename that speaker '
              'everywhere; give two the same name to merge them.'
              '${widget.onSeek != null ? ' Click a time to check the recording.' : ''}'
        : 'Speakers are not identified. Use More actions, then Identify speakers.'
              '${widget.onSeek != null ? ' Click a time to check the recording.' : ''}';
    final showWho = d.speakers.isNotEmpty && q.isEmpty;
    final head = 1 + (showWho ? 1 : 0);
    final list = SelectionArea(
      // Scrolling by hand (wheel, trackpad, scroll bar) stops the following; the app's
      // own scrolling to the spoken passage does not count.
      child: NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          if (n.direction != ScrollDirection.idle && _following && _active != null) {
            setState(() => _following = false);
          }
          return false;
        },
        child: widget.frame([
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 24),
            sliver: SliverList.builder(
              itemCount: head + rows.length,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(hint, style: t.hint),
                  );
                }
                if (showWho && i == 1) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final sp in d.speakers)
                          _name(
                            t,
                            'who-${sp.n}',
                            sp.n,
                            sp.label,
                            pill: true,
                            trailing: Padding(
                              padding: const EdgeInsets.only(left: 5),
                              child: Text(
                                talkTime(sp.seconds),
                                style: TextStyle(fontSize: 12.5, color: t.sub),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }
                final (index, p) = rows[i - head];
                final spoken = index == _active;
                return Container(
                  key: _rowKeys.putIfAbsent(index, GlobalKey.new),
                  padding: const EdgeInsets.fromLTRB(7, 6, 6, 6),
                  decoration: BoxDecoration(
                    color: spoken ? t.newBg : null,
                    border: Border(
                      bottom: BorderSide(color: t.line),
                      left: BorderSide(width: 3, color: spoken ? t.accent : Colors.transparent),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: _TimeChip(p.t, _seekAndFollow),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (p.spk != null)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Transform.translate(
                                      offset: const Offset(-6, 0),
                                      child: _name(t, 'p-$index', p.spk!, p.who),
                                    ),
                                  ),
                                ),
                              for (final (piece, hit) in splitMatches(p.text, q))
                                TextSpan(
                                  text: piece,
                                  style: hit ? TextStyle(backgroundColor: t.mark) : null,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ], _scroll),
      ),
    );
    if (_following || _active == null || _searching) return list;
    return Stack(
      children: [
        list,
        Positioned(
          left: 0,
          right: 12,
          bottom: 14,
          child: Center(
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: Btn(
                icon: Icons.my_location,
                label: 'Follow the recording',
                tooltip: 'Scroll back to the passage being played and keep up with it',
                onPressed: _follow,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
