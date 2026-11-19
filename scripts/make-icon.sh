#!/bin/bash
# Makes mac/AppIcon.icns: the VSCode logo on a dark macOS icon, with a round
# badge in the bottom right.
#
# Usage: scripts/make-icon.sh path/to/badge.svg
#   The badge is a one-path SVG, such as a Font Awesome icon.
#
# Needs rsvg-convert (brew install librsvg) and Visual Studio Code, which has
# the logo. Set VSCODE_APP if VSCode is not in /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

BADGE="${1:-}"
[ -f "$BADGE" ] || fail "Usage: scripts/make-icon.sh path/to/badge.svg"
command -v rsvg-convert >/dev/null 2>&1 || fail "This needs rsvg-convert. Run: brew install librsvg"
LOGO="${VSCODE_APP:-/Applications/Visual Studio Code.app}/Contents/Resources/app/out/media/code-icon.svg"
[ -f "$LOGO" ] || fail "No VSCode logo at $LOGO. Set VSCODE_APP=/path/to/Visual Studio Code.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -I - "$LOGO" "$BADGE" >"$TMP/icon.svg" <<'PY'
import re, sys
logo, badge = (open(p).read() for p in sys.argv[1:3])

# The macOS icon shape: an 824 px square with smooth corners, centred on a
# 1024 px canvas. r = 182 matches the shape of the VSCode icon.
def shape(x, y, size, r):
    # One smooth corner as Bezier points, in units of r (PaintCode's iOS corner).
    corner = [("L", [(1.52866471, 0)]),
              ("C", [(1.08849323, 0), (0.86840689, 0), (0.66993427, 0.065496)]),
              ("L", [(0.63149399, 0.074911)]),
              ("C", [(0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)]),
              ("L", [(0.065496, 0.66993427)]),
              ("C", [(0, 0.86840701), (0, 1.08849299), (0, 1.52866483)])]
    e, f = x + size, y + size
    # (a, b) = distance along the edge from the corner, distance in from the edge.
    corners = [lambda a, b: (e - a * r, y + b * r),  # top right
               lambda a, b: (e - b * r, f - a * r),  # bottom right
               lambda a, b: (x + a * r, f - b * r),  # bottom left
               lambda a, b: (x + b * r, y + a * r)]  # top left
    d = "M%.2f %.2f" % (x + 1.52866483 * r, y)
    for at in corners:
        for cmd, points in corner:
            d += cmd + " ".join("%.2f %.2f" % at(a, b) for a, b in points)
    return d + "Z"

sq = shape(100, 100, 824, 182)
logo = re.sub(r"^<svg[^>]*>|</svg>\s*$", "", logo.strip())
glyph = re.search(r'\sd="([^"]+)"', badge).group(1)
vb = [float(n) for n in re.search(r'viewBox="([^"]+)"', badge).group(1).split()]

cx = cy = 716  # badge centre
r = 172        # badge radius
ring = 20      # gap between the badge and the logo
s = 1.5 * r / max(vb[2], vb[3])
gx, gy = cx - (vb[0] + vb[2] / 2) * s, cy - (vb[1] + vb[3] / 2) * s

print(f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#3a3a3f"/><stop offset="1" stop-color="#18181b"/>
  </linearGradient>
  <linearGradient id="badge" x1="0" y1="{cy - r}" x2="0" y2="{cy + r}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#dcdce2"/>
  </linearGradient>
  <clipPath id="shape"><path d="{sq}"/></clipPath>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
    <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.35"/>
  </filter>
  <filter id="badgeShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.45"/>
  </filter>
</defs>
<path d="{sq}" fill="url(#bg)" filter="url(#shadow)"/>
<path d="{sq}" fill="none" stroke="#fff" stroke-opacity="0.12" stroke-width="6" clip-path="url(#shape)"/>
<g transform="translate(216 224) scale(2.25)">{logo}</g>
<circle cx="{cx}" cy="{cy}" r="{r + ring}" fill="url(#bg)" clip-path="url(#shape)"/>
<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#badge)" filter="url(#badgeShadow)"/>
<path transform="translate({gx:.2f} {gy:.2f}) scale({s:.4f})" d="{glyph}" fill="#1e1e22"/>
</svg>''')
PY

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$TMP/icon.svg" -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$TMP/icon.svg" -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/mac/AppIcon.icns"
echo "Made $ROOT/mac/AppIcon.icns"
