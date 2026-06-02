# Claude 红绿灯 · 单 RGB 灯版(适合 RP2040-Zero)
# 一颗 WS2812 切换颜色显示状态,收到串口单字节 R/Y/G/0 切换:
#   R=红(呼吸)  Y=黄(慢闪)  G=绿(常亮)  0=灭
#
# DATA_PIN 默认 15 = 外接单颗 WS2812(VCC→3V3 / GND / DIN→GP15),与 3 灯版接法一致。
# 想用 RP2040-Zero 板载那颗 WS2812(零接线)的话,把 DATA_PIN 改成 16。

import sys
import select
import time
from machine import Pin
import neopixel

DATA_PIN = 15      # 外接单颗 WS2812;板载灯改成 16
NUM_LEDS = 1
BRIGHTNESS = 255   # 0-255(整体亮度:红峰值 / 黄峰值 / 绿常亮 全部满亮 255)

np = neopixel.NeoPixel(Pin(DATA_PIN), NUM_LEDS)

COLORS = {
    'R': (BRIGHTNESS, 0, 0),                      # 红
    'Y': (BRIGHTNESS, int(BRIGHTNESS * 0.5), 0),  # 琥珀黄
    'G': (0, BRIGHTNESS, 0),                       # 绿(常亮,满亮 255)
    '0': (0, 0, 0),                                # 灭
}


def fill(rgb):
    np[0] = rgb
    np.write()


def scale(rgb, f):
    return (int(rgb[0] * f), int(rgb[1] * f), int(rgb[2] * f))


# 开机自检:红→黄→绿 各亮一下
for s in ('R', 'Y', 'G'):
    fill(COLORS[s])
    time.sleep(0.18)
fill((0, 0, 0))

poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

state = '0'
phase = 0.0
last = time.ticks_ms()

while True:
    if poll.poll(0):
        ch = sys.stdin.read(1)
        # 只在状态真的变化时重置;收到与当前相同的状态字节直接忽略,这样
        # agent 周期性强制重发(兜底重连)不会每次打断呼吸/慢闪动画。
        if ch in ('R', 'Y', 'G', '0') and ch != state:
            state = ch
            phase = 0.0
            fill(COLORS[ch])
            last = time.ticks_ms()

    now = time.ticks_ms()
    dt = time.ticks_diff(now, last) / 1000.0
    last = now

    if state == 'R':
        # 呼吸:三角波,约 2s 一循环,亮度 5%~100%
        phase = (phase + dt / 2.0) % 1.0
        f = phase * 2 if phase < 0.5 else 2 - phase * 2
        f = 0.05 + 0.95 * f   # 谷底 5% → 峰值 100%(改第一个数调谷底)
        fill(scale(COLORS['R'], f))
    elif state == 'Y':
        # 快闪:周期 0.7s,亮 ~0.47s 灭 ~0.23s
        phase = (phase + dt / 0.7) % 1.0
        fill(COLORS['Y'] if phase < 0.67 else (0, 0, 0))
    # G / 0 常亮,fill 已处理

    time.sleep_ms(30)
