# Meeting notes

**In short:** turns a recorded meeting into a transcript on this Mac, so Claude can write
the notes. Open the Meeting Notes app, say `/meeting-notes` in Claude Code, or run the
commands below yourself.
The recording and its audio never leave this Mac: ffmpeg pulls out the audio and
whisper.cpp turns it into text. The notes step is different: when Claude writes the
notes, the transcript text (and any screen frames it looks at) goes to Claude, like any
other file Claude reads.

## Where things are

| What | Where |
|---|---|
| Recordings it looks for | `~/Movies` (OBS) and `~/Desktop` (Mac screen recordings), top level only |
| Extra recording folders | one path per line in `~/Documents/Meetings/recording-folders.txt` |
| Notes, one folder per meeting | `~/Documents/Meetings/<date>-<time>-<title>/` |
| Names and terms to spell right | `~/Documents/Meetings/vocabulary.txt` |
| Speech model (3 GB) | `models/ggml-large-v3.bin` (not in git) |
| Speaker models (35 MB) and their Python package | `models/diar/`, `.venv/` (not in git) |
| Recorder (built from `recorder/main.swift`) | `recorder/build.noindex/Meeting Recorder.app`, not in git: run `recorder/build.sh`. A helper with no window, kept out of Spotlight and the Apps list on purpose |
| The app | `/Applications/Meeting Notes.app`, the one app to open. Source in `desktop/` (Flutter); run `desktop/install.sh` to build and install it. Its icon is `app/app.icns` |
| Engine log | `~/Library/Logs/meeting-notes.log` |
| Claude skill | `~/.claude/skills/meeting-notes/SKILL.md` |

Each meeting folder holds `transcript.md` (timestamped text), `notes.md` (written by
Claude), `segments.json` (raw timings), `meta.json`, `whisper.log` and `frames/`.

## The app

Open **Meeting Notes** from Applications. It is a Mac app with its own window and Dock
icon (written in Flutter, source in `desktop/`). Opening it starts the engine (`gui.py`,
which listens on this Mac only); quitting it, or closing its window, stops the engine,
unless a transcription, a notes job or a recording is still running: those are left to
finish, and opening the app again shows them. The window fills its space and does not
scroll as a whole: only the recordings list and the notes or transcript scroll.

| Where | What you can do |
|---|---|
| Top bar, **Record** | Opens the **New recording** panel under the button: **Sound only** (no picture: the Mac's sound and your microphone, for a call nobody shares a screen in or a meeting in the room), then a list of **Screens** and **Windows** with a picture of each, a large picture of the chosen one, and for a screen you can drag on the picture to record only that area (**Whole screen** clears it). Options: **Record my microphone**, **Transcribe when I stop**. **Start recording**, **Cancel**, a refresh button for the pictures |
| Top bar while recording | A red dot, what is being recorded (for example **Recording · Main screen** or **Recording · Sound only**), the time, **Change…** and **Stop**. **Change…** opens the same list as New recording, titled **Change what is recorded**: pick another screen, a window, an area or **Sound only**, then **Switch** (or **Cancel**). The recording keeps running and stays one file |
| Top bar, **Settings** | A panel under the button: the spelling list and extra recording folders. **Save** or **Cancel** |
| **Recordings** list | Every recording, newest first, with its status: New, Transcript only, Notes written, No audio track, Recording missing, or the running job. The round-arrow button looks for new recordings |
| Options on a recording (three dots on its row) | The same menu as **More actions**, without opening the meeting first: **Transcribe…**, **Write notes with Claude**, **Transcribe again…**, **Identify speakers…**, **Rename**, the file shortcuts, **Move notes to Trash**, or **Stop** while a job runs. Up and Down move through a menu, Enter chooses |
| Resizing | Drag the edge of the recordings list, or the short bar under the recording to make it taller or shorter (some text always stays in view). Double-click either to reset; with it focused, the arrow keys move it. The sizes and the window's size and place are remembered |
| Meeting header | For a meeting with a transcript it sits under the recording, above the tabs, and scrolls away with the text to leave room (scroll back up, or switch tab, to see it again; the options on the meeting's row in the list are always there). The title (click to rename; Enter saves, Esc cancels), then one main button for the next step: **Transcribe** (with a language choice) or **Write notes**. While a job runs: its progress and **Stop** |
| **More actions** (the three dots) | **Rewrite notes with Claude** (asks first), **Transcribe again…** (asks for the language and how many people spoke; replaces the transcript, keeps the notes), **Identify speakers…**, **Rename**, **Edit notes in text editor**, **Open transcript file**, **Show recording in Finder**, **Open notes folder**, **Move notes to Trash** (asks first, then offers **Undo**) |
| **Notes** / **Transcript** tabs | Read either; the text can be selected and copied. **Search the transcript** filters passages and marks each match |
| Speakers | The transcript shows who spoke each passage, with a row of speakers and their talking time on top. Click a name to rename that speaker everywhere (Enter saves, Esc cancels; an empty name goes back to the number; the same name on two speakers merges them). **Identify speakers…** runs the voice step again and asks **How many people spoke?** |
| Video and times | A recording with no picture gets a slim player bar above the text. Otherwise the recording stays pinned at the top. Under it come the meeting's title line, which scrolls away, and the **Notes** / **Transcript** tabs with the search, which stay in view. Click any time in the transcript or notes to play from there |
| Transcript follows the recording | While the recording plays (or is moved with the slider), the passage being spoken is marked with a coloured bar and background, and the transcript scrolls to keep it near the top. Scroll by hand and it stops following and shows **Follow the recording** at the bottom; press it, or click a time, to follow again. It does not scroll while you are searching, though the spoken passage is still marked if it is among the matches. Nothing is marked until the recording has been played or moved |
| Player controls | Play or pause (or click the picture), a slider to move through it, **Mute** / **Unmute** with a volume slider beside it (the volume is remembered), a speed button (1×, 1.25×, 1.5×, 2×) and **Full screen** |
| Full screen | The recording fills the screen on black, in macOS full screen, carrying on from where it was. Leave with Esc, the **Leave full screen** button in the controls, or the × at the top right; the window goes back to how it was. Space plays or pauses; Left and Right move 5 seconds. The controls and the pointer hide after a moment while it plays and return when the mouse moves |
| Light and dark | Follows the Mac's appearance |

Every panel and menu closes with its Close or Cancel button, Esc, or a click outside
it. Esc with nothing open clears the search if there is one, then closes the meeting.
In a narrow window the list and the meeting show one at a time, with a back arrow
(on the tabs row, so it stays in view).

If the engine cannot start, the window says why, shows the log's path
(`~/Library/Logs/meeting-notes.log`) and offers **Try again**.

**Meeting Recorder** is a helper the app starts when you press Record; it is kept out
of Spotlight and the Apps list, and opened by hand it just opens Meeting Notes. The
first time, macOS may ask to let Meeting Notes read your Documents and Desktop folders
(the notes and Mac screen recordings live there).

What a recording holds:

- **Sound only from start to end** is saved as a sound file (`Meeting <date> <time>.m4a`);
  anything with a picture as a video (`.mov`). Both are in `~/Movies`.
- **The picture's size is set by what you start with** (the Mac's main screen when you
  start with Sound only). What you switch to later is fitted inside it, with black
  bars if its shape differs.
- **While on Sound only the picture is black**; the sound carries on.
- **A change the recorder cannot make** (the window was closed meanwhile) leaves the
  recording as it was and says so at the bottom of the window.
- **The microphone** is on or off for the whole recording: it is chosen at the start.

A window is recorded as the part of the screen where it sits when you press Start or
Switch, with all of the Mac's sound. (Recording the window by itself captured only that app's
own sound, so a meeting in another app's audio path would have been silent.)

Recording needs two permissions the first time, for "Meeting Recorder": Screen & System
Audio Recording (System Settings > Privacy & Security) and Microphone. Until the first
is on, the panel says so. The recorder is its own small app, so a recording keeps going
if Meeting Notes is quit; open it again to stop the recording.

Jobs run one at a time. No: editing notes inside the app (it opens your text editor),
saving a screen frame from the app (command line only), deleting a recording from the
app, pausing a recording, turning the microphone on or off during a recording, a window recording that follows the window when it moves,
drawing the area with the keyboard, a floating small player, marking single words as they are spoken (whole passages only), following in the Notes tab, playing `.mkv`, `.webm` or `.flv` recordings inside
the app (it says so; use **Show recording in Finder**), a menu bar icon.

The older web page is still there: `python3 gui.py` opens http://127.0.0.1:4322 in the
browser, using the same engine. It has no Sound only choice and no Change… while
recording; those are in the app only.

## Checks

| What | Command |
|---|---|
| The engine's recording rules (9 tests) | `python3 -m unittest test_gui` |
| The app (rules, and the window against a stand-in engine) | `cd desktop && flutter test` |

## Commands

`python3 meeting.py <command>`

| Command | What it does |
|---|---|
| `list` | Every recording found, its length, whether it has sound, and its status: `new`, `transcript only`, `notes written`, `no audio track` |
| `transcribe <n\|path\|latest>` | Transcribes one recording. `--title "..."`, `--lang auto\|zh\|en` (default `auto`), `--force` to redo (keeps `notes.md`) |
| `frame <meeting> <HH:MM:SS>` | Saves the screen at that moment as a PNG in the meeting's `frames/` |
| `speakers <meeting>` | Tells the speakers apart again, keeping the transcript text. `--count N` if you know how many people spoke. Resets the names |
| `name <meeting> <n> "<name>"` | Gives Speaker n a name everywhere in the transcript. An empty name goes back to "Speaker n". Give two speakers the same name to merge them |
| `title <meeting> "<title>"` | Renames a meeting and its folder |
| `remove <meeting>` | Moves the meeting's notes folder to the Trash. The recording is never touched |
| `restore <path in Trash>` | Puts a removed meeting back |

`<meeting>` is a folder path or any part of the folder name that matches one meeting.

## Limits

- **Speaker labels are a guess by voice.** Each passage is labelled Speaker 1, 2, 3 until
  you name them. A label can be wrong, one person can be split in two, and two people
  sharing a microphone can be merged. A voice heard for under 20 seconds joins its
  nearest speaker or stays unlabelled. Saying how many people spoke helps.
- **No sound, no notes.** A Mac screen recording has sound only if a microphone was
  chosen in its options. OBS recordings have it.
- **English and Mandarin mixed** works with `auto`: the audio is cut at pauses into pieces
  under 30 seconds and each piece is transcribed in the language it starts in. A piece
  where the speaker switches language part-way can come out translated instead of as
  spoken. `zh` writes everything in Chinese, including English speech; `en` writes
  everything in English.
- Names, numbers and product terms are the usual mistakes: add them to `vocabulary.txt`.
- If the transcriber gets stuck repeating a line, the tool says so (`stuck` in
  `meta.json`, a red note in the page). Transcribe again.
- About 3 to 6 minutes of work per hour of meeting on this Mac.
- Only what the recording captured: if OBS did not record the other side's audio, they
  are not in the transcript.

## Setup on another Mac

For speaker labels: `python3 -m venv .venv && .venv/bin/pip install sherpa-onnx`, then
put `sherpa-onnx-pyannote-segmentation-3-0` (unpacked) and
`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` in `models/diar/`, both
from the `k2-fsa/sherpa-onnx` GitHub releases. Without them the tool still transcribes.

`brew install ffmpeg whisper-cpp`, run `recorder/build.sh` (needs Xcode's command line
tools, macOS 15 or later) and `desktop/install.sh` (needs Flutter and Xcode; the app
looks for this folder at `~/Documents/Code/meeting-notes`, or where `MEETING_NOTES_TOOL`
points), then download `ggml-large-v3.bin` (from
`huggingface.co/ggerganov/whisper.cpp`) and `ggml-silero-v5.1.2.bin` (from
`huggingface.co/ggml-org/whisper-vad`) into `models/`.
