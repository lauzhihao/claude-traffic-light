import math

def defs():
    return '''<defs>
  <radialGradient id="bg" cx="40%" cy="34%" r="80%">
    <stop offset="0%"  stop-color="#E68A64"/>
    <stop offset="55%" stop-color="#CF6A43"/>
    <stop offset="100%" stop-color="#B44E2E"/>
  </radialGradient>
  <radialGradient id="dotG" cx="38%" cy="32%" r="78%">
    <stop offset="0%" stop-color="#63E98A"/>
    <stop offset="100%" stop-color="#1BA046"/>
  </radialGradient>
  <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
    <feGaussianBlur stdDeviation="22" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="ss" x="-50%" y="-50%" width="200%" height="200%">
    <feDropShadow dx="0" dy="9" stdDeviation="16" flood-color="#39140a" flood-opacity="0.25"/>
  </filter>
</defs>'''

def rays(cx, cy, n, r0, rlong, rshort, w, color):
    out=[f'<g filter="url(#ss)">']
    for k in range(n):
        a = k*360.0/n
        r1 = rlong if k%2==0 else rshort
        x = cx - w/2; y = cy - r1; h = r1 - r0
        out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{w/2:.1f}" '
                   f'fill="{color}" transform="rotate({a:.2f} {cx} {cy})"/>')
    out.append(f'<circle cx="{cx}" cy="{cy}" r="{w*0.62:.1f}" fill="{color}"/>')  # 中心合拢
    out.append('</g>')
    return "\n".join(out)

def dot(cx, cy, r, fill):
    return (f'<g filter="url(#glow)">'
            f'<circle cx="{cx}" cy="{cy}" r="{r+15}" fill="#ffffff"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"/></g>')

def build(dot_fill="url(#dotG)"):
    S=1024; cx=cy=S/2
    b=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">',
       defs(), f'<rect width="{S}" height="{S}" fill="url(#bg)"/>',
       rays(cx, cy-12, 12, 24, 300, 226, 46, "#F5EFE4"),
       dot(766, 762, 128, dot_fill), '</svg>']
    return "\n".join(b)

open("/tmp/cticon/master_green.svg","w").write(build("url(#dotG)"))
print("ok")

# 追加:生成无点底图(给 Widget 当背景)
def build_base():
    S=1024; cx=cy=S/2
    b=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">',
       defs(), f'<rect width="{S}" height="{S}" fill="url(#bg)"/>',
       rays(cx, cy, 12, 24, 300, 226, 46, "#F5EFE4"), '</svg>']
    return "\n".join(b)
open("/tmp/cticon/base.svg","w").write(build_base())
print("base ok")
