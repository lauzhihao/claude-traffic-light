# Claude 红绿灯 · 单 RGB 灯版(适合 RP2040-Zero)
# 一颗 WS2812 切色显示状态:R=红呼吸 Y=黄快闪 G=绿常亮 0=灭
# 质感:正弦 + gamma 呼吸(渐变顺滑、低端不跳格)、状态间淡入淡出、~50fps。
#
# DATA_PIN 默认 15 = 外接单颗 WS2812(VCC→3V3 / GND / DIN→GP15)。
# 用 RP2040-Zero 板载那颗 WS2812(零接线)把 DATA_PIN 改成 16。

import sys
import select
import time
import math
from machine import Pin
import neopixel

DATA_PIN = 15              # 外接单颗 WS2812;板载灯改成 16
NUM_LEDS = 1
BRIGHTNESS = 255          # 峰值 / 常亮亮度(0-255)

BREATH_PERIOD = 3.0        # 红呼吸周期(s),慢一点更从容
BREATH_GAMMA = 2.4         # 呼吸 gamma(越大低端越柔、停留越久,像 Mac 睡眠灯)
BREATH_FLOOR = 8           # 呼吸谷底最低 PWM(别全灭、也避开低端跳格)
YELLOW_PERIOD = 0.7        # 黄快闪周期(s)
YELLOW_DUTY = 0.6          # 黄亮占比
TRANS_DUR = 0.35           # 状态切换淡入淡出时长(s)

RED = (BRIGHTNESS, 0, 0)
AMBER = (BRIGHTNESS, int(BRIGHTNESS * 0.5), 0)
GREEN = (0, BRIGHTNESS, 0)
OFF = (0, 0, 0)
BASE = {'R': RED, 'Y': AMBER, 'G': GREEN, '0': OFF}

np = neopixel.NeoPixel(Pin(DATA_PIN), NUM_LEDS)
disp = OFF                 # 当前实际显示色(淡入淡出的起点)


def render(rgb):
    global disp
    np[0] = rgb
    np.write()
    disp = rgb


def lerp(a, b, t):
    return (int(a[0] + (b[0] - a[0]) * t),
            int(a[1] + (b[1] - a[1]) * t),
            int(a[2] + (b[2] - a[2]) * t))


def scale(rgb, f):
    return (int(rgb[0] * f), int(rgb[1] * f), int(rgb[2] * f))


def breath_f(ph):
    s = (1 - math.cos(2 * math.pi * ph)) / 2     # 正弦 0..1,峰在 ph=0.5
    d = s ** BREATH_GAMMA                         # gamma:渐变感知更均匀
    return (BREATH_FLOOR + (255 - BREATH_FLOOR) * d) / 255.0


# 开机自检:红→黄→绿 各亮一下
for _s in ('R', 'Y', 'G'):
    render(BASE[_s])
    time.sleep(0.18)
render(OFF)

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
            trans_from = disp                      # 从当前色淡入淡出到新状态
            trans_start = time.ticks_ms()
            state = ch
            phase = 0.5 if ch == 'R' else 0.0      # 红从峰值接上过渡终点

    now = time.ticks_ms()
    dt = time.ticks_diff(now, last) / 1000.0
    last = now

    if trans_from is not None:
        t = time.ticks_diff(now, trans_start) / 1000.0 / TRANS_DUR
        if t >= 1.0:
            trans_from = None
            render(BASE[state])                    # 精确落到终点
        else:
            render(lerp(trans_from, BASE[state], t))
    elif state == 'R':
        phase = (phase + dt / BREATH_PERIOD) % 1.0
        render(scale(RED, breath_f(phase)))
    elif state == 'Y':
        phase = (phase + dt / YELLOW_PERIOD) % 1.0
        render(AMBER if phase < YELLOW_DUTY else OFF)
    # G / 0:静态,过渡末已渲染,保持不动

    time.sleep_ms(20)
