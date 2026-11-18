#!/usr/bin/env python3
"""Local web page to manage and run the meeting-notes tool.

  python3 gui.py            then open http://127.0.0.1:4322
  python3 gui.py --no-open  don't open the browser

Listens on this Mac only (127.0.0.1). Standard library only.
"""
import hashlib
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import meeting as m

PORT = int(os.environ.get("MEETING_GUI_PORT", "4322"))
TOOL = Path(__file__).resolve().parent
PAGE = TOOL / "gui.html"
SKILL = Path.home() / ".claude" / "skills" / "meeting-notes" / "SKILL.md"
ENV = dict(os.environ)
ENV["PATH"] = f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + ENV.get("PATH", "")
os.environ["PATH"] = ENV["PATH"]  # so ffprobe is found when started from the app
MEDIA_TYPES = {".mov": "video/quicktime", ".mp4": "video/mp4", ".m4v": "video/mp4",
               ".mkv": "video/x-matroska", ".webm": "video/webm", ".m4a": "audio/mp4",
               ".mp3": "audio/mpeg", ".wav": "audio/wav", ".flv": "video/x-flv"}

# In a .noindex folder so Spotlight and the Apps list show one app, Meeting Notes, not two.
REC_APP = TOOL / "recorder" / "build.noindex" / "Meeting Recorder.app"
REC_STATE = m.MEETINGS / ".recorder.json"
REC_CMD = m.MEETINGS / ".recorder-cmd.json"   # what to switch to, read by the recorder
REC_DIR = Path.home() / "Movies"
PREVIEW = m.MEETINGS / ".preview"   # pictures of the screens and windows, for choosing
REC_ACTIVE = ("starting", "recording", "stopping")
rec_opts = {"auto": False, "label": ""}

_probe_cache = {}
_lock = threading.Lock()
jobs = {}            # recording path -> job dict
work = queue.Queue()  # jobs run one at a time


def rid(path):
    return hashlib.sha1(str(path).encode()).hexdigest()[:12]


def probe(path):
    st = path.stat()
    key = (str(path), st.st_mtime, st.st_size)
    if key not in _probe_cache:
        _probe_cache[key] = m.probe(path)
    return _probe_cache[key]


def tool(*args):
    """Run meeting.py; return (ok, message)."""
    r = subprocess.run([sys.executable, str(TOOL / "meeting.py"), *args],
                       text=True, capture_output=True, env=ENV)
    out = (r.stdout if r.returncode == 0 else r.stderr or r.stdout).strip()
    return r.returncode == 0, re.sub(r"^error: ", "", out)


# ---------- state ----------

def job_view(path):
    j = jobs.get(str(path))
    if not j:
        return None
    v = {k: j[k] for k in ("kind", "state", "message")}
    v["elapsed"] = int((j.get("ended") or time.time()) - j["started"]) if j.get("started") else 0
    if j["state"] == "running" and j["kind"] in ("transcribe", "speakers") and j.get("folder"):
        try:
            pr = json.loads((Path(j["folder"]) / "progress.json").read_text())
            v["progress"] = int(100 * pr["done"] / max(1, pr["total"]))
            v["step"] = pr.get("step", "transcribe")
        except (OSError, ValueError, KeyError):
            pass
    return v


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def recording():
    """The recorder's state, or None when nothing is being or was just recorded."""
    try:
        st = json.loads(REC_STATE.read_text())
    except (OSError, ValueError):
        return None
    state = st.get("state")
    if state in REC_ACTIVE and st.get("pid") and not alive(st["pid"]):
        state = "error"
        st["error"] = "The recorder stopped unexpectedly. The file so far may not open."
    if state == "starting" and not st.get("pid") and time.time() - st.get("started", 0) > 20:
        state = "error"
        st["error"] = "The recorder did not start. Build it with recorder/build.sh and try again."
    kind = st.get("source")
    return {"state": state, "out": st.get("out"), "error": st.get("error"),
            "mic": st.get("mic"), "elapsed": int(time.time() - st.get("started", time.time())),
            "auto": rec_opts["auto"], "source": kind,
            # What is being recorded now, in words. The recorder's kind wins if they disagree
            # (a switch that was refused, or this server restarted during the recording).
            "label": rec_opts["label"] if rec_opts["label"] and rec_opts.get("kind") == kind
            else {"none": "Sound only", "window": "A window", "area": "Part of a screen"}.get(kind, "A screen"),
            "switchError": st.get("switchError"), "switchAt": st.get("switchAt")}


def list_sources():
    """Ask the recorder what can be recorded. Returns (ok, data or message)."""
    if not REC_APP.exists():
        return False, "The recorder is not built yet. Run recorder/build.sh once."
    with _lock:
        m.shutil.rmtree(PREVIEW, ignore_errors=True)
        PREVIEW.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", "-n", str(REC_APP), "--args", "--list", "--dir", str(PREVIEW)])
        f = PREVIEW / "sources.json"
        for _ in range(60):
            if f.exists():
                break
            time.sleep(0.25)
        else:
            return False, "The recorder did not answer. Try again."
        try:
            data = json.loads(f.read_text())
        except ValueError:
            return False, "The recorder's answer could not be read. Try again."
    if data.get("error"):
        return False, data["error"]
    return True, data


def source_choice(source, rect):
    """Check the app's choice against what the recorder last listed.
    Returns (choice, label, error). choice is what the recorder is told:
    {} (main screen), {"none": True}, {"window": id}, or {"display": id, "rect": [x, y, w, h]}."""
    if not source:
        return {}, "Main screen", None
    kind = source.get("kind") if isinstance(source, dict) else None
    if kind == "none":
        return {"none": True}, "Sound only", None
    try:
        data = json.loads((PREVIEW / "sources.json").read_text())
        sid = int(source["id"])
    except (OSError, ValueError, KeyError, TypeError):
        return None, "", "Choose what to record again."
    if kind == "window":
        win = next((w for w in data.get("windows", []) if w["id"] == sid), None)
        if not win:
            return None, "", "That window is no longer in the list. Refresh the previews."
        return {"window": sid}, win.get("app") or "A window", None
    disp = next((d for d in data.get("displays", []) if d["id"] == sid), None)
    if kind != "display" or not disp:
        return None, "", "That screen is no longer connected. Refresh the previews."
    choice = {"display": sid}
    label = "Main screen" if disp.get("main") else f"Screen {disp.get('number', '')}".strip()
    if rect:
        try:
            x, y, w, h = (float(rect[k]) for k in ("x", "y", "w", "h"))
        except (KeyError, TypeError, ValueError):
            return None, "", "The chosen area could not be read. Drag it again."
        if not (0 <= x < 1 and 0 <= y < 1 and 0.05 <= w <= 1 and 0.05 <= h <= 1
                and x + w <= 1.001 and y + h <= 1.001):
            return None, "", "The chosen area is too small or off the screen. Drag it again."
        W, H = disp["width"], disp["height"]
        choice["rect"] = [round(x * W), round(y * H), round(w * W), round(h * H)]
        label += ", part"
    return choice, label, None


def choice_args(choice):
    """The recorder's command-line arguments for a choice."""
    if choice.get("none"):
        return ["--no-screen"]
    if "window" in choice:
        return ["--window", str(choice["window"])]
    if "display" in choice:
        args = ["--display", str(choice["display"])]
        if "rect" in choice:
            args += ["--rect", ",".join(str(n) for n in choice["rect"])]
        return args
    return []


def choice_kind(choice):
    """What the recorder will call this choice in its state file."""
    if choice.get("none"):
        return "none"
    if "window" in choice:
        return "window"
    return "area" if "rect" in choice else "display"


def start_recording(mic, auto, source=None, rect=None):
    rec = recording()
    if rec and rec["state"] in REC_ACTIVE:
        return False, "A recording is already running."
    if not REC_APP.exists():
        return False, "The recorder is not built yet. Run recorder/build.sh once."
    choice, label, err = source_choice(source, rect)
    if err:
        return False, err
    extra = choice_args(choice)
    REC_DIR.mkdir(parents=True, exist_ok=True)
    m.MEETINGS.mkdir(parents=True, exist_ok=True)
    out = REC_DIR / f"Meeting {time.strftime('%Y-%m-%d %H-%M-%S')}.mov"
    REC_STATE.write_text(json.dumps({"state": "starting", "out": str(out), "started": time.time()}))
    rec_opts.update(auto=bool(auto), label=label, kind=choice_kind(choice))
    REC_CMD.unlink(missing_ok=True)
    cmd = ["open", "-n", str(REC_APP), "--args", "--out", str(out), "--state", str(REC_STATE),
           "--cmd", str(REC_CMD)]
    if not mic:
        cmd.append("--no-mic")
    cmd += extra
    r = subprocess.run(cmd, text=True, capture_output=True)
    if r.returncode != 0:
        REC_STATE.unlink(missing_ok=True)
        return False, f"The recorder could not be opened: {r.stderr.strip()}"
    return True, ""


def switch_recording(source, rect):
    """Change what a running recording records: another screen, a window, an area, or sound only."""
    try:
        st = json.loads(REC_STATE.read_text())
    except (OSError, ValueError):
        return False, "Nothing is being recorded."
    if st.get("state") != "recording" or not alive(st.get("pid")):
        return False, "Nothing is being recorded."
    if not source:
        return False, "Choose what to record."
    choice, label, err = source_choice(source, rect)
    if err:
        return False, err
    REC_CMD.write_text(json.dumps(choice))
    rec_opts.update(label=label, kind=choice_kind(choice))
    os.kill(int(st["pid"]), signal.SIGUSR1)  # the recorder reads REC_CMD and switches
    return True, ""


def stop_recording():
    try:
        st = json.loads(REC_STATE.read_text())
    except (OSError, ValueError):
        return False, "Nothing is being recorded."
    if st.get("state") not in REC_ACTIVE or not alive(st.get("pid")):
        return False, "Nothing is being recorded."
    os.kill(int(st["pid"]), 2)  # SIGINT: the recorder finishes the file, then exits
    threading.Thread(target=after_recording, args=(st.get("out"), int(st["pid"])), daemon=True).start()
    return True, ""


def after_recording(out, pid):
    """Wait for the file to be finished; transcribe it if that was asked for."""
    for _ in range(60):
        if not alive(pid):
            break
        time.sleep(0.5)
    rec = recording()
    # A recording with no picture ends up as .m4a: the recorder's last word says which file.
    out = (rec or {}).get("out") or out
    if not rec or rec["state"] != "finished" or not out or not Path(out).is_file():
        return
    if rec_opts["auto"]:
        e = find(rid(Path(out)))
        if e and e["audio"]:
            start_job("transcribe", e, lang="auto", force=False)
    REC_STATE.unlink(missing_ok=True)


def entries():
    """Every recording, plus meetings whose recording has gone."""
    out, seen = [], set()
    by_source = {meta.get("source"): (d, meta) for d, meta in m.meetings()}
    rec = recording()
    being_written = rec["out"] if rec and rec["state"] in REC_ACTIVE else None
    for p in m.find_recordings():
        # The file being written, under either ending: sound only is saved as .m4a at the end.
        if being_written and p.with_suffix("") == Path(being_written).with_suffix(""):
            continue
        dur, audio = probe(p)
        d, meta = by_source.get(str(p), (None, None))
        seen.add(str(p))
        out.append(entry(p, dur, audio, d, meta, True))
    for src, (d, meta) in by_source.items():
        if src not in seen:
            p = Path(src)
            exists = p.is_file()
            dur, audio = probe(p) if exists else (meta.get("duration_seconds", 0), 1)
            out.append(entry(p, dur, audio, d, meta, exists))
    out.sort(key=lambda e: e["recorded"], reverse=True)
    return out


def entry(p, dur, audio, folder, meta, exists):
    if folder is None:
        status = "new" if audio else "no-audio"
    elif (folder / "notes.md").exists():
        status = "notes"
    elif (folder / "transcript.md").exists():
        status = "transcript"
    else:
        status = "new"
    when = meta["recorded_at"] if meta else m.recorded_at(p).isoformat(timespec="minutes")
    return {
        "id": rid(p), "path": str(p), "file": p.name, "exists": exists,
        "recorded": when, "duration": m.hms(dur), "audio": bool(audio), "status": status,
        "folder": str(folder) if folder else None,
        "title": (meta or {}).get("title"),
        "lang": (meta or {}).get("language_setting"),
        "partial": (meta or {}).get("partial", False),
        "stuck": (meta or {}).get("stuck"),
        "speakers": (meta or {}).get("speakers", 0),
        "playable": exists and p.suffix.lower() in MEDIA_TYPES,
        "job": job_view(p),
    }


def find(id_):
    for e in entries():
        if e["id"] == id_:
            return e
    return None


def settings():
    def read(p):
        return p.read_text() if p.exists() else ""
    missing = [t for t in ("ffmpeg", "whisper-cli") if not m.shutil.which(t, path=ENV["PATH"])]
    if not m.MODEL.exists():
        missing.append("speech model")
    return {"vocabulary": read(m.VOCAB_FILE), "folders": read(m.EXTRA_DIRS_FILE),
            "defaultFolders": [str(d) for d in m.RECORDING_DIRS],
            "meetingsDir": str(m.MEETINGS), "missing": missing,
            "claude": bool(m.shutil.which("claude", path=ENV["PATH"]))}


def meeting_detail(e):
    folder = Path(e["folder"])
    paras, speakers = [], []
    if (folder / "segments.json").exists():
        segs = m.load_segments(folder)
        names = m.speaker_names(folder)
        paras = [{"t": int(t), "text": text, "spk": spk, "who": m.speaker_label(spk, names)}
                 for t, text, spk in m.paragraphs(segs)]
        seconds = {}
        for a, b, _, spk in segs:
            if spk:
                seconds[spk] = seconds.get(spk, 0) + (b - a)
        speakers = [{"n": n, "name": names.get(n, ""), "label": m.speaker_label(n, names),
                     "seconds": round(sec)} for n, sec in sorted(seconds.items())]
    notes = folder / "notes.md"
    return {"paragraphs": paras, "speakers": speakers,
            "notes": notes.read_text() if notes.exists() else None}


# ---------- jobs ----------

def start_job(kind, e, **opts):
    with _lock:
        cur = jobs.get(e["path"])
        if cur and cur["state"] in ("queued", "running"):
            return False, "This recording is already being worked on."
        j = {"kind": kind, "state": "queued", "message": "", "path": e["path"],
             "folder": e["folder"], "started": None, "ended": None, "proc": None,
             "stop": False, "opts": opts}
        jobs[e["path"]] = j
    work.put(j)
    return True, ""


def worker():
    while True:
        j = work.get()
        if j["stop"]:
            j.update(state="stopped", message="Stopped before it started.")
            continue
        j.update(state="running", started=time.time())
        try:
            {"transcribe": run_transcribe, "notes": run_notes, "speakers": run_speakers}[j["kind"]](j)
        except Exception as exc:  # keep the worker alive
            j.update(state="error", message=str(exc))
        j["ended"] = time.time()
        j["proc"] = None


def run_transcribe(j):
    cmd = [sys.executable, "-u", str(TOOL / "meeting.py"), "transcribe", j["path"],
           "--lang", j["opts"].get("lang", "auto")]
    if j["opts"].get("force"):
        cmd.append("--force")
    if j["opts"].get("count"):
        cmd += ["--speakers", str(j["opts"]["count"])]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV)
    j["proc"] = p
    lines = []
    for line in p.stdout:
        lines.append(line.rstrip())
        mt = re.match(r"Folder\s*:\s*(.+)", line)
        if mt:
            j["folder"] = mt.group(1).strip()
    p.wait()
    finish(j, p.returncode, lines, lambda: True)


def run_speakers(j):
    cmd = [sys.executable, "-u", str(TOOL / "meeting.py"), "speakers", j["folder"]]
    if j["opts"].get("count"):
        cmd += ["--count", str(j["opts"]["count"])]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV)
    j["proc"] = p
    lines = [line.rstrip() for line in p.stdout]
    p.wait()
    finish(j, p.returncode, lines, lambda: True)


def run_notes(j):
    folder = j["folder"]
    prompt = (
        f"Follow the instructions in {SKILL}. The meeting in {folder} is already transcribed, "
        "so skip steps 1 and 2 and do not transcribe again. Do steps 3 to 6: read all of "
        "transcript.md, look at frames where the talk points at the screen, give the meeting a "
        "title if it is still 'untitled', and write notes.md in the meeting folder (replace it "
        "if it exists). Finish with one line saying what you wrote.")
    cmd = ["claude", "-p", prompt, "--add-dir", str(m.MEETINGS), "--allowedTools",
           "Read", "Write", "Edit", f"Bash(python3 {TOOL / 'meeting.py'}:*)"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         env=ENV, cwd=str(m.MEETINGS))
    j["proc"] = p
    lines = [line.rstrip() for line in p.stdout]
    p.wait()

    def wrote():
        d = m.meeting_for(Path(j["path"]))
        return bool(d and (d / "notes.md").exists()
                    and (d / "notes.md").stat().st_mtime >= j["started"] - 1)
    finish(j, p.returncode, lines, wrote)


def finish(j, code, lines, check):
    tail = "\n".join(l for l in lines[-6:] if l)
    if j["stop"]:
        j.update(state="stopped", message="Stopped.")
    elif code == 0 and check():
        j.update(state="done", message=tail)
    else:
        j.update(state="error", message=re.sub(r"^error: ", "", tail) or f"exited with code {code}")


# ---------- http ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def fail(self, msg, code=400):
        self.send_json({"ok": False, "error": msg}, code)

    def local_only(self):
        """Refuse requests another website could make the browser send."""
        ok_hosts = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
        if self.headers.get("Host") not in ok_hosts:
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin in {f"http://{h}" for h in ok_hosts}

    def do_GET(self):
        if not self.local_only():
            return self.fail("not allowed", 403)
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/":
            body = PAGE.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/api/state":
            self.send_json({"ok": True, "entries": entries(), "settings": settings(),
                            "recording": recording(), "recorderBuilt": REC_APP.exists()})
        elif u.path == "/api/meeting":
            e = find(q.get("id", [""])[0])
            if not e or not e["folder"]:
                return self.fail("That meeting has no transcript yet.", 404)
            self.send_json({"ok": True, **meeting_detail(e)})
        elif u.path.startswith("/preview/"):
            name = u.path.split("/")[2]
            f = PREVIEW / name
            if not re.fullmatch(r"(display|window)-\d+\.png", name) or not f.is_file():
                return self.fail("not found", 404)
            body = f.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif u.path.startswith("/media/"):
            self.media(u.path.split("/")[2])
        else:
            self.fail("not found", 404)

    def media(self, id_):
        e = find(id_)
        if not e or not e["playable"]:
            return self.fail("not found", 404)
        path = Path(e["path"])
        size = path.stat().st_size
        start, end = 0, size - 1
        rng = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if rng:
            if rng.group(1):
                start = int(rng.group(1))
                end = int(rng.group(2)) if rng.group(2) else end
            elif rng.group(2):
                start = max(0, size - int(rng.group(2)))
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            end = min(end, size - 1)
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", MEDIA_TYPES[path.suffix.lower()])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if not self.local_only():
            return self.fail("not allowed", 403)
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self.fail("bad request")
        action = urlparse(self.path).path.removeprefix("/api/")
        e = find(body["id"]) if "id" in body else None
        needs_entry = {"transcribe", "notes", "stop", "title", "remove", "reveal", "open",
                       "speakers", "speaker"}
        count = body.get("count")
        if count is not None and not (isinstance(count, int) and 1 <= count <= 12):
            return self.fail("The number of people must be between 1 and 12.")
        if action in needs_entry and not e:
            return self.fail("That recording is no longer in the list. Refresh and try again.", 404)

        if action == "transcribe":
            if not e["exists"]:
                return self.fail("The recording file is gone, so it cannot be transcribed.")
            if not e["audio"]:
                return self.fail("This recording has no audio track.")
            lang = body.get("lang", "auto")
            if lang not in ("auto", "zh", "en"):
                return self.fail("Unknown language setting.")
            ok, msg = start_job("transcribe", e, lang=lang, force=bool(e["folder"]), count=count)
        elif action == "speakers":
            if not e["folder"] or not e["exists"]:
                return self.fail("This needs a transcript and the recording file.")
            ok, msg = start_job("speakers", e, count=count)
        elif action == "speaker":
            if not e["folder"]:
                return self.fail("This meeting has no transcript yet.")
            try:
                number = str(int(body.get("number")))
            except (TypeError, ValueError):
                return self.fail("Unknown speaker.")
            ok, msg = tool("name", e["folder"], number, str(body.get("name", "")))
        elif action == "notes":
            if e["status"] not in ("transcript", "notes"):
                return self.fail("Transcribe the recording first.")
            if not settings()["claude"]:
                return self.fail("The `claude` command was not found, so notes cannot be written from here.")
            ok, msg = start_job("notes", e)
        elif action == "stop":
            j = jobs.get(e["path"])
            if not j or j["state"] not in ("queued", "running"):
                return self.fail("Nothing is running for this recording.")
            j["stop"] = True
            if j.get("proc"):
                j["proc"].terminate()
            ok, msg = True, ""
        elif action == "title":
            if not e["folder"]:
                return self.fail("Transcribe the recording before naming it.")
            ok, msg = tool("title", e["folder"], str(body.get("title", "")))
        elif action == "remove":
            if not e["folder"]:
                return self.fail("There are no notes to remove.")
            j = jobs.get(e["path"])
            if j and j["state"] in ("queued", "running"):
                return self.fail("Stop the running job first.")
            ok, msg = tool("remove", e["folder"])
            if ok:
                trashed = re.search(r"Moved to the Trash: (.+)", msg)
                jobs.pop(e["path"], None)
                return self.send_json({"ok": True, "trashed": trashed.group(1) if trashed else None})
        elif action == "restore":
            ok, msg = tool("restore", str(body.get("trashed", "")))
        elif action == "reveal":
            target = e["folder"] if body.get("what") == "notes" else e["path"]
            if not target or not Path(target).exists():
                return self.fail("That file is no longer there.")
            subprocess.run(["open", target] if body.get("what") == "notes" else ["open", "-R", target])
            ok, msg = True, ""
        elif action == "open":
            f = Path(e["folder"] or "") / ("notes.md" if body.get("what") == "notes" else "transcript.md")
            if not e["folder"] or not f.exists():
                return self.fail("That file does not exist yet.")
            subprocess.run(["open", "-t", str(f)])
            ok, msg = True, ""
        elif action == "record/start":
            ok, msg = start_recording(body.get("mic", True), body.get("auto", True),
                                      body.get("source"), body.get("rect"))
        elif action == "record/sources":
            ok, data = list_sources()
            if ok:
                return self.send_json({"ok": True, **data})
            msg = data
        elif action == "record/switch":
            ok, msg = switch_recording(body.get("source"), body.get("rect"))
        elif action == "record/stop":
            ok, msg = stop_recording()
        elif action == "record/dismiss":
            rec = recording()
            if rec and rec["state"] in REC_ACTIVE:
                return self.fail("The recording is still running.")
            REC_STATE.unlink(missing_ok=True)
            ok, msg = True, ""
        elif action == "settings":
            folders = str(body.get("folders", ""))
            bad = [l.strip() for l in folders.splitlines()
                   if l.strip() and not l.startswith("#") and not Path(l.strip()).expanduser().is_dir()]
            if bad:
                return self.fail("Not a folder on this Mac: " + ", ".join(bad))
            m.MEETINGS.mkdir(parents=True, exist_ok=True)
            m.VOCAB_FILE.write_text(str(body.get("vocabulary", "")))
            m.EXTRA_DIRS_FILE.write_text(folders)
            ok, msg = True, ""
        else:
            return self.fail("not found", 404)
        self.send_json({"ok": True, "message": msg}) if ok else self.fail(msg)


def main():
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        print(f"Port {PORT} is in use: the page is probably already running at http://127.0.0.1:{PORT}")
        if "--no-open" not in sys.argv:
            webbrowser.open(f"http://127.0.0.1:{PORT}")
        return
    threading.Thread(target=worker, daemon=True).start()
    url = f"http://127.0.0.1:{PORT}"
    print(f"Meeting notes: {url}   (Ctrl+C to stop)")
    if "--no-open" not in sys.argv:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
