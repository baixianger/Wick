# Flat emerald-green GLASS app icon (Apple Music style): squircle with a vivid
# green gradient, layered specular/sheen highlights for a liquid-glass look, and
# white candlesticks (K-line) trending up as the glyph (Wick = candle wick).
S = 1024
M = 48; W = S - 2*M; RX = 232   # near edge-to-edge squircle, Apple-style

# wavy white line (折线), upward trend, with a soft area fill under it
LINE_PTS = [(160,648),(286,600),(388,642),(500,540),(602,584),(726,452),(828,498),(880,372)]
def _path(pts):
    d = f"M {pts[0][0]},{pts[0][1]} "
    for i in range(1,len(pts)):
        x0,y0=pts[i-1]; x1,y1=pts[i]; mx=(x0+x1)/2
        d += f"C {mx},{y0} {mx},{y1} {x1},{y1} "
    return d
LINE_D = _path(LINE_PTS)
AREA_D = LINE_D + f"L {LINE_PTS[-1][0]},760 L {LINE_PTS[0][0]},760 Z"

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs>
  <!-- emerald body gradient (lighter top-left → deep bottom-right) -->
  <linearGradient id="gBody" x1="0.1" y1="0" x2="0.9" y2="1">
    <stop offset="0" stop-color="#4dE38a"/>
    <stop offset="0.45" stop-color="#16b85f"/>
    <stop offset="1" stop-color="#067a40"/>
  </linearGradient>
  <!-- top sheen: glossy white fade over the upper third -->
  <linearGradient id="gSheen" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.55"/>
    <stop offset="0.16" stop-color="#ffffff" stop-opacity="0.16"/>
    <stop offset="0.38" stop-color="#ffffff" stop-opacity="0"/>
  </linearGradient>
  <!-- big soft specular highlight, upper-left -->
  <radialGradient id="gSpec" cx="0.3" cy="0.22" r="0.6">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.5"/>
    <stop offset="0.5" stop-color="#ffffff" stop-opacity="0.08"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
  </radialGradient>
  <!-- bottom vignette for depth -->
  <radialGradient id="gVig" cx="0.5" cy="1.05" r="0.75">
    <stop offset="0" stop-color="#003d20" stop-opacity="0.45"/>
    <stop offset="0.6" stop-color="#003d20" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="gArea" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.30"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="gWhite" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff"/>
    <stop offset="1" stop-color="#eafff3"/>
  </linearGradient>
  <filter id="fShadow" x="-25%" y="-25%" width="150%" height="150%">
    <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#0a3d22" flood-opacity="0.45"/>
  </filter>
  <clipPath id="clip"><rect x="{M}" y="{M}" width="{W}" height="{W}" rx="{RX}"/></clipPath>
</defs>

<!-- body + shadow -->
<rect x="{M}" y="{M}" width="{W}" height="{W}" rx="{RX}" fill="url(#gBody)" filter="url(#fShadow)"/>

<g clip-path="url(#clip)">
  <rect x="{M}" y="{M}" width="{W}" height="{W}" fill="url(#gVig)"/>
  <rect x="{M}" y="{M}" width="{W}" height="{W}" fill="url(#gSpec)"/>
  <!-- candlesticks -->
  <!-- soft area fill under the line -->
  <path d="{AREA_D}" fill="url(#gArea)"/>
  <!-- the line: subtle shadow for lift, then white core -->
  <path d="{LINE_D}" fill="none" stroke="#054a28" stroke-opacity="0.35" stroke-width="30" stroke-linecap="round" stroke-linejoin="round" transform="translate(0,8)"/>
  <path d="{LINE_D}" fill="none" stroke="url(#gWhite)" stroke-width="26" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="{LINE_D}" fill="none" stroke="#ffffff" stroke-opacity="0.6" stroke-width="8" stroke-linecap="round" stroke-linejoin="round" transform="translate(0,-5)"/>
  <!-- glossy top sheen on top of everything for the glass read -->
  <rect x="{M}" y="{M}" width="{W}" height="{W}" fill="url(#gSheen)"/>
  <!-- crisp inner rim highlight (top) -->
  <rect x="{M+3}" y="{M+3}" width="{W-6}" height="{W-6}" rx="{RX-3}" fill="none" stroke="#ffffff" stroke-opacity="0.5" stroke-width="2"/>
</g>
</svg>'''
open("/tmp/wickicon/icon_glass.svg","w").write(svg)
print("ok")
