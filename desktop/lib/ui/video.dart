// The recording: pinned above the text, or full screen.
// Controls: play or pause, scrub, volume and mute, speed, full screen.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../engine.dart';
import '../logic.dart';
import 'theme.dart';

class VideoPane extends StatefulWidget {
  final String path;

  /// A recording with no picture: just the controls, in a slim bar.
  final bool soundOnly;

  /// Told where playback is, each time it moves on or starts or stops. Not told while the
  /// recording is still untouched at its start.
  final void Function(double seconds, bool playing)? onPosition;

  /// Told the picture's width divided by its height once the recording has opened.
  final void Function(double aspect)? onAspect;

  /// Where the volume is remembered.
  final Prefs? prefs;
  const VideoPane({
    super.key,
    required this.path,
    this.soundOnly = false,
    this.onPosition,
    this.onAspect,
    this.prefs,
  });
  @override
  State<VideoPane> createState() => VideoPaneState();
}

class VideoPaneState extends State<VideoPane> {
  late VideoPlayerController _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(VideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _c.dispose();
      _open();
    }
  }

  void _open() {
    _error = null;
    _c = VideoPlayerController.file(File(widget.path));
    _told = -1;
    _toldPlaying = false;
    _c.addListener(_tell);
    final mine = _c;
    _c
        .initialize()
        .then((_) {
          if (mounted && identical(mine, _c)) {
            final saved = widget.prefs?.number('volume100');
            if (saved != null) _c.setVolume((saved / 100).clamp(0.0, 1.0));
            setState(() {});
            final a = _c.value.aspectRatio;
            if (a > 0) widget.onAspect?.call(a);
          }
        })
        .catchError((Object e) {
          if (mounted && identical(mine, _c)) {
            setState(
              () => _error =
                  'This recording cannot be played here. Use Show recording in '
                  'Finder (in the options menu) to open it in another player.',
            );
          }
        });
  }

  double _told = -1;
  bool _toldPlaying = false;

  void _tell() {
    final v = _c.value;
    if (!v.isInitialized || widget.onPosition == null) return;
    final at = v.position.inMilliseconds / 1000;
    if (_told < 0 && at == 0 && !v.isPlaying) return; // untouched so far
    if ((at - _told).abs() < 0.2 && v.isPlaying == _toldPlaying) return;
    _told = at;
    _toldPlaying = v.isPlaying;
    widget.onPosition!(at, v.isPlaying);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Moves to [seconds] without starting to play.
  Future<void> seek(int seconds) async {
    if (_c.value.isInitialized) await _c.seekTo(Duration(seconds: seconds));
  }

  Future<void> pause() async {
    if (_c.value.isInitialized) await _c.pause();
  }

  /// Jumps to [seconds] and plays: what a click on a time does.
  Future<void> seekPlay(int seconds) async {
    if (!_c.value.isInitialized) return;
    await _c.seekTo(Duration(seconds: seconds));
    await _c.play();
  }

  /// Shows the recording over the whole screen. The same player carries on, so it
  /// keeps its place, speed and volume going in and coming back.
  void openFullScreen() {
    if (!_c.value.isInitialized) return;
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 140),
        reverseTransitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (_, _, _) => FullScreenPlayer(controller: _c, prefs: widget.prefs),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: t.sunk, borderRadius: BorderRadius.circular(10)),
        child: Text(_error!, style: t.hint),
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _c,
      builder: (context, v, _) {
        final ready = v.isInitialized;
        final aspect = ready && v.aspectRatio > 0 ? v.aspectRatio : 16 / 9;
        final controls = PlayerControls(
          controller: _c,
          prefs: widget.prefs,
          onFullScreen: widget.soundOnly ? null : openFullScreen,
        );
        if (widget.soundOnly) {
          return Container(
            padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
            decoration: BoxDecoration(color: t.sunk, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Tooltip(
                    message: 'This recording has sound only',
                    child: Icon(Icons.graphic_eq, size: 18, color: t.sub),
                  ),
                ),
                Expanded(child: controls),
              ],
            ),
          );
        }
        final picture = GestureDetector(
          onTap: () => togglePlay(_c),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.black,
              child: ready
                  ? VideoPlayer(_c)
                  : const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                      ),
                    ),
            ),
          ),
        );
        // As wide as the space allows, but never so tall that the controls fall outside it.
        return LayoutBuilder(
          builder: (context, box) {
            var w = box.maxWidth;
            if (box.maxHeight.isFinite) {
              final room = (box.maxHeight - 38).clamp(40.0, double.infinity);
              if (room * aspect < w) w = room * aspect;
            }
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                // The controls keep room for the volume slider even under a narrow picture.
                width: math.max(w, math.min(box.maxWidth, 520.0)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: w,
                      child: AspectRatio(aspectRatio: aspect, child: picture),
                    ),
                    const SizedBox(height: 4),
                    controls,
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

void togglePlay(VideoPlayerController c) {
  final v = c.value;
  if (!v.isInitialized) return;
  if (v.isPlaying) {
    c.pause();
  } else {
    if (v.position >= v.duration) c.seekTo(Duration.zero);
    c.play();
  }
}

/// The row under the picture. The same row serves the top, the sound-only bar and full screen.
class PlayerControls extends StatefulWidget {
  final VideoPlayerController controller;
  final Prefs? prefs;

  /// Null when there is no picture to make bigger.
  final VoidCallback? onFullScreen;

  /// True inside full screen, where the button leaves it.
  final bool inFullScreen;
  const PlayerControls({
    super.key,
    required this.controller,
    this.prefs,
    this.onFullScreen,
    this.inFullScreen = false,
  });
  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  double? _scrub; // seconds, while the slider is being dragged
  double _before = 1; // the volume to return to when unmuting

  VideoPlayerController get c => widget.controller;

  void _setVolume(double v, {bool save = false}) {
    c.setVolume(v);
    if (save) widget.prefs?.set('volume100', (v * 100).roundToDouble());
  }

  void _toggleMute() {
    final now = c.value.volume;
    if (now > 0) {
      _before = now;
      _setVolume(0, save: true);
    } else {
      _setVolume(_before > 0 ? _before : 1, save: true);
    }
  }

  SliderThemeData _slider(T t) => SliderThemeData(
    trackHeight: 3,
    activeTrackColor: t.accent,
    inactiveTrackColor: t.line,
    thumbColor: t.accent,
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
  );

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final ready = v.isInitialized;
        final total = ready ? v.duration.inMilliseconds / 1000 : 0.0;
        final at = _scrub ?? (ready ? v.position.inMilliseconds / 1000 : 0.0);
        return LayoutBuilder(
          builder: (context, box) {
            // Fewer things when there is less room: first the volume slider, then the total time.
            final roomy = box.maxWidth >= 470;
            final shortTime = box.maxWidth < 360;
            return SizedBox(
              height: 34,
              child: Row(
                children: [
                  Btn(
                    kind: BtnKind.quiet,
                    icon: v.isPlaying ? Icons.pause : Icons.play_arrow,
                    tooltip: v.isPlaying ? 'Pause' : 'Play',
                    onPressed: ready ? () => togglePlay(c) : null,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    shortTime ? hms(at.floor()) : '${hms(at.floor())} / ${hms(total.floor())}',
                    style: TextStyle(
                      fontSize: 12,
                      color: t.sub,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: _slider(t),
                      child: Slider(
                        value: total <= 0 ? 0 : at.clamp(0, total).toDouble(),
                        max: total <= 0 ? 1 : total,
                        semanticFormatterCallback: (s) => hms(s.floor()),
                        onChanged: ready ? (s) => setState(() => _scrub = s) : null,
                        onChangeEnd: (s) async {
                          await c.seekTo(Duration(milliseconds: (s * 1000).round()));
                          if (mounted) setState(() => _scrub = null);
                        },
                      ),
                    ),
                  ),
                  Btn(
                    kind: BtnKind.quiet,
                    icon: volumeIcon(v.volume),
                    tooltip: v.volume > 0 ? 'Mute' : 'Unmute',
                    onPressed: ready ? _toggleMute : null,
                  ),
                  if (roomy)
                    SizedBox(
                      width: 84,
                      child: SliderTheme(
                        data: _slider(t),
                        child: Slider(
                          value: v.volume.clamp(0.0, 1.0),
                          semanticFormatterCallback: (x) => 'Volume ${(x * 100).round()}%',
                          onChanged: ready ? (x) => _setVolume(x) : null,
                          onChangeEnd: (x) => _setVolume(x, save: true),
                        ),
                      ),
                    ),
                  Tooltip(
                    message: 'Playback speed',
                    child: TextButton(
                      onPressed: ready
                          ? () => c.setPlaybackSpeed(nextSpeed(v.playbackSpeed))
                          : null,
                      style: TextButton.styleFrom(
                        foregroundColor: t.ink,
                        minimumSize: const Size(40, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      child: Text(speedLabel(v.playbackSpeed)),
                    ),
                  ),
                  if (widget.onFullScreen != null)
                    Btn(
                      kind: BtnKind.quiet,
                      icon: widget.inFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      tooltip: widget.inFullScreen ? 'Leave full screen (Esc)' : 'Full screen',
                      onPressed: ready ? widget.onFullScreen : null,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

IconData volumeIcon(double volume) =>
    volume <= 0 ? Icons.volume_off : (volume < 0.5 ? Icons.volume_down : Icons.volume_up);

const _window = MethodChannel('meeting_notes/window');

/// Asks macOS to put the window in or out of full screen. True when it changed.
Future<bool> _nativeFullScreen(bool on) async {
  // A picture taken for checking (see main.dart) stays in its window.
  if (Platform.environment.containsKey('MEETING_NOTES_SHOT')) return false;
  try {
    return await _window.invokeMethod<bool>('fullScreen', on) ?? false;
  } on Object {
    return false; // no window to ask (tests): the page still fills the window
  }
}

/// The recording over the whole screen, on black. Esc, the button or the × leaves.
/// Space plays or pauses; Left and Right move 5 seconds. The controls hide while the
/// mouse is still and the recording plays.
class FullScreenPlayer extends StatefulWidget {
  final VideoPlayerController controller;
  final Prefs? prefs;
  const FullScreenPlayer({super.key, required this.controller, this.prefs});
  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends State<FullScreenPlayer> {
  bool _entered = false; // we put the window in full screen, so we take it out again
  bool _awake = true;
  Timer? _sleep;

  VideoPlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _nativeFullScreen(true).then((changed) => _entered = changed);
    _wake();
  }

  @override
  void dispose() {
    _sleep?.cancel();
    if (_entered) _nativeFullScreen(false);
    super.dispose();
  }

  void _wake() {
    if (!_awake && mounted) setState(() => _awake = true);
    _sleep?.cancel();
    _sleep = Timer(const Duration(milliseconds: 2600), () {
      if (mounted && c.value.isPlaying) setState(() => _awake = false);
    });
  }

  void _leave() => Navigator.of(context).maybePop();

  void _skip(int seconds) {
    final v = c.value;
    if (!v.isInitialized) return;
    final to = v.position + Duration(seconds: seconds);
    c.seekTo(to < Duration.zero ? Duration.zero : (to > v.duration ? v.duration : to));
    _wake();
  }

  @override
  Widget build(BuildContext context) {
    // Always the dark colours here: the controls sit on black.
    return Theme(
      data: T.night.theme(),
      child: Builder(
        builder: (context) {
          final t = T.of(context);
          return Scaffold(
            backgroundColor: Colors.black,
            body: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _leave,
                const SingleActivator(LogicalKeyboardKey.space): () {
                  togglePlay(c);
                  _wake();
                },
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-5),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(5),
              },
              child: Focus(
                autofocus: true,
                child: MouseRegion(
                  cursor: _awake ? MouseCursor.defer : SystemMouseCursors.none,
                  onHover: (_) => _wake(),
                  child: DefaultTextStyle(
                    style: t.body,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            togglePlay(c);
                            _wake();
                          },
                          child: Center(
                            child: ValueListenableBuilder<VideoPlayerValue>(
                              valueListenable: c,
                              builder: (context, v, _) => AspectRatio(
                                aspectRatio: v.aspectRatio > 0 ? v.aspectRatio : 16 / 9,
                                child: VideoPlayer(c),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 14,
                          right: 14,
                          child: IgnorePointer(
                            ignoring: !_awake,
                            child: AnimatedOpacity(
                              opacity: _awake ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: _OnPicture(
                                icon: Icons.close,
                                tooltip: 'Leave full screen (Esc)',
                                size: 34,
                                onPressed: _leave,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            ignoring: !_awake,
                            child: AnimatedOpacity(
                              opacity: _awake ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Color(0x00000000), Color(0xD9000000)],
                                  ),
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 980),
                                    child: PlayerControls(
                                      controller: c,
                                      prefs: widget.prefs,
                                      inFullScreen: true,
                                      onFullScreen: _leave,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A round button that sits on the picture.
class _OnPicture extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  const _OnPicture({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 26,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.black.withValues(alpha: 0.62),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.58, color: Colors.white),
        ),
      ),
    ),
  );
}
