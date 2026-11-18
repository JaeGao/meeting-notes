import 'package:flutter_test/flutter_test.dart';
import 'package:meeting_notes/logic.dart';
import 'package:meeting_notes/models.dart';

Entry entry({
  String status = 'new',
  String? folder,
  bool exists = true,
  bool audio = true,
  String? title,
  Job? job,
}) => Entry(
  id: 'a',
  path: '/m/a.mov',
  file: 'a.mov',
  recorded: '2026-11-18T11:32',
  duration: '00:22:52',
  status: status,
  folder: folder,
  exists: exists,
  audio: audio,
  title: title,
  job: job,
);

List<Act> acts(Entry e) => [
  for (final m in menuFor(e))
    if (m != null) m.act,
];

void main() {
  group('times and names', () {
    test('hms and secs round-trip', () {
      expect(hms(3725), '01:02:05');
      expect(secs('01:02:05'), 3725);
      expect(secs('2:05'), 125);
    });
    test('dates read like the Mac writes them', () {
      expect(longWhen('2026-11-18T11:32'), 'Wed, Nov 18, 2026, 11:32 AM');
      expect(shortWhen('2026-11-17T14:16'), 'Nov 17, 2:16 PM');
      expect(shortWhen('2026-11-17T00:05'), 'Nov 17, 12:05 AM');
      expect(longWhen('not a date'), 'not a date');
    });
    test('a recording is named by its title, else its file', () {
      expect(displayName(entry()), 'a.mov');
      expect(displayName(entry(folder: '/f', title: 'untitled')), 'Untitled meeting');
      expect(displayName(entry(folder: '/f', title: 'Weekly sync')), 'Weekly sync');
      expect(editableTitle(entry(folder: '/f', title: 'untitled')), '');
    });
    test('talk time never shows zero minutes', () {
      expect(talkTime(10), '<1 min');
      expect(talkTime(600), '10 min');
    });
  });

  group('status chip', () {
    test('a running job wins over the status', () {
      final e = entry(
        status: 'transcript',
        folder: '/f',
        job: const Job(kind: 'notes', state: 'running'),
      );
      expect(chipFor(e).label, 'Writing notes');
      expect(
        chipFor(
          entry(
            job: const Job(kind: 'transcribe', state: 'queued'),
          ),
        ).label,
        'Waiting',
      );
    });
    test('a missing recording is called out', () {
      expect(
        chipFor(entry(status: 'notes', folder: '/f', exists: false)).label,
        'Recording missing',
      );
    });
    test('each status has its label', () {
      expect(chipFor(entry()).label, 'New');
      expect(chipFor(entry(status: 'no-audio', audio: false)).label, 'No audio track');
      expect(chipFor(entry(status: 'notes', folder: '/f')).label, 'Notes written');
    });
    test('progress label says what is happening', () {
      expect(
        progressLabel(const Job(kind: 'transcribe', state: 'running', progress: 40, elapsed: 65)),
        'Transcribing 40% · 00:01:05',
      );
      expect(
        progressLabel(
          const Job(kind: 'transcribe', state: 'running', step: 'speakers', elapsed: 5),
        ),
        'Telling speakers apart · 00:00:05',
      );
      expect(progressLabel(const Job(kind: 'notes', state: 'queued')), 'Waiting for another job');
    });
  });

  group('options menu', () {
    test('a new recording can only be transcribed and shown', () {
      expect(acts(entry()), [Act.transcribe, Act.reveal]);
    });
    test('no audio: nothing to transcribe', () {
      expect(acts(entry(status: 'no-audio', audio: false)), [Act.reveal]);
    });
    test('a transcript offers notes, redo, speakers, rename, files and trash', () {
      expect(acts(entry(status: 'transcript', folder: '/f')), [
        Act.writeNotes,
        Act.transcribeAgain,
        Act.identifySpeakers,
        Act.rename,
        Act.openTranscript,
        Act.reveal,
        Act.openFolder,
        Act.remove,
      ]);
    });
    test('written notes can be rewritten and edited', () {
      final a = acts(entry(status: 'notes', folder: '/f'));
      expect(a, containsAll([Act.rewriteNotes, Act.editNotes]));
      expect(a, isNot(contains(Act.writeNotes)));
    });
    test('while a job runs: Stop, and no trash or redo', () {
      final a = acts(
        entry(
          status: 'transcript',
          folder: '/f',
          job: const Job(kind: 'transcribe', state: 'running'),
        ),
      );
      expect(a.first, Act.stop);
      expect(a, isNot(contains(Act.remove)));
      expect(a, isNot(contains(Act.transcribeAgain)));
      expect(a, isNot(contains(Act.writeNotes)));
    });
    test('a missing recording cannot be transcribed again or shown', () {
      final a = acts(entry(status: 'notes', folder: '/f', exists: false));
      expect(a, isNot(contains(Act.transcribeAgain)));
      expect(a, isNot(contains(Act.identifySpeakers)));
      expect(a, isNot(contains(Act.reveal)));
      expect(a, contains(Act.remove));
    });
    test('never starts or ends with a dividing line, never two in a row', () {
      for (final e in [
        entry(),
        entry(status: 'no-audio', audio: false),
        entry(status: 'transcript', folder: '/f'),
        entry(status: 'notes', folder: '/f', exists: false),
        entry(
          job: const Job(kind: 'transcribe', state: 'running'),
        ),
      ]) {
        final m = menuFor(e);
        expect(m.first, isNotNull);
        expect(m.last, isNotNull);
        for (var i = 1; i < m.length; i++) {
          expect(m[i] == null && m[i - 1] == null, isFalse);
        }
      }
    });
  });

  group('record area', () {
    test('an area smaller than 5% of either side is refused', () {
      expect(areaBetween(0.1, 0.1, 0.12, 0.9), isNull);
      expect(areaBetween(0.1, 0.1, 0.9, 0.14), isNull);
    });
    test('a drag in any direction gives the same area, kept on the picture', () {
      final a = areaBetween(0.8, 0.9, 0.2, 0.1)!;
      expect([a.x, a.y], [0.2, 0.1]);
      expect(a.w, closeTo(0.6, 1e-9));
      expect(a.h, closeTo(0.8, 1e-9));
      final b = areaBetween(-0.5, -1, 0.5, 0.5)!;
      expect([b.x, b.y, b.w, b.h], [0, 0, 0.5, 0.5]);
    });
    test('the info line names the size in screen points', () {
      const d = Source(kind: 'display', id: 1, width: 2000, height: 1000);
      expect(areaInfo(d, null), startsWith('Recording the whole screen'));
      expect(areaInfo(d, const Area(0, 0, 0.5, 0.5)), contains('1000 × 500'));
      const w = Source(kind: 'window', id: 2, width: 10, height: 10, app: 'Zoom');
      expect(areaInfo(w, null), contains('this Zoom window'));
    });
  });

  group('what is recorded', () {
    test('sound only is a source with its own words', () {
      expect(sourceName(Source.soundOnly), 'Sound only');
      expect(areaInfo(Source.soundOnly, null), startsWith('No picture'));
    });
    test('the top bar says what is being recorded', () {
      expect(
        recordingLabel(const RecState(state: 'recording', label: 'Zoom', mic: true)),
        'Recording · Zoom',
      );
      expect(
        recordingLabel(const RecState(state: 'recording', label: 'Sound only', mic: false)),
        'Recording · Sound only · no microphone',
      );
      expect(recordingLabel(const RecState(state: 'recording')), 'Recording');
      expect(recordingLabel(const RecState(state: 'starting', label: 'Zoom')), 'Starting…');
      expect(recordingLabel(const RecState(state: 'stopping')), 'Saving…');
    });
    test('recordings with no picture are told by their ending', () {
      expect(isSoundFile('/m/Meeting 1.M4A'), isTrue);
      expect(isSoundFile('/m/a.wav'), isTrue);
      expect(isSoundFile('/m/a.mov'), isFalse);
    });
  });

  group('following the recording', () {
    const starts = [0, 44, 66, 114, 142];
    test('the passage being spoken is the last one that has started', () {
      expect(activePassage(starts, 0), 0);
      expect(activePassage(starts, 43.9), 0);
      expect(activePassage(starts, 44), 1);
      expect(activePassage(starts, 100), 2);
      expect(activePassage(starts, 9999), 4);
    });
    test('nothing is marked before the first passage, or with no passages', () {
      expect(activePassage([12, 30], 5), isNull);
      expect(activePassage([], 5), isNull);
    });
    test('speeds go round: 1, 1.25, 1.5, 2, and back', () {
      expect([1.0, 1.25, 1.5, 2.0, 0.7].map(nextSpeed).toList(), [1.25, 1.5, 2.0, 1.0, 1.0]);
      expect([1.0, 1.25, 2.0].map(speedLabel).toList(), ['1×', '1.25×', '2×']);
    });
  });

  group('notes format', () {
    test('headings, paragraphs and lists', () {
      final b = parseNotes(
        '# Title\n\nOne line\nsame paragraph\n\n- a\n- b\n\n1. x\n2. y\n### Small',
      );
      expect(b.map((x) => x.runtimeType).toList(), [Heading, Para, ListBlock, ListBlock, Heading]);
      expect((b[0] as Heading).level, 1);
      expect((b[1] as Para).spans.single.text, 'One line same paragraph');
      expect((b[2] as ListBlock).ordered, isFalse);
      expect((b[3] as ListBlock).ordered, isTrue);
      expect((b[3] as ListBlock).items.length, 2);
    });
    test('tables drop the rule line and keep escaped bars', () {
      final t = parseNotes('| A | B |\n|---|:--|\n| 1 | x \\| y |').single as TableBlock;
      expect(t.rows.length, 2);
      expect(t.rows[1][1].single.text, 'x | y');
    });
    test('bold, code and times inside a line', () {
      final s = parseInline('See **the `code` at [00:01:05]** then [1:02:03] end');
      expect(s.map((x) => x.text).toList(), [
        'See ',
        'the ',
        'code',
        ' at ',
        '00:01:05',
        ' then ',
        '1:02:03',
        ' end',
      ]);
      expect(s[1].bold && s[2].bold && s[2].code, isTrue);
      expect(s[4].seek, 65);
      expect(s[6].seek, 3723);
      expect(s.last.bold, isFalse);
    });
    test('a bracket that is not a time stays text', () {
      expect(parseInline('[note] and [12:5]').single.text, '[note] and [12:5]');
    });
  });

  group('search', () {
    test('finds every place, ignoring case, and joins back to the text', () {
      const text = 'Tax code and TAX rate';
      final parts = splitMatches(text, ' tax ');
      expect(parts.where((p) => p.$2).map((p) => p.$1).toList(), ['Tax', 'TAX']);
      expect(parts.map((p) => p.$1).join(), text);
    });
    test('an empty search matches nothing', () {
      expect(splitMatches('abc', '  '), [('abc', false)]);
    });
  });
}
