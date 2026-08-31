# PWizard

Merge one or more PDFs / images into a single JPEG, and compress it to fit
under a target file size. Built for the classic "government/university portal
wants a single scanned document under 100KB" problem — merge multi-page scans
into one image, then squeeze it under the limit while keeping the best
quality possible.

## Features

- Merge **any number** of PDFs and/or images, in the order you give them
- Renders **every page** of a multi-page PDF (not just the first)
- Pick a specific PDF page or range with `-p`
- Stack pages **vertically** or side-by-side **horizontally**
- Iteratively lowers JPEG quality to hit your size target with minimal
  quality loss, then falls back to resizing / grayscale if needed
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
| `-o FILE` | Output filename | `final_result.jpg` |
| `-s KB`   | Target max size in KB | `100` |
| `-d DPI`  | DPI used when rendering PDF pages | `150` |
| `-w WIDTH` | Max width (px) during compression attempts | `1200` |
| `-m MODE` | Merge direction: `vertical` or `horizontal` | `vertical` |
| `-p RANGE` | PDF pages to use: `all`, `2`, or `1-3` | `all` |
| `-g` | Also try a grayscale fallback pass if size target isn't hit | off |
| `-f` | Force overwrite of an existing output file | off |
| `-h` | Show help | — |

### Examples

```bash
# Compress a single-page PDF to <=100KB
./converter.sh sem1.pdf

# Merge every page of a multi-page scanned PDF into one image
./converter.sh -o application_form.jpg -s 150 scanned_form.pdf

# Only use pages 1-3 of a PDF
./converter.sh -p 1-3 -s 200 scan.pdf

# Combine a PDF and a photo side-by-side
./converter.sh -m horizontal -o combined.jpg photo_id.pdf signature.jpg

# Merge several separately-scanned page images into one file
./converter.sh page1.jpg page2.jpg page3.jpg -o merged.jpg

# Very tight size budget — allow a grayscale fallback pass
./converter.sh -s 50 -g -o tiny.jpg bulky_scan.pdf
```

## How it works

1. **Render** — every PDF is rendered to PNG page-by-page at `-d` DPI (all
   pages by default, or a chosen range via `-p`); images are normalized to
   PNG as-is.
2. **Merge** — all resulting page images are stacked vertically or placed
   side-by-side horizontally, in the order the files were given.
3. **Compress** — the merged image is exported as JPEG, stepping quality down
   through `95 → 90 → 85 → ... → 30` (resized to `-w` width each time) until
   it fits under `-s` KB.
4. **Fallback** — if no quality step gets under the target, it tries one more
   pass at quality 30, a smaller width, optional grayscale (`-g`), and
   `jpegoptim` if installed. If it's still over budget, it writes the file
   anyway and prints a warning with suggestions (lower `-d`/`-w`, narrow
   `-p`, or add `-g`).

## Contribution
Open for contribution for more features or bug fixes. Please raise a PR if you feel so. 
