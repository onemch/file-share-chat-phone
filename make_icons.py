#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 PWA 图标（纯标准库，无需 Pillow）。运行：python make_icons.py"""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'static')
BG_A = (108, 92, 231)
BG_B = (154, 134, 247)


def rounded(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x <= x1 and y0 <= y <= y1):
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def rgba(size):
    rows = []
    for py in range(size):
        row = bytearray()
        y = py / size
        for px in range(size):
            x = px / size

            # 圆角背景 + 对角渐变
            if not rounded(x, y, 0.0, 0.0, 1.0, 1.0, 0.22):
                row.extend((0, 0, 0, 0))
                continue
            t = min(1.0, (x * 0.55 + y * 0.45))
            r = int(BG_A[0] + (BG_B[0] - BG_A[0]) * t)
            g = int(BG_A[1] + (BG_B[1] - BG_A[1]) * t)
            b = int(BG_A[2] + (BG_B[2] - BG_A[2]) * t)

            # 白色文件夹（标签 + 主体）
            tag = rounded(x, y, 0.21, 0.30, 0.48, 0.43, 0.035)
            body = rounded(x, y, 0.20, 0.38, 0.80, 0.75, 0.065)
            if tag or body:
                r = g = b = 255

            # 紫色向上箭头（在文件夹上镂空）
            shaft = 0.468 <= x <= 0.532 and 0.455 <= y <= 0.645
            head = 0.355 <= y <= 0.505 and abs(x - 0.5) <= 0.125 * ((y - 0.355) / 0.15)
            if shaft or head:
                r, g, b = 108, 92, 231

            row.extend((r, g, b, 255))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b''.join(b'\x00' + row for row in rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for size in (192, 512):
        rows = rgba(size)
        write_png(os.path.join(OUT, f'icon-{size}.png'), size, rows)
        print(f'icon-{size}.png')
    write_png(os.path.join(OUT, 'apple-touch-icon.png'), 192, rgba(192))
    print('apple-touch-icon.png')
