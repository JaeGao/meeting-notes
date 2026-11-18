#!/usr/bin/env python3
"""Meeting recordings -> local transcripts. Standard library only.

  meeting.py list                     recordings found, and which already have notes
  meeting.py transcribe <rec>         <rec> = a path, a number from `list`, or `latest`
  meeting.py frame <meeting> <time>   save the screen at HH:MM:SS as a PNG
  meeting.py title <meeting> "<t>"    rename a meeting
  meeting.py speakers <meeting>       tell the speakers apart again (--count N if known)
  meeting.py name <meeting> <n> "<name>"   give Speaker n a name
  meeting.py remove <meeting>         move a meeting's notes folder to the Trash

Nothing leaves this Mac: ffmpeg pulls the audio out, whisper.cpp turns it into text.
The recording itself is never changed, moved or deleted.
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
TOOL = Path(__file__).resolve().parent
MEETINGS = Path(os.environ.get("MEETINGS_DIR", HOME / "Documents" / "Meetings"))
RECORDING_DIRS = [HOME / "Movies", HOME / "Desktop"]  # OBS, Mac screen recordings
EXTRA_DIRS_FILE = MEETINGS / "recording-folders.txt"   # one extra folder per line
VOCAB_FILE = MEETINGS / "vocabulary.txt"                # names and terms, one per line
MODEL = TOOL / "models" / "ggml-large-v3.bin"
VAD_MODEL = TOOL / "models" / "ggml-silero-v5.1.2.bin"
EXTS = {".mov", ".mkv", ".mp4", ".m4a", ".wav", ".mp3", ".webm", ".flv", ".m4v"}
MIN_BYTES = 100_000
# No instruction sentence is given to whisper: it imitates the prompt's style, and a
# bilingual sentence made it write every line twice. Only the vocabulary list is used.


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def need(tool):
    if not shutil.which(tool):
        die(f"`{tool}` is not installed. Install it with: brew install "
            f"{'whisper-cpp' if tool == 'whisper-cli' else tool}")


# ---------- recordings ----------

def recording_dirs():
    dirs = list(RECORDING_DIRS)
    if EXTRA_DIRS_FILE.exists():
        for line in EXTRA_DIRS_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                dirs.append(Path(line).expanduser())
    return [d for d in dirs if d.is_dir()]


def recorded_at(path):
    """Start time from the file name (OBS, Mac screen recording), else the file date."""
    name = path.stem
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})[ _T](?:at )?(\d{2})[-.:](\d{2})(?:[-.:](\d{2}))?", name)
    if m:
        y, mo, d, h, mi, s = (int(x) if x else 0 for x in m.groups())
        try:
            return dt.datetime(y, mo, d, h, mi, s)
        except ValueError:
            pass
    return dt.datetime.fromtimestamp(path.stat().st_mtime)


def probe(path):
    """(duration in seconds, number of audio tracks)."""
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type",
             "-of", "json", str(path)])
    if r.returncode != 0:
        return 0.0, 0
    data = json.loads(r.stdout or "{}")
    dur = float(data.get("format", {}).get("duration", 0) or 0)
    audio = sum(1 for s in data.get("streams", []) if s.get("codec_type") == "audio")
    return dur, audio


def find_recordings():
    found = []
    for d in recording_dirs():
        for p in d.iterdir():
            if p.is_file() and p.suffix.lower() in EXTS and not p.name.startswith(".") \
                    and p.stat().st_size >= MIN_BYTES:
                found.append(p)
    return sorted(found, key=recorded_at, reverse=True)


def meetings():
    out = []
    if MEETINGS.is_dir():
        for d in sorted(MEETINGS.iterdir(), reverse=True):
            meta = d / "meta.json"
            if d.is_dir() and meta.exists():
                try:
                    out.append((d, json.loads(meta.read_text())))
                except json.JSONDecodeError:
                    pass
    return out


def meeting_for(path):
    for d, meta in meetings():
        if meta.get("source") == str(path):
            return d
    return None


def hms(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def cmd_list(args):
    need("ffprobe")
    recs = find_recordings()
    if not recs:
        print("No recordings found in:", ", ".join(str(d) for d in recording_dirs()))
        return
    print(f"{'#':>2}  {'Recorded':16}  {'Length':8}  {'Audio':5}  {'Status':15}  File")
    for i, p in enumerate(recs, 1):
        dur, audio = probe(p)
        folder = meeting_for(p)
        if folder is None:
            status = "new" if audio else "no audio track"
        elif (folder / "notes.md").exists():
            status = "notes written"
        else:
            status = "transcript only"
        print(f"{i:>2}  {recorded_at(p):%Y-%m-%d %H:%M}  {hms(dur)}  "
              f"{'yes' if audio else 'NO':5}  {status:15}  {p}")
    print(f"\nNotes folder: {MEETINGS}")


def resolve_recording(ref):
    recs = None
    if ref == "latest":
        recs = find_recordings()
        if not recs:
            die("no recordings found")
        return recs[0]
    if ref.isdigit():
        recs = find_recordings()
        n = int(ref)
        if not 1 <= n <= len(recs):
            die(f"there is no recording #{n}; `list` shows 1 to {len(recs)}")
        return recs[n - 1]
    p = Path(ref).expanduser().resolve()
    if not p.is_file():
        die(f"no such file: {p}")
    return p


# ---------- transcription ----------

def slugify(text):
    s = re.sub(r"[^\w\s-]", "", text.lower(), flags=re.UNICODE)
    return re.sub(r"[\s_]+", "-", s).strip("-")[:60] or "meeting"


def vocabulary():
    if not VOCAB_FILE.exists():
        return ""
    words = [w.strip() for w in VOCAB_FILE.read_text().splitlines()
             if w.strip() and not w.startswith("#")]
    return ", ".join(words)


def extract_audio(src, wav, audio_tracks, start=None, end=None):
    cmd = ["ffmpeg", "-v", "error", "-y"]
    if start:
        cmd += ["-ss", start]
    if end:
        cmd += ["-to", end]
    cmd += ["-i", str(src)]
    if audio_tracks > 1:  # OBS can keep mic and desktop sound on separate tracks
        ins = "".join(f"[0:a:{i}]" for i in range(audio_tracks))
        cmd += ["-filter_complex", f"{ins}amix=inputs={audio_tracks}:normalize=0[a]", "-map", "[a]"]
    else:
        cmd += ["-map", "0:a:0"]
    cmd += ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)]
    r = run(cmd)
    if r.returncode != 0:
        die(f"ffmpeg could not read the audio:\n{r.stderr.strip()}")


def paragraphs(segments, gap=2.0, max_chars=450):
    """Group segments (start, end, text[, speaker]) into readable paragraphs:
    (start_seconds, text, speaker). A new paragraph starts when the speaker changes."""
    out, cur, cur_start, last_end, cur_spk = [], [], None, None, None
    for seg in segments:
        start, end, text = seg[0], seg[1], seg[2].strip()
        spk = seg[3] if len(seg) > 3 else None
        if not text:
            continue
        if cur and (spk != cur_spk or start - last_end > gap or sum(len(t) for t in cur) > max_chars):
            out.append((cur_start, " ".join(cur), cur_spk))
            cur = []
        if not cur:
            cur_start, cur_spk = start, spk
        cur.append(text)
        last_end = end
    if cur:
        out.append((cur_start, " ".join(cur), cur_spk))
    return out


# ---------- speakers ----------

VENV_PY = TOOL / ".venv" / "bin" / "python"
DIARIZE = TOOL / "diarize.py"


def find_speakers(wav, tmp, count=None, progress=None):
    """Who spoke when, for a 16 kHz mono wav. Returns turns [(start, end, speaker)] or
    None with a printed reason. Runs diarize.py in the tool's .venv."""
    if not VENV_PY.exists() or not DIARIZE.exists():
        print("note: speaker labels are off (the .venv with sherpa-onnx is not set up; see README).")
        return None
    out = Path(tmp) / "turns.json"
    cmd = [str(VENV_PY), str(DIARIZE), str(wav), str(out), "--threshold", "0.9"]
    if count:
        cmd += ["--speakers", str(count)]
    if progress:
        cmd += ["--progress", str(progress)]
    r = run(cmd)
    if r.returncode != 0 or not out.exists():
        print(f"warning: speakers could not be told apart: {(r.stderr or r.stdout).strip()[-300:]}")
        return None
    return [(t["start"], t["end"], t["speaker"]) for t in json.loads(out.read_text())]


def label_segments(segs, turns, offset=0.0):
    """Give each transcript segment the speaker who talks most during it. Speakers are
    numbered 1, 2, 3 in order of first appearance; voices heard for under 8 seconds (or
    1% of the talking) stay unlabelled, since they are usually noise or a split voice."""
    total = {}
    for a, b, spk in turns:
        total[spk] = total.get(spk, 0) + (b - a)
    floor = max(8.0, 0.01 * sum(total.values()))
    keep = {spk for spk, t in total.items() if t >= floor}
    number, out = {}, []
    for a, b, text in segs:
        best, best_overlap = None, 0.0
        for ta, tb, spk in turns:
            ov = min(b, tb + offset) - max(a, ta + offset)
            if ov > best_overlap and spk in keep:
                best, best_overlap = spk, ov
        if best is not None and best not in number:
            number[best] = len(number) + 1
        out.append((a, b, text, number.get(best)))
    return out, len(number)


def speaker_names(folder):
    f = folder / "speakers.json"
    try:
        return {int(k): v for k, v in json.loads(f.read_text()).items()} if f.exists() else {}
    except (ValueError, AttributeError):
        return {}


def speaker_label(n, names):
    return None if n is None else names.get(n) or f"Speaker {n}"


def load_segments(folder):
    return [(x["start"], x["end"], x["text"], x.get("speaker"))
            for x in json.loads((folder / "segments.json").read_text())]


def write_transcript(folder, meta, segs):
    """Write segments.json and transcript.md from segments (start, end, text, speaker)."""
    (folder / "segments.json").write_text(json.dumps(
        [{"start": round(a, 2), "end": round(b, 2), "text": t.strip(), "speaker": spk}
         for a, b, t, spk in segs], ensure_ascii=False, indent=1) + "\n")
    names = speaker_names(folder)
    labelled = any(spk for _, _, _, spk in segs)
    when = dt.datetime.fromisoformat(meta["recorded_at"])
    who = ("- Speakers are told apart by voice on this Mac. A label can be wrong, one person can "
           "be split in two, and two similar voices can be merged."
           if labelled else "- Speakers are not identified.")
    lines = [f"# Transcript: {meta['title']}", "",
             f"- Recorded: {when:%Y-%m-%d %H:%M}, {hms(meta['duration_seconds'])} long",
             f"- Source: `{meta['source']}`",
             f"- Made on this Mac with whisper.cpp ({meta['model']}), language "
             f"`{meta['language_setting']}`",
             who,
             "- Names, numbers and mixed-language passages can be wrong: check the recording at "
             "the time shown before quoting.", ""]
    paras = paragraphs(segs)
    for start, text, spk in paras:
        label = speaker_label(spk, names)
        lines.append(f"**[{hms(start)}]{' ' + label + ':' if label else ''}** {text}")
        lines.append("")
    (folder / "transcript.md").write_text("\n".join(lines))
    return paras


def split_audio(wav, tmp, target=22.0, lo=10.0, hi=29.0):
    """Cut the audio at pauses into pieces of about `target` seconds.
    Returns [(start_seconds, piece_path)]."""
    r = run(["ffmpeg", "-v", "info", "-i", str(wav), "-af", "silencedetect=noise=-35dB:d=0.35",
             "-f", "null", "-"])
    total = probe(wav)[0]
    starts = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", r.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", r.stderr)]
    pauses = [(a + b) / 2 for a, b in zip(starts, ends)]
    cuts, cur = [], 0.0
    while total - cur > hi:
        near = [t for t in pauses if cur + lo <= t <= cur + hi]
        cur = min(near, key=lambda t: abs(t - (cur + target))) if near else cur + target
        cuts.append(cur)
    if not cuts:
        return [(0.0, wav)]
    r = run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-f", "segment", "-segment_times",
             ",".join(f"{c:.3f}" for c in cuts), "-c", "copy", str(tmp / "piece_%04d.wav")])
    if r.returncode != 0:
        die(f"ffmpeg could not split the audio:\n{r.stderr.strip()}")
    pieces = sorted(tmp.glob("piece_*.wav"))
    return list(zip([0.0] + cuts, pieces))


# Lines whisper invents over silence or music (it learned them from subtitle files).
GHOST = re.compile(r"amara\.org|subtitles by|thanks? (you )?for watching|字幕(由|提供|志愿者)|请不吝点赞|明镜与点点",
                   re.IGNORECASE)


def stuck_run(segs, limit=8):
    """Whisper can get stuck repeating one sentence. Returns (times, start, text) of the
    longest run of identical lines if it is `limit` or more, else None."""
    best, run, run_start = None, 1, 0
    for i in range(1, len(segs) + 1):
        same = i < len(segs) and segs[i][2].strip() == segs[i - 1][2].strip()
        if same:
            if run == 1:
                run_start = i - 1
            run += 1
            continue
        text = segs[i - 1][2].strip()
        if run >= limit and len(text) > 12 and (best is None or run > best[0]):
            best = (run, segs[run_start][0], text)
        run = 1
    return best


def cmd_transcribe(args):
    for t in ("ffmpeg", "ffprobe", "whisper-cli"):
        need(t)
    if not MODEL.exists():
        die(f"speech model missing: {MODEL}")
    src = resolve_recording(args.recording)
    dur, audio_tracks = probe(src)
    if not audio_tracks:
        die(f"this recording has no audio track, so there is nothing to transcribe:\n  {src}\n"
            "Mac screen recordings only capture sound if a microphone is chosen in the "
            "recording options.")
    existing = meeting_for(src)
    if existing and not args.force and not args.out:
        die(f"already transcribed: {existing}\nUse --force to transcribe it again "
            "(notes.md is kept).")

    when = recorded_at(src)
    title = args.title or (json.loads((existing / "meta.json").read_text()).get("title")
                           if existing else None) or "untitled"
    if args.out:
        folder = Path(args.out).expanduser()
    else:
        folder = existing or MEETINGS / f"{when:%Y-%m-%d-%H%M}-{slugify(title)}"
    folder.mkdir(parents=True, exist_ok=True)

    prompt = vocabulary()

    print(f"Recording : {src}")
    print(f"Length    : {hms(dur)}   Language: {args.lang}")
    print(f"Folder    : {folder}", flush=True)
    offset = 0.0
    if args.start:
        parts = [float(x) for x in args.start.split(":")]
        offset = sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
    progress = folder / "progress.json"
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        extract_audio(src, wav, audio_tracks, args.start, args.end)
        # Cut at pauses into pieces of under 30 s. Each piece gets its own language
        # detection (so Mandarin stays Mandarin and English stays English) and a fresh
        # start (so one bad stretch cannot make the rest of the transcript repeat).
        chunks = split_audio(wav, Path(tmp))
        cmd = ["whisper-cli", "-m", str(MODEL), "-l", args.lang, "-oj", "-t", "8", "-sns"]
        if prompt:
            cmd += ["--prompt", prompt]
        if VAD_MODEL.exists() and not args.no_vad:
            cmd += ["--vad", "-vm", str(VAD_MODEL)]
        cmd += [str(c) for _, c in chunks]
        print(f"Transcribing {len(chunks)} pieces (a one-hour meeting takes several minutes)...",
              flush=True)
        started = dt.datetime.now()
        with open(folder / "whisper.log", "w") as log:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=log)
            while proc.poll() is None:
                done = sum(1 for _, c in chunks if Path(str(c) + ".json").exists())
                progress.write_text(json.dumps({"done": done, "total": len(chunks)}))
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
        progress.unlink(missing_ok=True)
        segs, langs, missing = [], {}, 0
        for at, c in chunks:
            out_json = Path(str(c) + ".json")
            if not out_json.exists():
                missing += 1
                continue
            data = json.loads(out_json.read_text(errors="replace"))
            lang = data.get("result", {}).get("language", args.lang)
            for sg in data.get("transcription", []):
                if sg["text"].strip() and not GHOST.search(sg["text"]):
                    langs[lang] = langs.get(lang, 0) + 1
                    segs.append((sg["offsets"]["from"] / 1000 + at + offset,
                                 sg["offsets"]["to"] / 1000 + at + offset, sg["text"]))
        if proc.returncode != 0 or missing == len(chunks):
            die(f"whisper failed; see {folder / 'whisper.log'}")
        turns = None
        if segs and not args.no_speakers:
            print("Telling the speakers apart...", flush=True)
            turns = find_speakers(wav, tmp, args.speakers, progress)
            progress.unlink(missing_ok=True)
        took = (dt.datetime.now() - started).total_seconds()

    stuck = stuck_run(segs)
    detected = ", ".join(f"{k} ({v} lines)" for k, v in sorted(langs.items(), key=lambda x: -x[1]))
    if turns:
        segs4, n_speakers = label_segments(segs, turns, offset)
    else:
        segs4, n_speakers = [(a, b, t, None) for a, b, t in segs], 0

    meta = {
        "title": title,
        "recorded_at": when.isoformat(timespec="minutes"),
        "duration_seconds": round(dur),
        "source": str(src),
        "language_setting": args.lang,
        "language_detected": detected,
        "model": MODEL.name,
        "transcribed_at": dt.datetime.now().isoformat(timespec="minutes"),
        "partial": bool(args.start or args.end),
        "pieces_failed": missing,
        "speakers": n_speakers,
        "stuck": ({"times": stuck[0], "from": hms(stuck[1]), "text": stuck[2]} if stuck else None),
    }
    (folder / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    (folder / "speakers.json").unlink(missing_ok=True)   # numbers change with every run
    paras = write_transcript(folder, meta, segs4)

    words = sum(len(t.split()) for _, t, _ in paras)
    print(f"Done in {took:.0f} s: {len(paras)} paragraphs, about {words} words"
          f"{f', {n_speakers} speakers' if n_speakers else ''}.")
    print(f"Transcript: {folder / 'transcript.md'}")
    if not paras:
        print("warning: no speech was found in this recording.")
    if stuck:
        print(f"warning: the transcriber repeated one line {stuck[0]} times from {hms(stuck[1])} "
              f"({stuck[2]!r}). That part of the transcript is not real: transcribe again, "
              "or try --lang en or --lang zh.")


# ---------- meeting folders ----------

def resolve_meeting(ref):
    p = Path(ref).expanduser()
    if p.is_dir() and (p / "meta.json").exists():
        return p.resolve()
    cands = [d for d, _ in meetings() if ref in d.name]
    if len(cands) == 1:
        return cands[0]
    if not cands:
        die(f"no meeting matches '{ref}' in {MEETINGS}")
    die("more than one meeting matches:\n  " + "\n  ".join(d.name for d in cands))


def cmd_frame(args):
    need("ffmpeg")
    folder = resolve_meeting(args.meeting)
    meta = json.loads((folder / "meta.json").read_text())
    src = Path(meta["source"])
    if not src.exists():
        die(f"the recording is no longer at {src}")
    if not re.fullmatch(r"\d{1,2}(:\d{2}){1,2}", args.time):
        die("time must look like 12:34 or 01:02:03")
    frames = folder / "frames"
    frames.mkdir(exist_ok=True)
    out = frames / f"{args.time.replace(':', '-')}.png"
    r = run(["ffmpeg", "-v", "error", "-y", "-ss", args.time, "-i", str(src),
             "-frames:v", "1", "-vf", "scale='min(1920,iw)':-2", str(out)])
    if r.returncode != 0 or not out.exists():
        die(f"could not read a frame at {args.time}: {r.stderr.strip() or 'past the end?'}")
    print(out)


def cmd_title(args):
    folder = resolve_meeting(args.meeting)
    meta = json.loads((folder / "meta.json").read_text())
    title = args.title.strip()
    if not title:
        die("the title cannot be empty")
    when = dt.datetime.fromisoformat(meta["recorded_at"])
    new = folder.parent / f"{when:%Y-%m-%d-%H%M}-{slugify(title)}"
    if new != folder and new.exists():
        die(f"a meeting folder with that name already exists: {new}")
    old_title = meta.get("title", "untitled")
    meta["title"] = title
    (folder / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    if (folder / "segments.json").exists():
        write_transcript(folder, meta, load_segments(folder))
    if new != folder:
        folder.rename(new)
    print(new)


def cmd_remove(args):
    folder = resolve_meeting(args.meeting)
    trash = HOME / ".Trash"
    dest = trash / folder.name
    if dest.exists():
        dest = trash / f"{folder.name} {dt.datetime.now():%H%M%S}"
    shutil.move(str(folder), str(dest))
    print(f"Moved to the Trash: {dest}")
    print("The recording itself was not touched. Undo with: meeting.py restore "
          f"'{dest}'")


def cmd_speakers(args):
    """Tell the speakers apart again for a meeting that is already transcribed."""
    for t in ("ffmpeg", "ffprobe"):
        need(t)
    folder = resolve_meeting(args.meeting)
    meta = json.loads((folder / "meta.json").read_text())
    src = Path(meta["source"])
    if not src.is_file():
        die(f"the recording is no longer at {src}")
    if meta.get("partial"):
        die("this transcript covers only part of the recording; transcribe it again instead")
    if args.count is not None and not 1 <= args.count <= 12:
        die("the number of people must be between 1 and 12")
    segs = [(a, b, t) for a, b, t, _ in load_segments(folder)]
    progress = folder / "progress.json"
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        extract_audio(src, wav, probe(src)[1])
        print("Telling the speakers apart...", flush=True)
        turns = find_speakers(wav, tmp, args.count, progress)
    progress.unlink(missing_ok=True)
    if not turns:
        die("no speakers were found")
    segs4, n = label_segments(segs, turns)
    meta["speakers"] = n
    (folder / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    (folder / "speakers.json").unlink(missing_ok=True)
    write_transcript(folder, meta, segs4)
    print(f"{n} speakers found. Names were reset: the numbers are new.")
    print(f"Transcript: {folder / 'transcript.md'}")


def cmd_name(args):
    """Give a speaker a name (an empty name goes back to "Speaker N")."""
    folder = resolve_meeting(args.meeting)
    meta = json.loads((folder / "meta.json").read_text())
    n = meta.get("speakers", 0)
    if not 1 <= args.number <= n:
        die(f"this meeting has speakers 1 to {n}" if n else "this meeting has no speaker labels yet")
    name = args.name.strip()
    if len(name) > 40 or any(c in name for c in "*[]\n"):
        die("a name must be 40 characters or fewer, without * [ ]")
    names = speaker_names(folder)
    if name:
        names[args.number] = name
    else:
        names.pop(args.number, None)
    (folder / "speakers.json").write_text(json.dumps(names, indent=1, ensure_ascii=False) + "\n")
    write_transcript(folder, meta, load_segments(folder))
    print(f"Speaker {args.number} is now {name or f'Speaker {args.number}'}.")


def cmd_restore(args):
    src = Path(args.trashed).expanduser().resolve()
    trash = (HOME / ".Trash").resolve()
    if src.parent != trash or not (src / "meta.json").exists():
        die("that is not a meeting folder in the Trash")
    meta = json.loads((src / "meta.json").read_text())
    when = dt.datetime.fromisoformat(meta["recorded_at"])
    dest = MEETINGS / f"{when:%Y-%m-%d-%H%M}-{slugify(meta.get('title', 'untitled'))}"
    if dest.exists():
        die(f"a meeting folder is already there: {dest}")
    MEETINGS.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dest))
    print(dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    t = sub.add_parser("transcribe")
    t.add_argument("recording", help="path, number from `list`, or `latest`")
    t.add_argument("--lang", default="auto", help="auto (default), zh, en, or any whisper code")
    t.add_argument("--title")
    t.add_argument("--force", action="store_true", help="transcribe again")
    t.add_argument("--start", help="only from this time (HH:MM:SS), for testing")
    t.add_argument("--end", help="only up to this time (HH:MM:SS), for testing")
    t.add_argument("--out", help="write to this folder instead (for testing)")
    t.add_argument("--no-vad", action="store_true", help="do not skip silence")
    t.add_argument("--speakers", type=int, help="how many people speak, if you know")
    t.add_argument("--no-speakers", action="store_true", help="do not label speakers")
    t.set_defaults(fn=cmd_transcribe)
    f = sub.add_parser("frame")
    f.add_argument("meeting")
    f.add_argument("time")
    f.set_defaults(fn=cmd_frame)
    r = sub.add_parser("title")
    r.add_argument("meeting")
    r.add_argument("title")
    r.set_defaults(fn=cmd_title)
    d = sub.add_parser("remove")
    d.add_argument("meeting")
    d.set_defaults(fn=cmd_remove)
    sp = sub.add_parser("speakers")
    sp.add_argument("meeting")
    sp.add_argument("--count", type=int, help="how many people speak, if you know")
    sp.set_defaults(fn=cmd_speakers)
    nm = sub.add_parser("name")
    nm.add_argument("meeting")
    nm.add_argument("number", type=int)
    nm.add_argument("name")
    nm.set_defaults(fn=cmd_name)
    u = sub.add_parser("restore")
    u.add_argument("trashed", help="the folder's path in the Trash, as `remove` printed it")
    u.set_defaults(fn=cmd_restore)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
