# 组件面板图标生成脚本（24x24 PNG，蓝色 LCL 风格）
# 用法：python3 gen_icons.py  然后重新生成资源：
#   lazres ../lwdesign_icons.lrs TLWForm.png TLWLoginForm.png TLWFileUpload.png \
#          TLWDBGrid.png TLWDBNavigator.png TLWChart.png TLWGauge.png \
#          TLWColorPicker.png TLWHTMLFrame.png TLWPDFFrame.png
from PIL import Image, ImageDraw

BLUE   = (59, 130, 196, 255); DBLUE = (39, 91, 150, 255)
LBLUE  = (166, 205, 236, 255); GREEN = (86, 156, 74, 255)
ORANGE = (240, 156, 40, 255); RED  = (214, 79, 79, 255)
WHITE  = (255, 255, 255, 255); GRAY = (130, 138, 148, 255)
LGRAY  = (225, 230, 236, 255); TEAL = (52, 152, 140, 255)
S = 24

def canvas():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)

def window(d, x0=2, y0=3, x1=21, y1=20):
    d.rectangle([x0, y0, x1, y1], fill=WHITE, outline=DBLUE)
    d.rectangle([x0, y0, x1, y0+4], fill=BLUE)
    for i, c in enumerate((RED, ORANGE, GREEN)):
        d.rectangle([x0+2+i*3, y0+1, x0+3+i*3, y0+3], fill=c)

def arrow_up(d, x0, y0, h, color):
    cx = x0 + 3
    d.rectangle([cx, y0+4, cx+1, y0+h], fill=color)
    for i, w in enumerate((3, 2, 1)):
        d.line([cx-w, y0+4-i, cx+w+1, y0+4-i], fill=color)

def save(img, name):
    img.save(name + '.png'); print('ok', name)

img, d = canvas(); window(d)
d.ellipse([7, 9, 16, 18], outline=TEAL); d.line([7, 13, 16, 13], fill=TEAL)
save(img, 'TLWForm')

img, d = canvas(); window(d)
d.rectangle([9, 13, 15, 19], fill=ORANGE, outline=DBLUE)
d.arc([10, 9, 14, 14], start=180, end=360, fill=DBLUE)
save(img, 'TLWLoginForm')

img, d = canvas()
d.polygon([(4,2),(14,2),(18,6),(18,21),(4,21)], fill=WHITE, outline=DBLUE)
d.line([14,2,14,6], fill=DBLUE); d.line([14,6,18,6], fill=DBLUE)
arrow_up(d, 8, 8, 12, GREEN); d.rectangle([7, 19, 15, 20], fill=GREEN)
save(img, 'TLWFileUpload')

img, d = canvas()
d.rectangle([2, 3, 21, 20], fill=WHITE, outline=DBLUE)
d.rectangle([2, 3, 21, 7], fill=BLUE)
for x in (9, 15): d.line([x, 3, x, 20], fill=LBLUE)
for y in (11, 15): d.line([2, y, 21, y], fill=LBLUE)
d.rectangle([2, 7, 8, 10], fill=LBLUE); d.rectangle([2, 15, 8, 20], fill=LBLUE)
save(img, 'TLWDBGrid')

img, d = canvas()
d.rectangle([2, 8, 21, 16], fill=LGRAY, outline=GRAY)
def tri(cx, direction, color):
    if direction == 'L': d.polygon([(cx+1, 9), (cx+1, 15), (cx-2, 12)], fill=color)
    else: d.polygon([(cx, 9), (cx, 15), (cx+3, 12)], fill=color)
d.line([4, 9, 4, 15], fill=RED); tri(5, 'L', RED)
tri(11, 'L', ORANGE); tri(13, 'R', GREEN)
tri(18, 'R', BLUE); d.line([19, 9, 19, 15], fill=BLUE)
save(img, 'TLWDBNavigator')

img, d = canvas()
d.rectangle([2, 2, 21, 21], fill=WHITE, outline=DBLUE)
d.rectangle([4, 14, 7, 19], fill=BLUE); d.rectangle([9, 10, 12, 19], fill=GREEN)
d.rectangle([14, 6, 17, 19], fill=ORANGE)
d.line([4, 9, 10, 6], fill=RED); d.line([10, 6, 16, 3], fill=RED)
d.ellipse([15, 2, 17, 4], fill=RED)
save(img, 'TLWChart')

img, d = canvas()
d.arc([3, 5, 21, 21], start=180, end=270, fill=RED, width=3)
d.arc([3, 5, 21, 21], start=270, end=315, fill=ORANGE, width=3)
d.arc([3, 5, 21, 21], start=315, end=360, fill=GREEN, width=3)
d.line([12, 13, 18, 8], fill=DBLUE, width=2)
d.ellipse([10, 11, 14, 15], fill=BLUE, outline=DBLUE)
save(img, 'TLWGauge')

img, d = canvas()
d.rectangle([2, 4, 11, 13], fill=RED, outline=DBLUE)
d.rectangle([12, 4, 21, 13], fill=GREEN, outline=DBLUE)
d.rectangle([2, 14, 11, 21], fill=BLUE, outline=DBLUE)
d.rectangle([12, 14, 21, 21], fill=ORANGE, outline=DBLUE)
d.ellipse([9, 9, 15, 15], fill=WHITE, outline=DBLUE)
save(img, 'TLWColorPicker')

img, d = canvas()
d.polygon([(4,2),(15,2),(19,6),(19,21),(4,21)], fill=WHITE, outline=DBLUE)
d.line([15,2,15,6], fill=DBLUE); d.line([15,6,19,6], fill=DBLUE)
d.rectangle([4, 8, 19, 19], fill=(232, 240, 248, 255))
d.line([9, 10, 6, 14], fill=TEAL); d.line([6, 14, 9, 18], fill=TEAL)
d.line([13, 10, 16, 14], fill=TEAL); d.line([16, 14, 13, 18], fill=TEAL)
d.line([11, 9, 12, 19], fill=GRAY)
save(img, 'TLWHTMLFrame')

img, d = canvas()
d.polygon([(3,2),(14,2),(18,6),(18,21),(3,21)], fill=WHITE, outline=DBLUE)
d.line([14,2,14,6], fill=DBLUE); d.line([14,6,18,6], fill=DBLUE)
d.rectangle([1, 13, 15, 20], fill=RED)
px = [(3,14),(4,14),(5,14),(3,15),(5,15),(3,16),(4,16),(5,16),(5,17),(5,18),
      (7,14),(8,14),(8,15),(8,16),(8,17),(8,18),(7,15),(7,16),(7,17),(7,18),
      (10,14),(11,14),(12,14),(12,15),(12,16),(12,17),(11,17),(10,17),(10,18),(11,18)]
for x, y in px: d.point((x, y), fill=WHITE)
save(img, 'TLWPDFFrame')
