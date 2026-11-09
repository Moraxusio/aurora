"""Rasterize Aurora 3's original geometric mark with stdlib only.

Source artwork: app/assets/branding/aurora3.svg. Generates anti-aliased RGBA
PNG and PNG-framed multi-size Windows ICO; no external/GPL assets or fonts.
Run with Python 3: python tools/icon3.py
"""
from pathlib import Path
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def curve(points, controls, count=40):
    p0 = points[-1]
    a, b, end = controls
    for i in range(1, count + 1):
        t = i / count
        u = 1 - t
        points.append((u*u*u*p0[0] + 3*u*u*t*a[0] + 3*u*t*t*b[0] + t*t*t*end[0],
                       u*u*u*p0[1] + 3*u*u*t*a[1] + 3*u*t*t*b[1] + t*t*t*end[1]))


def quad(points, control, end):
    start = points[-1]
    curve(points, ((start[0] + (control[0]-start[0])*2/3, start[1] + (control[1]-start[1])*2/3),
                   (end[0] + (control[0]-end[0])*2/3, end[1] + (control[1]-end[1])*2/3), end), 20)


def png(width, pixels):
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data) & 0xffffffff)
    rows = b''.join(b'\0' + pixels[y*width*4:(y+1)*width*4] for y in range(width))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, width, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')


def render(size):
    scale = 4
    width = size * scale
    factor = width / 256
    pixels = bytearray(width * width * 4)

    def color(a, b, x, y):
        t = max(0, min(1, (x+y) / (2*width)))
        return bytes((round(a[0]*(1-t)+b[0]*t), round(a[1]*(1-t)+b[1]*t), round(a[2]*(1-t)+b[2]*t), 255))

    def rect(x0, y0, x1, y1, radius, a, b):
        x0, y0, x1, y1, radius = [v * factor for v in (x0, y0, x1, y1, radius)]
        for y in range(max(0, int(y0)), min(width, math.ceil(y1))):
            cy = max(y0 + radius, min(y + .5, y1 - radius))
            extent = math.sqrt(max(0, radius*radius - (y+.5-cy)**2))
            left = x0 + radius - extent
            right = x1 - radius + extent
            for x in range(max(0, math.ceil(left-.5)), min(width, math.ceil(right-.5))):
                i = (y*width + x)*4
                pixels[i:i+4] = color(a, b, x, y)

    def polygon(points, a, b):
        points = [(x*factor, y*factor) for x, y in points]
        for y in range(max(0, int(min(y for _, y in points))), min(width, math.ceil(max(y for _, y in points)))):
            yy = y + .5
            intersections = []
            for i, (x0, y0) in enumerate(points):
                x1, y1 = points[(i+1) % len(points)]
                if (y0 <= yy < y1) or (y1 <= yy < y0):
                    intersections.append(x0 + (yy-y0)*(x1-x0)/(y1-y0))
            intersections.sort()
            for left, right in zip(intersections[0::2], intersections[1::2]):
                for x in range(max(0, math.ceil(left-.5)), min(width, math.ceil(right-.5))):
                    i = (y*width + x)*4
                    pixels[i:i+4] = color(a, b, x, y)

    rect(8, 8, 248, 248, 54, (20, 39, 71), (20, 19, 47))
    peak = [(40, 190), (106, 54)]
    quad(peak, (111, 42), (126, 42))
    peak += [(142, 42), (212, 190), (174, 190), (127, 87), (79, 190)]
    polygon(peak, (100, 240, 220), (73, 137, 255))
    ribbon = [(43, 175)]
    curve(ribbon, ((80, 122), (111, 180), (149, 132)))
    curve(ribbon, ((166, 109), (185, 105), (208, 111)))
    ribbon += [(219, 143)]
    curve(ribbon, ((177, 124), (169, 196), (127, 178)))
    curve(ribbon, ((90, 160), (78, 204), (46, 211)))
    polygon(ribbon, (143, 121, 255), (215, 126, 240))
    rect(165, 165, 241, 241, 23, (120, 134, 221), (120, 134, 221))
    rect(167, 167, 239, 239, 21, (19, 36, 64), (19, 36, 64))
    three = [(183, 181), (209, 181)]
    quad(three, (225, 181), (225, 195))
    quad(three, (225, 203), (217, 207))
    quad(three, (225, 211), (225, 219))
    quad(three, (225, 233), (209, 233))
    three += [(183, 233), (183, 221), (208, 221)]
    quad(three, (213, 221), (213, 217))
    quad(three, (213, 213), (207, 213))
    three += [(195, 213), (195, 201), (207, 201)]
    quad(three, (213, 201), (213, 197))
    quad(three, (213, 193), (208, 193))
    three += [(183, 193)]
    polygon(three, (237, 244, 255), (237, 244, 255))
    reduced = bytearray(size*size*4)
    for y in range(size):
        for x in range(size):
            src = [((y*scale+dy)*width+x*scale+dx)*4 for dy in range(scale) for dx in range(scale)]
            dst = (y*size+x)*4
            # Average premultiplied colours to avoid dark transparent fringes.
            alpha = sum(pixels[i+3] for i in src)
            reduced[dst+3] = round(alpha / (scale*scale))
            if alpha:
                for c in range(3):
                    reduced[dst+c] = round(sum(pixels[i+c]*pixels[i+3] for i in src) / alpha)
    return png(size, reduced)


def main():
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    images = [render(s) for s in sizes]
    assets = ROOT / 'app/assets/branding'
    assets.mkdir(parents=True, exist_ok=True)
    (assets / 'aurora3-256.png').write_bytes(images[-1])
    offset = 6 + 16*len(sizes)
    headers = []
    for size, data in zip(sizes, images):
        headers.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    icon = ROOT / 'app/windows/runner/resources/app_icon.ico'
    icon.write_bytes(struct.pack('<HHH', 0, 1, len(sizes)) + b''.join(headers) + b''.join(images))
    print(f'Generated original Aurora 3 PNG and ICO ({len(sizes)} sizes)')


if __name__ == '__main__':
    main()
