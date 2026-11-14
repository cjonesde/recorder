import csv

import numpy as np
import pytest

import speaker_test

RATE = 16000


def seconds(n):
    return int(round(n * RATE))


def harmonic_tone(duration, f0=150.0, harmonics=5):
    t = np.arange(seconds(duration)) / RATE
    wave = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, harmonics + 1))
    return wave / np.sqrt(np.mean(wave ** 2))


def at_dbfs(unit_rms_signal, dbfs):
    return unit_rms_signal * 32768.0 * 10 ** (dbfs / 20.0)


def place(total, start, signal):
    out = np.zeros(seconds(total))
    a = seconds(start)
    out[a:a + len(signal)] += signal[: len(out) - a]
    return out


def as_int16(signal):
    return np.clip(np.round(signal), -32768, 32767).astype(np.int16)


def delayed(signal, lag, attenuation_db):
    shift = seconds(lag)
    out = np.zeros_like(signal)
    out[shift:] = signal[:-shift] * 10 ** (-attenuation_db / 20.0)
    return out


def speech_like_bursts(total, start, stop, rng):
    out = np.zeros(seconds(total))
    t = start
    while t < stop:
        length = rng.uniform(0.08, 0.35)
        gap = rng.uniform(0.04, 0.2)
        n = min(seconds(length), seconds(stop) - seconds(t))
        if n <= 0:
            break
        noise = rng.standard_normal(n)
        ramp = np.hanning(n)
        level = rng.uniform(-26.0, -16.0)
        out[seconds(t):seconds(t) + n] += at_dbfs(noise * ramp / np.sqrt(np.mean((noise * ramp) ** 2)), level)
        t += length + gap
    return out


@pytest.fixture(scope="module")
def coach():
    return speaker_test.load_coach(speaker_test.DEFAULT_COACH)


def test_tap_quiet_mask_closes_with_lead_and_hangover():
    desktop = as_int16(place(6.0, 2.0, at_dbfs(harmonic_tone(1.0), -20.0)))
    mask = speaker_test.tap_quiet_mask(speaker_test.window_db(desktop))
    centres = speaker_test.window_centres(len(mask))
    closed = (centres >= 1.7) & (centres <= 3.5)
    assert closed.any()
    assert not mask[closed].any()
    assert mask[np.argmin(np.abs(centres - 1.0))]
    assert mask[np.argmin(np.abs(centres - 4.0))]


def test_bleed_lag_is_found():
    rng = np.random.default_rng(7)
    desktop_signal = speech_like_bursts(10.0, 1.0, 9.0, rng)
    mic_signal = delayed(desktop_signal, 0.04, 18.0) + rng.standard_normal(len(desktop_signal)) * 3.0
    report = speaker_test.bleed_report(as_int16(desktop_signal), as_int16(mic_signal))
    assert 0.03 <= report["lag"] <= 0.05
    assert 15.0 <= report["attenuation_db"] <= 21.0


def test_syllable_nuclei_counts_synthetic_train(coach):
    duration = 5.0
    t = np.arange(seconds(duration)) / RATE
    envelope = 0.5 * (1.0 - np.cos(2 * np.pi * 4.0 * t))
    mic = as_int16(at_dbfs(harmonic_tone(duration) * envelope, -18.0))
    voiced = speaker_test.voiced_frame_times(mic, coach)
    nuclei = speaker_test.syllable_nuclei(speaker_test.level_contour(mic), voiced)
    assert 18 <= len(nuclei) <= 22


def test_gated_phrase_ends_drop_bleed_only_phrases(coach):
    total = 11.0
    rng = np.random.default_rng(3)
    desktop_signal = np.zeros(seconds(total))
    for start in (3.0, 7.0):
        desktop_signal += place(total, start, at_dbfs(harmonic_tone(1.0, f0=210.0), -20.0))
    own = np.zeros(seconds(total))
    for start in (1.0, 5.0, 9.0):
        own += place(total, start, at_dbfs(harmonic_tone(1.0, f0=120.0), -20.0))
    mic_signal = own + delayed(desktop_signal, 0.04, 18.0) + rng.standard_normal(seconds(total)) * 2.0
    report = speaker_test.analyze_pcm(as_int16(desktop_signal), as_int16(mic_signal), coach)
    every_end = [e["t"] for e in report["phrase_ends"]]
    gated_ends = [e["t"] for e in report["phrase_ends"] if e["gated"]]
    bleed_ends = [t for t in every_end if 3.0 <= t <= 4.2 or 7.0 <= t <= 8.2]
    own_ends = [t for t in every_end if 1.8 <= t <= 2.2 or 5.8 <= t <= 6.2]
    assert len(bleed_ends) == 2
    assert len(own_ends) == 2
    assert not any(t in gated_ends for t in bleed_ends)
    assert all(t in gated_ends for t in own_ends)


def test_score_reports_agreement(tmp_path):
    path = tmp_path / "labels.csv"
    rows = [
        {"t": "1.0", "contour": "rise", "rise": "4.0", "fall": "0.0", "gated": "1", "ear": "rise"},
        {"t": "2.0", "contour": "fall", "rise": "0.0", "fall": "3.0", "gated": "1", "ear": "fall"},
        {"t": "3.0", "contour": "level", "rise": "1.0", "fall": "1.0", "gated": "0", "ear": "level"},
        {"t": "4.0", "contour": "fall", "rise": "0.0", "fall": "2.0", "gated": "0", "ear": "rise"},
        {"t": "5.0", "contour": "rise", "rise": "3.5", "fall": "0.0", "gated": "1", "ear": ""},
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    result = speaker_test.score_csv(path)
    assert result["all"]["marked"] == 4
    assert result["all"]["agreement"] == pytest.approx(0.75)
    assert result["gated"]["marked"] == 2
    assert result["gated"]["agreement"] == pytest.approx(1.0)
