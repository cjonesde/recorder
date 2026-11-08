"""Run models sequentially so concurrent inference cannot distort latency measurements."""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL = ROOT / "Tools/ASRBenchmark"
BINARY = TOOL / ".build/release/ASRBenchmark"
RESULTS = ROOT / "docs/benchmarks"
RESULTS.mkdir(parents=True, exist_ok=True)

cases = [
    ("whisper", "openai_whisper-base", "jfk.wav", "auto", 3, "base-en-auto"),
    ("parakeet", "ultra", "jfk.wav", "auto", 3, "ultra-en"),
    ("whisper", "openai_whisper-tiny", "jfk.wav", "auto", 3, "tiny-en-auto"),
    ("whisper", "openai_whisper-base", "german.aiff", "auto", 3, "base-de-auto"),
    ("whisper", "openai_whisper-tiny", "german.aiff", "auto", 3, "tiny-de-auto"),
    ("whisper", "openai_whisper-base", "jfk.wav", "en", 3, "base-en-fixed"),
    ("whisper", "openai_whisper-base", "german.aiff", "de", 3, "base-de-fixed"),
    ("whisper", "openai_whisper-base", "german.aiff", "auto", 0, "base-de-no-retry"),
    ("parakeet", "ultra", "german.aiff", "auto", 3, "ultra-de"),
    ("parakeet", "v3", "jfk.wav", "auto", 3, "v3-en"),
    ("parakeet", "v3", "german.aiff", "auto", 3, "v3-de"),
    ("parakeet", "redux", "jfk.wav", "auto", 3, "redux-en"),
    ("parakeet", "redux", "german.aiff", "auto", 3, "redux-de"),
    ("whisper", "openai_whisper-base", "long-en.wav", "en", 3, "base-long-workers16"),
    ("whisper", "openai_whisper-base", "long-en.wav", "en", 3, "base-long-workers2"),
    ("whisper", "openai_whisper-base", "noisy-en.wav", "auto", 3, "base-noisy-retry"),
    ("whisper", "openai_whisper-base", "noisy-en.wav", "auto", 0, "base-noisy-no-retry"),
]

failed = []
for backend, model, fixture, language, retries, name in cases:
    if model == "redux" and len(sys.argv) == 1:
        print(f"Skipping {name}: request it explicitly; first ANE compilation can take many minutes", flush=True)
        continue
    if len(sys.argv) > 1 and name not in sys.argv[1:]:
        continue
    output = RESULTS / f"{name}.json"
    if output.exists():
        print(f"Keeping {output.name}", flush=True)
        continue
    print(f"Running {name}", flush=True)
    workers = "16" if name.endswith("workers16") else "2" if name.endswith("workers2") else "1"
    with (RESULTS / f"{name}.log").open("w") as log:
        result = subprocess.run(
            [str(BINARY), backend, model, str(TOOL / "fixtures" / fixture),
             language, str(output), "5", str(retries), workers],
            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
            timeout=1200,
        )
    if result.returncode:
        print(f"Failed {name}; see {name}.log", flush=True)
        failed.append(name)
        continue
    result = json.loads(output.read_text())
    print(f"{name}: {result['warmMedianSeconds']:.3f}s, "
          f"{result['warmRealtimeMultiplier']:.1f}x realtime, "
          f"{result['peakRSSBytes'] / 2**20:.0f} MiB peak RSS", flush=True)

if failed:
    raise SystemExit(f"Failed benchmarks: {', '.join(failed)}")
