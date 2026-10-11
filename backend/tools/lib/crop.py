# 데모 전용: 원본 사진을 격자로 잘라 "누끼" 대용 JPEG를 만든다. 실제 분리·배경 제거가 아니다.
# 사용: python -I crop.py <원본> <출력폴더> <개수>  → 표준출력에 각 조각의 bbox(0~1) JSON
import json, sys
from PIL import Image, ImageOps
src, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
img = ImageOps.exif_transpose(Image.open(src)).convert('RGB')
w, h = img.size
cols = n if n <= 3 else 3
rows = (n + cols - 1) // cols
boxes = []
for i in range(n):
    r, c = divmod(i, cols)
    box = [c / cols, r / rows, (c + 1) / cols, (r + 1) / rows]
    piece = img.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))
    piece.thumbnail((640, 640))
    piece.save(f'{out}/item-{i}.jpg', 'JPEG', quality=85)
    # 대표 색: 가운데 영역 평균
    cw, ch = piece.size
    core = piece.crop((cw // 4, ch // 4, cw * 3 // 4, ch * 3 // 4)).resize((1, 1))
    color = '#%02x%02x%02x' % core.getpixel((0, 0))
    boxes.append({'bbox': [round(v, 4) for v in box], 'color_hex': color})
print(json.dumps(boxes))
