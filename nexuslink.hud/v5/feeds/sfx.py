#!/usr/bin/env python3
"""F5 startup cue: one calm, generated 1.75 s wav for the HUD boot sequence.

Design (MAIN-SCREEN-BUILD.md Phase 2 item 10: "soft sfx, generated locally,
subtle, one file"):

  * three sine partials (fundamental + 2nd + 3rd, exact 1:2:3) with a gentle
    downward pitch settle (220 Hz -> 196 Hz) and a very slow 0.35 Hz tremolo at
    8 percent depth, so the file breathes instead of sitting on one static sine;
  * 180 ms raised-cosine attack (starts at exactly zero, no click);
  * exponential body decay plus a 350 ms raised-cosine release, so the tail is
    long and quiet and ends at zero;
  * loudness normalised to -16.0 LUFS integrated (ITU-R BS.1770 K-weighting +
    gating, implemented here in numpy) under a -1.5 dBTP true-peak ceiling
    (4x band-limited oversampling). Both numbers are measured, not assumed.

Everything is deterministic: partial phases come from `random.Random(SEED)`
(stdlib, stream-stable across Python versions), so `--regenerate` reproduces
the committed `startup.wav` byte for byte.

numpy is the one third-party import, explicitly allowed for F5 by
`cards/feeds-brief.md`. Nothing here touches the network or the live host.

Usage:
  python3 sfx.py                 # rebuild startup.wav + print a summary
  python3 sfx.py --regenerate    # same, said out loud
  python3 sfx.py --json          # rebuild + one JSON object on stdout
  python3 sfx.py --self-check    # assert every property, non-zero exit on fail
  python3 sfx.py --out /tmp/x.wav

Exit codes: 0 success, 1 self-check failure, 2 programming error (bad
arguments, numpy missing).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import sys
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path

try:
    import numpy as np
except ImportError:  # pragma: no cover - numpy is a stated prerequisite for F5
    sys.stderr.write(
        "error: numpy is required for F5 (python3 -m pip install numpy). "
        "This card states numpy 2.0.2 is installed on this Mac.\n"
    )
    raise SystemExit(2)

# --------------------------------------------------------------------------
# Contract constants (every one of these is asserted by --self-check)
# --------------------------------------------------------------------------

SAMPLE_RATE = 48000
DURATION_S = 1.75
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2
SEED = 20261023

TARGET_LUFS = -16.0
TRUE_PEAK_CEILING_DBTP = -1.5
LUFS_TOLERANCE_LU = 0.5

DC_LIMIT_FRAC = 0.005  # 0.5 percent of full scale
CLICK_WINDOW_S = 0.005  # first 5 ms
CLICK_BOUND_FS = 0.010  # max |sample-to-sample step| there, 1.0 percent FS
STEP_BOUND_FS = 0.030  # max |step| anywhere in the file, 3.0 percent FS
HF_LIMIT_HZ = 4000.0
HF_LIMIT_FRAC = 0.001  # energy above 4 kHz under 0.1 percent: band-limited
MAX_FILE_BYTES = 300 * 1024

# Envelope
ATTACK_S = 0.180
DECAY_TAU_S = 0.55
RELEASE_S = 0.350

# Pitch settle: f(t) = f_end + (f_start - f_end) * exp(-t / TAU)
SETTLE_TAU_S = 0.45

# (label, f_start_hz, f_end_hz, level_db_below_fundamental, detune_cents)
PARTIALS = (
    ("fundamental", 220.0, 196.0, 0.0, 0.0),
    ("second", 440.0, 392.0, -9.0, 5.0),
    ("third", 660.0, 588.0, -20.0, -4.0),
)

# Slow breathing on top of the decay: calm, never fully still.
TREMOLO_HZ = 0.35
TREMOLO_DEPTH = 0.08

DEFAULT_WAV = Path(__file__).resolve().parent / "startup.wav"

# K-weighting, BS.1770 coefficients for 48 kHz (stage 1 shelf, stage 2 RLB HPF)
KW_SHELF_B = (1.53512485958697, -2.69169618940638, 1.19839281085285)
KW_SHELF_A = (1.0, -1.69065929318241, 0.73248077421585)
KW_HPF_B = (1.0, -2.0, 1.0)
KW_HPF_A = (1.0, -1.99004745483398, 0.99007225036621)


# --------------------------------------------------------------------------
# Synthesis
# --------------------------------------------------------------------------


def render() -> "np.ndarray":
    """Render the cue as float64 mono in roughly [-0.5, 0.5], deterministically."""
    rng = random.Random(SEED)
    n = int(round(SAMPLE_RATE * DURATION_S))
    t = np.arange(n, dtype=np.float64) / SAMPLE_RATE

    # Attack: raised cosine, exactly zero at t = 0.
    attack = np.where(
        t < ATTACK_S,
        0.5 * (1.0 - np.cos(np.pi * np.minimum(t, ATTACK_S) / ATTACK_S)),
        1.0,
    )
    # Body: exponential decay, long quiet tail.
    body = np.exp(-np.maximum(t - ATTACK_S, 0.0) / DECAY_TAU_S)
    # Release: raised cosine over the last RELEASE_S, landing on zero.
    release_start = DURATION_S - RELEASE_S
    ramp = np.clip((t - release_start) / RELEASE_S, 0.0, 1.0)
    release = 0.5 * (1.0 + np.cos(np.pi * ramp))

    tremolo = 1.0 - TREMOLO_DEPTH * 0.5 * (1.0 - np.cos(2.0 * math.pi * TREMOLO_HZ * t))
    envelope = attack * body * release * tremolo

    signal = np.zeros(n, dtype=np.float64)
    # Seeded phases only; every musical choice below is a fixed constant.
    for label, f_start, f_end, level_db, detune_cents in PARTIALS:
        ratio = 2.0 ** (detune_cents / 1200.0)
        start = f_start * ratio
        end = f_end * ratio
        # Integral of an exponentially settling frequency, in cycles.
        cycles = end * t + (start - end) * SETTLE_TAU_S * (1.0 - np.exp(-t / SETTLE_TAU_S))
        phase = 2.0 * math.pi * cycles + rng.uniform(0.0, 2.0 * math.pi)
        signal += 10.0 ** (level_db / 20.0) * np.sin(phase)

    signal *= envelope
    # One soft one-pole low-pass at 3 kHz: keeps the cue dull and calm and
    # guarantees nothing above the audible "chime" region survives.
    signal = _one_pole_lowpass(signal, cutoff_hz=3000.0)
    peak = float(np.max(np.abs(signal))) or 1.0
    return signal / peak * 0.35


def _one_pole_lowpass(x: "np.ndarray", cutoff_hz: float) -> "np.ndarray":
    alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff_hz / SAMPLE_RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc += alpha * (x[i] - acc)
        y[i] = acc
    return y


# --------------------------------------------------------------------------
# Measurement
# --------------------------------------------------------------------------


def _biquad(x: "np.ndarray", b, a) -> "np.ndarray":
    b0, b1, b2 = b
    a1, a2 = a[1], a[2]
    y = np.empty_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(x.size):
        xi = float(x[i])
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, xi
        y2, y1 = y1, yi
        y[i] = yi
    return y


def integrated_loudness(x: "np.ndarray") -> float:
    """ITU-R BS.1770-4 integrated loudness in LUFS for one channel."""
    y = _biquad(x, KW_SHELF_B, KW_SHELF_A)
    y = _biquad(y, KW_HPF_B, KW_HPF_A)
    block = int(round(0.400 * SAMPLE_RATE))
    step = int(round(0.100 * SAMPLE_RATE))
    if y.size < block:
        return float("-inf")
    powers = []
    for start in range(0, y.size - block + 1, step):
        seg = y[start : start + block]
        powers.append(float(np.mean(seg * seg)))
    loudness = [
        (-0.691 + 10.0 * math.log10(p)) if p > 0.0 else float("-inf") for p in powers
    ]
    gated = [p for p, l in zip(powers, loudness) if l > -70.0]
    if not gated:
        return float("-inf")
    relative = -0.691 + 10.0 * math.log10(float(np.mean(gated))) - 10.0
    gated = [p for p, l in zip(powers, loudness) if l > -70.0 and l > relative]
    if not gated:
        return float("-inf")
    return -0.691 + 10.0 * math.log10(float(np.mean(gated)))


def true_peak(x: "np.ndarray", oversample: int = 4) -> float:
    """Peak of the 4x band-limited oversampled signal (dBTP source)."""
    n = x.size
    spectrum = np.fft.rfft(x)
    padded = np.zeros(oversample * n // 2 + 1, dtype=complex)
    padded[: spectrum.size] = spectrum
    if n % 2 == 0:
        padded[n // 2] *= 0.5  # split the Nyquist bin between +f and -f
    up = np.fft.irfft(padded, n=oversample * n) * oversample
    return float(np.max(np.abs(up)))


def _db(value: float) -> float:
    return 20.0 * math.log10(max(abs(value), 1e-12))


def normalise(signal: "np.ndarray"):
    """Gain to TARGET_LUFS, never past the true-peak ceiling. Returns (x, gain, limited)."""
    gain = 1.0
    limited = False
    for _ in range(12):
        candidate = signal * gain
        lufs = integrated_loudness(candidate)
        tp_db = _db(true_peak(candidate))
        if not math.isfinite(lufs):
            break
        to_target = gain * 10.0 ** ((TARGET_LUFS - lufs) / 20.0)
        to_ceiling = gain * 10.0 ** ((TRUE_PEAK_CEILING_DBTP - tp_db) / 20.0)
        wanted = min(to_target, to_ceiling)
        limited = to_ceiling < to_target * (1.0 - 1e-9)
        if abs(wanted - gain) / gain < 1e-4:
            gain = wanted
            break
        gain = wanted
    return signal * gain, gain, limited


def to_pcm16(x: "np.ndarray") -> "np.ndarray":
    scaled = np.clip(x, -1.0, 1.0) * 32767.0
    return np.round(scaled).astype(np.int16)


# --------------------------------------------------------------------------
# File I/O
# --------------------------------------------------------------------------


def write_wav(path: Path, pcm: "np.ndarray") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".sfx-", suffix=".wav")
    os.close(fd)
    try:
        with wave.open(tmp, "wb") as handle:
            handle.setnchannels(CHANNELS)
            handle.setsampwidth(SAMPLE_WIDTH_BYTES)
            handle.setframerate(SAMPLE_RATE)
            handle.writeframes(pcm.tobytes())
        # mkstemp creates 0600; the cue is a shared asset, so give it the same
        # mode a normal checkout would have.
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)  # atomic, per cards/feeds-brief.md
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_wav(path: Path):
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        frames = handle.getnframes()
        raw = handle.readframes(frames)
    pcm = np.frombuffer(raw, dtype="<i2")
    if channels > 1:
        pcm = pcm.reshape(-1, channels)[:, 0]
    return {
        "channels": channels,
        "width": width,
        "rate": rate,
        "frames": frames,
        "pcm": pcm,
        "samples": pcm.astype(np.float64) / 32768.0,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def measure(path: Path) -> dict:
    data = read_wav(path)
    samples = data["samples"]
    dc = float(np.mean(samples)) if samples.size else 0.0
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
    return {
        "path": str(path),
        "duration_s": data["frames"] / float(data["rate"]) if data["rate"] else 0.0,
        "sample_rate": data["rate"],
        "channels": data["channels"],
        "sample_width_bits": data["width"] * 8,
        "frames": data["frames"],
        "peak_dbfs": _db(peak),
        "true_peak_dbtp": _db(true_peak(samples)),
        "rms_dbfs": _db(rms),
        "lufs_integrated": integrated_loudness(samples),
        "dc_offset_frac": dc,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
        "_samples": samples,
    }


def build(path: Path) -> dict:
    signal = render()
    normalised, gain, limited = normalise(signal)
    pcm = to_pcm16(normalised)
    write_wav(path, pcm)
    info = measure(path)
    info["gain"] = gain
    info["ceiling_limited"] = limited
    info.pop("_samples", None)
    return info


# --------------------------------------------------------------------------
# Spectrum / click helpers used by the self-check
# --------------------------------------------------------------------------


def spectrum_peaks(samples: "np.ndarray", count: int = 5):
    window = np.hanning(samples.size)
    magnitude = np.abs(np.fft.rfft(samples * window))
    freqs = np.fft.rfftfreq(samples.size, 1.0 / SAMPLE_RATE)
    # Local maxima only, so we do not report three bins of the same lobe.
    order = np.argsort(magnitude)[::-1]
    picked = []
    for index in order:
        f = float(freqs[index])
        if all(abs(f - other[0]) > 20.0 for other in picked):
            picked.append((f, float(magnitude[index])))
        if len(picked) >= count:
            break
    return picked


def matched_peak(peaks, f_start: float, f_end: float, tolerance: float = 8.0):
    """First spectral peak inside the band a settling partial sweeps through."""
    low = f_end - tolerance
    high = f_start + tolerance
    for freq, magnitude in peaks:
        if low <= freq <= high:
            return freq, magnitude
    return None, 0.0


def hf_energy_fraction(samples: "np.ndarray") -> float:
    magnitude = np.abs(np.fft.rfft(samples)) ** 2
    freqs = np.fft.rfftfreq(samples.size, 1.0 / SAMPLE_RATE)
    total = float(np.sum(magnitude))
    if total <= 0.0:
        return 0.0
    return float(np.sum(magnitude[freqs > HF_LIMIT_HZ])) / total


# --------------------------------------------------------------------------
# Self-check
# --------------------------------------------------------------------------


class Checker:
    def __init__(self) -> None:
        self.failures = 0

    def check(self, name: str, ok: bool, detail: str) -> None:
        if ok:
            print("PASS {}: {}".format(name, detail))
        else:
            self.failures += 1
            print("FAIL {}: {}".format(name, detail))

    def done(self) -> int:
        if self.failures:
            print("SELF-CHECK FAILED: {} assertion(s) failed".format(self.failures))
            return 1
        print("SELF-CHECK PASSED: all assertions hold")
        return 0


def self_check() -> int:
    check = Checker()
    committed = DEFAULT_WAV
    if not committed.exists():
        print("FAIL fixture: committed wav missing: {}".format(committed))
        print("SELF-CHECK FAILED: 1 assertion(s) failed")
        return 1

    # Render into a scratch directory: --self-check must never rewrite the
    # committed artifact (cards/feeds-brief.md: nothing changes state in a test).
    with tempfile.TemporaryDirectory(prefix="sfx-selfcheck-") as scratch:
        built_path = Path(scratch) / "startup.wav"
        print(
            "self-check: rendering a fresh cue from seed {} into {}".format(
                SEED, built_path
            )
        )
        info = build(built_path)
        data = read_wav(built_path)
        samples = data["samples"]

        # 1 - container
        check.check(
            "container",
            data["channels"] == CHANNELS
            and data["rate"] == SAMPLE_RATE
            and data["width"] * 8 == 16,
            "channels={} rate={} bits={}".format(
                data["channels"], data["rate"], data["width"] * 8
            ),
        )

        # 2 - exact duration
        measured_duration = data["frames"] / float(data["rate"])
        check.check(
            "duration",
            1.5 <= measured_duration <= 2.0,
            "{:.6f} s (frames={}, bound 1.5..2.0)".format(
                measured_duration, data["frames"]
            ),
        )

        # 3 - size
        check.check(
            "size",
            info["bytes"] < MAX_FILE_BYTES,
            "{} bytes < {} bytes".format(info["bytes"], MAX_FILE_BYTES),
        )

        # 4 - true peak under the stated ceiling
        check.check(
            "true-peak",
            info["true_peak_dbtp"] <= TRUE_PEAK_CEILING_DBTP + 0.05,
            "{:.3f} dBTP <= {:.1f} dBTP ceiling (sample peak {:.3f} dBFS)".format(
                info["true_peak_dbtp"], TRUE_PEAK_CEILING_DBTP, info["peak_dbfs"]
            ),
        )

        # 5 - loudness
        lufs = info["lufs_integrated"]
        check.check(
            "loudness",
            math.isfinite(lufs) and abs(lufs - TARGET_LUFS) <= LUFS_TOLERANCE_LU,
            "{:.3f} LUFS, target {:.1f} +/- {:.1f} LU (rms {:.3f} dBFS)".format(
                lufs, TARGET_LUFS, LUFS_TOLERANCE_LU, info["rms_dbfs"]
            ),
        )

        # 6 - DC offset
        check.check(
            "dc-offset",
            abs(info["dc_offset_frac"]) <= DC_LIMIT_FRAC,
            "{:.6f} of full scale <= {:.4f} (0.5 percent)".format(
                info["dc_offset_frac"], DC_LIMIT_FRAC
            ),
        )

        # 7 - click at the start, and no step anywhere
        first = samples[:1]
        window = max(2, int(round(CLICK_WINDOW_S * SAMPLE_RATE)))
        steps = np.abs(np.diff(samples[:window]))
        max_step_start = float(np.max(steps)) if steps.size else 0.0
        all_steps = np.abs(np.diff(samples))
        max_step_all = float(np.max(all_steps)) if all_steps.size else 0.0
        check.check(
            "start-silence",
            abs(float(first[0])) <= CLICK_BOUND_FS,
            "first sample {:.6f} of full scale".format(float(first[0])),
        )
        check.check(
            "no-click",
            max_step_start <= CLICK_BOUND_FS,
            "max first-difference in first {:.0f} ms = {:.6f} FS (bound {:.4f}); "
            "first 10 samples = {}".format(
                CLICK_WINDOW_S * 1000.0,
                max_step_start,
                CLICK_BOUND_FS,
                ", ".join("{:.6f}".format(v) for v in samples[:10]),
            ),
        )
        check.check(
            "no-discontinuity",
            max_step_all <= STEP_BOUND_FS,
            "max first-difference anywhere = {:.6f} FS (bound {:.4f})".format(
                max_step_all, STEP_BOUND_FS
            ),
        )

        # 8 - band limited, nothing above the calm region
        hf = hf_energy_fraction(samples)
        check.check(
            "band-limit",
            hf <= HF_LIMIT_FRAC,
            "energy above {:.0f} Hz = {:.6f} of total (bound {:.4f})".format(
                HF_LIMIT_HZ, hf, HF_LIMIT_FRAC
            ),
        )

        # 9 - real partials, not silence and not one sine
        peaks = spectrum_peaks(samples, count=5)
        top = [f for f, _ in peaks]
        matched = []
        for _label, f_start, f_end, _level, _detune in PARTIALS:
            freq, magnitude = matched_peak(peaks, f_start, f_end)
            matched.append((f_start, f_end, freq, magnitude))
        check.check(
            "partials",
            all(entry[2] is not None for entry in matched),
            "top peaks {} Hz; each designed partial found inside its settle band: {}".format(
                ["{:.1f}".format(f) for f in top],
                ", ".join(
                    "{:.0f}-{:.0f} Hz -> {}".format(
                        entry[0],
                        entry[1],
                        "none" if entry[2] is None else "{:.1f} Hz".format(entry[2]),
                    )
                    for entry in matched
                ),
            ),
        )
        fundamental_mag = matched[0][3]
        second_mag = matched[1][3]
        relative = (
            _db(second_mag) - _db(fundamental_mag) if fundamental_mag > 0 else -99.0
        )
        check.check(
            "partial-balance",
            -14.0 <= relative <= -5.0,
            "second partial {:.2f} dB relative to the fundamental "
            "(designed -9.0 dB)".format(relative),
        )

        # 10 - determinism: two fresh renders are byte-identical
        twin_path = Path(scratch) / "startup-twin.wav"
        build(twin_path)
        hash_first = sha256_file(built_path)
        hash_second = sha256_file(twin_path)
        check.check(
            "determinism",
            hash_first == hash_second,
            "render A {} / render B {}".format(hash_first[:16], hash_second[:16]),
        )

        # 11 - and they match the committed artifact byte for byte
        committed_hash = sha256_file(committed)
        check.check(
            "committed-matches",
            hash_first == committed_hash,
            "fresh {} vs committed {} ({})".format(
                hash_first[:16], committed_hash[:16], committed
            ),
        )

        print(
            "measured: {} s, {:.3f} dBTP true peak, {:.3f} dBFS peak, "
            "{:.3f} dBFS RMS, {:.3f} LUFS, {} bytes".format(
                measured_duration,
                info["true_peak_dbtp"],
                info["peak_dbfs"],
                info["rms_dbfs"],
                info["lufs_integrated"],
                info["bytes"],
            )
        )
    return check.done()


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def summary(info: dict) -> dict:
    return {
        "ok": True,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "generated",
        "path": info["path"],
        "duration_s": round(info["duration_s"], 6),
        "sample_rate": info["sample_rate"],
        "channels": info["channels"],
        "sample_width_bits": info["sample_width_bits"],
        "peak_dbfs": round(info["peak_dbfs"], 3),
        "true_peak_dbtp": round(info["true_peak_dbtp"], 3),
        "rms_dbfs": round(info["rms_dbfs"], 3),
        "lufs_integrated": round(info["lufs_integrated"], 3),
        "target_lufs": TARGET_LUFS,
        "true_peak_ceiling_dbtp": TRUE_PEAK_CEILING_DBTP,
        "ceiling_limited": info["ceiling_limited"],
        "gain": round(info["gain"], 6),
        "dc_offset_frac": round(info["dc_offset_frac"], 8),
        "bytes": info["bytes"],
        "sha256": info["sha256"],
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate the HUD startup cue (calm, 1.75 s, 48 kHz mono 16-bit)."
    )
    parser.add_argument("--regenerate", action="store_true", help="rebuild the wav")
    parser.add_argument("--json", action="store_true", help="one JSON object on stdout")
    parser.add_argument("--self-check", action="store_true", help="assert every property")
    parser.add_argument(
        "--out", default=str(DEFAULT_WAV), help="output path (default: next to this script)"
    )
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check()

    info = build(Path(args.out).expanduser())
    if args.json:
        print(json.dumps(summary(info), sort_keys=True))
    else:
        print("startup cue written: {}".format(info["path"]))
        print(
            "duration {:.6f} s | {:.0f} Hz mono {}-bit | peak {:.3f} dBFS | "
            "true peak {:.3f} dBTP | RMS {:.3f} dBFS | {:.3f} LUFS".format(
                info["duration_s"],
                info["sample_rate"],
                info["sample_width_bits"],
                info["peak_dbfs"],
                info["true_peak_dbtp"],
                info["rms_dbfs"],
                info["lufs_integrated"],
            )
        )
        print(
            "{} bytes | sha256 {} | ceiling-limited {}".format(
                info["bytes"], info["sha256"], info["ceiling_limited"]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
