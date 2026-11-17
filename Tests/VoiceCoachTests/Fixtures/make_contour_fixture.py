import importlib.util
import json
import math
import sys
from pathlib import Path

import numpy as np

COACH = Path.home() / "projects/cjonesde/cj-plugins/plugins/cj-video/skills/talking-head-coaching/scripts/coach.py"


def load_coach(path):
    spec = importlib.util.spec_from_file_location("coach", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["coach"] = module
    spec.loader.exec_module(module)
    return module


def glide(times, base, start, semitones):
    span = times[-1] - start
    progress = np.clip((times - start) / span, 0, 1) if span > 0 else np.zeros_like(times)
    return base * np.power(2.0, semitones * progress / 12.0)


def cases():
    times = np.round(np.arange(0, 1.2, 0.01), 2)
    flat = np.full(times.shape, 120.0)
    out = []
    out.append(("clear rise", times, glide(times, 120.0, 0.9, 4.0), 0.6, 1.0))
    out.append(("clear fall", times, glide(times, 140.0, 0.85, -3.0), 0.6, 1.0))
    out.append(("level", times, flat + 0.5 * np.sin(times * 20), 0.6, 1.0))
    body_rise = glide(times, 120.0, 0.6, 4.0)
    body_rise[times > 0.85] = body_rise[times <= 0.85][-1] * np.power(2.0, -3.0 * (times[times > 0.85] - 0.85) / 0.35 / 12.0)
    out.append(("rise then fall", times, body_rise, 0.6, 1.0))
    sparse = flat.copy()
    sparse[times > 0.3] = 0.0
    sparse[[60, 70, 80]] = 120.0
    out.append(("too few voiced", times, sparse, 0.6, 1.0))
    spike = glide(times, 120.0, 0.9, 4.0)
    spike[85] = spike[85] * 2.0
    out.append(("octave spike", times, spike, 0.6, 1.0))
    early = glide(times, 120.0, 0.5, 4.0)
    early[times > 0.75] = early[times <= 0.75][-1]
    out.append(("rise in body level end", times, early, 0.6, 1.0))
    gaps = glide(times, 120.0, 0.9, 4.5)
    gaps[::4] = 0.0
    out.append(("unvoiced gaps", times, gaps, 0.6, 1.0))
    return out


def clean(values):
    return [None if (isinstance(v, float) and math.isnan(v)) else float(v) for v in values]


def main():
    coach = load_coach(Path(sys.argv[1]) if len(sys.argv) > 1 else COACH)
    fixture = []
    for name, times, f0, start, end in cases():
        st = coach.clean_f0(f0.astype(np.float64))
        contour, rise, fall = coach.terminal_contour(times, st, start, end)
        fixture.append({
            "name": name,
            "times": [float(t) for t in times],
            "f0": [float(v) for v in f0],
            "start": start,
            "end": end,
            "st": clean(st),
            "contour": contour,
            "rise": float(rise),
            "fall": float(fall),
        })
    target = Path(__file__).resolve().parent / "contour-fixture.json"
    target.write_text(json.dumps(fixture, indent=1))
    for case in fixture:
        print(f"{case['name']}: {case['contour']} rise {case['rise']:.3f} fall {case['fall']:.3f}")


if __name__ == "__main__":
    main()
