from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

DEFAULT_COACH = Path.home() / "projects/cjonesde/cj-plugins/plugins/cj-core/skills/talking-head-coaching/scripts/coach.py"

RATE = 16000
WINDOW = 0.05
TAP_QUIET_DB = -50.0
GATE_LEAD = 0.3
GATE_HANGOVER = 0.5
OVERLAP_MARGIN_DB = 6.0
SPEECH_ABOVE_FLOOR_DB = 10.0
SPEECH_MIN_DB = -60.0
FLOOR_PERCENTILE = 10

LEVEL_HOP = 160
LEVEL_FRAME = 480
NUCLEUS_HYSTERESIS_DB = 2.0
NUCLEUS_VOICED_TOLERANCE = 0.03

ENVELOPE_HOP = 32
MAX_BLEED_LAG = 0.3
MIN_BLEED_SECONDS = 1.0

ENDING_SPAN_BEFORE = 0.7
ENDING_SPAN_AFTER = 0.25
CLIP_BEFORE = 3.0
CLIP_AFTER = 0.5

USABLE_AGREEMENT = 0.8
USABLE_MIN_MARKED = 15
USABLE_SCORABLE_SHARE = 0.5

CSV_FIELDS = ["t", "contour", "rise", "fall", "gated", "ear"]


class SpeakerTestError(Exception):
    pass


def load_coach(path: Path):
    path = Path(path).expanduser()
    if not path.is_file():
        raise SpeakerTestError(f"coach.py not found at {path}")
    spec = importlib.util.spec_from_file_location("coach", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("coach", module)
    spec.loader.exec_module(module)
    if module.AUDIO_RATE != RATE or abs(module.AUDIO_WINDOW - WINDOW) > 1e-9:
        raise SpeakerTestError("coach.py uses a different audio rate or window than this tool")
    return module


def ffmpeg_path() -> str:
    found = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not Path(found).exists():
        raise SpeakerTestError("ffmpeg not found")
    return found


def load_stereo(path: Path) -> tuple[np.ndarray, np.ndarray]:
    cmd = [ffmpeg_path(), "-v", "error", "-i", str(path), "-vn", "-ac", "2", "-ar", str(RATE), "-f", "s16le", "-"]
    run = subprocess.run(cmd, capture_output=True)
    if run.returncode != 0:
        raise SpeakerTestError(f"ffmpeg could not read {path}: {run.stderr.decode(errors='replace').strip()[-300:]}")
    frames = np.frombuffer(run.stdout, np.int16)
    frames = frames[: len(frames) // 2 * 2].reshape(-1, 2)
    return frames[:, 0].copy(), frames[:, 1].copy()


def to_db(rms: np.ndarray) -> np.ndarray:
    return 20 * np.log10(np.maximum(rms, 1.0) / 32768.0)


def window_db(pcm: np.ndarray) -> np.ndarray:
    n = int(RATE * WINDOW)
    count = len(pcm) // n
    windows = pcm[: count * n].astype(np.float64).reshape(count, n)
    return to_db(np.sqrt((windows ** 2).mean(axis=1)))


def window_centres(count: int) -> np.ndarray:
    return (np.arange(count) + 0.5) * WINDOW


def tap_quiet_mask(desktop_db: np.ndarray, quiet_db: float = TAP_QUIET_DB, lead: float = GATE_LEAD,
                   hangover: float = GATE_HANGOVER) -> np.ndarray:
    active = desktop_db > quiet_db
    lead_windows = int(round(lead / WINDOW))
    hangover_windows = int(round(hangover / WINDOW))
    counts = np.concatenate([[0], np.cumsum(active)])
    index = np.arange(len(active))
    lo = np.clip(index - hangover_windows, 0, len(active))
    hi = np.clip(index + lead_windows + 1, 0, len(active))
    return (counts[hi] - counts[lo]) == 0


def speech_mask(level_db: np.ndarray) -> np.ndarray:
    if level_db.size == 0:
        return np.zeros(0, bool)
    floor = float(np.percentile(level_db, FLOOR_PERCENTILE))
    return level_db > max(floor + SPEECH_ABOVE_FLOOR_DB, SPEECH_MIN_DB)


def own_speech_mask(desktop_db: np.ndarray, mic_db: np.ndarray) -> np.ndarray:
    count = min(len(desktop_db), len(mic_db))
    desktop_db, mic_db = desktop_db[:count], mic_db[:count]
    tap_active = desktop_db > TAP_QUIET_DB
    return speech_mask(mic_db) & (~tap_active | (mic_db > desktop_db + OVERLAP_MARGIN_DB))


def envelope_db(pcm: np.ndarray) -> np.ndarray:
    count = len(pcm) // ENVELOPE_HOP
    hops = pcm[: count * ENVELOPE_HOP].astype(np.float64).reshape(count, ENVELOPE_HOP)
    return to_db(np.sqrt((hops ** 2).mean(axis=1)))


def bleed_report(desktop: np.ndarray, mic: np.ndarray) -> dict:
    desktop_db = window_db(desktop)
    closed = ~tap_quiet_mask(desktop_db)
    hops_per_window = int(RATE * WINDOW) // ENVELOPE_HOP
    desktop_env = envelope_db(desktop)
    mic_env = envelope_db(mic)
    max_lag = int(round(MAX_BLEED_LAG * RATE / ENVELOPE_HOP))
    usable = min(len(desktop_env), len(mic_env)) - max_lag
    region = np.repeat(closed, hops_per_window)[: max(usable, 0)]
    picked = np.flatnonzero(region)
    report = {"lag": None, "attenuation_db": None, "correlation": None,
              "tap_closed_seconds": float(closed.sum() * WINDOW)}
    if picked.size * ENVELOPE_HOP / RATE < MIN_BLEED_SECONDS:
        return report
    reference = desktop_env[picked] - desktop_env[picked].mean()
    reference_norm = np.sqrt((reference ** 2).sum())
    best_lag, best_corr = 0, -np.inf
    for lag in range(max_lag + 1):
        candidate = mic_env[picked + lag]
        candidate = candidate - candidate.mean()
        norm = np.sqrt((candidate ** 2).sum()) * reference_norm
        corr = float((reference * candidate).sum() / norm) if norm > 0 else 0.0
        if corr > best_corr:
            best_lag, best_corr = lag, corr
    lag_samples = best_lag * ENVELOPE_HOP
    aligned_mic_db = window_db(mic[lag_samples:])
    count = min(len(desktop_db), len(aligned_mic_db))
    active = desktop_db[:count] > TAP_QUIET_DB
    if active.any():
        report["attenuation_db"] = float(np.median(desktop_db[:count][active] - aligned_mic_db[:count][active]))
    report["lag"] = lag_samples / RATE
    report["correlation"] = best_corr
    return report


def level_contour(pcm: np.ndarray) -> np.ndarray:
    if len(pcm) < LEVEL_FRAME:
        return np.zeros(0)
    squares = np.concatenate([[0.0], np.cumsum(pcm.astype(np.float64) ** 2)])
    starts = np.arange(0, len(pcm) - LEVEL_FRAME + 1, LEVEL_HOP)
    energy = (squares[starts + LEVEL_FRAME] - squares[starts]) / LEVEL_FRAME
    return to_db(np.sqrt(energy))


def level_contour_times(count: int) -> np.ndarray:
    return (np.arange(count) * LEVEL_HOP + LEVEL_FRAME / 2) / RATE


def voiced_frame_times(pcm: np.ndarray, coach) -> np.ndarray:
    track = coach.pitch_track(pcm)
    if track is None:
        return np.zeros(0)
    times, f0, _ = track
    return np.asarray(times)[f0 > 0]


def hysteresis_peaks(level_db: np.ndarray, hysteresis: float = NUCLEUS_HYSTERESIS_DB) -> list[int]:
    peaks = []
    rising = True
    best_index, best_value = 0, -np.inf
    low_value = np.inf
    for index, value in enumerate(level_db):
        if rising:
            if value > best_value:
                best_index, best_value = index, value
            elif value < best_value - hysteresis:
                peaks.append(best_index)
                rising = False
                low_value = value
        else:
            if value < low_value:
                low_value = value
            elif value > low_value + hysteresis:
                rising = True
                best_index, best_value = index, value
    return peaks


def syllable_nuclei(level_db: np.ndarray, voiced_times: np.ndarray) -> list[float]:
    if level_db.size == 0:
        return []
    floor = float(np.percentile(level_db, FLOOR_PERCENTILE))
    times = level_contour_times(len(level_db))
    voiced_times = np.sort(np.asarray(voiced_times, dtype=np.float64))
    nuclei = []
    for index in hysteresis_peaks(level_db):
        if level_db[index] <= floor + SPEECH_ABOVE_FLOOR_DB:
            continue
        t = times[index]
        lo = np.searchsorted(voiced_times, t - NUCLEUS_VOICED_TOLERANCE, side="left")
        hi = np.searchsorted(voiced_times, t + NUCLEUS_VOICED_TOLERANCE, side="right")
        if hi > lo:
            nuclei.append(float(t))
    return nuclei


def mask_at(mask: np.ndarray, t: float) -> bool:
    index = int(t / WINDOW)
    return 0 <= index < len(mask) and bool(mask[index])


def ending_is_quiet(t: float, mask: np.ndarray) -> bool:
    first = int(max(0.0, t - ENDING_SPAN_BEFORE) / WINDOW)
    last = int((t + ENDING_SPAN_AFTER) / WINDOW)
    if last >= len(mask):
        return False
    return bool(mask[first:last + 1].all())


def rate(count: int, seconds: float) -> float | None:
    return count / seconds if seconds > 0 else None


def contour_counts(ends: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for end in ends:
        counts[end["contour"]] = counts.get(end["contour"], 0) + 1
    return dict(sorted(counts.items()))


def analyze_pcm(desktop: np.ndarray, mic: np.ndarray, coach) -> dict:
    count = min(len(desktop), len(mic))
    desktop, mic = desktop[:count], mic[:count]
    desktop_db = window_db(desktop)
    mic_db = window_db(mic)
    quiet = tap_quiet_mask(desktop_db)
    speech = speech_mask(mic_db)
    own = own_speech_mask(desktop_db, mic_db)
    own_quiet = own & quiet
    track = coach.pitch_track(mic)
    voiced = np.asarray(track[0])[track[1] > 0] if track is not None else np.zeros(0)
    nuclei = syllable_nuclei(level_contour(mic), voiced)
    gated_nuclei = [t for t in nuclei if mask_at(quiet, t)]
    stats = coach.audio_stats(mic)
    phrase_ends = []
    if stats is not None and track is not None:
        times, _, st = track
        for phrase in coach.pause_phrases(stats.pauses):
            contour, rise, fall = coach.terminal_contour(times, st, phrase.last_word, phrase.end)
            phrase_ends.append({"t": round(float(phrase.end), 3), "contour": contour, "rise": round(float(rise), 2),
                                "fall": round(float(fall), 2), "gated": ending_is_quiet(phrase.end, quiet)})
    gated_ends = [e for e in phrase_ends if e["gated"]]
    own_seconds = float(own.sum() * WINDOW)
    return {
        "duration": count / RATE,
        "tap_quiet_share": float(quiet.mean()) if quiet.size else 0.0,
        "own_speech_seconds": own_seconds,
        "scorable_share": float(own_quiet.sum() / own.sum()) if own.any() else 0.0,
        "articulation_rate": {
            "all": rate(len(nuclei), float(speech.sum() * WINDOW)),
            "gated": rate(len(gated_nuclei), float((speech & quiet).sum() * WINDOW)),
        },
        "nuclei": {"all": len(nuclei), "gated": len(gated_nuclei)},
        "endings": {"all": contour_counts(phrase_ends), "gated": contour_counts(gated_ends)},
        "bleed": bleed_report(desktop, mic),
        "phrase_ends": phrase_ends,
        "verdict": "needs ear marks",
    }


def analyze(path: Path, coach) -> dict:
    desktop, mic = load_stereo(path)
    report = analyze_pcm(desktop, mic, coach)
    report["audio"] = str(path)
    return report


def write_csv(path: Path, phrase_ends: list[dict]) -> None:
    with Path(path).open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for end in phrase_ends:
            writer.writerow({"t": f"{end['t']:.3f}", "contour": end["contour"], "rise": f"{end['rise']:.2f}",
                             "fall": f"{end['fall']:.2f}", "gated": "1" if end["gated"] else "0", "ear": ""})


def report_sidecar(csv_path: Path) -> Path:
    csv_path = Path(csv_path)
    return csv_path.with_name(csv_path.stem + ".report.json")


def write_clips(directory: Path, mic: np.ndarray, phrase_ends: list[dict]) -> list[Path]:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for number, end in enumerate(phrase_ends, start=1):
        a = max(0, int(round((end["t"] - CLIP_BEFORE) * RATE)))
        b = min(len(mic), int(round((end["t"] + CLIP_AFTER) * RATE)))
        if b <= a:
            continue
        tag = "gated" if end["gated"] else "open"
        path = directory / f"{number:03d}_{end['t']:08.2f}s_{tag}.wav"
        with wave.open(str(path), "wb") as clip:
            clip.setnchannels(1)
            clip.setsampwidth(2)
            clip.setframerate(RATE)
            clip.writeframes(np.ascontiguousarray(mic[a:b], dtype=np.int16).tobytes())
        written.append(path)
    return written


def agreement(rows: list[dict]) -> dict:
    marked = [r for r in rows if (r.get("ear") or "").strip()]
    matches = sum(1 for r in marked if r["ear"].strip().lower() == (r.get("contour") or "").strip().lower())
    return {"marked": len(marked), "matches": matches, "agreement": matches / len(marked) if marked else None}


def score_csv(path: Path) -> dict:
    with Path(path).open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    gated = [r for r in rows if (r.get("gated") or "").strip() in ("1", "true", "True")]
    return {"all": agreement(rows), "gated": agreement(gated)}


def verdict(gated: dict, scorable_share: float | None) -> str:
    if gated["marked"] < USABLE_MIN_MARKED:
        return f"needs ear marks ({gated['marked']} of {USABLE_MIN_MARKED} gated endings marked)"
    if scorable_share is None:
        return "needs scorable share from analyze"
    usable = gated["agreement"] >= USABLE_AGREEMENT and scorable_share >= USABLE_SCORABLE_SHARE
    return "desk speakers usable" if usable else "headset tool"


def format_rate(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}/s"


def format_report(report: dict) -> str:
    bleed = report["bleed"]
    lines = [
        f"audio: {report.get('audio', '')}",
        f"duration: {report['duration']:.1f} s, tap quiet share: {report['tap_quiet_share']:.2f}",
        f"own speech: {report['own_speech_seconds']:.1f} s, scorable share: {report['scorable_share']:.2f}",
        f"articulation rate: all {format_rate(report['articulation_rate']['all'])}, "
        f"gated {format_rate(report['articulation_rate']['gated'])} "
        f"(nuclei {report['nuclei']['all']} / {report['nuclei']['gated']})",
        f"endings all: {report['endings']['all']}",
        f"endings gated: {report['endings']['gated']}",
    ]
    if bleed["lag"] is None:
        lines.append(f"bleed: not measured (tap closed {bleed['tap_closed_seconds']:.1f} s)")
    else:
        attenuation = "n/a" if bleed["attenuation_db"] is None else f"{bleed['attenuation_db']:.1f} dB"
        lines.append(f"bleed: lag {bleed['lag'] * 1000:.0f} ms, attenuation {attenuation}, "
                     f"correlation {bleed['correlation']:.2f}")
    lines.append(f"verdict: {report['verdict']}")
    return "\n".join(lines)


def format_score(result: dict, decided: str) -> str:
    lines = []
    for name in ("all", "gated"):
        part = result[name]
        value = "n/a" if part["agreement"] is None else f"{part['agreement']:.2f}"
        lines.append(f"{name}: {part['matches']} of {part['marked']} ear marks agree, agreement {value}")
    if "scorable_share" in result:
        lines.append(f"scorable share: {result['scorable_share']:.2f}")
    lines.append(f"verdict: {decided}")
    return "\n".join(lines)


def run_analyze(args) -> int:
    coach = load_coach(args.coach)
    desktop, mic = load_stereo(args.audio)
    report = analyze_pcm(desktop, mic, coach)
    report["audio"] = str(args.audio)
    if args.csv:
        write_csv(args.csv, report["phrase_ends"])
        summary = {k: v for k, v in report.items() if k != "phrase_ends"}
        report_sidecar(args.csv).write_text(json.dumps(summary, indent=2))
    if args.clips:
        report["clips_written"] = len(write_clips(args.clips, mic, report["phrase_ends"]))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(format_report(report))
        if args.csv:
            print(f"csv: {args.csv} ({len(report['phrase_ends'])} endings)")
        if args.clips:
            print(f"clips: {report['clips_written']} written to {args.clips}")
    return 0


def run_score(args) -> int:
    result = score_csv(args.labels)
    scorable_share = args.scorable_share
    sidecar = report_sidecar(args.labels)
    if scorable_share is None and sidecar.is_file():
        scorable_share = json.loads(sidecar.read_text()).get("scorable_share")
    if scorable_share is not None:
        result["scorable_share"] = scorable_share
    decided = verdict(result["gated"], scorable_share)
    result["verdict"] = decided
    print(json.dumps(result, indent=2) if args.json else format_score(result, decided))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="speaker_test")
    root.add_argument("--coach", type=Path, default=DEFAULT_COACH)
    commands = root.add_subparsers(dest="command", required=True)
    analyze_command = commands.add_parser("analyze")
    analyze_command.add_argument("audio", type=Path)
    analyze_command.add_argument("--csv", type=Path)
    analyze_command.add_argument("--clips", type=Path)
    analyze_command.add_argument("--json", action="store_true")
    analyze_command.set_defaults(run=run_analyze)
    score_command = commands.add_parser("score")
    score_command.add_argument("labels", type=Path)
    score_command.add_argument("--scorable-share", type=float)
    score_command.add_argument("--json", action="store_true")
    score_command.set_defaults(run=run_score)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.run(args)
    except SpeakerTestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
