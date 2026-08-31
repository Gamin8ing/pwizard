#!/usr/bin/env bash
# converter.sh — merge PDF page(s)/image(s) into a single JPEG under a target size.
#
# Fixes vs. original version:
#   - `-h` now exits 0 (was exiting 1, which breaks `script -h && ...` checks)
#   - Accepts ANY number of input files, not just 1-2 (real merge support)
#   - Multi-page PDFs now render all requested pages (was hardcoded to page 1 only,
#     silently dropping the rest of the document)
#   - New `-p RANGE` flag to pick pages from a PDF (e.g. "1-3", "2", "all")
#   - Numeric flags (-s/-d/-w) are validated; bad input fails fast with a clear error
#     instead of a cryptic arithmetic error later
#   - Works with ImageMagick 6 (`convert`) or 7 (`magick`) — original only checked `magick`
#   - Fallback compression pass now respects `-w` instead of a hardcoded 900px
#   - All error/log output goes to stderr consistently
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUT="final_result.jpg"
TARGET_KB=100
DPI=150
WIDTH=1200
MERGE_MODE="vertical"
PAGE_RANGE="all"
GRAYSCALE_FALLBACK=0
FORCE=0
QUALITY_STEPS=(95 90 85 80 75 70 65 60 55 50 45 40 35 30)
FALLBACK_QUALITY=30

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
log()  { echo "$*" >&2; }
die()  { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options] <file1> [file2 ...]

Merges one or more PDFs/images (all pages of each PDF, in order) into a
single image, then compresses it to fit under a target file size.

Options:
  -o FILE    Output filename (default: $OUT)
  -s KB      Target max size in KB (default: $TARGET_KB)
  -d DPI     DPI for PDF render (default: $DPI)
  -w WIDTH   Max width in pixels during compression attempts (default: $WIDTH)
  -m MODE    Merge mode: vertical (default) or horizontal
  -p RANGE   PDF page range: "all" (default), a single page "2", or a range "1-3"
             Applies to every PDF given; images are unaffected.
  -g         Also try a grayscale fallback pass if size target isn't met
  -f         Force overwrite of output if it exists
  -h         Show this help

Examples:
  $0 sem1.pdf                            # compress a single PDF (all its pages, stacked)
  $0 -m horizontal a.pdf b.jpg           # combine side-by-side
  $0 -o result.jpg -s 80 f.png           # produce <=80KB output
  $0 -p 1-3 -s 200 scan.pdf              # only pages 1-3 of scan.pdf, <=200KB
  $0 page1.jpg page2.jpg page3.jpg       # merge several page images into one file
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while getopts ":o:s:d:w:m:p:gfh" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    s) TARGET_KB="$OPTARG" ;;
    d) DPI="$OPTARG" ;;
    w) WIDTH="$OPTARG" ;;
    m)
       [[ "$OPTARG" =~ ^(vertical|horizontal)$ ]] || die "-m must be 'vertical' or 'horizontal'"
       MERGE_MODE="$OPTARG"
       ;;
    p) PAGE_RANGE="$OPTARG" ;;
    g) GRAYSCALE_FALLBACK=1 ;;
    f) FORCE=1 ;;
    h) usage; exit 0 ;;
    \?) die "invalid option -$OPTARG (see -h)" ;;
    :)  die "option -$OPTARG requires an argument" ;;
  esac
done
shift $((OPTIND-1))

[ $# -ge 1 ] || { usage; exit 1; }

is_uint "$TARGET_KB" || die "-s must be a positive integer (got '$TARGET_KB')"
is_uint "$DPI"       || die "-d must be a positive integer (got '$DPI')"
is_uint "$WIDTH"     || die "-w must be a positive integer (got '$WIDTH')"

if [[ "$PAGE_RANGE" != "all" ]] && ! [[ "$PAGE_RANGE" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
  die "-p must be 'all', a page number, or a range like 1-3 (got '$PAGE_RANGE')"
fi

INPUT_FILES=("$@")
for f in "${INPUT_FILES[@]}"; do
  [ -f "$f" ] || die "'$f' not found."
done

if [ -f "$OUT" ] && [ "$FORCE" -ne 1 ]; then
  die "output '$OUT' exists. Use -f to overwrite."
fi

MAX_BYTES=$(( TARGET_KB * 1024 ))

# ---------------------------------------------------------------------------
# Dependency checks (support ImageMagick 6 `convert` or 7 `magick`)
# ---------------------------------------------------------------------------
if command -v magick >/dev/null 2>&1; then
  IM() { magick "$@"; }
elif command -v convert >/dev/null 2>&1; then
  IM() { convert "$@"; }
else
  die "ImageMagick not found (need 'magick' or 'convert')."
fi
command -v pdftoppm >/dev/null 2>&1 || die "'pdftoppm' (poppler-utils) not found."
JPEGOPTIM_AVAILABLE=0
command -v jpegoptim >/dev/null 2>&1 && JPEGOPTIM_AVAILABLE=1

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# Rendering: turn each input file into one or more page PNGs, in order
# ---------------------------------------------------------------------------

# render_pdf_pages <pdf> <outbase> -> appends resulting PNG paths to PAGE_PNGS
render_pdf_pages() {
  local input="$1" outbase="$2"
  local -a range_flags=()

  if [[ "$PAGE_RANGE" == "all" ]]; then
    : # no -f/-l => render every page
  elif [[ "$PAGE_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    range_flags=(-f "${BASH_REMATCH[1]}" -l "${BASH_REMATCH[2]}")
  else
    range_flags=(-f "$PAGE_RANGE" -l "$PAGE_RANGE")
  fi

  pdftoppm -png -r "$DPI" "${range_flags[@]}" "$input" "$outbase" \
    || die "failed to render PDF '$input'."

  local -a rendered=("${outbase}"-*.png)
  [ -e "${rendered[0]}" ] || die "PDF '$input' produced no pages for range '$PAGE_RANGE'."

  # pdftoppm names pages "<outbase>-<n>.png"; sort numerically by that <n>
  local sorted
  sorted=$(printf '%s\n' "${rendered[@]}" \
    | sed -E "s#^(${outbase}-)([0-9]+)(\.png)\$#\2 \1\2\3#" \
    | sort -n | cut -d' ' -f2-)
  while IFS= read -r p; do PAGE_PNGS+=("$p"); done <<< "$sorted"
}

# render_image <input> <outbase> -> appends the resulting PNG path to PAGE_PNGS
render_image() {
  local input="$1" outbase="$2"
  IM "$input" "${outbase}.png"
  PAGE_PNGS+=("${outbase}.png")
}

log "Processing input(s)..."
PAGE_PNGS=()
i=0
for f in "${INPUT_FILES[@]}"; do
  i=$((i+1))
  safe_name="$(basename "$f" | sed 's/[^a-zA-Z0-9]/_/g')"
  outbase="$tmpdir/${i}_${safe_name}"
  ext="${f##*.}"; ext="${ext,,}"
  if [ "$ext" = "pdf" ]; then
    render_pdf_pages "$f" "$outbase"
  else
    render_image "$f" "$outbase"
  fi
done

log "Rendered ${#PAGE_PNGS[@]} page(s) from ${#INPUT_FILES[@]} input file(s)."

# ---------------------------------------------------------------------------
# Merge all pages into a single image
# ---------------------------------------------------------------------------
combined="$tmpdir/combined.png"
if [ "${#PAGE_PNGS[@]}" -eq 1 ]; then
  cp "${PAGE_PNGS[0]}" "$combined"
else
  append_flag="-append"
  [ "$MERGE_MODE" = "horizontal" ] && append_flag="+append"
  IM "${PAGE_PNGS[@]}" $append_flag "$combined"
fi
log "Combined image ready ($MERGE_MODE merge)."

# ---------------------------------------------------------------------------
# Compression: step down JPEG quality until under the size target
# ---------------------------------------------------------------------------
final_tmp="$tmpdir/final_tmp.jpg"
success=0

for q in "${QUALITY_STEPS[@]}"; do
  IM "$combined" -strip -interlace Plane -sampling-factor 4:2:0 \
     -quality "$q" -resize "${WIDTH}x" "$final_tmp"

  size=$(stat -c%s "$final_tmp")
  log "  quality=$q -> $((size/1024)) KB"
  if [ "$size" -le "$MAX_BYTES" ]; then
    mv "$final_tmp" "$OUT"
    log "Success: wrote '$OUT' ($((size/1024)) KB) at quality=$q"
    success=1
    break
  fi
done

if [ "$success" -ne 1 ]; then
  log "Target not reached with normal quality steps; trying fallback reductions..."
  fallback_width=$(( WIDTH < 900 ? WIDTH : 900 ))

  if [ "$GRAYSCALE_FALLBACK" -eq 1 ]; then
    IM "$combined" -colorspace Gray -strip -interlace Plane -sampling-factor 4:2:0 \
       -quality "$FALLBACK_QUALITY" -resize "${fallback_width}x" "$final_tmp"
  else
    IM "$combined" -strip -interlace Plane -sampling-factor 4:2:0 \
       -quality "$FALLBACK_QUALITY" -resize "${fallback_width}x" "$final_tmp"
  fi

  if [ "$JPEGOPTIM_AVAILABLE" -eq 1 ]; then
    jpegoptim --size="${TARGET_KB}k" --strip-all "$final_tmp" >/dev/null 2>&1 || true
  fi

  size=$(stat -c%s "$final_tmp")
  mv "$final_tmp" "$OUT"
  log "Fallback output: '$OUT' -> $((size/1024)) KB"
  if [ "$size" -gt "$MAX_BYTES" ]; then
    log "Warning: still above target (${TARGET_KB} KB). Try lowering -d (DPI) or -w (WIDTH), narrowing -p (page range), or adding -g for grayscale."
    exit 2
  fi
fi

exit 0
