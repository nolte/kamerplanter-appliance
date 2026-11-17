#!/usr/bin/env python3
"""Set the title onto the generated appliance banners.

The image generator renders no text (FLUX garbles lettering), so the title is a
typography overlay, as for the main Kamerplanter banner. Reads the text-free
renders under design/renders/ and writes docs/assets/images/banner-appliance-*.png.

Needs Pillow and Noto Sans (Fedora: google-noto-sans-fonts, Debian/Ubuntu: fonts-noto-core).
Run from the repository root: python3 design/banner_text.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_DIR = Path("/usr/share/fonts/truetype/noto")
TITLE = "Kamerplanter Appliance"
SUBTITLE = "Plant lifecycle management, ready to boot"

# Text block: the empty right part of the banner, right of the data dots.
BOX_LEFT, BOX_RIGHT = 1040, 1860
TITLE_MAX_PX, SUBTITLE_RATIO, GAP_PX = 96, 0.42, 18

VARIANTS = {
    # variant: (title colour = brand primary, subtitle colour = brand secondary)
    "light": ("#2e7d32", "#5c6bc0"),
    "dark": ("#66bb6a", "#9fa8da"),
}


def fit(font_file: Path, text: str, max_px: int, width: int) -> ImageFont.FreeTypeFont:
    size = max_px
    while size > 10:
        font = ImageFont.truetype(str(font_file), size)
        if font.getlength(text) <= width:
            return font
        size -= 2
    raise SystemExit(f"cannot fit {text!r} into {width}px")


def main() -> None:
    width = BOX_RIGHT - BOX_LEFT
    title_font = fit(FONT_DIR / "NotoSans-SemiBold.ttf", TITLE, TITLE_MAX_PX, width)
    sub_font = fit(
        FONT_DIR / "NotoSans-Regular.ttf", SUBTITLE, int(title_font.size * SUBTITLE_RATIO), width
    )
    for variant, (title_colour, sub_colour) in VARIANTS.items():
        image = Image.open(f"design/renders/banner-appliance-{variant}.jpg").convert("RGB")
        draw = ImageDraw.Draw(image)
        centre_x = BOX_LEFT + width / 2
        t_box = draw.textbbox((0, 0), TITLE, font=title_font, anchor="ls")
        s_box = draw.textbbox((0, 0), SUBTITLE, font=sub_font, anchor="ls")
        t_h, s_h = t_box[3] - t_box[1], s_box[3] - s_box[1]
        top = (image.height - (t_h + GAP_PX + s_h)) / 2
        draw.text((centre_x, top - t_box[1]), TITLE, font=title_font, fill=title_colour, anchor="ms")
        draw.text(
            (centre_x, top + t_h + GAP_PX - s_box[1]),
            SUBTITLE,
            font=sub_font,
            fill=sub_colour,
            anchor="ms",
        )
        out = Path(f"docs/assets/images/banner-appliance-{variant}.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        # A 256-colour palette keeps the flat illustration intact and the file
        # under the 500 KB limit of the check-added-large-files hook.
        image.quantize(256, dither=Image.Dither.FLOYDSTEINBERG).save(out, optimize=True)
        print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
