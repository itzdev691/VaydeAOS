#!/usr/bin/env python3
"""Generate the terminal login sequence with quiet, smoothly enveloped synth tones."""
import math
from pathlib import Path
import struct
import wave

SAMPLE_RATE = 44_100
DURATION = 3.45
PEAK = 0.22
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/VaydeAOS/Assets/startup-chime.wav"
samples = [0.0] * round(SAMPLE_RATE * DURATION)


def tone(onset, duration, frequency, gain, sweep=0):
    for index in range(round(duration * SAMPLE_RATE)):
        target = round(onset * SAMPLE_RATE) + index
        if target >= len(samples):
            break
        t = index / SAMPLE_RATE
        envelope = min(1, t / 0.008) * min(1, (duration - t) / 0.035)
        phase = math.tau * (frequency * t + sweep * t * t / (2 * duration))
        signal = math.sin(phase) + 0.18 * math.sin(phase * 2) + 0.07 * math.sin(phase * 3)
        samples[target] += gain * envelope * signal


# Connection handshake, followed by eight restrained terminal key tones.
tone(0, 0.12, 330, 0.10, 150)
tone(0.15, 0.10, 660, 0.08)
for key in range(8):
    tone(0.4 + key * 0.16, 0.055, [880, 1100, 990, 1320][key % 4], 0.065)
    tone(0.415 + key * 0.16, 0.025, 1760, 0.018)
# Soft rising carrier accompanies the workspace entrance.
tone(2.12, 0.85, 180, 0.045, 360)
# Login accepted, aligned with the transition flash.
tone(3.07, 0.18, 660, 0.09)
tone(3.16, 0.24, 990, 0.075)
scale = min(1, PEAK / max(abs(value) for value in samples))
pcm = [round(value * scale * 32767) for value in samples]
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(OUTPUT), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(SAMPLE_RATE)
    audio.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))
print(f"{OUTPUT}: {DURATION:.2f}s PCM16; peak {max(abs(v) for v in pcm) / 32767:.3f}")
