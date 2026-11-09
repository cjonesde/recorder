"""Create public/synthetic fixtures without accessing the user's recordings."""
import math
from pathlib import Path
import random
import struct
import subprocess
import urllib.request
import wave

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FIXTURES.mkdir(exist_ok=True)
urllib.request.urlretrieve(
    "https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/samples/jfk.wav",
    FIXTURES / "jfk.wav",
)
subprocess.run([
    "say", "-v", "Anna", "-r", "165", "-o", str(FIXTURES / "german.aiff"),
    "Guten Morgen. Wir besprechen heute die Planung für das nächste Projekt. "
    "Die neue Anwendung soll Sprache schnell und zuverlässig in Text umwandeln. "
    "Alle Aufnahmen bleiben auf diesem Computer. Am Freitag prüfen wir gemeinsam "
    "die Ergebnisse und entscheiden über die nächsten Schritte.",
], check=True)
with wave.open(str(FIXTURES / "jfk.wav"), "rb") as source:
    params = source.getparams()
    frames = source.readframes(source.getnframes())
with wave.open(str(FIXTURES / "long-en.wav"), "wb") as output:
    output.setparams(params)
    output.writeframes(frames * 12)
assert params.sampwidth == 2
samples = struct.unpack("<" + "h" * (len(frames) // 2), frames)
rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
random_source = random.Random(42)
noisy = [max(-32768, min(32767, round(sample + random_source.gauss(0, rms * 2))))
         for sample in samples]
with wave.open(str(FIXTURES / "noisy-en.wav"), "wb") as output:
    output.setparams(params)
    output.writeframes(struct.pack("<" + "h" * len(noisy), *noisy))
