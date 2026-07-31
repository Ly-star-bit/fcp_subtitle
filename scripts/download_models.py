"""Download the SenseVoice (ASR) and Silero VAD models used by fcp-subtitle.

Run once: uv run python scripts/download_models.py
"""

from __future__ import annotations

import io
import sys
import tarfile
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = PROJECT_ROOT / "models"

SENSE_VOICE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
)
SILERO_VAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
)


def _download(url: str) -> bytes:
    print(f"下载: {url}")
    with urllib.request.urlopen(url) as response:
        total = int(response.headers.get("Content-Length", 0))
        chunks = []
        read = 0
        while chunk := response.read(1 << 20):
            chunks.append(chunk)
            read += len(chunk)
            if total:
                print(f"\r  {read / 1e6:.1f}/{total / 1e6:.1f} MB", end="", flush=True)
        print()
        return b"".join(chunks)


def download_sense_voice() -> None:
    target_dir = MODELS_DIR / "sense-voice"
    model_file = target_dir / "model.int8.onnx"
    tokens_file = target_dir / "tokens.txt"
    if model_file.is_file() and tokens_file.is_file():
        print("SenseVoice 模型已存在,跳过")
        return

    target_dir.mkdir(parents=True, exist_ok=True)
    data = _download(SENSE_VOICE_URL)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:bz2") as tar:
        for member in tar.getmembers():
            name = Path(member.name).name
            if name in ("model.int8.onnx", "tokens.txt"):
                member.name = name
                tar.extract(member, path=target_dir)
    print(f"已保存到 {target_dir}")


def download_silero_vad() -> None:
    target = MODELS_DIR / "silero_vad.onnx"
    if target.is_file():
        print("Silero VAD 模型已存在,跳过")
        return

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    data = _download(SILERO_VAD_URL)
    target.write_bytes(data)
    print(f"已保存到 {target}")


def main() -> None:
    try:
        download_sense_voice()
        download_silero_vad()
    except Exception as exc:  # noqa: BLE001
        print(f"下载失败: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print("模型准备完成")


if __name__ == "__main__":
    main()
