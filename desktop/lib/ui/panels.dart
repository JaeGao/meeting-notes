// The panels: transcribe options, identify speakers, settings, and new recording.
// Plus the one place that turns a chosen menu item into an action.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'popover.dart';
import 'theme.dart';

// ---------- running a menu ----------

/// Opens the options menu of [e] under [anchor] and carries out the choice.
Future<void> openMenu(BuildContext anchor, Store s, Entry e) async {
  final act = await showPanel<Act>(
    anchor,
    label: 'Options for ${displayName(e)}',
    builder: (_) => MenuList(menuFor(e)),
  );
  if (act == null || !anchor.mounted) return;
  await runAct(anchor, s, e, act);
}

Future<void> runAct(BuildContext anchor, Store s, Entry e, Act act) async {
  switch (act) {
    case Act.stop:
      await s.stopJob(e);
    case Act.transcribe || Act.transcribeAgain:
      final c = await showPanel<TranscribeChoice>(anchor, builder: (_) => TranscribePanel(e));
      if (c != null) await s.transcribe(e, c.lang, count: c.count);
    case Act.identifySpeakers:
      final c = await showPanel<SpeakersChoice>(anchor, builder: (_) => const SpeakersPanel());
      if (c != null) await s.identifySpeakers(e, count: c.count);
    case Act.writeNotes:
      await s.writeNotes(e);
    case Act.rewriteNotes:
      final yes = await confirmBox(
        anchor,
        'Rewrite the notes?',
        'Claude writes the notes again and replaces the current notes file, including any '
            'edits you made to it.',
        'Rewrite notes',
      );
      if (yes) await s.writeNotes(e);
    case Act.rename:
      if (s.sel != e.id) s.select(e.id);
      s.requestRename();
    case Act.editNotes || Act.openTranscript || Act.reveal || Act.openFolder:
      await s.open(e, act);
    case Act.remove:
      final yes = await confirmBox(
        anchor,
        'Move notes to Trash?',
        'The transcript and notes for this meeting go to the Trash. The recording is not touched.',
        'Move to Trash',
      );
      if (yes) await s.remove(e);
  }
}

// ---------- transcribe / speakers ----------

class TranscribeChoice {
  final String lang;
  final int? count;
  const TranscribeChoice(this.lang, this.count);
}

class SpeakersChoice {
  final int? count;
  const SpeakersChoice(this.count);
}

const _countOptions = <(int, String)>[
  (0, 'Work it out (can find too many)'),
  (2, '2 people'),
  (3, '3 people'),
  (4, '4 people'),
  (5, '5 people'),
  (6, '6 people'),
  (7, '7 people'),
  (8, '8 people'),
  (9, '9 people'),
  (10, '10 people'),
];

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}

class TranscribePanel extends StatefulWidget {
  final Entry entry;
  const TranscribePanel(this.entry, {super.key});
  @override
  State<TranscribePanel> createState() => _TranscribePanelState();
}

class _TranscribePanelState extends State<TranscribePanel> {
  late String _lang = languages.any((l) => l.$1 == widget.entry.lang) ? widget.entry.lang! : 'auto';
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final again = widget.entry.hasFolder;
    final what = again ? 'Transcribe again' : 'Transcribe';
    return SizedBox(
      width: 352,
      child: PanelFrame(
        title: what,
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                again
                    ? 'Replaces the transcript. Your notes file is kept.'
                    : 'Choose how the speech should be written down.',
                style: t.hint,
              ),
              const SizedBox(height: 6),
              for (final (v, l) in languages)
                _RadioRow(label: l, selected: _lang == v, onTap: () => setState(() => _lang = v)),
              const SizedBox(height: 12),
              const _FieldLabel('How many people spoke?'),
              Sel<int>(
                value: _count,
                options: _countOptions,
                expand: true,
                label: 'How many people spoke?',
                onChanged: (v) => setState(() => _count = v),
              ),
            ],
          ),
        ),
        footer: [
          Btn(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          Btn(
            label: what,
            kind: BtnKind.primary,
            autofocus: true,
            onPressed: () =>
                Navigator.of(context).pop(TranscribeChoice(_lang, _count == 0 ? null : _count)),
          ),
        ],
      ),
    );
  }
}

class _RadioRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RadioRow({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? t.accent : t.sub,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    );
  }
}

class SpeakersPanel extends StatefulWidget {
  const SpeakersPanel({super.key});
  @override
  State<SpeakersPanel> createState() => _SpeakersPanelState();
}

class _SpeakersPanelState extends State<SpeakersPanel> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return SizedBox(
      width: 372,
      child: PanelFrame(
        title: 'Identify speakers',
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Listens to the recording again and labels each passage by voice. The transcript '
                'text is kept. Names you gave are reset, because the speaker numbers change.',
                style: t.hint,
              ),
              const SizedBox(height: 10),
              const _FieldLabel('How many people spoke?'),
              Sel<int>(
                value: _count,
                options: _countOptions,
                expand: true,
                autofocus: true,
                label: 'How many people spoke?',
                onChanged: (v) => setState(() => _count = v),
              ),
              const SizedBox(height: 8),
              Text(
                'Saying how many gives better labels. Two people on one microphone still count as two.',
                style: t.hint,
              ),
            ],
          ),
        ),
        footer: [
          Btn(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          Btn(
            label: 'Identify speakers',
            kind: BtnKind.primary,
            onPressed: () => Navigator.of(context).pop(SpeakersChoice(_count == 0 ? null : _count)),
          ),
        ],
      ),
    );
  }
}

// ---------- settings ----------

class SettingsPanel extends StatefulWidget {
  final Store store;
  const SettingsPanel(this.store, {super.key});
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final _vocab = TextEditingController(text: widget.store.settings?.vocabulary ?? '');
  late final _folders = TextEditingController(text: widget.store.settings?.folders ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _vocab.dispose();
    _folders.dispose();
    super.dispose();
  }

  Widget _area(TextEditingController c, int lines, {bool autofocus = false}) {
    final t = T.of(context);
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: c,
      autofocus: autofocus,
      minLines: lines,
      maxLines: lines,
      autocorrect: false,
      enableSuggestions: false,
      style: t.mono.copyWith(color: t.ink),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: t.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: border(t.line),
        enabledBorder: border(t.line),
        focusedBorder: border(t.accent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = widget.store.settings ?? const Settings();
    return SizedBox(
      width: 480,
      child: PanelFrame(
        title: 'Settings',
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _FieldLabel('Names and terms to spell correctly'),
              Text(
                'One per line, about 40 at most. Used from the next transcription.',
                style: t.hint,
              ),
              const SizedBox(height: 8),
              _area(_vocab, 8, autofocus: true),
              const SizedBox(height: 12),
              const _FieldLabel('Extra folders to look in for recordings'),
              Text(
                'One path per line. Always included: ${s.defaultFolders.join(' and ')}.',
                style: t.hint,
              ),
              const SizedBox(height: 8),
              _area(_folders, 3),
              const SizedBox(height: 10),
              Text('Transcripts and notes are saved in ${s.meetingsDir}.', style: t.hint),
            ],
          ),
        ),
        footer: [
          Btn(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          Btn(
            label: 'Save',
            kind: BtnKind.primary,
            onPressed: _saving
                ? null
                : () async {
                    setState(() => _saving = true);
                    final ok = await widget.store.saveSettings(_vocab.text, _folders.text);
                    if (!context.mounted) return;
                    if (ok) {
                      Navigator.of(context).pop();
                    } else {
                      setState(() => _saving = false);
                    }
                  },
          ),
        ],
      ),
    );
  }
}

// ---------- new recording ----------

class RecordPanel extends StatelessWidget {
  final Store store;

  /// True when a recording is running and the panel changes what it records.
  final bool switching;
  const RecordPanel(this.store, {super.key, this.switching = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final src = store.sources;
        final ready = !src.loading && src.error == null && store.pick != null;
        return SizedBox(
          width: 820,
          height: 560,
          child: PanelFrame(
            title: switching ? 'Change what is recorded' : 'New recording',
            fillBody: true,
            headerActions: [
              Btn(
                kind: BtnKind.quiet,
                icon: Icons.refresh,
                tooltip: 'Refresh the pictures',
                onPressed: src.loading ? null : store.loadSources,
              ),
            ],
            body: _body(context),
            footer: [
              if (!switching) ...[
                _Check(
                  label: 'Record my microphone',
                  value: store.recMic,
                  onChanged: (v) => store.setRecOptions(mic: v),
                ),
                _Check(
                  label: 'Transcribe when I stop',
                  value: store.recAuto,
                  onChanged: (v) => store.setRecOptions(auto: v),
                ),
                const SizedBox(width: 8),
              ],
              Btn(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
              if (switching)
                Btn(
                  label: 'Switch',
                  kind: BtnKind.primary,
                  onPressed: !ready
                      ? null
                      : () async {
                          final ok = await store.switchSource();
                          if (ok && context.mounted) Navigator.of(context).pop();
                        },
                )
              else
                Btn(
                  label: 'Start recording',
                  kind: BtnKind.primary,
                  leading: const _Dot(Colors.white, size: 8),
                  onPressed: !ready
                      ? null
                      : () async {
                          final ok = await store.startRecording();
                          if (ok && context.mounted) Navigator.of(context).pop();
                        },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final t = T.of(context);
    final src = store.sources;
    if (src.loading) {
      return Center(
        child: Text('Getting a picture of each screen and window…', style: TextStyle(color: t.sub)),
      );
    }
    if (src.error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NoteBox(src.error!, bad: true),
              const SizedBox(height: 12),
              Btn(label: 'Try again', onPressed: store.loadSources),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final list = _SourceList(store);
        final preview = _Preview(store);
        if (c.maxWidth < 600) {
          return Column(
            children: [
              SizedBox(
                height: c.maxHeight * 0.4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: t.line)),
                  ),
                  child: list,
                ),
              ),
              Expanded(child: preview),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              width: 250,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: t.line)),
                ),
                child: list,
              ),
            ),
            Expanded(child: preview),
          ],
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot(this.color, {this.size = 9});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Check extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Check({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 32,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: t.accent,
                checkColor: t.onAccent,
                side: BorderSide(color: t.sub, width: 1.5),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _SourceList extends StatelessWidget {
  final Store store;
  const _SourceList(this.store);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final src = store.sources;
    Widget label(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Text(
        s.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: t.sub,
          letterSpacing: 0.5,
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(6),
      children: [
        label('No screen'),
        _SourceTile(store, Source.soundOnly),
        label('Screens'),
        for (final d in src.displays) _SourceTile(store, d),
        label('Windows'),
        if (src.windows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('No open windows found.', style: t.hint),
          ),
        for (final w in src.windows) _SourceTile(store, w),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  final Store store;
  final Source source;
  const _SourceTile(this.store, this.source);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final on = store.pick?.kind == source.kind && store.pick?.id == source.id;
    final fg = on ? t.newInk : t.ink;
    final bytes = store.thumbs[source.thumb];
    final detail = switch (source.kind) {
      'none' => 'Sound and microphone',
      'window' => source.title,
      _ => '${source.width} × ${source.height}',
    };
    return Semantics(
      selected: on,
      button: true,
      child: Material(
        color: on ? t.newBg : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => store.choose(source),
          hoverColor: t.sunk,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 40,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: t.sunk,
                    border: Border.all(color: t.line),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: source.isSoundOnly
                      ? Icon(Icons.graphic_eq, size: 20, color: t.sub)
                      : bytes == null
                      ? null
                      : Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          alignment: Alignment.topLeft,
                          gaplessPlayback: true,
                        ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sourceName(source),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w600, color: fg, height: 1.3),
                      ),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: fg.withValues(alpha: 0.8),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final Store store;
  const _Preview(this.store);

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final s = store.pick;
    final bytes = s == null ? null : store.thumbs[s.thumb];
    final isDisplay = s?.kind == 'display';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Text(s == null ? '' : areaInfo(s, store.area), style: t.hint),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: (s != null && s.isSoundOnly)
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.graphic_eq, size: 44, color: t.sub),
                        const SizedBox(height: 8),
                        Text(
                          'Sound only',
                          style: TextStyle(color: t.sub, fontWeight: FontWeight.w600),
                        ),
                      ],
                    )
                  : (s == null || bytes == null || s.width <= 0 || s.height <= 0)
                  ? Text('No picture available.', style: TextStyle(color: t.sub))
                  : AspectRatio(
                      aspectRatio: s.width / s.height,
                      child: _Stage(store: store, source: s, bytes: bytes),
                    ),
            ),
          ),
          if (isDisplay) ...[
            const SizedBox(height: 8),
            Btn(
              label: 'Whole screen',
              onPressed: store.area == null ? null : () => store.setArea(null),
            ),
          ],
        ],
      ),
    );
  }
}

/// The picture of what will be recorded. On a screen, dragging marks the area to record.
class _Stage extends StatefulWidget {
  final Store store;
  final Source source;
  final Uint8List bytes;
  const _Stage({required this.store, required this.source, required this.bytes});
  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  Offset? _from, _to; // while dragging, as shares of the picture

  Offset _share(Offset local, Size size) =>
      Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    final canDrag = widget.source.kind == 'display';
    Rect? shown;
    if (_from != null && _to != null) {
      shown = Rect.fromPoints(_from!, _to!);
    } else if (canDrag && widget.store.area != null) {
      final a = widget.store.area!;
      shown = Rect.fromLTWH(a.x, a.y, a.w, a.h);
    }
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final picture = Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            border: Border.all(color: t.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                widget.bytes,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                semanticLabel: 'Picture of what will be recorded',
              ),
              if (shown != null) CustomPaint(painter: _AreaPainter(shown)),
            ],
          ),
        );
        if (!canDrag) return picture;
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => setState(() {
              _from = _share(d.localPosition, size);
              _to = _from;
            }),
            onPanUpdate: (d) => setState(() => _to = _share(d.localPosition, size)),
            onPanCancel: () => setState(() => _from = _to = null),
            onPanEnd: (_) {
              final a = areaBetween(_from!.dx, _from!.dy, _to!.dx, _to!.dy);
              setState(() => _from = _to = null);
              widget.store.setArea(a);
              if (a == null) {
                widget.store.say(
                  'That area is too small. Drag a bigger one, or keep the whole screen.',
                );
              }
            },
            child: picture,
          ),
        );
      },
    );
  }
}

class _AreaPainter extends CustomPainter {
  final Rect share;
  _AreaPainter(this.share);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      share.left * size.width,
      share.top * size.height,
      share.right * size.width,
      share.bottom * size.height,
    );
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF4D4D),
    );
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.share != share;
}
