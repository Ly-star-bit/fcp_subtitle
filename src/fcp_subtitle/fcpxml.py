"""Build a frame-accurate FCPXML with each subtitle line as an editable Basic Title clip.

Verified against Apple's FCPXML DTD and a real working srt-to-fcpxml converter:
- times are rational fractions of the sequence's frameDuration ("N/Ds"), never
  decimal seconds, or long files drift out of sync with the audio;
- <format> and the Basic Title <effect> must use distinct resource ids;
- gaps in the spine's primary storyline must be filled with explicit <gap>
  elements, they cannot be left implicit.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from fractions import Fraction
from xml.dom import minidom

from .asr import Segment

BASIC_TITLE_UID = (
    ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"
)

# fps label -> (frame duration numerator, denominator)
FRAME_DURATIONS: dict[str, tuple[int, int]] = {
    "23.976": (1001, 24000),
    "24": (1, 24),
    "25": (1, 25),
    "29.97": (1001, 30000),
    "30": (1, 30),
}


def frame_duration_for_fps(fps: str) -> Fraction:
    if fps not in FRAME_DURATIONS:
        choices = ", ".join(FRAME_DURATIONS)
        raise ValueError(f"不支持的帧率 {fps!r},可选: {choices}")
    num, den = FRAME_DURATIONS[fps]
    return Fraction(num, den)


def _quantize_frames(seconds: float, frame_duration: Fraction) -> int:
    return round(Fraction(seconds).limit_denominator(1_000_000) / frame_duration)


def _frames_to_time(frame_count: int, frame_duration: Fraction) -> str:
    total = frame_count * frame_duration
    if total.denominator == 1:
        return f"{total.numerator}s"
    return f"{total.numerator}/{total.denominator}s"


def seconds_to_fcp_time(seconds: float, frame_duration: Fraction) -> str:
    """Quantize `seconds` to the nearest frame and format as an FCPXML rational time."""
    return _frames_to_time(_quantize_frames(seconds, frame_duration), frame_duration)


def build_fcpxml(
    segments: list[Segment],
    fps: str = "25",
    width: int = 1920,
    height: int = 1080,
    font: str = "PingFang SC",
    font_size: int = 60,
    font_color: str = "1 1 1 1",
    event_name: str = "SenseVoice 字幕导入",
    project_name: str = "自动字幕时间线",
) -> str:
    frame_duration = frame_duration_for_fps(fps)

    fcpxml = ET.Element("fcpxml", version="1.9")

    resources = ET.SubElement(fcpxml, "resources")
    ET.SubElement(
        resources,
        "format",
        id="r1",
        name=f"FFVideoFormat{height}p{fps.replace('.', '')}",
        frameDuration=f"{frame_duration.numerator}/{frame_duration.denominator}s",
        width=str(width),
        height=str(height),
        colorSpace="1-1-1 (Rec. 709)",
    )
    ET.SubElement(resources, "effect", id="r2", name="Basic Title", uid=BASIC_TITLE_UID)

    library = ET.SubElement(fcpxml, "library")
    event = ET.SubElement(library, "event", name=event_name)
    project = ET.SubElement(event, "project", name=project_name)
    sequence = ET.SubElement(
        project, "sequence", format="r1", tcStart="0s", tcFormat="NDF"
    )
    spine = ET.SubElement(sequence, "spine")

    cursor_frames = 0
    ordered = sorted(segments, key=lambda s: s.start)
    for index, seg in enumerate(ordered):
        start_frames = _quantize_frames(seg.start, frame_duration)
        end_frames = max(
            _quantize_frames(seg.end, frame_duration), start_frames + 1
        )
        if start_frames < cursor_frames:
            start_frames = cursor_frames
            end_frames = max(end_frames, start_frames + 1)

        if start_frames > cursor_frames:
            ET.SubElement(
                spine,
                "gap",
                name="Gap",
                offset=_frames_to_time(cursor_frames, frame_duration),
                start="0s",
                duration=_frames_to_time(start_frames - cursor_frames, frame_duration),
            )

        offset_str = _frames_to_time(start_frames, frame_duration)
        duration_str = _frames_to_time(end_frames - start_frames, frame_duration)

        title = ET.SubElement(
            spine,
            "title",
            ref="r2",
            name=seg.text,
            offset=offset_str,
            duration=duration_str,
            start=offset_str,
        )
        text = ET.SubElement(title, "text")
        text_style = ET.SubElement(text, "text-style", ref=f"ts{index}")
        text_style.text = seg.text
        text_style_def = ET.SubElement(title, "text-style-def", id=f"ts{index}")
        ET.SubElement(
            text_style_def,
            "text-style",
            font=font,
            fontSize=str(font_size),
            fontFace="Regular",
            fontColor=font_color,
            alignment="center",
        )

        cursor_frames = end_frames

    rough = ET.tostring(fcpxml, encoding="unicode")
    pretty = minidom.parseString(rough).toprettyxml(indent="    ")
    # minidom emits its own xml declaration without the fcpxml DOCTYPE; rebuild the header.
    body = pretty.split("?>\n", 1)[1]
    return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n\n' + body
