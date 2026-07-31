"""Generate the app icon PNG (1024x1024): gradient rounded-rect + caption bubble.

Run: uv run --with pillow python gui/scripts/make_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "assets" / "AppIcon.png"


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def main() -> None:
    # Vertical gradient: deep blue -> violet
    top = (30, 60, 180)
    bottom = (120, 60, 200)
    img = Image.new("RGB", (SIZE, SIZE))
    for y in range(SIZE):
        t = y / (SIZE - 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for_draw = Image.new("RGB", (SIZE, 1), row)
        img.paste(for_draw, (0, y))

    draw = ImageDraw.Draw(img)

    # Caption bubble: white rounded rect with a small tail
    bx0, by0, bx1, by1 = 170, 260, 854, 660
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=90, fill=(255, 255, 255))
    draw.polygon([(300, by1 - 6), (300, by1 + 110), (430, by1 - 6)], fill=(255, 255, 255))

    # Subtitle text lines inside the bubble (gradient-colored bars)
    bar_color = (70, 90, 200)
    bar_color2 = (150, 160, 230)
    draw.rounded_rectangle([250, 350, 774, 420], radius=35, fill=bar_color)
    draw.rounded_rectangle([250, 470, 620, 540], radius=35, fill=bar_color2)

    # Bottom subtitle strip hint: two small bars like timeline clips
    draw.rounded_rectangle([200, 760, 500, 830], radius=26, fill=(255, 255, 255, 230))
    draw.rounded_rectangle([540, 760, 830, 830], radius=26, fill=(255, 255, 255, 160))

    # Apply macOS-style rounded corners (squircle approximation)
    mask = rounded_rect_mask(SIZE, radius=230)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    out.save(OUT)
    print(f"已生成: {OUT}")


if __name__ == "__main__":
    main()
