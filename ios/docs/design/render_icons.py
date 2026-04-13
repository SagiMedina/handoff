"""
Handoff app icon — final asset renderer.

Renders the three iOS 18 variants (light / dark / tinted) of Direction A v4
"Tight + Intense" directly into the iOS Asset Catalog.

Run from the repo root:
    python3 ios/docs/design/render_icons.py

Geometry is the source of truth — must match ios/docs/design/app-icon.svg.
"""

from PIL import Image, ImageDraw, ImageFilter
import os

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
APPICON_DIR = os.path.join(
    REPO, "ios", "Handoff", "Resources", "Assets.xcassets", "AppIcon.appiconset"
)

# --------------------------------------------------------------------------
# Geometry — MUST match app-icon.svg
# --------------------------------------------------------------------------

SIZE = 1024

# Chevron master shape (leading, unshifted)
LEADING_TIP   = (720, 512)
LEADING_UPPER = (336, 256)
LEADING_LOWER = (336, 768)

# v4 Tight + Intense parameters
STROKE_WIDTH    = 120
TRAILING_OFFSET = (-88, 32)
TRAILING_OPACITY = 0.60
GLOW_RADIUS     = 72
GLOW_OPACITY    = 0.40

# Radial background
BG_CENTER = (640, 576)
BG_OUTER_RADIUS = 900

# Palette
GREEN = (63, 185, 80)   # #3FB950
BLUE  = (88, 166, 255)  # #58A6FF
WHITE = (255, 255, 255)

# Background palettes per appearance
BG_LIGHT   = ((22, 27, 34),  (1, 4, 9))    # #161B22 -> #010409
BG_DARK    = ((13, 17, 23),  (0, 0, 0))    # #0D1117 -> #000000
BG_TINTED  = ((28, 28, 30),  (0, 0, 0))    # #1C1C1E -> #000000


# --------------------------------------------------------------------------
# Drawing primitives
# --------------------------------------------------------------------------

def radial_gradient(size, center, inner, outer, outer_radius):
    """
    Fast radial gradient via concentric ellipses.
    Starts with the outer color as the base fill, then draws inward.
    """
    img = Image.new("RGB", (size, size), outer)
    draw = ImageDraw.Draw(img)
    cx, cy = center
    steps = outer_radius
    for i in range(steps, 0, -2):
        t = i / outer_radius
        eased = 1 - (1 - t) ** 2
        r = int(inner[0] * (1 - eased) + outer[0] * eased)
        g = int(inner[1] * (1 - eased) + outer[1] * eased)
        b = int(inner[2] * (1 - eased) + outer[2] * eased)
        draw.ellipse([cx - i, cy - i, cx + i, cy + i], fill=(r, g, b))
    return img


def chevron_overlay(canvas_size, offset, color, opacity, stroke_width):
    """
    Render a chevron stroke (two segments) onto a fresh RGBA overlay.
    Rounded caps + rounded join via explicit circles at all 3 points.
    """
    ox, oy = offset
    tip = (LEADING_TIP[0] + ox, LEADING_TIP[1] + oy)
    upper = (LEADING_UPPER[0] + ox, LEADING_UPPER[1] + oy)
    lower = (LEADING_LOWER[0] + ox, LEADING_LOWER[1] + oy)

    alpha = int(round(255 * opacity))
    rgba = (*color, alpha)

    overlay = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.line([upper, tip], fill=rgba, width=stroke_width)
    draw.line([tip, lower], fill=rgba, width=stroke_width)

    r = stroke_width // 2
    for cx, cy in [upper, tip, lower]:
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rgba)

    return overlay


def compose_icon(leading_color, trailing_color, bg_inner, bg_outer,
                 trailing_opacity=TRAILING_OPACITY,
                 include_glow=True):
    """
    Compose one variant of the Handoff chevron.
    """
    bg = radial_gradient(SIZE, BG_CENTER, bg_inner, bg_outer, BG_OUTER_RADIUS)
    canvas = bg.convert("RGBA")

    # Trailing chevron first (behind)
    trailing = chevron_overlay(
        canvas.size, TRAILING_OFFSET, trailing_color,
        trailing_opacity, STROKE_WIDTH,
    )
    canvas.alpha_composite(trailing)

    # Leading chevron glow (optional)
    if include_glow and GLOW_RADIUS > 0:
        glow = chevron_overlay(
            canvas.size, (0, 0), leading_color,
            GLOW_OPACITY, STROKE_WIDTH + GLOW_RADIUS // 2,
        )
        glow = glow.filter(ImageFilter.GaussianBlur(radius=GLOW_RADIUS))
        canvas.alpha_composite(glow)

    # Leading chevron (front)
    leading = chevron_overlay(
        canvas.size, (0, 0), leading_color, 1.0, STROKE_WIDTH,
    )
    canvas.alpha_composite(leading)

    return canvas.convert("RGB")


# --------------------------------------------------------------------------
# Variant renderers
# --------------------------------------------------------------------------

def render_light():
    """Standard appearance — full color on the GitHub-dark radial."""
    return compose_icon(GREEN, BLUE, *BG_LIGHT, include_glow=True)


def render_dark():
    """iOS 18 Dark appearance — same composition, deeper background."""
    return compose_icon(GREEN, BLUE, *BG_DARK, include_glow=True)


def render_tinted():
    """
    iOS 18 Tinted appearance — grayscale. The system tints the light areas
    to the user's chosen hue, so:
      - Background = near-black  (stays dark after tint)
      - Trailing   = white @ 0.55 (becomes medium tint)
      - Leading    = white @ 1.0  (becomes full tint)
    The brightness differential preserves the handoff contrast under any tint.
    No glow — it dilutes the contrast Apple uses for luminance-based tinting.
    """
    return compose_icon(
        leading_color=WHITE,
        trailing_color=WHITE,
        bg_inner=BG_TINTED[0],
        bg_outer=BG_TINTED[1],
        trailing_opacity=0.55,
        include_glow=False,
    )


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    os.makedirs(APPICON_DIR, exist_ok=True)

    outputs = [
        ("icon_1024.png",        render_light()),
        ("icon_1024_dark.png",   render_dark()),
        ("icon_1024_tinted.png", render_tinted()),
    ]

    for name, img in outputs:
        path = os.path.join(APPICON_DIR, name)
        img.save(path, "PNG", optimize=True)
        print(f"wrote {path}")

    print("done.")


if __name__ == "__main__":
    main()
