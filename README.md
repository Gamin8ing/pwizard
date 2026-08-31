# PWizard

Merge one or more PDFs / images into a single output file — either one
flattened JPEG, or a real multi-page PDF — and compress it to fit under a
target file size. Built for the classic "government/university portal wants
a scanned document under 100KB" problem.

## Features

- Accepts **any mix** of PDFs, JPGs, and PNGs, in any order, any count
- **Two distinct output modes**, chosen by the extension you give `-o`:
  - `-o out.jpg` / `out.jpeg` — every page from every input is stacked into
    **one flattened image** (vertical or horizontal via `-m`), then
    compressed as a single JPEG.
  - `-o out.pdf` — every page is kept **separate**, in the same order given,
    and assembled into a **real multi-page PDF** (not a flattened image
    wrapped in a PDF shell).
- Renders **every page** of a multi-page PDF input by default (not just the
  first) — pick a specific page/range with `-p`
- Iteratively lowers JPEG quality to hit your size target with minimal
  quality loss, then falls back to resizing / grayscale if needed
- Flags can go anywhere on the command line — before, after, or between
  filenames
- Handles filenames and paths with spaces without issue
- Works with either ImageMagick 6 (`convert`) or ImageMagick 7 (`magick`)

## Requirements

- **bash** (4+)
- **ImageMagick** — provides `convert` or `magick`
- **poppler-utils** — provides `pdftoppm` (for reading PDFs)
- **jpegoptim** *(optional)* — used as an extra squeeze in the fallback pass
  if installed; the script works fine without it

### Install on Debian/Ubuntu

```bash
sudo apt update
sudo apt install imagemagick poppler-utils jpegoptim
```

### Install on macOS (Homebrew)

```bash
brew install imagemagick poppler jpegoptim
```

## Setup

```bash
git clone <this-repo-url>
cd <this-repo>
chmod +x converter.sh
```

Optionally add it to your `PATH`:

```bash
sudo cp converter.sh /usr/local/bin/converter
```

## Usage

```
./converter.sh [options] <file1> [file2 ...]
```

| Option | Meaning | Default |
|---|---|---|
| `-o FILE` | Output filename: `.jpg`/`.jpeg` (flattened image) or `.pdf` (multi-page PDF) | `final_result.jpg` |
| `-s KB`   | Target max size in KB for the whole output | `100` |
| `-d DPI`  | DPI used when rendering PDF pages | `150` |
| `-w WIDTH` | Max width (px) during compression attempts | `1200` |
| `-m MODE` | Merge direction for **image output only**: `vertical` or `horizontal` | `vertical` |
| `-p RANGE` | PDF pages to use: `all`, `2`, or `1-3` | `all` |
| `-g` | Also try a grayscale fallback pass if size target isn't hit | off |
| `-f` | Force overwrite of an existing output file | off |
| `-h` | Show help | — |

### Examples

```bash
# Compress a single-page PDF to <=100KB, as a JPEG
./converter.sh sem1.pdf

# Merge two multi-page PDFs into ONE real multi-page PDF, <=100KB total
./converter.sh -o merged.pdf a.pdf b.pdf

# Merge every page of a scanned PDF into one flattened JPEG image
./converter.sh -o application_form.jpg -s 150 scanned_form.pdf

# Only use pages 1-3 of a PDF, output as a (3-page) PDF
./converter.sh -p 1-3 -o pages.pdf -s 200 scan.pdf

# Combine a PDF and a photo side-by-side into one JPEG
./converter.sh -m horizontal -o combined.jpg photo_id.pdf signature.jpg

# Turn separate page images into one multi-page PDF
./converter.sh page1.jpg page2.jpg page3.jpg -o merged.pdf

# Very tight size budget — allow a grayscale fallback pass
./converter.sh -s 50 -g -o tiny.jpg bulky_scan.pdf
```

## How it works

1. **Render** — every PDF is rendered to PNG page-by-page at `-d` DPI (all
   pages by default, or a chosen range via `-p`); images are normalized to
   PNG as-is. Order is preserved across all input files.
2. **Branch on output type:**
   - **JPEG output**: all rendered pages are stacked vertically or placed
     side-by-side horizontally (per `-m`) into one flattened image.
   - **PDF output**: pages stay separate. `-m` is ignored here (nothing is
     being stacked).
3. **Compress** — pages are exported as JPEG, stepping quality down through
   `95 → 90 → 85 → ... → 30` (resized to `-w` width each time). For PDF
   output, all pages are compressed at the same quality per attempt and then
   assembled into a candidate PDF; the *total* PDF size is checked against
   `-s` KB.
4. **Fallback** — if no quality step gets under the target, it tries one more
   pass at quality 30, a smaller width, optional grayscale (`-g`), and
   `jpegoptim` if installed. If it's still over budget, it writes the file
   anyway and prints a warning with suggestions (lower `-d`/`-w`, narrow
   `-p`, or add `-g`).

## Contribution
Open for contribution for more features or bug fixes. Please raise a PR if you feel so.
