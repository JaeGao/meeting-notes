// Walks the window with a stand-in engine: every way in has a way out, and each action
// reaches the engine with the right request.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meeting_notes/engine.dart';
import 'package:meeting_notes/models.dart';
import 'package:meeting_notes/store.dart';
import 'package:meeting_notes/ui/detail.dart';
import 'package:meeting_notes/ui/home.dart';
import 'package:meeting_notes/ui/theme.dart';

Map<String, dynamic> meeting(String id, String title, String status, {String? folder}) => {
  'id': id,
  'path': '/m/$id.mkv',
  'file': '$id.mkv',
  'exists': true,
  'recorded': '2026-11-18T11:32',
  'duration': '00:22:52',
  'audio': true,
  'status': status,
  'folder': folder,
  'title': folder == null ? null : title,
  'playable': false,
  'job': null,
};

class FakeApi extends Api {
  final calls = <(String, Map<String, dynamic>)>[];
  String? failNext;
  Map<String, dynamic>? recording;
  int extraPassages = 0; // more transcript, to have something to scroll through
  List<Map<String, dynamic>> entries = [
    meeting('n1', 'Weekly sync', 'notes', folder: '/f/n1'),
    meeting('t1', 'Planning', 'transcript', folder: '/f/t1'),
    meeting('new1', '', 'new'),
  ];

  @override
  Future<Map<String, dynamic>> get(String path) async {
    if (path == 'state') {
      return {
        'ok': true,
        'entries': entries,
        'recording': recording,
        'recorderBuilt': true,
        'settings': {
          'vocabulary': 'Acme',
          'folders': '',
          'defaultFolders': ['/Users/x/Movies'],
          'meetingsDir': '/Users/x/Documents/Meetings',
          'missing': <String>[],
          'claude': true,
        },
      };
    }
    return {
      'ok': true,
      'notes': path.endsWith('n1') ? '# Notes\n\nDecided at [00:01:05].' : null,
      'paragraphs': [
        {'t': 0, 'text': 'Tax code first.', 'spk': 1, 'who': 'Speaker 1'},
        {'t': 65, 'text': 'Then the rate.', 'spk': 2, 'who': 'Speaker 2'},
        for (var i = 0; i < extraPassages; i++)
          {
            't': 100 + i * 10,
            'text': 'Passage number $i of the long talk.',
            'spk': 1,
            'who': 'Speaker 1',
          },
      ],
      'speakers': [
        {'n': 1, 'name': '', 'label': 'Speaker 1', 'seconds': 600},
        {'n': 2, 'name': '', 'label': 'Speaker 2', 'seconds': 20},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic> body = const {}]) async {
    calls.add((path, body));
    if (failNext != null) {
      final e = failNext;
      failNext = null;
      return {'ok': false, 'error': e};
    }
    if (path == 'record/sources') {
      return {
        'ok': true,
        'displays': [
          {'id': 1, 'width': 2000, 'height': 1000, 'main': true, 'number': 1, 'thumb': ''},
        ],
        'windows': [
          {'id': 7, 'title': 'Call', 'app': 'Zoom', 'width': 800, 'height': 600, 'thumb': ''},
        ],
      };
    }
    if (path == 'remove') return {'ok': true, 'trashed': '/Trash/n1'};
    return {'ok': true, 'message': ''};
  }

  @override
  Future<Uint8List?> preview(String name) async => null;

  List<String> get paths => [for (final c in calls) c.$1];
  Map<String, dynamic> body(String path) => calls.lastWhere((c) => c.$1 == path).$2;
}

class FakeEngine extends Engine {
  FakeEngine(super.api);
  @override
  Future<String?> ensure() async => null;
  @override
  Future<void> stopIfIdle() async {}
}

class NoPrefs extends Prefs {
  final data = <String, double?>{};
  @override
  void load() {}
  @override
  double? number(String key) => data[key];
  @override
  void set(String key, double? value) => data[key] = value;
}

Store? _live;

/// A window test that stops the store's refresh timer before the test ends.
void appTest(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      _live?.dispose();
      _live = null;
    }
  });
}

Future<(Store, FakeApi)> open(
  WidgetTester tester, {
  Size size = const Size(1280, 820),
  void Function(FakeApi api)? setUp,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // The recording dot pulses for ever; with reduced motion it stays still and tests can settle.
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
    disableAnimations: true,
  );
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final api = FakeApi();
  setUp?.call(api);
  final store = Store(api: api, engine: FakeEngine(api), prefs: NoPrefs());
  _live = store;
  await tester.pumpWidget(
    MaterialApp(
      theme: T.light.theme(),
      builder: (context, child) => Stack(
        children: [
          ?child,
          ToastLayer(store: store),
        ],
      ),
      home: HomePage(store: store),
    ),
  );
  await store.start();
  await tester.pumpAndSettle();
  return (store, api);
}

Future<void> esc(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

final more = find.byTooltip('More actions');

void main() {
  appTest('the list opens a meeting and Esc closes it', (tester) async {
    final (store, _) = await open(tester);
    expect(find.text('Choose a recording on the left, or press Record.'), findsOneWidget);
    await tap(tester, find.text('Weekly sync'));
    expect(store.sel, 'n1');
    expect(find.text('Notes'), findsWidgets);
    expect(find.textContaining('Decided at'), findsOneWidget);
    await esc(tester);
    expect(store.sel, isNull);
    expect(find.text('Choose a recording on the left, or press Record.'), findsOneWidget);
  });

  appTest('the menu closes with Esc or a click outside and leaves the meeting open', (
    tester,
  ) async {
    final (store, _) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, more);
    expect(find.text('Move notes to Trash'), findsOneWidget);
    await esc(tester);
    expect(find.text('Move notes to Trash'), findsNothing);
    expect(store.sel, 'n1');
    await tap(tester, more);
    await tester.tapAt(const Offset(700, 700));
    await tester.pumpAndSettle();
    expect(find.text('Move notes to Trash'), findsNothing);
    expect(store.sel, 'n1');
  });

  appTest('a row has its own options menu without opening the meeting', (tester) async {
    final (store, api) = await open(tester);
    await tap(tester, find.byTooltip('Options for Planning'));
    expect(find.text('Write notes with Claude'), findsOneWidget);
    await tap(tester, find.text('Write notes with Claude'));
    expect(api.body('notes'), {'id': 't1'});
    expect(store.sel, isNull);
  });

  appTest('trash asks first, then offers Undo', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, more);
    await tap(tester, find.text('Move notes to Trash'));
    expect(find.text('Move notes to Trash?'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(api.paths, isNot(contains('remove')));

    await tap(tester, more);
    await tap(tester, find.text('Move notes to Trash'));
    await tap(tester, find.text('Move to Trash'));
    expect(api.body('remove'), {'id': 'n1'});
    expect(find.text('Notes moved to the Trash.'), findsOneWidget);
    await tap(tester, find.text('Undo'));
    expect(api.body('restore'), {'trashed': '/Trash/n1'});
    expect(find.text('Notes moved to the Trash.'), findsNothing);
  });

  appTest('rewriting notes asks first', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, more);
    await tap(tester, find.text('Rewrite notes with Claude'));
    expect(find.text('Rewrite the notes?'), findsOneWidget);
    await esc(tester);
    expect(api.paths, isNot(contains('notes')));
  });

  appTest('the title is renamed in place: Enter saves, Esc cancels only the edit', (tester) async {
    final (store, api) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.byTooltip('Click to rename'));
    await tester.enterText(find.byType(TextField), 'Tax sync');
    await esc(tester);
    expect(api.paths, isNot(contains('title')));
    expect(store.sel, 'n1', reason: 'Esc cancelled the edit, not the meeting');
    expect(find.byType(TextField), findsNothing);

    await tap(tester, find.byTooltip('Click to rename'));
    await tester.enterText(find.byType(TextField), '  Tax sync ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.body('title'), {'id': 'n1', 'title': 'Tax sync'});
  });

  appTest('Rename in a row menu opens that meeting with the title ready to type', (tester) async {
    final (store, _) = await open(tester);
    await tap(tester, find.byTooltip('Options for Planning'));
    await tap(tester, find.text('Rename'));
    expect(store.sel, 't1');
    expect(find.widgetWithText(TextField, 'Meeting title, then Enter'), findsOneWidget);
  });

  appTest('search filters passages; Esc clears it first, then closes the meeting', (tester) async {
    final (store, _) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.text('Transcript'));
    expect(find.textContaining('Tax code first.', findRichText: true), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'rate');
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 passages match.'), findsOneWidget);
    expect(find.textContaining('Tax code first.', findRichText: true), findsNothing);
    await esc(tester);
    expect(store.search, '');
    expect(store.sel, 'n1');
    await esc(tester);
    expect(store.sel, isNull);
  });

  appTest('a speaker is renamed from the transcript', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.text('Transcript'));
    await tap(tester, find.text('Speaker 2').first);
    await tester.enterText(find.widgetWithText(TextField, 'Name for Speaker 2'), 'Jae');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.body('speaker'), {'id': 'n1', 'number': 2, 'name': 'Jae'});
  });

  appTest('transcribe again asks for language and people, and can be cancelled', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, more);
    await tap(tester, find.text('Transcribe again…'));
    expect(find.text('Replaces the transcript. Your notes file is kept.'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(api.paths, isNot(contains('transcribe')));

    await tap(tester, more);
    await tap(tester, find.text('Transcribe again…'));
    await tap(tester, find.text('All in English'));
    await tap(tester, find.widgetWithText(TextButton, 'Transcribe again'));
    expect(api.body('transcribe'), {'id': 'n1', 'lang': 'en'});
  });

  appTest('a new recording is transcribed from its header', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('new1.mkv'));
    await tap(tester, find.widgetWithText(TextButton, 'Transcribe'));
    expect(api.body('transcribe'), {'id': 'new1', 'lang': 'auto'});
  });

  appTest('settings: Close and Cancel leave, Save sends and closes, a refusal stays open', (
    tester,
  ) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Settings'));
    expect(find.text('Names and terms to spell correctly'), findsOneWidget);
    await tap(tester, find.byTooltip('Close'));
    expect(find.text('Names and terms to spell correctly'), findsNothing);

    await tap(tester, find.text('Settings'));
    await tap(tester, find.text('Cancel'));
    expect(find.text('Names and terms to spell correctly'), findsNothing);

    await tap(tester, find.text('Settings'));
    api.failNext = 'Not a folder on this Mac: /nope';
    await tap(tester, find.text('Save'));
    expect(find.text('Not a folder on this Mac: /nope'), findsOneWidget);
    expect(find.text('Names and terms to spell correctly'), findsOneWidget);
    await tap(tester, find.text('Save'));
    expect(api.body('settings'), {'vocabulary': 'Acme', 'folders': ''});
    expect(find.text('Names and terms to spell correctly'), findsNothing);
    expect(find.text('Settings saved.'), findsOneWidget);
  });

  appTest('record: choose a source and start, or leave with Cancel, Close or Esc', (tester) async {
    final (_, api) = await open(tester);
    for (final leave in [
      () => tap(tester, find.text('Cancel')),
      () => tap(tester, find.byTooltip('Close')),
      () => esc(tester),
    ]) {
      await tap(tester, find.text('Record'));
      expect(find.text('New recording'), findsOneWidget);
      await leave();
      expect(find.text('New recording'), findsNothing);
    }
    expect(api.paths, isNot(contains('record/start')));

    await tap(tester, find.text('Record'));
    expect(find.text('Main screen'), findsOneWidget);
    await tap(tester, find.text('Zoom'));
    await tap(tester, find.text('Record my microphone'));
    await tap(tester, find.text('Start recording'));
    expect(api.body('record/start'), {
      'source': {'kind': 'window', 'id': 7},
      'rect': null,
      'mic': false,
      'auto': true,
    });
    expect(find.text('New recording'), findsNothing);
  });

  appTest('a refused recording keeps the panel open and says why', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Record'));
    api.failNext = 'A recording is already running.';
    await tap(tester, find.text('Start recording'));
    expect(find.text('A recording is already running.'), findsOneWidget);
    expect(find.text('New recording'), findsOneWidget);
  });

  appTest('a meeting with no screen share is recorded as sound only', (tester) async {
    final (_, api) = await open(tester);
    await tap(tester, find.text('Record'));
    await tap(tester, find.text('Sound only'));
    expect(find.textContaining('No picture: only the Mac\'s sound'), findsOneWidget);
    expect(find.text('Whole screen'), findsNothing);
    await tap(tester, find.text('Start recording'));
    expect(api.body('record/start'), {
      'source': {'kind': 'none'},
      'rect': null,
      'mic': true,
      'auto': true,
    });
  });

  Map<String, dynamic> running({String? switchError, double? switchAt}) => {
    'state': 'recording',
    'out': '/m/x.mov',
    'mic': true,
    'elapsed': 65,
    'source': 'display',
    'label': 'Main screen',
    'switchError': switchError,
    'switchAt': switchAt,
  };

  appTest('while recording, Change switches what is recorded', (tester) async {
    final (_, api) = await open(tester, setUp: (api) => api.recording = running());
    expect(find.text('Recording · Main screen'), findsOneWidget);
    expect(find.text('Record'), findsNothing);
    for (final leave in [() => tap(tester, find.text('Cancel')), () => esc(tester)]) {
      await tap(tester, find.text('Change…'));
      expect(find.text('Change what is recorded'), findsOneWidget);
      expect(find.text('Record my microphone'), findsNothing);
      expect(find.text('Start recording'), findsNothing);
      await leave();
      expect(find.text('Change what is recorded'), findsNothing);
    }
    expect(api.paths, isNot(contains('record/switch')));

    await tap(tester, find.text('Change…'));
    await tap(tester, find.text('Zoom'));
    await tap(tester, find.text('Switch'));
    expect(api.body('record/switch'), {
      'source': {'kind': 'window', 'id': 7},
      'rect': null,
    });
    expect(find.text('Change what is recorded'), findsNothing);

    await tap(tester, find.text('Change…'));
    await tap(tester, find.text('Sound only'));
    await tap(tester, find.text('Switch'));
    expect(api.body('record/switch'), {
      'source': {'kind': 'none'},
      'rect': null,
    });
  });

  appTest(
    'a refused change keeps the panel open; one the recorder refuses later is reported once',
    (tester) async {
      final (store, api) = await open(tester, setUp: (api) => api.recording = running());
      await tap(tester, find.text('Change…'));
      api.failNext = 'That window is no longer in the list. Refresh the previews.';
      await tap(tester, find.text('Switch'));
      expect(
        find.text('That window is no longer in the list. Refresh the previews.'),
        findsOneWidget,
      );
      expect(find.text('Change what is recorded'), findsOneWidget);
      await esc(tester);
      store.dismissToast();

      api.recording = running(switchError: 'That window is no longer open.', switchAt: 10);
      await store.refresh();
      await tester.pumpAndSettle();
      expect(find.text('That window is no longer open.'), findsOneWidget);
      store.dismissToast();
      await store.refresh();
      await tester.pumpAndSettle();
      expect(find.text('That window is no longer open.'), findsNothing);
    },
  );

  appTest('Change waits while the recording is starting or saving', (tester) async {
    await open(tester, setUp: (api) => api.recording = {...running(), 'state': 'stopping'});
    expect(find.text('Saving…'), findsOneWidget);
    await tap(tester, find.text('Change…'));
    expect(find.text('Change what is recorded'), findsNothing);
  });

  appTest('the transcript marks the passage being played and keeps it in view', (tester) async {
    await open(tester, setUp: (api) => api.extraPassages = 300);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.text('Transcript'));
    Finder passage(int i) =>
        find.textContaining('Passage number $i of the long talk.', findRichText: true);
    expect(passage(250), findsNothing, reason: 'far down, not on screen yet');
    expect(find.text('Follow the recording'), findsNothing);

    // The recording reaches passage 250.
    playheadOnScreen!.value = const Playhead(100 + 250 * 10 + 3, true);
    await tester.pumpAndSettle();
    expect(passage(250), findsOneWidget);
    final box = tester.widget<Container>(
      find.ancestor(of: passage(250), matching: find.byType(Container)).first,
    );
    expect((box.decoration as BoxDecoration).color, T.light.newBg, reason: 'marked as spoken');

    // Scrolling away by hand stops the following and offers a way back.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(passage(250)),
        scrollDelta: const Offset(0, -4000),
      ),
    );
    await tester.pumpAndSettle();
    expect(passage(250), findsNothing);
    expect(find.text('Follow the recording'), findsOneWidget);
    playheadOnScreen!.value = const Playhead(100 + 251 * 10 + 3, true);
    await tester.pumpAndSettle();
    expect(passage(251), findsNothing, reason: 'left where the owner scrolled to');

    await tap(tester, find.text('Follow the recording'));
    expect(passage(251), findsOneWidget);
    expect(find.text('Follow the recording'), findsNothing);

    // And back near the start.
    playheadOnScreen!.value = const Playhead(70, true);
    await tester.pumpAndSettle();
    expect(find.textContaining('Then the rate.', findRichText: true), findsOneWidget);
  });

  appTest('the title scrolls away with the text; the tabs and search stay', (tester) async {
    await open(tester, setUp: (api) => api.extraPassages = 300);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.text('Transcript'));
    final title = find.byTooltip('Click to rename');
    expect(title.hitTestable(), findsOneWidget);
    final tabTop = tester.getTopLeft(find.text('Transcript')).dy;

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.textContaining('Tax code first.', findRichText: true)),
        scrollDelta: const Offset(0, 3000),
      ),
    );
    await tester.pumpAndSettle();
    expect(title.hitTestable(), findsNothing, reason: 'the title has scrolled off');
    expect(find.text('Transcript').hitTestable(), findsOneWidget);
    expect(find.text('Notes').hitTestable(), findsOneWidget);
    expect(find.byType(TextField).hitTestable(), findsOneWidget, reason: 'search stays');
    expect(tester.getTopLeft(find.text('Transcript')).dy, lessThan(tabTop), reason: 'moved up');

    // Switching tab starts that text at its top, with the title back.
    await tap(tester, find.text('Notes'));
    expect(title.hitTestable(), findsOneWidget);
  });

  appTest('nothing is marked until the recording is played', (tester) async {
    await open(tester);
    await tap(tester, find.text('Weekly sync'));
    await tap(tester, find.text('Transcript'));
    final first = find.textContaining('Tax code first.', findRichText: true);
    final box = tester.widget<Container>(
      find.ancestor(of: first, matching: find.byType(Container)).first,
    );
    expect((box.decoration as BoxDecoration).color, isNull);
  });

  appTest('narrow window: one pane at a time, with a Back arrow', (tester) async {
    final (store, _) = await open(tester, size: const Size(600, 700));
    expect(find.text('RECORDINGS'), findsOneWidget);
    await tap(tester, find.text('Weekly sync'));
    expect(find.text('RECORDINGS'), findsNothing);
    await tap(tester, find.byTooltip('Back to recordings'));
    expect(store.sel, isNull);
    expect(find.text('RECORDINGS'), findsOneWidget);
    await tap(tester, find.text('Planning'));
    await esc(tester);
    expect(find.text('RECORDINGS'), findsOneWidget);
  });

  appTest('an engine that will not start says so and offers Try again', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeApi();
    final engine = _DeadEngine(api);
    final store = Store(api: api, engine: engine, prefs: NoPrefs());
    _live = store;
    await tester.pumpWidget(
      MaterialApp(
        theme: T.light.theme(),
        home: HomePage(store: store),
      ),
    );
    await store.start();
    await tester.pumpAndSettle();
    expect(find.text('Meeting Notes could not start'), findsOneWidget);
    expect(find.text('no python'), findsOneWidget);
    engine.dead = false;
    await tap(tester, find.text('Try again'));
    expect(find.text('Weekly sync'), findsOneWidget);
  });
}

class _DeadEngine extends FakeEngine {
  bool dead = true;
  _DeadEngine(super.api);
  @override
  Future<String?> ensure() async => dead ? 'no python' : null;
}
