# Claude 红绿灯 · Pico MicroPython 固件(三灯版)
# 串口单字节 R/Y/G/0:R=红呼吸 Y=黄快闪 G=绿常亮 0=灭
# 质感:正弦 + gamma 呼吸(渐变顺滑、低端不跳格)、状态间淡入淡出、~50fps。

import sys
import select
import time
import math
from machine import Pin
import neopixel

DATA_PIN = 15
NUM_LEDS = 3
BRIGHTNESS = 255            # 峰值 / 常亮亮度(0-255)
RED_IDX, YELLOW_IDX, GREEN_IDX = 0, 1, 2

BREATH_PERIOD = 3.0         # 红呼吸周期(s),慢一点更从容
BREATH_GAMMA = 2.4          # 呼吸 gamma(越大低端越柔、停留越久,像 Mac 睡眠灯)
BREATH_FLOOR = 8            # 呼吸谷底最低 PWM(别全灭、也避开低端跳格)
YELLOW_PERIOD = 0.7         # 黄快闪周期(s)
YELLOW_DUTY = 0.6           # 黄亮占比
TRANS_DUR = 0.35            # 状态切换淡入淡出时长(s)

AMBER = (BRIGHTNESS, int(BRIGHTNESS * 0.5), 0)

np = neopixel.NeoPixel(Pin(DATA_PIN), NUM_LEDS)
disp = [(0, 0, 0)] * NUM_LEDS      # 当前实际显示色(淡入淡出的起点)


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


def static_cols(s):
    return [(BRIGHTNESS, 0, 0) if s == 'R' else (0, 0, 0),
            AMBER if s == 'Y' else (0, 0, 0),
            (0, BRIGHTNESS, 0) if s == 'G' else (0, 0, 0)]


def breath_pwm(ph):
    s = (1 - math.cos(2 * math.pi * ph)) / 2     # 正弦 0..1,峰在 ph=0.5
    d = s ** BREATH_GAMMA                         # gamma:渐变感知更均匀
    return int(BREATH_FLOOR + (BRIGHTNESS - BREATH_FLOOR) * d + 0.5)


# 开机自检:红→黄→绿 各亮一下
for _s in ('R', 'Y', 'G'):
    render(static_cols(_s))
    time.sleep(0.18)
render(static_cols('0'))

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
            phase = 0.5 if ch == 'R' else 0.0      # 红从峰值接上过渡终点

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
    elif state == 'R':
        phase = (phase + dt / BREATH_PERIOD) % 1.0
        render([(breath_pwm(phase), 0, 0), (0, 0, 0), (0, 0, 0)])
    elif state == 'Y':
        phase = (phase + dt / YELLOW_PERIOD) % 1.0
        render([(0, 0, 0), AMBER if phase < YELLOW_DUTY else (0, 0, 0), (0, 0, 0)])
    # G / 0:静态,过渡末已渲染,保持不动

    time.sleep_ms(20)
