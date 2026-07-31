from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from .asr import AsrModels, transcribe
from .fcpxml import FRAME_DURATIONS, build_fcpxml
from .paths import SENSE_VOICE_MODEL, SENSE_VOICE_TOKENS, SILERO_VAD_MODEL


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="fcp-subtitle",
        description="用 SenseVoice 把音频/视频转成 Final Cut Pro 可编辑的 FCPXML 字幕",
    )
    parser.add_argument("audio", help="输入的音频或视频文件路径")
    parser.add_argument(
        "-o", "--output", help="输出 .fcpxml 路径,默认与输入同目录同名"
    )
    parser.add_argument(
        "--fps", default="25", choices=sorted(FRAME_DURATIONS), help="时间线帧率,默认 25"
    )
    parser.add_argument("--font", default="PingFang SC", help="字幕字体,默认 PingFang SC")
    parser.add_argument("--font-size", type=int, default=60, help="字号,默认 60")
    parser.add_argument(
        "--width", type=int, default=1920, help="时间线宽度,默认 1920"
    )
    parser.add_argument(
        "--height", type=int, default=1080, help="时间线高度,默认 1080"
    )
    parser.add_argument(
        "--provider", default="cpu", choices=["cpu", "coreml"], help="onnxruntime 推理后端,默认 cpu"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    audio_path = Path(args.audio).expanduser().resolve()
    if not audio_path.is_file():
        print(f"错误: 找不到文件 {audio_path}", file=sys.stderr)
        raise SystemExit(1)

    for model_path in (SENSE_VOICE_MODEL, SENSE_VOICE_TOKENS, SILERO_VAD_MODEL):
        if not model_path.is_file():
            print(
                f"错误: 缺少模型文件 {model_path}\n"
                "请先运行: uv run python scripts/download_models.py",
                file=sys.stderr,
            )
            raise SystemExit(1)

    output_path = (
        Path(args.output).expanduser().resolve()
        if args.output
        else audio_path.with_suffix(".fcpxml")
    )

    models = AsrModels(
        sense_voice_model=str(SENSE_VOICE_MODEL),
        tokens=str(SENSE_VOICE_TOKENS),
        silero_vad_model=str(SILERO_VAD_MODEL),
        provider=args.provider,
    )

    start_time = time.monotonic()
    segments = transcribe(str(audio_path), models)
    elapsed = time.monotonic() - start_time

    if not segments:
        print("警告: 没有识别到任何语音片段", file=sys.stderr)

    xml = build_fcpxml(
        segments,
        fps=args.fps,
        width=args.width,
        height=args.height,
        font=args.font,
        font_size=args.font_size,
    )
    output_path.write_text(xml, encoding="utf-8")

    print(f"识别 {len(segments)} 句,耗时 {elapsed:.1f}s")
    print(f"已生成: {output_path}")
