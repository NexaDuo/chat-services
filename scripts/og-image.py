#!/usr/bin/env python3
"""Build the Open Graph preview images under deploy/og-images/ (issue #273).

Standard library only (no ImageMagick, no Pillow), so the files can be rebuilt
on any host.

  scripts/og-image.py default [out.png]
      The platform fallback, deploy/og-images/default.png: two chat bubbles on
      a gradient, no text and no tenant branding.

  scripts/og-image.py compose <logo.png> <out.png>
      A tenant image from a logo on a flat background: the mark is cropped,
      scaled down without distortion and centred on a 1200x630 canvas filled
      with the logo's own background colour. deploy/og-images/nexaduo.png was
      built this way from assets/NexaDuo.png of github.com/NexaDuo/nexaduo.github.io.

deploy/open_graph.rb reads the dimensions from the files, so swapping artwork
needs no code change, only a recreate of chatwoot-rails.
"""
import math
import os
import struct
import sys
import zlib

WIDTH, HEIGHT = 1200, 630
# Largest side of the mark. It stays inside the central 630x630 square, which
# is what square crops (WhatsApp, some Facebook placements) keep.
MARK = 400
# Largest per-channel difference still treated as background noise.
NOISE = 6
SIGNATURE = b'\x89PNG\r\n\x1a\n'
DEPLOY = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'deploy', 'og-images')


def chunk(kind, data):
    body = kind + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)


def write_png(target, rows):
    """rows: HEIGHT bytes objects of WIDTH RGB pixels."""
    raw = bytearray()
    previous = bytes(WIDTH * 3)
    for row in rows:
        # Filter type 2 (Up): flat areas and vertical gradients become zeros.
        raw.append(2)
        raw.extend((a - b) & 0xFF for a, b in zip(row, previous))
        previous = row
    png = (SIGNATURE
           + chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
           + chunk(b'IEND', b''))
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    with open(target, 'wb') as handle:
        handle.write(png)
    print(f'{os.path.relpath(target)}: {WIDTH}x{HEIGHT} PNG, {len(png)} bytes')


def read_png(source):
    """Rows of RGB bytes from an 8-bit, non-interlaced RGB or RGBA PNG."""
    data = open(source, 'rb').read()
    if data[:8] != SIGNATURE:
        sys.exit(f'{source}: not a PNG')
    position, compressed, header = 8, b'', None
    while position < len(data):
        length, kind = struct.unpack('>I4s', data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            compressed += body
        position += 12 + length
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in (2, 6) or interlace:
        sys.exit(f'{source}: only 8-bit non-interlaced RGB/RGBA is supported')
    bpp = 3 if colour == 2 else 4
    stride = width * bpp
    raw = zlib.decompress(compressed)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = previous[i]
                c = previous[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            sys.exit(f'{source}: unknown filter {kind}')
        rows.append(line)
        previous = line
    if bpp == 4:
        # Flatten on the colour of the first pixel (the background we extend).
        base = rows[0][0:3]
        flat = []
        for line in rows:
            out = bytearray(width * 3)
            for x in range(width):
                alpha = line[x * 4 + 3] / 255.0
                for ch in range(3):
                    out[x * 3 + ch] = round(base[ch] + (line[x * 4 + ch] - base[ch]) * alpha)
            flat.append(out)
        rows = flat
    return width, height, rows


def taps(size_in, size_out):
    """Area (box) filter weights: for each output index, [(input index, weight)]."""
    ratio = size_in / size_out
    table = []
    for index in range(size_out):
        start, end = index * ratio, (index + 1) * ratio
        entry = []
        for source in range(int(start), min(size_in, int(math.ceil(end)))):
            weight = min(end, source + 1) - max(start, source)
            if weight > 0:
                entry.append((source, weight / ratio))
        table.append(entry)
    return table


def compose(source, target):
    width, height, rows = read_png(source)
    # The background is sampled from the source, not guessed: the most common
    # colour on its outer border. Encoder noise of a few levels is tolerated
    # and snapped to that colour below, so the extended canvas has no seam.
    border = [rows[0], rows[-1]] + [line[0:3] for line in rows] + [line[-3:] for line in rows]
    counts = {}
    for line in border:
        for x in range(0, len(line), 3):
            pixel = bytes(line[x:x + 3])
            counts[pixel] = counts.get(pixel, 0) + 1
    background = tuple(max(counts, key=counts.get))
    drift = max(abs(value - background[i % 3]) for line in border for i, value in enumerate(line))
    if drift > NOISE:
        sys.exit(f'{source}: the border is not one flat colour (drift {drift}); extending it would leave a seam')

    def differs(line, x):
        return any(abs(line[x * 3 + ch] - background[ch]) > NOISE for ch in range(3))

    ys = [y for y, line in enumerate(rows) if any(differs(line, x) for x in range(width))]
    xs = [x for x in range(width) if any(differs(rows[y], x) for y in ys)]
    left, right, top, bottom = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    scale = min(1.0, MARK / max(right - left, bottom - top))
    out_w, out_h = round((right - left) * scale), round((bottom - top) * scale)

    horizontal, vertical = taps(right - left, out_w), taps(bottom - top, out_h)
    narrow = []
    for line in rows[top:bottom]:
        out = []
        for entry in horizontal:
            for ch in range(3):
                out.append(sum(line[(left + x) * 3 + ch] * weight for x, weight in entry))
        narrow.append(out)
    mark = []
    for entry in vertical:
        line = bytearray(min(255, max(0, round(sum(narrow[y][i] * weight for y, weight in entry))))
                         for i in range(out_w * 3))
        for x in range(out_w):
            if not differs(line, x):
                line[x * 3:x * 3 + 3] = bytes(background)
        mark.append(bytes(line))

    x0, y0 = (WIDTH - out_w) // 2, (HEIGHT - out_h) // 2
    blank = bytes(background) * WIDTH
    canvas = []
    for y in range(HEIGHT):
        if y0 <= y < y0 + out_h:
            canvas.append(blank[:x0 * 3] + mark[y - y0] + blank[(x0 + out_w) * 3:])
        else:
            canvas.append(blank)
    print(f'source {width}x{height}, background rgb{background} (border drift {drift}), '
          f'mark {right - left}x{bottom - top} -> {out_w}x{out_h} at ({x0},{y0})')
    write_png(target, canvas)


def rounded_box(x, y, cx, cy, half_w, half_h, radius):
    """Signed distance to a rounded rectangle (negative inside)."""
    qx, qy = abs(x - cx) - half_w + radius, abs(y - cy) - half_h + radius
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - radius


def half_plane(x, y, ax, ay, bx, by):
    length = math.hypot(bx - ax, by - ay)
    return ((x - ax) * (by - ay) - (y - ay) * (bx - ax)) / length


def triangle(x, y, a, b, c):
    """Signed distance to a triangle (negative inside), for either winding."""
    edges = (half_plane(x, y, *a, *b), half_plane(x, y, *b, *c), half_plane(x, y, *c, *a))
    return max(edges) if half_plane(*c, *a, *b) < 0 else max(-e for e in edges)


def coverage(distance):
    return min(1.0, max(0.0, 0.5 - distance))


def blend(base, colour, alpha):
    return tuple(base[i] + (colour[i] - base[i]) * alpha for i in range(3))


def default_pixel(x, y):
    top, bottom = (24, 44, 84), (38, 110, 150)
    t = y / (HEIGHT - 1)
    colour = tuple(top[i] + (bottom[i] - top[i]) * t for i in range(3))
    # Soft light from the top-left corner.
    glow = max(0.0, 1.0 - math.hypot(x - 180, y - 80) / 900.0)
    colour = blend(colour, (90, 160, 200), 0.35 * glow * glow)

    back = min(rounded_box(x, y, 720, 350, 190, 105, 44),
               triangle(x, y, (800, 440), (880, 440), (872, 512)))
    colour = blend(colour, (150, 196, 222), 0.9 * coverage(back))

    front = min(rounded_box(x, y, 510, 275, 215, 120, 50),
                triangle(x, y, (350, 380), (440, 380), (352, 462)))
    colour = blend(colour, (255, 255, 255), coverage(front))

    for cx in (430, 510, 590):
        colour = blend(colour, (38, 96, 140), coverage(math.hypot(x - cx, y - 275) - 21))
    return bytes(int(round(c)) for c in colour)


def default(target):
    write_png(target, [b''.join(default_pixel(x + 0.5, y + 0.5) for x in range(WIDTH)) for y in range(HEIGHT)])


def main():
    args = sys.argv[1:]
    if args[:1] == ['default'] and len(args) <= 2:
        default(args[1] if len(args) == 2 else os.path.join(DEPLOY, 'default.png'))
    elif args[:1] == ['compose'] and len(args) == 3:
        compose(args[1], args[2])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
