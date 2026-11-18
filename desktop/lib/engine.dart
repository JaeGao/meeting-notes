// The engine is gui.py: a small local server that finds recordings, runs the transcriber,
// drives the recorder and writes notes. This file starts it, talks to it and stops it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const enginePort = 4322;
const _notAnswering = 'The engine is not answering. Quit Meeting Notes and open it again.';

String get _home => Platform.environment['HOME'] ?? '';

/// Where meeting.py and gui.py live.
String get toolDir =>
    Platform.environment['MEETING_NOTES_TOOL'] ?? '$_home/Documents/Code/meeting-notes';

String get logFile => '$_home/Library/Logs/meeting-notes.log';
String get supportDir => '$_home/Library/Application Support/Meeting Notes';

class Api {
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  final String _base = 'http://127.0.0.1:$enginePort';

  Future<Map<String, dynamic>> get(String path) => _send('GET', path, null);
  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic> body = const {}]) =>
      _send('POST', path, body);

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic>? body) async {
    try {
      final req = await _client.openUrl(method, Uri.parse('$_base/api/$path'));
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final data = jsonDecode(text);
      if (data is Map<String, dynamic>) return data;
      return {'ok': false, 'error': 'The engine sent an answer that could not be read.'};
    } on Object {
      return {'ok': false, 'error': _notAnswering};
    }
  }

  /// A picture of a screen or window, as made by the recorder for the record panel.
  Future<Uint8List?> preview(String name) async {
    try {
      final req = await _client.getUrl(Uri.parse('$_base/preview/$name'));
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      return b.takeBytes();
    } on Object {
      return null;
    }
  }

  Future<bool> isUp() async => (await get('state'))['ok'] == true;
}

class Engine {
  final Api api;
  Engine(this.api);

  File get _pidFile => File('$supportDir/engine.pid');

  /// Makes sure the engine is running. Returns null when it is, or what went wrong.
  Future<String?> ensure() async {
    if (await api.isUp()) return null;
    if (!File('$toolDir/gui.py').existsSync()) {
      return 'The engine was not found at $toolDir. Meeting Notes needs its meeting-notes '
          'folder there (or set MEETING_NOTES_TOOL to where it is).';
    }
    try {
      // "exec" so the process we start is Python itself and its id is the one to stop later.
      final p = await Process.start(
        '/bin/sh',
        [
          '-c',
          'export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"; '
              'cd "\$MN_TOOL" || exit 1; '
              'exec python3 -u gui.py --no-open >> "\$MN_LOG" 2>&1 < /dev/null',
        ],
        environment: {'MN_TOOL': toolDir, 'MN_LOG': logFile},
        mode: ProcessStartMode.detached,
      );
      Directory(supportDir).createSync(recursive: true);
      _pidFile.writeAsStringSync('${p.pid}');
    } on Object catch (e) {
      return 'The engine could not be started: $e';
    }
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (await api.isUp()) return null;
    }
    return 'The engine did not start within 10 seconds. The reason is in $logFile.';
  }

  /// Stops the engine this app started, unless it is still working on something.
  /// A running transcription, notes job or recording is left to finish.
  Future<void> stopIfIdle() async {
    if (!_pidFile.existsSync()) return; // started by hand: not ours to stop
    final st = await api.get('state');
    if (st['ok'] == true) {
      final rec = st['recording'];
      final recording =
          rec is Map && const ['starting', 'recording', 'stopping'].contains(rec['state']);
      final working = (st['entries'] as List? ?? const []).any((e) {
        final j = e is Map ? e['job'] : null;
        return j is Map && (j['state'] == 'running' || j['state'] == 'queued');
      });
      if (recording || working) return;
    }
    final pid = int.tryParse(_pidFile.readAsStringSync().trim());
    if (pid != null) Process.killPid(pid, ProcessSignal.sigterm);
    try {
      _pidFile.deleteSync();
    } on Object {
      // nothing to clean up
    }
  }
}

/// Small settings of this window only (pane widths), kept beside the engine's pid.
class Prefs {
  final File _file = File('$supportDir/prefs.json');
  Map<String, dynamic> _data = {};

  void load() {
    try {
      final d = jsonDecode(_file.readAsStringSync());
      if (d is Map<String, dynamic>) _data = d;
    } on Object {
      _data = {};
    }
  }

  double? number(String key) => (_data[key] as num?)?.toDouble();

  void set(String key, double? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value.roundToDouble();
    }
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(_data));
    } on Object {
      // widths are a convenience; not being able to save them is not an error to show
    }
  }
}
