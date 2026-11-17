#!/usr/bin/env python3
"""Set the title onto the generated appliance banners and build the social preview.

The image generator renders no text (FLUX garbles lettering), so the title is a
typography overlay, as for the main Kamerplanter banner. Reads the text-free
renders under design/renders/ and writes to docs/assets/images/:

- banner-appliance-{light,dark}.png: the 4:1 README banners;
- social-preview.png: the 2:1 GitHub social preview (1280x640, uploaded by hand
  under Settings > General > Social preview).

Needs Pillow and Noto Sans (Fedora: google-noto-sans-fonts, Debian/Ubuntu: fonts-noto-core).
Run from the repository root: python3 design/banner_text.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Debian/Ubuntu and Fedora install Noto Sans in different places.
FONT_DIRS = (Path("/usr/share/fonts/truetype/noto"), Path("/usr/share/fonts/google-noto"))
TITLE = "Kamerplanter Appliance"
SUBTITLE = "Plant lifecycle management, ready to boot"
OUT_DIR = Path("docs/assets/images")

# Banner text block: the empty right part of the banner, right of the data dots.
BOX_LEFT, BOX_RIGHT = 1040, 1860
TITLE_MAX_PX, SUBTITLE_RATIO, GAP_PX = 96, 0.42, 18

# Social preview: Kami and the mini PC cut from the light render, title beside them.
SOCIAL_SIZE = (1280, 640)
SOCIAL_SCENE_CROP = (90, 20, 560, 470)  # box in the light render holding Kami and the mini PC
SOCIAL_SCENE_HEIGHT = 560
SOCIAL_FADE_PX = 40
SOCIAL_TEXT_BOX = (660, 1220)  # left and right edge of the text column

VARIANTS = {
    # variant: (title colour = brand primary, subtitle colour = brand secondary)
    "light": ("#2e7d32", "#5c6bc0"),
    "dark": ("#66bb6a", "#9fa8da"),
}


def font_file(name: str) -> Path:
    for directory in FONT_DIRS:
        if (directory / name).is_file():
            return directory / name
    raise SystemExit(f"{name} not found in {', '.join(map(str, FONT_DIRS))}")


def fit(font_path: Path, text: str, max_px: int, width: int) -> ImageFont.FreeTypeFont:
    size = max_px
    while size > 10:
        font = ImageFont.truetype(str(font_path), size)
        if font.getlength(text) <= width:
            return font
        size -= 2
    raise SystemExit(f"cannot fit {text!r} into {width}px")


def draw_lines(image: Image.Image, lines, centre_x: float, gap: int) -> None:
    """Draw (text, font, colour) lines centred on centre_x, the block centred vertically."""
    draw = ImageDraw.Draw(image)
    boxes = [draw.textbbox((0, 0), text, font=font, anchor="ls") for text, font, _ in lines]
    heights = [box[3] - box[1] for box in boxes]
    y = (image.height - (sum(heights) + gap * (len(lines) - 1))) / 2
    for (text, font, colour), box, height in zip(lines, boxes, heights):
        draw.text((centre_x, y - box[1]), text, font=font, fill=colour, anchor="ms")
        y += height + gap


def save(image: Image.Image, name: str) -> None:
    out = OUT_DIR / name
    out.parent.mkdir(parents=True, exist_ok=True)
    # A 256-colour palette keeps the flat illustration intact and the file
    # under the 500 KB limit of the check-added-large-files hook.
    image.quantize(256, dither=Image.Dither.FLOYDSTEINBERG).save(out, optimize=True)
    print(f"wrote {out} ({out.stat().st_size} bytes)")


def banners() -> None:
    width = BOX_RIGHT - BOX_LEFT
    title_font = fit(font_file("NotoSans-SemiBold.ttf"), TITLE, TITLE_MAX_PX, width)
    sub_font = fit(
        font_file("NotoSans-Regular.ttf"), SUBTITLE, int(title_font.size * SUBTITLE_RATIO), width
    )
    for variant, (title_colour, sub_colour) in VARIANTS.items():
        image = Image.open(f"design/renders/banner-appliance-{variant}.jpg").convert("RGB")
        draw_lines(
            image,
            [(TITLE, title_font, title_colour), (SUBTITLE, sub_font, sub_colour)],
            BOX_LEFT + width / 2,
            GAP_PX,
        )
        save(image, f"banner-appliance-{variant}.png")


def social_preview() -> None:
    render = Image.open("design/renders/banner-appliance-light.jpg").convert("RGB")
    # The render's own background, so the cut-out scene blends in.
    image = Image.new("RGB", SOCIAL_SIZE, render.getpixel((render.width - 20, render.height // 2)))
    scene = render.crop(SOCIAL_SCENE_CROP)
    scale = SOCIAL_SCENE_HEIGHT / scene.height
    scene = scene.resize((round(scene.width * scale), SOCIAL_SCENE_HEIGHT), Image.LANCZOS)
    # Fade the cut edge into the background instead of a hard seam.
    mask = Image.new("L", scene.size, 255)
    for x in range(SOCIAL_FADE_PX):
        mask.paste(round(255 * x / SOCIAL_FADE_PX), (scene.width - 1 - x, 0, scene.width - x, scene.height))
    image.paste(scene, (40, (SOCIAL_SIZE[1] - SOCIAL_SCENE_HEIGHT) // 2), mask)

    left, right = SOCIAL_TEXT_BOX
    title_colour, sub_colour = VARIANTS["light"]
    first, second = TITLE.split(" ", 1)
    title_font = fit(font_file("NotoSans-SemiBold.ttf"), first, 120, right - left)
    sub_font = fit(font_file("NotoSans-Regular.ttf"), SUBTITLE, 40, right - left)
    draw_lines(
        image,
        [
            (first, title_font, title_colour),
            (second, title_font, title_colour),
            (SUBTITLE, sub_font, sub_colour),
        ],
        (left + right) / 2,
        22,
    )
    save(image, "social-preview.png")


if __name__ == "__main__":
    banners()
    social_preview()
