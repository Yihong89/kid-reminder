#!/usr/bin/env python3
"""Crop each paper's comprehension_oeq reading passage (with its printed
line-number margin) out of the scanned PDF, for the macOS app's "show
original scan" toggle -- OEQ questions constantly reference specific lines
("...(line 20)"), which the plain-text passage field has no way to answer
since the OCR transcription flattened the original line breaks.

Needs survey/<slug>/pNNN.png to already exist (render_paper.py). Locates the
passage box on that low-res page image via its printed border, then re-crops
the same region at high dpi straight from the PDF for a crisp result. Some
papers spread the passage across two pages -- CONT_PAGES lists those, and the
two crops are stitched into one image.

Usage:
    python3 crop_passage.py                 # all papers in PAGES
    python3 crop_passage.py mgs taonan       # just these
"""
import sys
from pathlib import Path

import fitz
import numpy as np
from PIL import Image

BASE = Path(__file__).parent
OUT = BASE.parent.parent / "backend" / "epaper-images"
RENDER_DPI = 240

# slug -> 1-indexed page (in survey/<slug>/pNNN.png) holding the start of the
# comprehension_oeq passage. Found by OCR-matching the passage's first few
# words against every page (see git history for the one-off search script).
PAGES = {
    "acsj": 10, "aitong": 13, "catholichigh": 14, "henrypark": 11, "mgs": 9,
    "nanhua": 13, "nanyang": 13, "plmgs": 21, "raffles": 11, "redswastika": 16,
    "rosyth": 11, "scgs": 15, "stnicholas": 18, "taonan": 23,
}

# slug -> second page, for passages long enough to spill onto the next
# printed page. Found by checking the max "(line N)" referenced in that
# paper's questions against how many lines PAGES[slug] alone actually shows.
CONT_PAGES = {
    "catholichigh": 15, "henrypark": 12, "nanhua": 14, "plmgs": 22,
}

# (slug, page_no) -> manual (x0,y0,x1,y1) in the survey PNG's own pixel space,
# for pages where the auto border-line detector misfires (faint scan, or a
# short trailing box whose vertical border run is too short to clear the
# generic column threshold).
MANUAL_BOX = {
    ("scgs", 15): (95, 145, 860, 1285),
}


def find_box(img: Image.Image):
    """Locate the passage's bordered box by its printed border lines: a
    border row/column sustains a much longer contiguous run of dark pixels
    than any line of text ever does (letterforms have gaps; a ruled line
    doesn't). Absolute pixel-run thresholds, not fractions of image size,
    since scan quality (and therefore how solid the ruled line renders)
    varies paper to paper.
    """
    arr = np.array(img.convert("L"))
    h, w = arr.shape
    dark = arr < 180

    def max_run(vec):
        run = best = 0
        for v in vec:
            if v:
                run += 1
                best = max(best, run)
            else:
                run = 0
        return best

    row_hits = [y for y in range(h) if max_run(dark[y, :]) > 100]
    col_hits = [x for x in range(w) if max_run(dark[:, x]) > 60]
    if not row_hits or not col_hits:
        return None
    return (min(col_hits), min(row_hits), max(col_hits), max(row_hits))


def trim_bottom_whitespace(img: Image.Image, pad: int = 20) -> Image.Image:
    """Trim trailing blank rows below the last real line of text.

    Some pages print a box border that runs well past the last line of text,
    down to a footer like "END OF BOOKLET A" -- so the crop's bottom can land
    far below the passage itself. A vertical rule column (the box border, or
    a separate line-number-column divider) is excluded first, since it would
    otherwise look like "content" all the way down. What's left is grouped
    into runs of consecutive dark rows: each real text line is a thick run
    (glyph height plus ascenders/descenders); the box's own horizontal
    bottom-border line is a lone, much thinner run, isolated after a large
    gap. Trailing runs that are far thinner than the median text-line run
    are dropped as border artifacts before picking the true last content row.
    """
    arr = np.array(img.convert("L"))
    h, w = arr.shape
    dark = arr < 180
    col_dark_frac = dark.mean(axis=0)
    content_cols = col_dark_frac <= 0.3
    if not content_cols.any():
        return img
    # A count, not "any": scanned pages carry sparse speckle noise (a handful
    # of stray dark pixels per row) that would otherwise make every row look
    # like it has content. Real text is dozens-to-hundreds of dark pixels
    # per row at this resolution.
    row_dark_count = (arr[:, content_cols] < 200).sum(axis=1)
    mask = row_dark_count > 20
    if not mask.any():
        return img

    runs = []
    i = 0
    while i < h:
        if mask[i]:
            j = i
            while j < h and mask[j]:
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1

    thicknesses = [end - start for start, end in runs]
    median_thickness = sorted(thicknesses)[len(thicknesses) // 2]
    while len(runs) > 1 and (runs[-1][1] - runs[-1][0]) < 0.5 * median_thickness:
        runs.pop()

    last = runs[-1][1] - 1
    return img.crop((0, 0, img.width, min(img.height, last + pad)))


def crop_page(slug: str, page_no: int, doc) -> Image.Image | None:
    survey_png = BASE / "survey" / slug / f"p{page_no:03d}.png"
    low = Image.open(survey_png)
    box = MANUAL_BOX.get((slug, page_no)) or find_box(low)
    if box is None:
        print(f"{slug} p{page_no}: NO BOX on {survey_png}")
        return None
    x0, y0, x1, y1 = box

    page = doc[page_no - 1]
    pr = page.rect
    # The existing survey/ renders are NOT all at a single fixed dpi (some
    # measured ~100dpi, not the 110 render_paper.py's default would give) --
    # so effective dpi is derived per page from the PDF's own point-rect vs
    # the survey PNG's pixel size, instead of assuming a constant.
    dpi_x = low.width * 72 / pr.width
    dpi_y = low.height * 72 / pr.height

    # Outward margin in points -- covers papers that print line numbers just
    # outside the border, without also pulling in the instruction line above
    # or "(Go on to next page)" below.
    mx, my = 16, 6
    pt_x0 = x0 / dpi_x * 72 - mx
    pt_y0 = y0 / dpi_y * 72 - my
    pt_x1 = x1 / dpi_x * 72 + mx
    pt_y1 = y1 / dpi_y * 72 + my
    clip = fitz.Rect(max(pt_x0, 0), max(pt_y0, 0), min(pt_x1, pr.width), min(pt_y1, pr.height))
    try:
        pix = page.get_pixmap(dpi=RENDER_DPI, clip=clip)
    except Exception as e:
        print(f"{slug} p{page_no}: RENDER FAILED box={box} clip={clip}: {e}")
        return None
    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    return trim_bottom_whitespace(img)


def stitch(top: Image.Image, bottom: Image.Image) -> Image.Image:
    w = max(top.width, bottom.width)

    def resize_to_w(im: Image.Image) -> Image.Image:
        if im.width == w:
            return im
        h = round(im.height * w / im.width)
        return im.resize((w, h), Image.LANCZOS)

    top, bottom = resize_to_w(top), resize_to_w(bottom)
    gap = 14
    combined = Image.new("RGB", (w, top.height + gap + bottom.height), "white")
    combined.paste(top, (0, 0))
    combined.paste(bottom, (0, top.height + gap))
    return combined


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ok, fail = [], []
    slugs = sys.argv[1:] or list(PAGES.keys())
    for slug in slugs:
        pdf = BASE / "papers" / f"2025-english-{slug}.pdf"
        doc = fitz.open(pdf)
        img = crop_page(slug, PAGES[slug], doc)
        if img is None:
            fail.append(slug)
            continue
        if slug in CONT_PAGES:
            img2 = crop_page(slug, CONT_PAGES[slug], doc)
            if img2 is None:
                fail.append(slug)
                continue
            img = stitch(img, img2)
        out_path = OUT / f"{slug}-2025-passage.png"
        img.save(out_path)
        print(f"{slug}: -> {out_path} ({img.width}x{img.height})")
        ok.append(slug)

    print(f"\n{len(ok)} ok, {len(fail)} failed: {fail}")


if __name__ == "__main__":
    main()
