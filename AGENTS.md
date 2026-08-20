# Jolt working rules

## Raster images and icons

Use the `imagegen` skill for raster imagery unless the user explicitly asks for a different medium.

1. Generate one image per distinct creative direction, then inspect the actual outputs before choosing one.
2. Treat the user-selected output as the canonical source: copy it to `art/icon-master.png` and do not redraw or replace it without their direction.
3. Build all macOS icon sizes from that master source with `Scripts/make-icon.sh`; do not invent a second version of the artwork in code.
4. For pixel art, explicitly require large deliberate square pixels, hard edges, no antialiasing, no gradients, no text, no lettering, and no watermark.
5. State the exact palette and make the subject recognizable at small icon sizes.

## Current Jolt icon direction

- A coffee cup with acid-green and mint concentric signal rings on its dark coffee surface, centered on DHR charcoal with no text.
- Palette: `#050608` charcoal, `#b7ff58` acid green, `#77d7b1` mint, and `#eef2e8` off-white.
- The selected artwork in `art/icon-master.png` is the source of truth for this direction.
