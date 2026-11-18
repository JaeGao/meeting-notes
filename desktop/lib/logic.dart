// Rules with no drawing in them, so they can be tested on their own:
// names and labels, which menu items a recording gets, the notes format, the record area.
import 'dart:math' as math;

import 'models.dart';

const statusLabels = {
  'new': 'New',
  'transcript': 'Transcript only',
  'notes': 'Notes written',
  'no-audio': 'No audio track',
};

const languages = [
  ('auto', 'Auto (English and Mandarin)'),
  ('zh', 'All in Chinese'),
  ('en', 'All in English'),
];

String hms(int s) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
}

int secs(String t) => t.split(':').fold(0, (a, v) => a * 60 + (int.tryParse(v) ?? 0));

String displayName(Entry e) {
  final t = e.title;
  if (t != null && t.isNotEmpty && t != 'untitled') return t;
  return e.hasFolder ? 'Untitled meeting' : e.file;
}

/// The title as the owner typed it: empty while the meeting is still untitled.
String editableTitle(Entry e) => (e.title != null && e.title != 'untitled') ? e.title! : '';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec', //
];

String _clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "Wed, Nov 18, 2026, 11:32 AM". Falls back to the raw text if it is not a date.
String longWhen(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}, ${_clock(d)}';
}

/// "Nov 18, 11:32 AM".
String shortWhen(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_months[d.month - 1]} ${d.day}, ${_clock(d)}';
}

/// The duration without a leading "00:" hour.
String shortDuration(String d) => d.startsWith('00:') ? d.substring(3) : d;

// ---------- status chip ----------

enum ChipTone { fresh, transcript, notes, off, bad }

class ChipSpec {
  final String label;
  final ChipTone tone;
  const ChipSpec(this.label, this.tone);
}

String jobVerb(Job j) => switch (j.kind) {
  'notes' => 'Writing notes',
  'speakers' => 'Finding speakers',
  _ => 'Transcribing',
};

ChipSpec chipFor(Entry e) {
  final j = e.job;
  if (j != null && j.busy) {
    return j.state == 'queued'
        ? const ChipSpec('Waiting', ChipTone.off)
        : ChipSpec(jobVerb(j), ChipTone.fresh);
  }
  if (!e.exists) return const ChipSpec('Recording missing', ChipTone.bad);
  return switch (e.status) {
    'transcript' => const ChipSpec('Transcript only', ChipTone.transcript),
    'notes' => const ChipSpec('Notes written', ChipTone.notes),
    'no-audio' => const ChipSpec('No audio track', ChipTone.off),
    _ => const ChipSpec('New', ChipTone.fresh),
  };
}

/// The line under the progress bar while a job runs.
String progressLabel(Job j) {
  if (j.state == 'queued') return 'Waiting for another job';
  if (j.kind == 'notes') return 'Claude is writing notes · ${hms(j.elapsed)}';
  final what = (j.kind == 'speakers' || j.step == 'speakers')
      ? 'Telling speakers apart'
      : 'Transcribing';
  final pct = j.progress != null ? ' ${j.progress}%' : '';
  return '$what$pct · ${hms(j.elapsed)}';
}

// ---------- the options menu of a recording ----------

enum Act {
  stop,
  transcribe,
  transcribeAgain,
  writeNotes,
  rewriteNotes,
  identifySpeakers,
  rename,
  editNotes,
  openTranscript,
  reveal,
  openFolder,
  remove,
}

class MenuEntry {
  final Act act;
  final String label;
  final bool danger;
  const MenuEntry(this.act, this.label, {this.danger = false});
}

/// The menu for a recording, in order. A null is a dividing line.
List<MenuEntry?> menuFor(Entry e) {
  final items = <MenuEntry?>[];
  if (e.busy) {
    final what = switch (e.job!.kind) {
      'notes' => 'writing notes',
      'speakers' => 'finding speakers',
      _ => 'transcribing',
    };
    items.add(MenuEntry(Act.stop, 'Stop $what'));
  } else {
    if (e.status == 'new' && e.exists && e.audio) {
      items.add(const MenuEntry(Act.transcribe, 'Transcribe…'));
    }
    if (e.status == 'transcript') {
      items.add(const MenuEntry(Act.writeNotes, 'Write notes with Claude'));
    }
    if (e.status == 'notes') {
      items.add(const MenuEntry(Act.rewriteNotes, 'Rewrite notes with Claude'));
    }
    if (e.hasFolder && e.exists && e.audio) {
      items.add(const MenuEntry(Act.transcribeAgain, 'Transcribe again…'));
      items.add(const MenuEntry(Act.identifySpeakers, 'Identify speakers…'));
    }
  }
  if (e.hasFolder) items.add(const MenuEntry(Act.rename, 'Rename'));
  if (items.isNotEmpty) items.add(null);
  if (e.status == 'notes') items.add(const MenuEntry(Act.editNotes, 'Edit notes in text editor'));
  if (e.hasFolder) items.add(const MenuEntry(Act.openTranscript, 'Open transcript file'));
  if (e.exists) items.add(const MenuEntry(Act.reveal, 'Show recording in Finder'));
  if (e.hasFolder) items.add(const MenuEntry(Act.openFolder, 'Open notes folder'));
  if (e.hasFolder && !e.busy) {
    items.add(null);
    items.add(const MenuEntry(Act.remove, 'Move notes to Trash', danger: true));
  }
  while (items.isNotEmpty && items.last == null) {
    items.removeLast();
  }
  return items;
}

// ---------- the record area ----------

/// The smallest area that can be recorded, as a share of the screen's width or height.
const minAreaShare = 0.05;

/// The area between two points on the picture (each 0..1), or null when it is too small.
Area? areaBetween(double x1, double y1, double x2, double y2) {
  double c(double v) => v.clamp(0.0, 1.0);
  final a = Area(
    math.min(c(x1), c(x2)),
    math.min(c(y1), c(y2)),
    (c(x1) - c(x2)).abs(),
    (c(y1) - c(y2)).abs(),
  );
  return (a.w < minAreaShare || a.h < minAreaShare) ? null : a;
}

String areaInfo(Source s, Area? area) {
  if (s.isSoundOnly) {
    return "No picture: only the Mac's sound and your microphone. For a call nobody shares a "
        'screen in, or a meeting in the room. While recording, Change… can add a screen.';
  }
  if (s.kind == 'window') {
    return 'Records the part of the screen where this ${s.app} window is now, with all of '
        "the Mac's sound. Keep it in place and in front.";
  }
  if (area == null) {
    return 'Recording the whole screen. Drag on the picture to record only part of it.';
  }
  return 'Recording only the marked area, about ${(area.w * s.width).round()} × '
      '${(area.h * s.height).round()}. Drag again to change it.';
}

String sourceName(Source s) => switch (s.kind) {
  'none' => 'Sound only',
  'window' => s.app,
  _ => s.main ? 'Main screen' : 'Screen ${s.number}',
};

/// The top bar's words while recording.
String recordingLabel(RecState r) => switch (r.state) {
  'starting' => 'Starting…',
  'stopping' => 'Saving…',
  _ => [
    'Recording',
    if (r.label != null && r.label!.isNotEmpty) r.label!,
    if (r.mic == false) 'no microphone',
  ].join(' · '),
};

/// Which passage is being spoken at [seconds], given when each passage starts (in order):
/// the last one that has started. Null before the first passage or with no passages.
int? activePassage(List<int> starts, double seconds) {
  var lo = 0, hi = starts.length - 1;
  int? found;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (starts[mid] <= seconds) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

const playbackSpeeds = [1.0, 1.25, 1.5, 2.0];

/// The speed after [now] in the round of speeds; an unknown speed goes back to 1.
double nextSpeed(double now) {
  final i = playbackSpeeds.indexWhere((s) => (s - now).abs() < 0.01);
  return i < 0 ? 1.0 : playbackSpeeds[(i + 1) % playbackSpeeds.length];
}

String speedLabel(double s) => '${s == s.roundToDouble() ? s.toInt() : s}×';

const _soundEndings = ['.m4a', '.mp3', '.wav'];

/// True for a recording with no picture, which gets a slim player instead of a video.
bool isSoundFile(String path) => _soundEndings.any(path.toLowerCase().endsWith);

// ---------- speakers ----------

/// Minutes a speaker talked, as shown beside the name.
String talkTime(int seconds) {
  final m = (seconds / 60).round();
  return m == 0 ? '<1 min' : '$m min';
}

/// A stable hue per speaker number, so a speaker keeps one colour.
double speakerHue(int n) => ((n * 67) % 360).toDouble();

// ---------- notes (a small part of Markdown) ----------

class Span {
  final String text;
  final bool bold, code;
  final int? seek; // seconds, when the span is a [HH:MM:SS] time
  const Span(this.text, {this.bold = false, this.code = false, this.seek});
}

sealed class Block {
  const Block();
}

class Heading extends Block {
  final int level;
  final List<Span> spans;
  const Heading(this.level, this.spans);
}

class Para extends Block {
  final List<Span> spans;
  const Para(this.spans);
}

class ListBlock extends Block {
  final bool ordered;
  final List<List<Span>> items;
  const ListBlock(this.ordered, this.items);
}

class TableBlock extends Block {
  /// The first row is the header.
  final List<List<List<Span>>> rows;
  const TableBlock(this.rows);
}

final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[(\d{1,2}:\d{2}:\d{2})\]');

List<Span> parseInline(String s, {bool bold = false}) {
  final out = <Span>[];
  var at = 0;
  for (final m in _inline.allMatches(s)) {
    if (m.start > at) out.add(Span(s.substring(at, m.start), bold: bold));
    if (m.group(1) != null) {
      out.addAll(parseInline(m.group(1)!, bold: true));
    } else if (m.group(2) != null) {
      out.add(Span(m.group(2)!, bold: bold, code: true));
    } else {
      out.add(Span(m.group(3)!, bold: bold, seek: secs(m.group(3)!)));
    }
    at = m.end;
  }
  if (at < s.length) out.add(Span(s.substring(at), bold: bold));
  return out;
}

final _heading = RegExp(r'^(#{1,3})\s+(.*)');
final _bullet = RegExp(r'^\s*[-*]\s+');
final _numbered = RegExp(r'^\s*\d+\.\s+');
final _tableRule = RegExp(r'^\|[\s:|-]+\|?$');
final _blockStart = RegExp(r'^(#{1,3}\s|\s*[-*]\s|\s*\d+\.\s|\|)');
final _cellSplit = RegExp(r'(?<!\\)\|');

List<String> _cells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith(r'\|')) r = r.substring(0, r.length - 1);
  return [for (final c in r.split(_cellSplit)) c.trim().replaceAll(r'\|', '|')];
}

List<Block> parseNotes(String src) {
  final lines = src.split('\n');
  final out = <Block>[];
  var i = 0;
  while (i < lines.length) {
    final l = lines[i];
    if (l.trim().isEmpty) {
      i++;
      continue;
    }
    final h = _heading.firstMatch(l);
    if (h != null) {
      out.add(Heading(h.group(1)!.length, parseInline(h.group(2)!)));
      i++;
      continue;
    }
    if (l.trim().startsWith('|')) {
      final rows = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(lines[i++].trim());
      }
      final body = rows.where((r) => !_tableRule.hasMatch(r));
      out.add(
        TableBlock([
          for (final r in body) [for (final c in _cells(r)) parseInline(c)],
        ]),
      );
      continue;
    }
    final isBullet = _bullet.hasMatch(l);
    if (isBullet || _numbered.hasMatch(l)) {
      final re = isBullet ? _bullet : _numbered;
      final items = <List<Span>>[];
      while (i < lines.length && re.hasMatch(lines[i])) {
        items.add(parseInline(lines[i++].replaceFirst(re, '')));
      }
      out.add(ListBlock(!isBullet, items));
      continue;
    }
    final p = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty && !_blockStart.hasMatch(lines[i])) {
      p.add(lines[i++]);
    }
    out.add(Para(parseInline(p.join(' '))));
  }
  return out;
}

/// Splits [text] around each place [query] appears, ignoring case.
/// Returns (piece, isMatch) pairs that join back to the text.
List<(String, bool)> splitMatches(String text, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [(text, false)];
  final lower = text.toLowerCase();
  if (lower.length != text.length) return [(text, false)]; // rare letters change length
  final out = <(String, bool)>[];
  var at = 0;
  while (true) {
    final i = lower.indexOf(q, at);
    if (i < 0) break;
    if (i > at) out.add((text.substring(at, i), false));
    out.add((text.substring(i, i + q.length), true));
    at = i + q.length;
  }
  if (at < text.length) out.add((text.substring(at), false));
  return out;
}
