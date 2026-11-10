#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 PWA / Android / iOS 图标（Pillow，4x 超采样抗锯齿）。

运行：.venv/Scripts/python.exe make_icons.py
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageOps

ROOT = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(ROOT, 'static')
AND_WWW = os.path.join(ROOT, 'android', 'assets', 'www')
IOS_WWW = os.path.join(ROOT, 'ios', 'FileSharePhone', 'www')
AND_RES = os.path.join(ROOT, 'android', 'res')
IOS_ICONSET = os.path.join(ROOT, 'ios', 'FileSharePhone',
                           'Assets.xcassets', 'AppIcon.appiconset')

C_A = (108, 92, 231)
C_B = (154, 134, 247)
PURPLE = (108, 92, 231, 255)
WHITE = (255, 255, 255, 255)
TAG = (233, 229, 255, 255)
GREEN = (37, 190, 121, 255)


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_master(size=1024):
    """在 4x 画布上绘制，再 LANCZOS 缩到目标尺寸，得到平滑边缘。"""
    n = size * 4
    u = n / 100.0  # 百分坐标

    # 背景：纵向 + 横向渐变取平均得到对角渐变，再叠加左上柔光
    v = Image.linear_gradient('L').resize((n, n), Image.BICUBIC)
    h = v.transpose(Image.Transpose.ROTATE_90)
    diag = ImageChops.add(v, h, scale=2.0)
    bg = ImageOps.colorize(diag, black=C_A, white=C_B).convert('RGBA')

    glow = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-n * .28, -n * .48, n * .92, n * .46], fill=(255, 255, 255, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(n * .075))
    bg = Image.alpha_composite(bg, glow)

    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    mask = Image.new('L', (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, n - 1, n - 1], radius=int(22.5 * u), fill=255)
    img.paste(bg, (0, 0), mask)

    # 文件夹投影
    shadow = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([20 * u, 39 * u, 80 * u, 78 * u],
                         radius=int(7 * u), fill=(42, 30, 110, 105))
    shadow = shadow.filter(ImageFilter.GaussianBlur(2.2 * u))
    img = Image.alpha_composite(img, shadow)
    d = ImageDraw.Draw(img)

    # 文件夹标签页 + 主体
    d.rounded_rectangle([20 * u, 28 * u, 49 * u, 43 * u],
                        radius=int(3.6 * u), fill=TAG)
    d.rounded_rectangle([19 * u, 37 * u, 81 * u, 75.5 * u],
                        radius=int(7.2 * u), fill=WHITE)

    # 上传箭头（紫色，圆头折线）
    w = int(5.6 * u)
    d.line([(50 * u, 64 * u), (50 * u, 45 * u)], fill=PURPLE, width=w)
    d.line([(39 * u, 54 * u), (50 * u, 43 * u), (61 * u, 54 * u)],
           fill=PURPLE, width=w, joint='curve')
    for p in [(50 * u, 64 * u), (50 * u, 45 * u), (39 * u, 54 * u), (61 * u, 54 * u)]:
        r = w / 2
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=PURPLE)

    # 右下角在线徽标
    d.ellipse([68 * u, 65 * u, 84 * u, 81 * u], fill=WHITE)
    d.ellipse([69.6 * u, 66.6 * u, 82.4 * u, 79.4 * u], fill=GREEN)

    return img.resize((size, size), Image.LANCZOS)


def targets():
    t = [
        (48, [os.path.join(AND_RES, 'mipmap-mdpi', 'ic_launcher.png')]),
        (72, [os.path.join(AND_RES, 'mipmap-hdpi', 'ic_launcher.png')]),
        (96, [os.path.join(AND_RES, 'mipmap-xhdpi', 'ic_launcher.png')]),
        (144, [os.path.join(AND_RES, 'mipmap-xxhdpi', 'ic_launcher.png')]),
        (192, [
            os.path.join(STATIC, 'icon-192.png'),
            os.path.join(AND_WWW, 'icon-192.png'),
            os.path.join(IOS_WWW, 'icon-192.png'),
            os.path.join(AND_RES, 'mipmap', 'ic_launcher.png'),
            os.path.join(AND_RES, 'mipmap-xxxhdpi', 'ic_launcher.png'),
        ]),
        (512, [
            os.path.join(STATIC, 'icon-512.png'),
            os.path.join(AND_WWW, 'icon-512.png'),
            os.path.join(IOS_WWW, 'icon-512.png'),
        ]),
        (180, [
            os.path.join(STATIC, 'apple-touch-icon.png'),
            os.path.join(AND_WWW, 'apple-touch-icon.png'),
            os.path.join(IOS_WWW, 'apple-touch-icon.png'),
        ]),
        (1024, [
            os.path.join(STATIC, 'icon-1024.png'),
            os.path.join(IOS_ICONSET, 'Icon-1024.png'),
        ]),
    ]
    return t


if __name__ == '__main__':
    master = make_master(1024)
    for size, paths in targets():
        im = master if size == 1024 else master.resize((size, size), Image.LANCZOS)
        for p in paths:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            im.save(p)
        print(f'{size:4d}px -> {len(paths)} files')
    print('图标已生成')
