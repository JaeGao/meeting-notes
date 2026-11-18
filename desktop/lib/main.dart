// Meeting Notes: a Mac app over the meeting-notes engine.
// Record a meeting, transcribe it on this Mac, read the transcript and notes beside the video.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'logic.dart';
import 'models.dart';
import 'store.dart';
import 'ui/detail.dart';
import 'ui/home.dart';
import 'ui/panels.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  runApp(MeetingNotesApp(store: store));
  store.start().then((_) => _check(store));
}

final _shotKey = GlobalKey();

class MeetingNotesApp extends StatefulWidget {
  final Store store;
  const MeetingNotesApp({super.key, required this.store});
  @override
  State<MeetingNotesApp> createState() => _MeetingNotesAppState();
}

class _MeetingNotesAppState extends State<MeetingNotesApp> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // Quitting stops the engine too, unless it is still transcribing, writing or recording.
    _life = AppLifecycleListener(
      onExitRequested: () async {
        await widget.store.engine.stopIfIdle();
        return ui.AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meeting Notes',
      debugShowCheckedModeBanner: false,
      theme: T.light.theme(),
      darkTheme: T.night.theme(),
      themeMode: switch (Platform.environment['MEETING_NOTES_THEME']) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      builder: (context, child) => RepaintBoundary(
        key: _shotKey,
        child: Stack(
          children: [
            ?child,
            ToastLayer(store: widget.store),
          ],
        ),
      ),
      home: HomePage(store: widget.store),
    );
  }
}

// ---------- checking the app by looking at it ----------
//
// MEETING_NOTES_OPEN=<what>[+<panel>] opens a state on launch, for example
//   notes+transcript   the first meeting with notes, on its Transcript tab
//   new                the first recording that is not transcribed
//   record | settings  that panel (soundonly: the record panel with Sound only chosen)
//   notes+more | notes+lang | notes+who   the meeting's menu or panels
//   notes+at+600   the transcript with the recording moved to 10:00 (the passage is marked)
// MEETING_NOTES_SHOT=<file.png> then saves a picture of the window and quits.
// (The video itself is drawn by macOS and stays black in that picture.)
Future<void> _check(Store s) async {
  final open = Platform.environment['MEETING_NOTES_OPEN'];
  final shot = Platform.environment['MEETING_NOTES_SHOT'];
  if (open == null && shot == null) return;
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final parts = (open ?? '').split('+');
  final what = parts.first;
  final panel = parts.length > 1 ? parts[1] : what;
  for (final e in s.entries) {
    if (e.id == what || (e.status == what && !e.busy)) {
      s.select(e.id);
      break;
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 900));
  final e = s.current;
  final more = moreButtonKey.currentContext;
  if (panel == 'transcript') s.setTab('transcript');
  if (panel == 'search') {
    s.setTab('transcript');
    s.setSearch(parts.length > 2 ? parts[2] : 'the');
  }
  if (panel == 'rename') s.requestRename();
  if (panel == 'fullscreen') videoPaneKey.currentState?.openFullScreen();
  if (panel == 'at') {
    // The transcript with the recording moved to a time (not played, so it stays silent).
    s.setTab('transcript');
    final to = int.tryParse(parts.length > 2 ? parts[2] : '') ?? 600;
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 900),
        () => videoPaneKey.currentState?.seek(to),
      ),
    );
  }
  if (panel == 'record' && recordButtonKey.currentContext != null) {
    openRecordPanel(recordButtonKey.currentContext!, s);
  }
  if (panel == 'soundonly' && recordButtonKey.currentContext != null) {
    openRecordPanel(recordButtonKey.currentContext!, s);
    unawaited(Future<void>.delayed(const Duration(seconds: 4), () => s.choose(Source.soundOnly)));
  }
  if (panel == 'settings' && settingsButtonKey.currentContext != null) {
    openSettingsPanel(settingsButtonKey.currentContext!, s);
  }
  if (e != null && more != null && more.mounted) {
    if (panel == 'more') unawaited(openMenu(more, s, e));
    if (panel == 'lang') unawaited(runAct(more, s, e, Act.transcribeAgain));
    if (panel == 'who') unawaited(runAct(more, s, e, Act.identifySpeakers));
    if (panel == 'trash') unawaited(runAct(more, s, e, Act.remove));
  }
  if (panel == 'toast') s.say('Notes moved to the Trash.', action: 'Undo', onAction: () async {});
  if (shot == null) return;
  final wait = int.tryParse(Platform.environment['MEETING_NOTES_SHOT_DELAY'] ?? '') ?? 2500;
  await Future<void>.delayed(Duration(milliseconds: wait));
  final boundary = _shotKey.currentContext?.findRenderObject();
  if (boundary is RenderRepaintBoundary) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final image = await boundary.toImage(pixelRatio: view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes != null) File(shot).writeAsBytesSync(bytes.buffer.asUint8List());
  }
  exit(0);
}
