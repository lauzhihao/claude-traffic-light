import math

def defs():
    return '''<defs>
  <radialGradient id="bg" cx="42%" cy="36%" r="82%">
    <stop offset="0%"  stop-color="#EA8C6C"/>
    <stop offset="58%" stop-color="#DC7351"/>
    <stop offset="100%" stop-color="#C85D3D"/>
  </radialGradient>
  <filter id="ss" x="-50%" y="-50%" width="200%" height="200%">
    <feDropShadow dx="0" dy="8" stdDeviation="14" flood-color="#3a140a" flood-opacity="0.22"/>
  </filter>
</defs>'''

def rays(cx, cy, n, r0, w, color, base, amp, phase_deg):
    # 有机不对称星芒:每道光长度随角度正弦变化(关于竖轴不对称→镜像可见)
    out=[f'<g filter="url(#ss)">']
    for k in range(n):
        a = k*360.0/n
        r1 = base + amp*math.sin(math.radians(a) + math.radians(phase_deg))
        x = cx - w/2; y = cy - r1; h = r1 - r0
        out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{w/2:.1f}" '
                   f'fill="{color}" transform="rotate({a:.2f} {cx} {cy})"/>')
    out.append(f'<circle cx="{cx}" cy="{cy}" r="{w*0.6:.1f}" fill="{color}"/>')
    out.append('</g>')
    return "\n".join(out)

def build(mirror=True):
    S=1024; cx=cy=S/2
    star = rays(cx, cy, 12, 24, 52, "#F4EEE2", base=316, amp=80, phase_deg=35)
    if mirror:   # 水平镜像(关于 x=512),和 Claude 原标朝向相反
        star = f'<g transform="translate({S},0) scale(-1,1)">{star}</g>'
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">',
        defs(), f'<rect width="{S}" height="{S}" fill="url(#bg)"/>', star, '</svg>'])

open("/tmp/cticon/icon2.svg","w").write(build(mirror=True))
print("ok")
