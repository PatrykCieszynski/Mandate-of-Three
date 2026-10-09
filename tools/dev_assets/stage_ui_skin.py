"""Stage exact, individual legacy PNGs behind semantic UI skin names. No resampling."""
from pathlib import Path
import hashlib, json, shutil
ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'dev_assets/legacy/ui_cache'
TARGET = ROOT / 'source/client/ui_web/web/inventory/legacy_skin'
CHROME = {
    'corner-tl':'pattern/board_corner_lefttop.tga.png',
    'corner-tr':'pattern/board_corner_righttop.tga.png',
    'corner-bl':'pattern/board_corner_leftbottom.tga.png',
    'corner-br':'pattern/board_corner_rightbottom.tga.png',
    'edge-top':'pattern/board_line_top.tga.png', 'edge-bottom':'pattern/board_line_bottom.tga.png',
    'edge-left':'pattern/board_line_left.tga.png', 'edge-right':'pattern/board_line_right.tga.png',
    'window-fill':'pattern/board_base.tga.png', 'title-center':'pattern/titlebar_center.tga.png',
    'close-normal':'public/close_button_01.sub.png', 'close-hover':'public/close_button_02.sub.png',
    'close-pressed':'public/close_button_03.sub.png', 'slot':'public/slot_base.sub.png',
    'yang':'game/windows/money_icon.sub.png',
}
ICONS = {'iron_sword':'item/00010.tga.png', 'short_sword':'item/00020.tga.png', 'potion':'item/27001.tga.png'}
def stage():
    TARGET.mkdir(parents=True,exist_ok=True)
    skin = {'chrome':{},'icons':{}}
    for category, entries in [('chrome',CHROME),('icons',ICONS)]:
        for name, relative in entries.items():
            source = CACHE / relative
            if not source.exists():
                print('Missing optional skin asset:', relative)
                continue
            target = TARGET / (name+'.png')
            shutil.copyfile(source,target)
            if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
                raise RuntimeError('Skin copy differs from source')
            skin[category][name] = './legacy_skin/'+target.name
    (TARGET/'skin.js').write_text('export const skin = '+json.dumps(skin)+';\n',encoding='utf-8')
    print('Staged',sum(map(len,skin.values())),'exact PNGs; no resize/retouch, no atlas coordinates')
if __name__ == '__main__': stage()
