// What the engine (gui.py) sends, as typed objects. Field names follow its JSON.

class Job {
  final String kind; // transcribe | notes | speakers
  final String state; // queued | running | done | error | stopped
  final String message;
  final int elapsed;
  final int? progress;
  final String? step;
  const Job({
    required this.kind,
    required this.state,
    this.message = '',
    this.elapsed = 0,
    this.progress,
    this.step,
  });

  factory Job.fromJson(Map<String, dynamic> j) => Job(
    kind: j['kind'] as String? ?? 'transcribe',
    state: j['state'] as String? ?? 'done',
    message: j['message'] as String? ?? '',
    elapsed: (j['elapsed'] as num?)?.toInt() ?? 0,
    progress: (j['progress'] as num?)?.toInt(),
    step: j['step'] as String?,
  );

  bool get busy => state == 'running' || state == 'queued';

  /// Everything that should redraw the header, without the ticking clock.
  String get signature => '$kind|$state|$message|$progress|$step';
}

class Stuck {
  final int times;
  final String from;
  const Stuck(this.times, this.from);
}

class Entry {
  final String id, path, file, recorded, duration, status;
  final bool exists, audio, partial, playable;
  final String? folder, title, lang;
  final Stuck? stuck;
  final int speakers;
  final Job? job;

  const Entry({
    required this.id,
    required this.path,
    required this.file,
    required this.recorded,
    required this.duration,
    required this.status,
    this.exists = true,
    this.audio = true,
    this.partial = false,
    this.playable = true,
    this.folder,
    this.title,
    this.lang,
    this.stuck,
    this.speakers = 0,
    this.job,
  });

  factory Entry.fromJson(Map<String, dynamic> j) {
    final s = j['stuck'];
    final job = j['job'];
    return Entry(
      id: j['id'] as String,
      path: j['path'] as String,
      file: j['file'] as String? ?? '',
      recorded: j['recorded'] as String? ?? '',
      duration: j['duration'] as String? ?? '00:00:00',
      status: j['status'] as String? ?? 'new',
      exists: j['exists'] as bool? ?? true,
      audio: j['audio'] as bool? ?? true,
      partial: j['partial'] == true,
      playable: j['playable'] as bool? ?? false,
      folder: j['folder'] as String?,
      title: j['title'] as String?,
      lang: j['lang'] as String?,
      stuck: s is Map ? Stuck((s['times'] as num?)?.toInt() ?? 0, '${s['from'] ?? ''}') : null,
      speakers: (j['speakers'] as num?)?.toInt() ?? 0,
      job: job is Map<String, dynamic> ? Job.fromJson(job) : null,
    );
  }

  bool get busy => job?.busy ?? false;
  bool get hasFolder => folder != null;
}

class Settings {
  final String vocabulary, folders, meetingsDir;
  final List<String> defaultFolders, missing;
  final bool claude;
  const Settings({
    this.vocabulary = '',
    this.folders = '',
    this.meetingsDir = '',
    this.defaultFolders = const [],
    this.missing = const [],
    this.claude = false,
  });

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    vocabulary: j['vocabulary'] as String? ?? '',
    folders: j['folders'] as String? ?? '',
    meetingsDir: j['meetingsDir'] as String? ?? '',
    defaultFolders: [...(j['defaultFolders'] as List? ?? const []).map((e) => '$e')],
    missing: [...(j['missing'] as List? ?? const []).map((e) => '$e')],
    claude: j['claude'] == true,
  );
}

class RecState {
  final String state; // starting | recording | stopping | finished | error
  final String? out, error;
  final bool? mic;
  final int elapsed;

  /// What is being recorded now: display | area | window | none (sound only), and in words.
  final String? source, label;

  /// Why the last Change was refused by the recorder, and when it said so.
  final String? switchError;
  final double? switchAt;
  const RecState({
    required this.state,
    this.out,
    this.error,
    this.mic,
    this.elapsed = 0,
    this.source,
    this.label,
    this.switchError,
    this.switchAt,
  });

  factory RecState.fromJson(Map<String, dynamic> j) => RecState(
    state: j['state'] as String? ?? 'error',
    out: j['out'] as String?,
    error: j['error'] as String?,
    mic: j['mic'] as bool?,
    elapsed: (j['elapsed'] as num?)?.toInt() ?? 0,
    source: j['source'] as String?,
    label: j['label'] as String?,
    switchError: j['switchError'] as String?,
    switchAt: (j['switchAt'] as num?)?.toDouble(),
  );

  bool get active => state == 'starting' || state == 'recording' || state == 'stopping';
  bool get failed => state == 'error';
}

class Paragraph {
  final int t;
  final String text, who;
  final int? spk;
  const Paragraph(this.t, this.text, this.spk, this.who);
}

class Speaker {
  final int n, seconds;
  final String name, label;
  const Speaker(this.n, this.name, this.label, this.seconds);
}

class Detail {
  final List<Paragraph> paragraphs;
  final List<Speaker> speakers;
  final String? notes;
  const Detail({this.paragraphs = const [], this.speakers = const [], this.notes});

  factory Detail.fromJson(Map<String, dynamic> j) => Detail(
    paragraphs: [
      for (final p in (j['paragraphs'] as List? ?? const []))
        Paragraph(
          (p['t'] as num?)?.toInt() ?? 0,
          p['text'] as String? ?? '',
          _speakerNumber(p['spk']),
          p['who'] as String? ?? '',
        ),
    ],
    speakers: [
      for (final s in (j['speakers'] as List? ?? const []))
        Speaker(
          (s['n'] as num).toInt(),
          s['name'] as String? ?? '',
          s['label'] as String? ?? '',
          (s['seconds'] as num?)?.toInt() ?? 0,
        ),
    ],
    notes: j['notes'] as String?,
  );

  static int? _speakerNumber(Object? v) {
    if (v is num) return v == 0 ? null : v.toInt();
    return null;
  }
}

class Source {
  final String kind; // display | window | none (no picture: sound only)
  final int id, width, height;
  final String thumb;
  final bool main;
  final int number;
  final String app, title;
  const Source({
    required this.kind,
    required this.id,
    required this.width,
    required this.height,
    this.thumb = '',
    this.main = false,
    this.number = 1,
    this.app = '',
    this.title = '',
  });

  /// No picture: the Mac's sound and the microphone only.
  static const soundOnly = Source(kind: 'none', id: 0, width: 0, height: 0);
  bool get isSoundOnly => kind == 'none';

  factory Source.fromJson(String kind, Map<String, dynamic> j) => Source(
    kind: kind,
    id: (j['id'] as num).toInt(),
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    thumb: j['thumb'] as String? ?? '',
    main: j['main'] == true,
    number: (j['number'] as num?)?.toInt() ?? 1,
    app: j['app'] as String? ?? '',
    title: j['title'] as String? ?? '',
  );
}

/// The area of a screen to record, as fractions (0..1) of its width and height.
class Area {
  final double x, y, w, h;
  const Area(this.x, this.y, this.w, this.h);
  Map<String, double> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

/// Where the recording's playback is.
class Playhead {
  final double seconds;
  final bool playing;
  const Playhead(this.seconds, this.playing);
}
