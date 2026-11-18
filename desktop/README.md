# Meeting Notes, the Mac app

**In short:** the window of the meeting-notes tool, written in Flutter. It starts the
engine (`../gui.py`), shows what it reports, and sends it every action. What the app
does, button by button, is in [`../README.md`](../README.md).

| Do this | Command |
|---|---|
| Build and install to Applications | `./install.sh` |
| Run while working on it | `flutter run -d macos` |
| Tests (rules, and the window against a stand-in engine) | `flutter test` |
| Check the code | `flutter analyze` |

| File | What is in it |
|---|---|
| `lib/logic.dart` | Rules with no drawing: labels, which menu items a recording gets, the notes format, the record area |
| `lib/models.dart` | What the engine sends, as typed objects |
| `lib/engine.dart` | Starts and stops the engine, talks to it over `127.0.0.1:4322`, saves pane widths |
| `lib/store.dart` | Everything the window shows and every action it can take |
| `lib/ui/` | The window: `home` (top bar, list, messages), `detail` (a meeting), `video`, `panels` (record, settings, transcribe, speakers), `popover` (menus, panels, the confirm dialog), `theme` (colours and shared controls), `grip` (pane edges) |

`install.sh` makes `build` a link to `build.noindex`, so Spotlight and the Apps list show only
the installed app. `flutter clean` removes the link; run `install.sh` again to put it back.

One package beyond Flutter itself: `video_player` (the Flutter team's), for the recording.

To look at a state without clicking, start the built app with
`MEETING_NOTES_OPEN` (for example `notes+transcript`, `record`, `settings`, `notes+more`),
`MEETING_NOTES_WINDOW=900x700`, `MEETING_NOTES_THEME=dark`, and
`MEETING_NOTES_SHOT=/path/file.png` to save a picture of the window and quit. The
details are at the bottom of `lib/main.dart`.
