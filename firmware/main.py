# Claude 红绿灯 · Pico MicroPython 固件
# 监听 USB 串口，收到 'R'/'Y'/'G' 字节后切换对应灯。
# 红灯有呼吸效果，黄灯慢闪，绿灯常亮。

import sys
import select
import time
from machine import Pin
import neopixel

DATA_PIN = 15
NUM_LEDS = 3
BRIGHTNESS = 80   # 0-255，调亮度

RED_IDX, YELLOW_IDX, GREEN_IDX = 0, 1, 2

np = neopixel.NeoPixel(Pin(DATA_PIN), NUM_LEDS)


def set_all(rgb):
    for i in range(NUM_LEDS):
        np[i] = rgb
    np.write()


def scale(rgb, factor):
    return (int(rgb[0] * factor), int(rgb[1] * factor), int(rgb[2] * factor))


def show_static(state):
    np[RED_IDX] = (BRIGHTNESS, 0, 0) if state == 'R' else (0, 0, 0)
    np[YELLOW_IDX] = (BRIGHTNESS, int(BRIGHTNESS * 0.45), 0) if state == 'Y' else (0, 0, 0)
    np[GREEN_IDX] = (0, BRIGHTNESS, 0) if state == 'G' else (0, 0, 0)
    np.write()


# 开机自检：红黄绿依次亮一下
for s in ('R', 'Y', 'G'):
    show_static(s)
    time.sleep(0.18)
show_static('0')


poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

state = '0'
last_anim = time.ticks_ms()
phase = 0.0


def animate(state, now):
    global phase
    dt = time.ticks_diff(now, last_anim) / 1000.0
    if state == 'R':
        # 呼吸：sin 波，周期约 2s
        phase = (phase + dt / 2.0) % 1.0
        # 三角波更便宜
        f = phase * 2 if phase < 0.5 else 2 - phase * 2
        f = 0.25 + 0.75 * f
        np[RED_IDX] = scale((BRIGHTNESS, 0, 0), f)
        np[YELLOW_IDX] = (0, 0, 0)
        np[GREEN_IDX] = (0, 0, 0)
        np.write()
    elif state == 'Y':
        # 慢闪：周期 1.2s，亮 0.8s 灭 0.4s
        phase = (phase + dt / 1.2) % 1.0
        on = phase < 0.67
        np[RED_IDX] = (0, 0, 0)
        np[YELLOW_IDX] = (BRIGHTNESS, int(BRIGHTNESS * 0.45), 0) if on else (0, 0, 0)
        np[GREEN_IDX] = (0, 0, 0)
        np.write()
    # G 和 0 不动画，show_static 已经处理


while True:
    if poll.poll(0):
        ch = sys.stdin.read(1)
        if ch in ('R', 'Y', 'G', '0'):
            state = ch
            phase = 0.0
            show_static(state)
            last_anim = time.ticks_ms()
    now = time.ticks_ms()
    if state in ('R', 'Y'):
        animate(state, now)
        last_anim = now
    time.sleep_ms(30)
