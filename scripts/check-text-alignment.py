#!/usr/bin/env python3
"""Does a text box's placeholder sit on the line you type on? Measured from two verify-app screenshots, not judged by eye.

  scripts/verify-app.sh start <scenario>; (press whatever opens the box)
  scripts/verify-app.sh shot <pid> box-empty        the box empty, placeholder showing
  scripts/verify-app.sh typekeys <pid> "Describe"   some letters with no descenders
  scripts/verify-app.sh shot <pid> box-typed
  scripts/check-text-alignment.py .build/verify/box-empty.png .build/verify/box-typed.png X0 Y0 X1 Y1   (a region around the box's first line, in pixels)

It finds the rows the placeholder's letters cover and the rows the typed letters cover, and compares their tops (the typed word has no
descenders, a placeholder usually has, so the bottoms differ and the tops are the honest comparison). The caret is not used: it blinks, and
a shot can catch it off. Prints the offset in pixels and exits 1 when the tops differ by more than 3 px (about 1.5 pt on a 2x display).
Needs Pillow.
"""
import sys
from PIL import Image


def rows(path, box, minimum):
    image = Image.open(path).convert('RGB')
    x0, y0, x1, y1 = box
    lum = lambda p: sum(p) / 3
    found = [y for y in range(y0, y1)
             if any(lum(image.getpixel((x, y))) > minimum and abs(image.getpixel((x, y))[2] - image.getpixel((x, y))[0]) < 25
                    for x in range(x0, x1))]
    return (min(found), max(found)) if found else None


def main():
    if len(sys.argv) != 7:
        print(__doc__)
        return 2
    empty, typed = sys.argv[1:3]
    box = tuple(int(v) for v in sys.argv[3:7])
    placeholder = rows(empty, box, 80)
    letters = rows(typed, box, 150)
    if not placeholder or not letters:
        print(f'no text found: placeholder {placeholder}, typed {letters}: check the region')
        return 2
    offset = placeholder[0] - letters[0]
    print(f'placeholder rows {placeholder}, typed rows {letters}: the placeholder is {offset:+d} px from the line you type on')
    return 0 if abs(offset) <= 3 else 1


sys.exit(main())
