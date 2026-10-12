"""Encode native review frames; optional Pillow tool, never a runtime dependency."""
import argparse
from pathlib import Path
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("frames", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    paths = sorted(args.frames.glob("frame-*.png"))
    if not paths:
        parser.error("No native frame PNGs found")
    # One palette for the full clip avoids independent per-frame color changes.
    palette_source = Image.new("RGB", (640, 360))
    for index in range(16):
        path = paths[round(index * (len(paths) - 1) / 15)]
        with Image.open(path) as frame:
            palette_source.paste(frame.convert("RGB").resize((160, 90)),
                                 ((index % 4) * 160, (index // 4) * 90))
    palette = palette_source.quantize(colors=256)
    frames = []
    for path in paths:
        with Image.open(path) as frame:
            rgb = frame.convert("RGB").resize((960, 540), Image.Resampling.LANCZOS)
            frames.append(rgb.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.output, save_all=True, append_images=frames[1:],
                   duration=125, loop=0, disposal=2, optimize=False)
    print(f"Encoded {len(frames)} native frames: {args.output}")


if __name__ == "__main__":
    main()
