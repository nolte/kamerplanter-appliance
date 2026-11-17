# Image prompt: Kami — Kamerplanter Appliance banner

> **Type:** hero banner
> **Variants:** Light + Dark
> **Target size:** 1920x480 px (4:1, README header)
> **Format:** PNG, solid background; the generator renders no text, the title is an overlay
> **Generator:** Cloudflare Workers AI, FLUX.2 Klein 4B (`flux-2-klein-4b`), with the Kami logo (and, for dark, the chosen light banner) as reference images; title set afterwards by `design/banner_text.py`
> **Character reference:** [`spec/design/KAMI-CHARACTER-REFERENCE.md`](https://github.com/nolte/kamerplanter/blob/develop/spec/design/KAMI-CHARACTER-REFERENCE.md) in `nolte/kamerplanter` (binding; the face and arms sit on the pot, the leaves carry no face)
> **Siblings:** `banner-kami-hauptapplikation.md` (main application), `banner-kami-ha-integration.md` (Home Assistant integration)

## Context

The banner of the appliance repository. Where the main banner shows Kami with grow light and meter, and the Home Assistant banner shows Kami inside a house with signal arcs, this one shows what the appliance is: Kamerplanter as a device you boot. Kami sits in its terracotta pot on top of a small mini PC whose status light glows green — "plug it in, boot it, it grows". Behind it, faint and secondary, a server rack unit and a cloud stand for the other places the appliance runs (hosted servers, Proxmox).

Indigo (#5c6bc0) carries the technology side, as in the Home Assistant banner. Mood: calm, dependable, friendly — "your plants, on their own box".

FLUX has no negative-prompt channel, so the prompts phrase every avoidance positively; an `Avoid:` clause would make text more likely, not less.

## Prompt — Light Mode

```
A wide panoramic hero banner illustration for a self-hosted plant management appliance, landscape 4:1 format. Clean flat 2D vector illustration, cute comic-style mascot, professional and calm.

Left third: the mascot Kami, exactly as in the reference image — a terracotta flower pot with a friendly face on the pot itself (two large round black eyes with white highlight dots and a small warm smile on the upper front of the pot) and two thin stick arms at the sides of the pot. From the soil grows a thin curved green stem with two large teardrop-shaped leaves pointing upward, plain leaves with a center vein and no face. Kami has a welcoming expression: leaves perked upward and lively, bright wide eyes, broad warm smile, one arm raised high and clearly waving in greeting with an open hand, the other arm relaxed.

Kami stands ON TOP of a small compact mini PC: the bottom of the terracotta pot rests directly on the flat lid of the mini PC, like a plant placed on a desk device, and the mini PC sits on the ground below it. The mini PC is about as wide as the pot and half as tall: a rounded rectangular box in indigo (#5c6bc0) with a lighter indigo top plate (#9fa8da), a short row of three small rounded vent slots, and one round status light glowing fresh green (#66bb6a) with a soft green halo. Behind the mini PC, smaller and fainter, a single flat server rack unit outline and a simple rounded cloud outline, both thin indigo lines (#9fa8da) at low opacity, clearly secondary.

From the mini PC, three thin gently curving dotted lines in light indigo (#9fa8da) flow toward the right, with four or five small round nodes in alternating green (#66bb6a) and indigo (#5c6bc0) along them, fading out by the middle of the image.

Colors: leaves #66bb6a with highlights #98ee99 and shadows #2e7d32, stem #43a047, pot #8d6e63 with a lighter band #a1887f and shadow #6d4c41, soil #795548. All outlines of Kami and the devices in dark green #1b5e20 and indigo #3949ab, uniform and smooth with rounded caps.

The right two-thirds of the image are calm, empty, plain background space. Background: one single flat uniform soft light gray #f5f5f5 across the whole image, edge to edge, with no color tints, no vignette, no floor band and no glow in any corner.

Style: flat solid color fills with subtle soft inner shading, clean crisp edges, bold simple shapes, fewer than ten colors, a pure illustration made only of shapes and color, completely free of letters, words, numbers, labels, logos and watermarks.
```

## Prompt — Dark Mode

```
A wide panoramic hero banner illustration for a self-hosted plant management appliance, landscape 4:1 format, designed for dark backgrounds. Clean flat 2D vector illustration, cute comic-style mascot, professional and calm.

Left third: the mascot Kami, exactly as in the reference image — a terracotta flower pot with a friendly face on the pot itself (two large round eyes with white highlight dots and a small warm smile on the upper front of the pot) and two thin stick arms at the sides of the pot. From the soil grows a thin curved green stem with two large teardrop-shaped leaves pointing upward, plain leaves with a center vein and no face. Kami has a welcoming expression: leaves perked upward and lively, bright wide eyes, broad warm smile, one arm raised high and clearly waving in greeting with an open hand, the other arm relaxed.

Kami stands ON TOP of a small compact mini PC: the bottom of the terracotta pot rests directly on the flat lid of the mini PC, like a plant placed on a desk device, and the mini PC sits on the ground below it. The mini PC is about as wide as the pot and half as tall: a rounded rectangular box in indigo (#5c6bc0) with a lighter indigo top plate (#9fa8da), a short row of three small rounded vent slots, and one round status light glowing bright green (#98ee99) with a soft green glow. Behind the mini PC, smaller and fainter, a single flat server rack unit outline and a simple rounded cloud outline, both thin muted indigo lines (#3949ab), clearly secondary.

From the mini PC, three thin gently curving dotted lines in muted indigo (#7986cb) flow toward the right, with four or five small softly glowing round nodes in alternating green (#66bb6a) and indigo (#9fa8da) along them, fading out by the middle of the image.

Colors: leaves #66bb6a with highlights #98ee99 and shadows #43a047, stem #43a047, pot #8d6e63 with a lighter band #a1887f and shadow #6d4c41, soil #795548. All outlines of Kami in light green #c8e6c9 and of the devices in light indigo #c5cae9, uniform and smooth with rounded caps, for contrast on the dark background.

The right two-thirds of the image are calm, empty, plain background space. Background: one single flat uniform deep dark gray #1e1e1e across the whole image, edge to edge, with no color tints, no vignette, no floor band and no glow in any corner.

Style: flat solid color fills with subtle soft inner shading, clean crisp edges, bold simple shapes, fewer than ten colors, a pure illustration made only of shapes and color, completely free of letters, words, numbers, labels, logos and watermarks.
```

## Generate

Needs `CLOUDFLARE_API_TOKEN` (scope Workers AI) and `CLOUDFLARE_ACCOUNT_ID` in the environment. The reference images are uploaded to Cloudflare. Cloudflare returns JPEG, hence the `.jpg` targets.

```bash
GEN=~/repos/github/claude-shared/plugins/nolte-media/skills/image-generate/scripts/image_generate.py
# Light: the Kami logo is the only reference.
python3 "$GEN" --provider cloudflare --model flux-2-klein-4b \
  --from-prompt-doc design/prompts/banner-kami-appliance.md --variant light \
  --width 1920 --height 480 --ref-image design/references/kami-logo-ref.png \
  -n 3 --out .render/banner-appliance-light.jpg
# Dark: the chosen light banner, scaled below 512 px, is a second reference;
# without it FLUX puts the pot beside the mini PC instead of on top of it.
python3 "$GEN" --provider cloudflare --model flux-2-klein-4b \
  --from-prompt-doc design/prompts/banner-kami-appliance.md --variant dark \
  --width 1920 --height 480 --ref-image design/references/kami-logo-ref.png \
  --ref-image design/references/composition-ref-light.png \
  -n 3 --out .render/banner-appliance-dark.jpg
```

Pick the best candidate per variant, check it against the character reference (face on the pot, no face on the leaves, no text), copy it to `design/renders/banner-appliance-{light,dark}.jpg`, and set the title with `python3 design/banner_text.py`, which writes `docs/assets/images/banner-appliance-{light,dark}.png`.

## Lessons from the first renders

- A requested background tint ("warm along the bottom left") comes out as strong orange and blue corners; ask for one flat uniform colour instead.
- FLUX ignores the light-green outlines of the dark variant and draws dark outlines; on #1e1e1e Kami stays readable, so this is accepted.
- An unconstrained prompt sometimes gives the mini PC a face of its own; reject such candidates (one character only).

## Post-processing

- [x] Kami matches the reference: face and arms on the pot, two plain leaves, no separate head
- [x] No letters, numbers or logos in the generated image; the mini PC carries no brand
- [x] Background is one flat colour on the right two-thirds
- [x] Title "Kamerplanter Appliance" (Noto Sans SemiBold, primary #2e7d32 / #66bb6a) and subtitle (secondary #5c6bc0 / #9fa8da) set by `design/banner_text.py`
- [x] Stored as `docs/assets/images/banner-appliance-{light,dark}.png`; the README picks the variant by colour scheme
- [x] Social preview `docs/assets/images/social-preview.png` (1280x640, 2:1) built by the same script from the light render: Kami and the mini PC on the left, the title in two lines on the right. GitHub has no API for it; upload it by hand under Settings > General > Social preview.
