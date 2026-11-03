#!/usr/bin/env python3
"""Side-by-side images of each design artboard and the app's screenshot of the matching scenario, for docs/design/chat-feed/PARITY.md.

  scripts/render-artboards.sh <artboard-dir>                  the artboards, rendered with docs/design/chat-feed/support.js
  WORKBENCH_CHAT_FEED=1 VERIFY_WINDOW_SIZE=1240x800 scripts/verify-app.sh start <scenario>   then `shot <pid> <name>` for each pair below
  scripts/design-pairs.py <artboard-dir> <app-shot-dir> <out-dir>

Needs Pillow. The app screenshot is scaled to the artboard's width; the app's own title bar makes it a few points taller.
"""
import sys
from PIL import Image, ImageDraw

PAIRS = [('Main', 'A-chat'), ('Main', 'A-chat-replying'), ('B-Goal', 'B-draft'), ('B-Goal', 'B-goal-approved'),
         ('C-Run', 'C-running'), ('D-Verify', 'D-needs-you'), ('D-Verify', 'D-review-changes'), ('F-Tasks', 'F-tasks'),
         ('F-Tasks', 'F-tasks-empty'), ('G-NewThread', 'G-new-goal'), ('Rail', 'Rail-threads')]

art_dir, app_dir, out_dir = sys.argv[1:4]
for art, app in PAIRS:
    try:
        a = Image.open(f'{art_dir}/{art}.png').convert('RGB')
        p = Image.open(f'{app_dir}/{app}.png').convert('RGB')
    except FileNotFoundError as error:
        print('skip', art, app, error)
        continue
    w = a.width
    if art == 'Rail':
        # The rail artboard is only the rail: take the app's rail (the left sixth, below the toolbar) at the same height.
        p = p.crop((0, round(p.height * 0.1), round(p.width * 0.2), p.height))
        p = p.resize((round(p.width * a.height / p.height), a.height), Image.LANCZOS)
        w = max(a.width, p.width)
    else:
        p = p.resize((w, round(p.height * w / p.width)), Image.LANCZOS)
    out = Image.new('RGB', (w * 2 + 30, max(a.height, p.height) + 30), (60, 60, 60))
    draw = ImageDraw.Draw(out)
    draw.text((8, 8), f'design: {art}', fill=(255, 255, 255))
    draw.text((w + 38, 8), f'app: {app}', fill=(255, 255, 255))
    out.paste(a, (0, 30))
    out.paste(p, (w + 30, 30))
    # A palette keeps these small enough to commit.
    out.quantize(colors=96, method=Image.Quantize.MEDIANCUT).save(f'{out_dir}/{art}__{app}.png', optimize=True)
    print('ok', art, app)
