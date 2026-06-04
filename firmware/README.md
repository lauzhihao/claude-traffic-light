# Pico 端固件

MicroPython，监听 USB 串口的单字节**状态**命令（`R`/`Y`/`G`/`0`），3 颗 WS2812 灯**一起同步**显示同一动画——字节代表状态、不是颜色：

| 字节 | 状态 | 三灯一起的效果 |
|---|---|---|
| `R` | 推理 | 黄色呼吸 |
| `Y` | 等你决策 | 红色闪烁 |
| `G` | 空闲 / 完成 | 绿色常亮 |
| `0` | 无 | 灭 |

## 一次性烧录 MicroPython

1. 下载 Pico 对应的 `.uf2` 固件：<https://micropython.org/download/RPI_PICO/>（Pico 2 用 `RPI_PICO2`）
2. **按住 Pico 板上的白色 BOOTSEL 键不放**，用 USB 线插电脑
3. 电脑弹出名为 `RPI-RP2` 的 U 盘
4. 把刚下的 `.uf2` 拖进去
5. U 盘自动消失、Pico 重启 → MicroPython 装好

## 部署 main.py

装 [Thonny](https://thonny.org)（最友好的 MicroPython IDE）：

1. 打开 Thonny → Run 菜单 → Configure interpreter → 选 `MicroPython (Raspberry Pi Pico)`
2. 打开本目录的 `main.py`
3. 文件 → 另存为... → 选 `Raspberry Pi Pico` → 文件名输入 `main.py`（必须叫这个名字才会开机自动运行）
4. 保存

或者用命令行 `mpremote`：

```bash
pip install mpremote
mpremote connect auto fs cp main.py :main.py
mpremote connect auto reset
```

## 测试

任意串口工具发字节：

```bash
# macOS / Linux
echo -n R > /dev/tty.usbmodem*   # 或 /dev/ttyACM0
echo -n Y > /dev/tty.usbmodem*
echo -n G > /dev/tty.usbmodem*
echo -n 0 > /dev/tty.usbmodem*   # 关灯
```

预期：开机自检三灯一起 黄→红→绿 各闪一下，然后每次收到状态字节三灯一起切：`R`=黄色呼吸、`Y`=红色闪烁、`G`=绿色常亮、`0`=灭。

## 接线提醒

- Pico `3V3` → 三颗 WS2812 的 VCC（并联）
- Pico `GND` → 三颗 WS2812 的 GND（并联）
- Pico `GP15` → 第一颗 WS2812 的 DIN
- LED1.DOUT → LED2.DIN → LED3.DIN（菊花链）

详见 `../HARDWARE.md`。

## 调优

- `BRIGHTNESS` 调亮度（0-255），晚上桌面用 60-80 不刺眼
- `DATA_PIN` 想换别的 GPIO 改这里
- 颜色：黄（琥珀）= `AMBER = (B, B/2, 0)`、红 = `RED`、绿 = `GREEN`，按口味改;想改“状态↔颜色”的对应,调 `static_cols()` 和 `R`/`Y` 两段渲染即可
