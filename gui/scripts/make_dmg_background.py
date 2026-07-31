"""Generate the DMG window background: install instructions + arrow.

Run: uv run --with pillow python gui/scripts/make_dmg_background.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 600, 420
OUT = Path(__file__).resolve().parent.parent / "assets" / "dmg_background.png"


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in (
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> None:
    # Subtle vertical gradient, light neutral
    top, bottom = (248, 248, 252), (235, 236, 244)
    img = Image.new("RGB", (W, H))
    for y in range(H):
        t = y / (H - 1)
        row_color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        img.paste(Image.new("RGB", (W, 1), row_color), (0, y))

    draw = ImageDraw.Draw(img)

    title_font = load_font(22)
    body_font = load_font(14)

    # Title
    title = "安装 FCP 字幕"
    tw = draw.textlength(title, font=title_font)
    draw.text(((W - tw) / 2, 40), title, fill=(40, 40, 60), font=title_font)

    # Instruction
    body = "把左边的「FCP字幕」拖到右边的 Applications 文件夹"
    bw = draw.textlength(body, font=body_font)
    draw.text(((W - bw) / 2, 82), body, fill=(110, 110, 130), font=body_font)

    # Arrow between icon positions (icons land at y≈210 center via dmg settings)
    ax0, ax1, ay = 240, 360, 215
    draw.line([(ax0, ay), (ax1 - 16, ay)], fill=(120, 120, 200), width=6)
    draw.polygon(
        [(ax1 - 18, ay - 14), (ax1 - 18, ay + 14), (ax1 + 4, ay)], fill=(120, 120, 200))

    # Footer hint
    foot = "首次打开:若系统提示未验证开发者,右键 App 选「打开」即可"
    fw = draw.textlength(foot, font=body_font)
    draw.text(((W - fw) / 2, H - 50), foot, fill=(150, 150, 165), font=body_font)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"已生成: {OUT}")


if __name__ == "__main__":
    main()
