"""Segment-level speech recognition: Silero VAD for timestamps, SenseVoice for text.

Mirrors the pipeline used by sherpa-onnx's official generate-subtitles.py example:
feed audio to the VAD in fixed windows, pop finished speech segments (each with a
start sample and a samples array), batch-decode them with SenseVoice, and pair the
segment's sample count back into a duration.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import sherpa_onnx

from .audio import SAMPLE_RATE, stream_pcm_chunks


@dataclass
class Segment:
    start: float
    duration: float
    text: str = ""

    @property
    def end(self) -> float:
        return self.start + self.duration


@dataclass
class AsrModels:
    sense_voice_model: str
    tokens: str
    silero_vad_model: str
    num_threads: int = 4
    provider: str = "cpu"
    vad_threshold: float = 0.2
    vad_min_silence_duration: float = 0.25
    vad_min_speech_duration: float = 0.25
    vad_max_speech_duration: float = 5.0


_NOISE_TEXTS = {"", ".", "The."}


def build_recognizer(models: AsrModels) -> sherpa_onnx.OfflineRecognizer:
    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=models.sense_voice_model,
        tokens=models.tokens,
        num_threads=models.num_threads,
        provider=models.provider,
        use_itn=True,
    )


def build_vad(models: AsrModels) -> tuple[sherpa_onnx.VoiceActivityDetector, int]:
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = models.silero_vad_model
    config.silero_vad.threshold = models.vad_threshold
    config.silero_vad.min_silence_duration = models.vad_min_silence_duration
    config.silero_vad.min_speech_duration = models.vad_min_speech_duration
    config.silero_vad.max_speech_duration = models.vad_max_speech_duration
    config.sample_rate = SAMPLE_RATE
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=100)
    return vad, config.silero_vad.window_size


def transcribe(audio_path: str, models: AsrModels) -> list[Segment]:
    recognizer = build_recognizer(models)
    vad, window_size = build_vad(models)

    segments: list[Segment] = []
    buffer = np.empty(0, dtype=np.float32)

    def drain_vad() -> None:
        streams = []
        pending: list[Segment] = []
        while not vad.empty():
            seg = Segment(
                start=vad.front.start / SAMPLE_RATE,
                duration=len(vad.front.samples) / SAMPLE_RATE,
            )
            stream = recognizer.create_stream()
            stream.accept_waveform(SAMPLE_RATE, vad.front.samples)
            streams.append(stream)
            pending.append(seg)
            vad.pop()

        for stream in streams:
            recognizer.decode_stream(stream)

        for seg, stream in zip(pending, streams):
            seg.text = stream.result.text.strip()
            if seg.text in _NOISE_TEXTS:
                continue
            segments.append(seg)

    for chunk in stream_pcm_chunks(audio_path):
        samples = np.frombuffer(chunk, dtype=np.int16).astype(np.float32) / 32768.0
        buffer = np.concatenate([buffer, samples])
        while len(buffer) > window_size:
            vad.accept_waveform(buffer[:window_size])
            buffer = buffer[window_size:]
        drain_vad()

    vad.flush()
    drain_vad()

    return segments
