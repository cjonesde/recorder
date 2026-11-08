"""Score final text from the saved bilingual streaming runs; never reads user audio."""
import argparse
import json
import re
from pathlib import Path


def words(text):
    return re.findall(r"\w+", text.casefold())


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, nargs="+")
    parser.add_argument("--reference", type=Path,
                        default=Path(__file__).parent / "fixtures/bilingual.json")
    parser.add_argument("--speech-onset", type=float, default=4.30)
    args = parser.parse_args()
    reference = words(" ".join(s["reference"] for s in json.loads(args.reference.read_text())))
    for path in args.results:
        result = json.loads(path.read_text())
        errors = distance(reference, words(result["finalText"]))
        first = next((e["wallSeconds"] for e in result["events"]
                      if reference[0] in words(e["text"])), None)
        print(json.dumps({"file": path.name, "referenceWords": len(reference), "wordErrors": errors,
                          "wer": errors / len(reference),
                          "firstReferenceWordAfterOnsetSeconds": None if first is None else first - args.speech_onset,
                          "finishSeconds": result["finishSeconds"]}, ensure_ascii=False))
