// Everything the window shows, and every action it can take. Widgets read this and call it.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'logic.dart';
import 'models.dart';

class Toast {
  final String text;
  final String? action;
  final Future<void> Function()? onAction;
  const Toast(this.text, {this.action, this.onAction});
}

enum Boot { starting, ready, failed }

class SourcesState {
  final bool loading;
  final String? error;
  final List<Source> displays, windows;
  const SourcesState({
    this.loading = false,
    this.error,
    this.displays = const [],
    this.windows = const [],
  });
}

class Store extends ChangeNotifier {
  final Api api;
  final Engine engine;
  final Prefs prefs;
  Store._(this.api, this.engine, this.prefs);
  factory Store({Api? api, Engine? engine, Prefs? prefs}) {
    final a = api ?? Api();
    return Store._(a, engine ?? Engine(a), prefs ?? Prefs());
  }

  Boot boot = Boot.starting;
  String? bootError;

  List<Entry> entries = [];
  Settings? settings;
  RecState? rec;
  bool recorderBuilt = true;

  String? sel;
  String tab = 'notes';
  String search = '';
  final Map<String, Detail> details = {};

  /// True while a title or speaker name is being typed, so Esc cancels that and nothing else.
  bool editing = false;

  /// Set by the menu's Rename; the header picks it up and opens the title field.
  bool renameRequested = false;

  Toast? toast;
  Timer? _toastTimer;
  double? _switchSeen;
  Timer? _timer;
  bool _disposed = false;

  // record panel
  SourcesState sources = const SourcesState(loading: true);
  Source? pick;
  Area? area;
  bool recMic = true, recAuto = true;
  final Map<String, Uint8List> thumbs = {};

  Entry? get current {
    for (final e in entries) {
      if (e.id == sel) return e;
    }
    return null;
  }

  // ---------- start and stop ----------

  Future<void> start() async {
    prefs.load();
    boot = Boot.starting;
    bootError = null;
    notifyListeners();
    final err = await engine.ensure();
    if (err != null) {
      boot = Boot.failed;
      bootError = err;
      notifyListeners();
      return;
    }
    boot = Boot.ready;
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ---------- messages ----------

  void say(String text, {String? action, Future<void> Function()? onAction}) {
    toast = Toast(text, action: action, onAction: onAction);
    _toastTimer?.cancel();
    _toastTimer = Timer(Duration(seconds: action != null ? 12 : 6), dismissToast);
    _changed();
  }

  void dismissToast() {
    _toastTimer?.cancel();
    if (toast == null) return;
    toast = null;
    _changed();
  }

  bool _ok(Map<String, dynamic> r) {
    if (r['ok'] == true) return true;
    say('${r['error'] ?? 'That did not work.'}');
    return false;
  }

  // ---------- the list ----------

  Future<void> refresh() async {
    final r = await api.get('state');
    if (_disposed) return;
    if (r['ok'] != true) {
      say('${r['error']}');
      _schedule(const Duration(seconds: 5));
      return;
    }
    final before = current;
    entries = [
      for (final e in (r['entries'] as List? ?? const []))
        Entry.fromJson(e as Map<String, dynamic>),
    ];
    final s = r['settings'];
    settings = s is Map<String, dynamic> ? Settings.fromJson(s) : settings;
    final rc = r['recording'];
    rec = rc is Map<String, dynamic> ? RecState.fromJson(rc) : null;
    // A Change the recorder refused (the window closed, say) is reported once.
    final at = rec?.switchAt;
    if (at != null && at != _switchSeen && rec?.switchError != null) say(rec!.switchError!);
    _switchSeen = at;
    recorderBuilt = r['recorderBuilt'] != false;

    final now = current;
    if (sel != null && now == null) {
      sel = null; // the recording left the list
    } else if (now != null && before != null) {
      final finished = before.busy && !now.busy;
      if (now.status != before.status || now.folder != before.folder || finished) {
        details.remove(now.id);
        unawaited(loadDetail());
      }
    }
    _changed();
    final recording = rec?.active ?? false;
    _schedule(
      recording
          ? const Duration(seconds: 1)
          : entries.any((e) => e.busy)
          ? const Duration(milliseconds: 1500)
          : const Duration(seconds: 15),
    );
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (!_disposed) _timer = Timer(d, refresh);
  }

  void select(String id) {
    sel = id;
    search = '';
    editing = false;
    tab = current?.status == 'transcript' ? 'transcript' : 'notes';
    _changed();
    unawaited(loadDetail());
  }

  void closeDetail() {
    sel = null;
    editing = false;
    search = '';
    _changed();
  }

  void setTab(String t) {
    tab = t;
    _changed();
  }

  void setSearch(String s) {
    search = s;
    _changed();
  }

  void setEditing(bool v) {
    editing = v;
  }

  /// Asks the header to open the title for typing (from the menu's Rename).
  void requestRename() {
    renameRequested = true;
    _changed();
  }

  Future<void> loadDetail() async {
    final e = current;
    if (e == null || !e.hasFolder) return;
    final r = await api.get('meeting?id=${e.id}');
    if (r['ok'] == true) {
      details[e.id] = Detail.fromJson(r);
      _changed();
    }
  }

  // ---------- actions on a recording ----------

  Future<void> transcribe(Entry e, String lang, {int? count}) async {
    _ok(await api.post('transcribe', {'id': e.id, 'lang': lang, 'count': ?count}));
    await refresh();
  }

  Future<void> identifySpeakers(Entry e, {int? count}) async {
    _ok(await api.post('speakers', {'id': e.id, 'count': ?count}));
    await refresh();
  }

  Future<void> writeNotes(Entry e) async {
    _ok(await api.post('notes', {'id': e.id}));
    await refresh();
  }

  Future<void> stopJob(Entry e) async {
    _ok(await api.post('stop', {'id': e.id}));
    await refresh();
  }

  Future<void> rename(Entry e, String title) async {
    final t = title.trim();
    if (t.isEmpty || t == editableTitle(e)) return;
    _ok(await api.post('title', {'id': e.id, 'title': t}));
    await refresh();
  }

  Future<void> renameSpeaker(Entry e, Speaker sp, String name) async {
    final v = name.trim();
    if (v == sp.name) return;
    _ok(await api.post('speaker', {'id': e.id, 'number': sp.n, 'name': v}));
    await loadDetail();
  }

  /// Opens a file or folder of the meeting outside the app.
  Future<void> open(Entry e, Act what) async {
    final r = switch (what) {
      Act.reveal => await api.post('reveal', {'id': e.id, 'what': 'recording'}),
      Act.openFolder => await api.post('reveal', {'id': e.id, 'what': 'notes'}),
      Act.editNotes => await api.post('open', {'id': e.id, 'what': 'notes'}),
      _ => await api.post('open', {'id': e.id, 'what': 'transcript'}),
    };
    _ok(r);
  }

  /// Moves the meeting's notes folder to the Trash and offers Undo.
  Future<void> remove(Entry e) async {
    final r = await api.post('remove', {'id': e.id});
    if (!_ok(r)) return;
    details.remove(e.id);
    final trashed = r['trashed'] as String?;
    say(
      'Notes moved to the Trash.',
      action: trashed != null ? 'Undo' : null,
      onAction: trashed == null
          ? null
          : () async {
              _ok(await api.post('restore', {'trashed': trashed}));
              await refresh();
              await loadDetail();
            },
    );
    await refresh();
  }

  // ---------- settings ----------

  /// Returns true when saved.
  Future<bool> saveSettings(String vocabulary, String folders) async {
    final r = await api.post('settings', {'vocabulary': vocabulary, 'folders': folders});
    if (!_ok(r)) return false;
    say('Settings saved.');
    await refresh();
    return true;
  }

  // ---------- recording ----------

  Future<void> loadSources() async {
    sources = const SourcesState(loading: true);
    _changed();
    final r = await api.post('record/sources');
    if (r['ok'] != true) {
      sources = SourcesState(error: '${r['error'] ?? 'The recorder did not answer. Try again.'}');
      _changed();
      return;
    }
    final displays = [
      for (final d in (r['displays'] as List? ?? const []))
        Source.fromJson('display', d as Map<String, dynamic>),
    ];
    final windows = [
      for (final w in (r['windows'] as List? ?? const []))
        Source.fromJson('window', w as Map<String, dynamic>),
    ];
    thumbs.clear();
    await Future.wait([
      for (final s in [...displays, ...windows])
        if (s.thumb.isNotEmpty)
          api.preview(s.thumb).then((b) {
            if (b != null) thumbs[s.thumb] = b;
          }),
    ]);
    sources = SourcesState(displays: displays, windows: windows);
    // Keep the choice if it is still there; otherwise the main screen, whole.
    final old = pick;
    Source? still;
    if (old != null && old.isSoundOnly) {
      still = old;
    } else if (old != null) {
      for (final s in old.kind == 'display' ? displays : windows) {
        if (s.id == old.id) still = s;
      }
    }
    if (still != null) {
      pick = still;
    } else {
      pick = displays.isEmpty
          ? null
          : displays.firstWhere((d) => d.main, orElse: () => displays.first);
      area = null;
    }
    _changed();
  }

  void choose(Source s) {
    pick = s;
    area = null;
    _changed();
  }

  void setArea(Area? a) {
    area = a;
    _changed();
  }

  void setRecOptions({bool? mic, bool? auto}) {
    recMic = mic ?? recMic;
    recAuto = auto ?? recAuto;
    _changed();
  }

  /// Returns true when the recorder was started.
  Future<bool> startRecording() async {
    final p = pick;
    if (p == null) return false;
    final r = await api.post('record/start', {
      'source': _sourceJson(p),
      'rect': p.kind == 'display' ? area?.toJson() : null,
      'mic': recMic,
      'auto': recAuto,
    });
    if (!_ok(r)) return false;
    await refresh();
    return true;
  }

  Map<String, dynamic> _sourceJson(Source p) =>
      p.isSoundOnly ? {'kind': 'none'} : {'kind': p.kind, 'id': p.id};

  /// Changes what the running recording records. Returns true when the recorder was told.
  Future<bool> switchSource() async {
    final p = pick;
    if (p == null) return false;
    final r = await api.post('record/switch', {
      'source': _sourceJson(p),
      'rect': p.kind == 'display' ? area?.toJson() : null,
    });
    if (!_ok(r)) return false;
    await refresh();
    return true;
  }

  Future<void> stopRecording() async {
    _ok(await api.post('record/stop'));
    await refresh();
  }

  Future<void> dismissRecordingError() async {
    await api.post('record/dismiss');
    await refresh();
  }
}
