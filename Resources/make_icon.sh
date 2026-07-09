#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
S=1024

# 1. Dark vertical-gradient background
magick -size ${S}x${S} gradient:'#232d42-#0a0d15' bg.png

# 2. Rounded-rect (squircle-ish) mask
R=228
magick -size ${S}x${S} xc:none -draw "roundrectangle 0,0 $((S-1)),$((S-1)) $R,$R" -alpha extract mask.png

# 3. Draw the database cylinder onto a transparent layer
#    centered at 512, top disk cap y=366, bottom cap y=666, rx=210 ry=66
magick -size ${S}x${S} xc:none \
  -stroke none \
  -fill '#0f7a72' -draw "ellipse 512,666 210,66 0,360" \
  -fill '#0f7a72' -draw "rectangle 302,366 722,666" \
  -fill '#157f77' -draw "rectangle 302,366 722,466" \
  -fill '#13847b' -draw "rectangle 302,366 722,406" \
  -fill none -stroke '#06413c' -strokewidth 7 \
      -draw "ellipse 512,486 210,66 0,360" \
      -draw "ellipse 512,576 210,66 0,360" \
  -stroke none \
  -fill '#2dd4bf' -draw "ellipse 512,366 210,66 0,360" \
  -fill '#0b0e16' -draw "ellipse 512,366 210,66 0,360" -channel A -evaluate multiply 0.0 +channel \
  cyl_tmp.png

# redo top disk cleanly (previous last op zeroed nothing useful) -> build disk separately
magick -size ${S}x${S} xc:none -stroke none \
  -fill '#0f7a72' -draw "ellipse 512,666 210,66 0,360" \
  -fill '#0f7a72' -draw "rectangle 302,366 722,666" \
  cyl_body.png
magick -size ${S}x${S} xc:none -stroke none \
  -fill '#5eead4' -draw "ellipse 512,366 210,66 0,360" \
  cyl_top.png
# subtle ring separators (front arcs approximated by full thin ellipses, dark)
magick -size ${S}x${S} xc:none \
  -fill none -stroke '#06413c' -strokewidth 6 \
  -draw "ellipse 512,486 210,66 20,160" \
  -draw "ellipse 512,576 210,66 20,160" \
  cyl_rings.png
# highlight on top disk
magick -size ${S}x${S} xc:none -stroke none \
  -fill '#eafffb' -draw "ellipse 470,350 92,20 0,360" \
  cyl_hi.png
magick cyl_hi.png -channel A -evaluate multiply 0.30 +channel cyl_hi.png

# 4. Composite cylinder pieces
magick cyl_body.png cyl_rings.png -composite \
       cyl_top.png -composite \
       cyl_hi.png -composite cylinder.png

# 5. Compose: background + cylinder, then apply rounded mask
magick bg.png cylinder.png -composite \
       mask.png -alpha off -compose CopyOpacity -composite \
       icon_1024.png

echo "done -> icon_1024.png"
