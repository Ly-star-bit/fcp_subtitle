"""Decode arbitrary audio/video files into a stream of 16kHz mono PCM chunks via ffmpeg."""

from __future__ import annotations

import shutil
import subprocess
from collections.abc import Iterator

SAMPLE_RATE = 16000
_CHUNK_SECONDS = 100


def check_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise RuntimeError(
            "未找到 ffmpeg,请先运行: brew install ffmpeg"
        )


def stream_pcm_chunks(audio_path: str, sample_rate: int = SAMPLE_RATE) -> Iterator[bytes]:
    """Yield raw s16le mono PCM byte chunks decoded from audio_path via ffmpeg."""
    check_ffmpeg()
    cmd = [
        "ffmpeg",
        "-i", audio_path,
        "-f", "s16le",
        "-acodec", "pcm_s16le",
        "-ac", "1",
        "-ar", str(sample_rate),
        "-loglevel", "error",
        "-",
    ]
    frames_per_read = sample_rate * _CHUNK_SECONDS
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert process.stdout is not None
    try:
        while True:
            data = process.stdout.read(frames_per_read * 2)  # 2 bytes per int16 sample
            if not data:
                break
            yield data
    finally:
        process.stdout.close()
        return_code = process.wait()
        if return_code != 0:
            stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
            raise RuntimeError(f"ffmpeg 解码失败 ({audio_path}): {stderr.strip()}")
