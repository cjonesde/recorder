"""Public real-speech fixtures with language boundaries and reference transcripts."""
import json
from pathlib import Path
import urllib.request
import wave

ROOT = Path(__file__).resolve().parent / "fixtures"
ROOT.mkdir(exist_ok=True)
BASE = "https://huggingface.co/datasets/FluidInference/fleurs-full/resolve/main"
references = {}
for language in ("de_de", "en_us"):
    reference = ROOT / f"{language}.trans.txt"
    if not reference.exists():
        urllib.request.urlretrieve(f"{BASE}/{language}/{reference.name}", reference)
    references.update(line.split(" ", 1) for line in reference.read_text().splitlines())

order = ["de_de_0000", "en_us_0000", "de_de_0001", "en_us_0001"]
segments = []
offset = 0
with wave.open(str(ROOT / "bilingual.wav"), "wb") as output:
    output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    for sample in order:
        language = sample[:5]
        audio = ROOT / f"{sample}.wav"
        if not audio.exists():
            urllib.request.urlretrieve(f"{BASE}/{language}/{audio.name}", audio)
        with wave.open(str(audio), "rb") as source:
            assert source.getnchannels() == 1 and source.getsampwidth() == 2 and source.getframerate() == 16000
            frames = source.readframes(source.getnframes())
        count = len(frames) // 2
        segments.append(dict(id=sample, start=offset / 16000, end=(offset + count) / 16000,
                             language=language, reference=references[sample]))
        output.writeframes(frames)
        output.writeframes(bytes(16000 * 2))
        offset += count + 16000
(ROOT / "bilingual.json").write_text(json.dumps(segments, indent=2, ensure_ascii=False))
print(json.dumps(segments, indent=2, ensure_ascii=False))
