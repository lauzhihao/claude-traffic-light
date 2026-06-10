# Claude 红绿灯 · Pico MicroPython 固件(三灯同步版 · 黄推理 / 红等你)
# 三颗灯当一个整体、一起显示当前状态:
#   R=推理中   → 三颗一起【黄色呼吸】
#   Y=等你决策 → 三颗一起【红色闪烁】
#   G=完成     → 三颗一起【绿色常亮】
#   0=灭       → 三颗一起灭
# 注:颜色相对常规红绿灯做了对调(推理黄、等你红);动画绑定状态不变(呼吸=推理、闪=等你)。
# 质感:正弦 + gamma 呼吸(顺滑、低端不跳格)、状态间淡入淡出、~50fps。

import sys
import select
import time
import math
from machine import Pin
import neopixel

DATA_PIN = 15
NUM_LEDS = 3
BRIGHTNESS = 255            # 峰值 / 常亮亮度(0-255)

BREATH_PERIOD = 3.0         # 呼吸周期(s)
BREATH_GAMMA = 2.4          # 呼吸 gamma(越大低端越柔)
BREATH_FLOOR = 8            # 呼吸谷底最低亮度(别全灭、避开低端跳格)
BLINK_PERIOD = 0.7          # 闪烁周期(s)
BLINK_DUTY = 0.6            # 闪烁亮占比
TRANS_DUR = 0.35            # 状态切换淡入淡出时长(s)

AMBER = (BRIGHTNESS, int(BRIGHTNESS * 0.5), 0)
RED = (BRIGHTNESS, 0, 0)
GREEN = (0, BRIGHTNESS, 0)
OFF = (0, 0, 0)

np = neopixel.NeoPixel(Pin(DATA_PIN), NUM_LEDS)
disp = [(0, 0, 0)] * NUM_LEDS      # 当前实际显示色(淡入淡出的起点)


def fill(col):
    return [col] * NUM_LEDS        # 三颗灯同色


def render(cols):
    global disp
    for i in range(NUM_LEDS):
        np[i] = cols[i]
    np.write()
    disp = list(cols)


def lerp(a, b, t):
    return (int(a[0] + (b[0] - a[0]) * t),
            int(a[1] + (b[1] - a[1]) * t),
            int(a[2] + (b[2] - a[2]) * t))


def scale(col, level):
    # 把基准色整体亮度缩放到 level(0..BRIGHTNESS),用于"整色呼吸"(不只调单通道)
    return (col[0] * level // BRIGHTNESS,
            col[1] * level // BRIGHTNESS,
            col[2] * level // BRIGHTNESS)


def state_color(s):
    if s == 'R':            # 推理 → 黄
        return AMBER
    if s == 'Y':            # 等你 → 红
        return RED
    if s == 'G':            # 完成 → 绿
        return GREEN
    return OFF


def static_cols(s):
    return fill(state_color(s))     # 静态/过渡落点:三颗同色


def breath_pwm(ph):
    s = (1 - math.cos(2 * math.pi * ph)) / 2     # 正弦 0..1,峰在 ph=0.5
    d = s ** BREATH_GAMMA                         # gamma:渐变感知更均匀
    return int(BREATH_FLOOR + (BRIGHTNESS - BREATH_FLOOR) * d + 0.5)


# 开机自检:三颗灯一起 红→黄→绿 各亮一下(验证三色都接对)
for _c in (RED, AMBER, GREEN):
    render(fill(_c))
    time.sleep(0.18)
render(fill(OFF))

poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

state = '0'
phase = 0.0
trans_from = None          # 不为 None = 正在淡入淡出
trans_start = 0
last = time.ticks_ms()

while True:
    if poll.poll(0):
        ch = sys.stdin.read(1)
        # 同状态字节忽略(配合 agent 每 3s 强制重发,不打断动画)
        if ch in ('R', 'Y', 'G', '0') and ch != state:
            trans_from = list(disp)                # 从当前色淡入淡出到新状态
            trans_start = time.ticks_ms()
            state = ch
            phase = 0.5 if ch == 'R' else 0.0      # 推理(呼吸)从峰值接上过渡终点

    now = time.ticks_ms()
    dt = time.ticks_diff(now, last) / 1000.0
    last = now

    if trans_from is not None:
        t = time.ticks_diff(now, trans_start) / 1000.0 / TRANS_DUR
        if t >= 1.0:
            trans_from = None
            render(static_cols(state))             # 精确落到终点
        else:
            tgt = static_cols(state)
            render([lerp(trans_from[i], tgt[i], t) for i in range(NUM_LEDS)])
    elif state == 'R':         # 推理 → 三颗一起【黄呼吸】
        phase = (phase + dt / BREATH_PERIOD) % 1.0
        render(fill(scale(AMBER, breath_pwm(phase))))
    elif state == 'Y':         # 等你 → 三颗一起【红闪】
        phase = (phase + dt / BLINK_PERIOD) % 1.0
        render(fill(RED if phase < BLINK_DUTY else OFF))
    # G / 0:静态,过渡末已渲染,三颗保持同色不动

    time.sleep_ms(20)
