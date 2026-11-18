#!/usr/bin/env python3
"""Who spoke when. Run with the tool's .venv Python (needs sherpa-onnx).

  diarize.py <audio.wav (16 kHz mono)> <out.json> [--speakers N] [--progress FILE]

Writes [{"start": s, "end": s, "speaker": 0}, ...]. Runs on this Mac only.

Two passes. The first (sherpa-onnx: pyannote segmentation + voice embeddings) splits
the talk into turns but finds far too many speakers, and it splits one person in two
when they switch between English and Mandarin. The second pass here takes each found
speaker's whole voice (up to 3 minutes of it), and merges speakers whose voices match.
Measured on a 61-minute English and Mandarin call: the same person scores 0.61 to 0.96
against their own other labels, different people 0.42 or less, so the line is 0.52.
"""
import argparse
import array
import json
import math
import sys
import wave
from pathlib import Path

import sherpa_onnx

MODELS = Path(__file__).resolve().parent / "models" / "diar"
SEGMENTATION = MODELS / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
EMBEDDING = MODELS / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"


MERGE_AT = 0.52     # voices at least this similar are one person
ADOPT_AT = 0.40     # a voice heard only briefly joins its nearest speaker above this
BRIEF = 20.0        # seconds; below this a voice is too short to stand on its own


def unit(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def merge_voices(turns, samples, extractor, wanted=-1):
    """turns: [(start, end, speaker)]. Returns the same turns with merged speaker ids."""
    by = {}
    for a, b, spk in turns:
        by.setdefault(spk, []).append((a, b))
    seconds = {spk: sum(b - a for a, b in ch) for spk, ch in by.items()}

    def voice(chunks, limit=180.0):
        st, used = extractor.create_stream(), 0.0
        for a, b in sorted(chunks, key=lambda c: c[0] - c[1]):   # longest turns first
            if used >= limit:
                break
            st.accept_waveform(16000, samples[int(a * 16000):int(b * 16000)])
            used += b - a
        st.input_finished()
        return unit(extractor.compute(st)) if extractor.is_ready(st) else None

    emb = {spk: voice(ch) for spk, ch in by.items()}
    emb = {spk: e for spk, e in emb.items() if e is not None}
    main = [spk for spk in emb if seconds[spk] >= BRIEF]
    if not main:
        main = sorted(emb, key=lambda k: -seconds[k])[:1]
    group = {spk: spk for spk in by}          # speaker -> the group it belongs to
    centre = {spk: emb[spk] for spk in main}  # group -> its voice
    weight = {spk: seconds[spk] for spk in main}
    while len(centre) > 1:
        pairs = [(cos(centre[a], centre[b]), a, b) for a in centre for b in centre if a < b]
        sim, a, b = max(pairs)
        if (wanted > 0 and len(centre) <= wanted) or (wanted <= 0 and sim < MERGE_AT):
            break
        wa, wb = weight[a], weight[b]
        centre[a] = unit([x * wa + y * wb for x, y in zip(centre[a], centre[b])])
        weight[a] = wa + wb
        del centre[b], weight[b]
        for spk, g in group.items():
            if g == b:
                group[spk] = a
    for spk in by:                             # brief voices: adopt, or leave unlabelled
        if group[spk] in centre:
            continue
        best = max(((cos(emb[spk], c), g) for g, c in centre.items()), default=(0, None)) \
            if spk in emb else (0, None)
        group[spk] = best[1] if best[0] >= ADOPT_AT else None
    return [(a, b, group[spk]) for a, b, spk in turns if group[spk] is not None]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("out")
    ap.add_argument("--speakers", type=int, default=-1, help="number of people, if known")
    ap.add_argument("--threshold", type=float, default=0.9,
                    help="first pass only: higher = fewer speakers before merging")
    ap.add_argument("--no-merge", action="store_true", help="skip the second pass")
    ap.add_argument("--progress")
    args = ap.parse_args()
    for f in (SEGMENTATION, EMBEDDING):
        if not f.exists():
            sys.exit(f"error: speaker model missing: {f}")

    with wave.open(args.wav, "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            sys.exit("error: expected 16 kHz, mono, 16-bit audio")
        pcm = array.array("h")
        pcm.frombytes(w.readframes(w.getnframes()))
    samples = [s / 32768.0 for s in pcm]

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(SEGMENTATION)),
            num_threads=4),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING), num_threads=8),
        # The first pass always over-splits on purpose; the second pass decides who is who.
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=args.threshold),
        min_duration_on=0.3, min_duration_off=0.5)
    if not config.validate():
        sys.exit("error: the speaker models could not be loaded")
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)

    def progress(done, total):
        if args.progress:
            Path(args.progress).write_text(json.dumps({"done": done, "total": total, "step": "speakers"}))
        return 0

    result = sd.process(samples, callback=progress).sort_by_start_time()
    turns = [(r.start, r.end, int(r.speaker)) for r in result]
    first = len({t[2] for t in turns})
    if not args.no_merge and turns:
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING), num_threads=8))
        turns = merge_voices(turns, samples, extractor, args.speakers)
    Path(args.out).write_text(json.dumps(
        [{"start": round(a, 2), "end": round(b, 2), "speaker": spk} for a, b, spk in turns]))
    print(f"{len(turns)} turns, {len({t[2] for t in turns})} speakers (first pass: {first})")


if __name__ == "__main__":
    main()
