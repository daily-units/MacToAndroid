#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
"""把带透明边距的方形底图裁剪并填充成**满幅不透明**的 PNG，供 build.sh 切 iconset。

为什么 macOS 需要满幅图：macOS 26 的图标系统会给「带透明边距的旧格式图标」自动垫一层
浅色底板，把图缩小放在中间（Chrome 的圆形 logo 就是这个效果）。要得到 Mail、Journal
那种满幅观感，图必须满幅不透明、由系统自己切圆角。

为什么手写：这台机器上没有任何图形库（无 PIL / cairosvg / ImageMagick / rsvg-convert），
而 qlmanage 渲染 SVG 时会把透明区域合成到白底，做不出 alpha。所以 PNG 的解码、
合成、编码全部自己实现。

做法：逐行/逐列找出 alpha 不为 0 的范围，裁掉透明边距；半透明像素按徽章底色合成，
底色取自徽章内部往里 24px 处——不能取边缘，那里通常是描边高光。

用法:
    make-icon.py 源图.png 输出.png --full-bleed [--inset-sample N]
"""
import struct
import sys
import zlib


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def decode_png(path):
    """返回 (w, h, nch, rows)。仅支持 8 位、非隔行、颜色类型 2/6。"""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        die(f"不是 PNG: {path}")

    w = h = ctype = bit = None
    interlace = 0
    idat = bytearray()
    i = 8
    while i < len(data):
        ln = struct.unpack('>I', data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        if typ == b'IHDR':
            w, h, bit, ctype, _c, _f, interlace = struct.unpack('>IIBBBBB', data[i + 8:i + 21])
        elif typ == b'IDAT':
            idat += data[i + 8:i + 8 + ln]
        i += 12 + ln

    if bit != 8 or ctype not in (2, 6) or interlace:
        die(f"仅支持 8 位非隔行的 RGB/RGBA PNG，当前 bit={bit} ctype={ctype} interlace={interlace}")

    nch = 3 if ctype == 2 else 4
    stride = w * nch
    raw = zlib.decompress(bytes(idat))

    rows = []
    prev = bytes(stride)
    pos = 0
    for _y in range(h):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 0:
            pass
        elif f == 1:
            for x in range(nch, stride):
                line[x] = (line[x] + line[x - nch]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - nch] if x >= nch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - nch] if x >= nch else 0
                b = prev[x]
                c = prev[x - nch] if x >= nch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        else:
            die(f"未知的行过滤类型 {f}")
        rows.append(bytes(line))
        prev = line

    return w, h, nch, rows

def encode_rgba(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    idat = zlib.compress(raw, 6)

    def chunk(typ, payload):
        return (struct.pack('>I', len(payload)) + typ + payload
                + struct.pack('>I', zlib.crc32(typ + payload) & 0xFFFFFFFF))

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', idat))
        f.write(chunk(b'IEND', b''))

def full_bleed(w, h, nch, rows, sample_inset=24):
    """裁掉透明边距并把半透明处按徽章底色合成，输出满幅不透明的正方形。

    填充色取自徽章内部往里 sample_inset 像素处——不能取边缘，那里通常是描边高光。
    """
    if nch != 4:
        die("--full-bleed 需要带 alpha 的底图；不带 alpha 的图本身就是满幅的")

    x0, y0, x1, y1 = w, h, -1, -1
    for y in range(h):
        r = rows[y]
        for x in range(w):
            if r[x * 4 + 3] > 128:
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
    if x1 < 0:
        die("整张图都是透明的")

    mid = (y0 + y1) // 2
    o = min(x0 + sample_inset, x1) * 4
    bg = (rows[mid][o], rows[mid][o + 1], rows[mid][o + 2])

    side = max(x1 - x0 + 1, y1 - y0 + 1)
    cx, cy = (x0 + x1 + 1) // 2, (y0 + y1 + 1) // 2
    sx, sy = cx - side // 2, cy - side // 2

    out = []
    for j in range(side):
        y = sy + j
        row = bytearray(side * 4)
        for i in range(side):
            x = sx + i
            k = i * 4
            row[k + 3] = 255                    # 满幅：alpha 全不透明
            if 0 <= x < w and 0 <= y < h:
                p = rows[y]
                q = x * 4
                a = p[q + 3]
                if a == 255:
                    row[k], row[k + 1], row[k + 2] = p[q], p[q + 1], p[q + 2]
                elif a == 0:
                    row[k], row[k + 1], row[k + 2] = bg
                else:
                    for c in range(3):
                        row[k + c] = (p[q + c] * a + bg[c] * (255 - a)) // 255
            else:
                row[k], row[k + 1], row[k + 2] = bg
        out.append(row)

    print(f"满幅: 徽章 {x1-x0+1}x{y1-y0+1} @ ({x0},{y0})  输出 {side}x{side}  填充色 RGB{bg}")
    return side, out

def main():
    args = sys.argv[1:]
    if len(args) < 2:
        die(__doc__)
    src, out = args[0], args[1]
    sample_inset = 24
    i = 2
    while i < len(args):
        key = args[i]
        if key == '--full-bleed':      # 只剩这一个模式，保留这个开关是为了兼容 build.sh 的调用
            i += 1
            continue
        if key == '--inset-sample':
            sample_inset = int(args[i + 1]); i += 2
            continue
        die(f"未知参数: {key}")

    w, h, nch, rows = decode_png(src)
    fside, frows = full_bleed(w, h, nch, rows, sample_inset)
    encode_rgba(out, fside, fside, frows)
    print(f"输出 {fside}x{fside} 满幅不透明  ->  {out}")


if __name__ == '__main__':
    main()
