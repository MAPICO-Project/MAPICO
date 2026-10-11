# 데모 전용 샘플 이미지 생성기. 실제 사진이 아니라 도형으로 그린 옷이다("SAMPLE" 표기).
# 사용: python -I sample-image.py flatlay <출력.jpg> top:#334455,bottom:#aa8855,...
#       python -I sample-image.py look <출력.jpg> <상의색> <하의색> <배경색>
import sys
from PIL import Image, ImageDraw

def shape(d, kind, box, color):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    cx = x0 + w / 2
    def P(fx, fy): return (x0 + fx * w, y0 + fy * h)
    if kind == 'top':
        d.polygon([P(.3, .15), P(.7, .15), P(.95, .35), P(.82, .48), P(.72, .4), P(.72, .9), P(.28, .9), P(.28, .4), P(.18, .48), P(.05, .35)], fill=color)
    elif kind == 'outerwear':
        d.polygon([P(.28, .1), P(.72, .1), P(.97, .3), P(.97, .9), P(.78, .9), P(.78, .45), P(.74, .95), P(.26, .95), P(.22, .45), P(.22, .9), P(.03, .9), P(.03, .3)], fill=color)
        d.line([P(.5, .12), P(.5, .95)], fill=(30, 30, 30), width=3)
    elif kind == 'bottom':
        d.polygon([P(.25, .08), P(.75, .08), P(.8, .95), P(.56, .95), P(.5, .35), P(.44, .95), P(.2, .95)], fill=color)
    elif kind == 'shoes':
        for off in (0, .42):
            d.rounded_rectangle([P(.08 + off, .45), P(.5 + off, .7)], radius=18, fill=color)
            d.rectangle([P(.08 + off, .66), P(.5 + off, .74)], fill=(240, 240, 240))
    elif kind == 'bag':
        d.arc([P(.3, .1), P(.7, .5)], 180, 360, fill=color, width=10)
        d.rounded_rectangle([P(.15, .3), P(.85, .88)], radius=16, fill=color)
    else:  # accessory: 모자
        d.ellipse([P(.1, .55), P(.9, .75)], fill=color)
        d.pieslice([P(.25, .2), P(.75, .9)], 180, 360, fill=color)

def hexcolor(v): return tuple(int(v[i:i + 2], 16) for i in (1, 3, 5))

mode, out = sys.argv[1], sys.argv[2]
if mode == 'flatlay':
    items = [part.split(':') for part in sys.argv[3].split(',')]
    cols = min(3, len(items)); rows = (len(items) + cols - 1) // cols
    cell = 360
    img = Image.new('RGB', (cell * cols, cell * rows), (236, 232, 226))
    d = ImageDraw.Draw(img)
    for i, (kind, color) in enumerate(items):
        r, c = divmod(i, cols)
        shape(d, kind, (c * cell + 30, r * cell + 30, (c + 1) * cell - 30, (r + 1) * cell - 30), hexcolor(color))
    d.text((8, 6), 'SAMPLE', fill=(150, 150, 150))
    img.save(out, 'JPEG', quality=88)
else:
    top, bottom, bg = (hexcolor(v) for v in sys.argv[3:6])
    img = Image.new('RGB', (720, 960), bg)
    d = ImageDraw.Draw(img)
    d.ellipse([300, 90, 420, 210], fill=(224, 190, 160))
    shape(d, 'top', (170, 210, 550, 560), top)
    shape(d, 'bottom', (220, 520, 500, 900), bottom)
    d.text((10, 8), 'SAMPLE OOTD', fill=(90, 90, 90))
    img.save(out, 'JPEG', quality=88)
