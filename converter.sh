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
#   - `-o` accepts .jpg/.jpeg/.pdf, and now the two behave properly differently:
#       .jpg/.jpeg -> all pages flattened into ONE stacked image (as before)
#       .pdf       -> a REAL multi-page PDF, one page per input page, in order
#                     (previously .pdf output was just a single flattened
#                     image mislabeled/wrapped as a 1-page PDF)
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

Accepts PDFs, JPGs, and PNGs (any mix, any count) and produces ONE output
file, compressed to fit under a target size:

  -o out.jpg / out.jpeg  -> every page from every input is stacked into
                            ONE flattened image (direction set by -m),
                            then compressed as a single JPEG.
  -o out.pdf             -> every page is kept as its own page, in the
                            same order as given, compressed and assembled
                            into a single real multi-page PDF. (-m is
                            ignored here — nothing is being stacked.)

Options:
  -o FILE    Output filename: .jpg/.jpeg or .pdf (default: $OUT)
  -s KB      Target max size in KB for the WHOLE output file (default: $TARGET_KB)
  -d DPI     DPI for PDF page rendering (default: $DPI)
  -w WIDTH   Max width in pixels during compression attempts (default: $WIDTH)
  -m MODE    Merge mode for image output only: vertical (default) or horizontal
  -p RANGE   PDF page range: "all" (default), a single page "2", or a range "1-3"
             Applies to every PDF given; images are unaffected.
  -g         Also try a grayscale fallback pass if size target isn't met
  -f         Force overwrite of output if it exists
  -h         Show this help

Examples:
  $0 sem1.pdf                            # compress a single PDF (all its pages, stacked into 1 JPEG)
  $0 -o merged.pdf a.pdf b.pdf           # merge two PDFs into one multi-page PDF, <=100KB
  $0 -m horizontal a.pdf b.jpg           # combine side-by-side into one JPEG
  $0 -o result.jpg -s 80 f.png           # produce <=80KB JPEG output
  $0 -p 1-3 -o pages.pdf -s 200 scan.pdf # only pages 1-3 of scan.pdf, as a PDF, <=200KB
  $0 page1.jpg page2.jpg -o combo.pdf    # turn separate page images into one 2-page PDF
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------------------------------------------------------------------------
# Argument parsing
#
# NOTE: this is a hand-rolled loop rather than `getopts` on purpose. Bash's
# getopts stops treating things as flags the moment it sees the first
# non-flag argument, so `converter.sh file1.pdf file2.pdf -o out.jpg` would
# leave "-o" and "out.jpg" as unparsed positional args (and "-o" would then
# fail the "file not found" check). This loop lets flags and files appear in
# any order, e.g. `converter.sh file1.pdf -o out.jpg file2.pdf` also works.
# ---------------------------------------------------------------------------
MERGE_MODE_EXPLICIT=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || die "-o requires an argument"; OUT="$2"; shift 2 ;;
    -s) [ $# -ge 2 ] || die "-s requires an argument"; TARGET_KB="$2"; shift 2 ;;
    -d) [ $# -ge 2 ] || die "-d requires an argument"; DPI="$2"; shift 2 ;;
    -w) [ $# -ge 2 ] || die "-w requires an argument"; WIDTH="$2"; shift 2 ;;
    -m)
       [ $# -ge 2 ] || die "-m requires an argument"
       [[ "$2" =~ ^(vertical|horizontal)$ ]] || die "-m must be 'vertical' or 'horizontal'"
       MERGE_MODE="$2"; MERGE_MODE_EXPLICIT=1; shift 2
       ;;
    -p) [ $# -ge 2 ] || die "-p requires an argument"; PAGE_RANGE="$2"; shift 2 ;;
    -g) GRAYSCALE_FALLBACK=1; shift ;;
    -f) FORCE=1; shift ;;
    -h) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*) die "invalid option '$1' (see -h)" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

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

OUT_EXT="${OUT##*.}"; OUT_EXT="${OUT_EXT,,}"
case "$OUT_EXT" in
  jpg|jpeg|pdf) ;;
  *) die "-o must end in .jpg, .jpeg, or .pdf (got '$OUT') — use .jpg/.jpeg for a single flattened compressed image, or .pdf for a real multi-page PDF with pages kept separate." ;;
esac

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
# From here the two output types genuinely diverge:
#
#   .jpg/.jpeg -> all pages are stacked (vertical/horizontal, per -m) into
#                 ONE flattened image, then compressed. (unchanged behavior)
#
#   .pdf       -> each page stays its own PDF page, in the original order.
#                 Every page is compressed uniformly (same JPEG quality/width
#                 for all pages at a given attempt) so the whole document fits
#                 the size target, then assembled into one multi-page PDF.
#                 -m (merge direction) doesn't apply here, since nothing is
#                 being stacked into a single image.
# ---------------------------------------------------------------------------

if [ "$OUT_EXT" = "pdf" ] && [ "$MERGE_MODE_EXPLICIT" -eq 1 ]; then
  log "Note: -m is ignored for PDF output — every page is kept separate."
fi

if [ "$OUT_EXT" = "pdf" ]; then
  # -------------------------------------------------------------------------
  # PDF output: compress every page at the same quality/width per attempt,
  # assemble into a multi-page PDF, and check the *total* PDF size.
  # -------------------------------------------------------------------------
  npages="${#PAGE_PNGS[@]}"
  success=0

  compress_pages_to() {
    # compress_pages_to <quality> <width> <grayscale:0|1> <dest_dir> -> fills PAGE_JPGS
    local q="$1" w="$2" gray="$3" dest="$4"
    PAGE_JPGS=()
    local idx=0 png pj
    for png in "${PAGE_PNGS[@]}"; do
      idx=$((idx+1))
      pj="$dest/page_${idx}.jpg"
      if [ "$gray" -eq 1 ]; then
        IM "$png" -colorspace Gray -strip -interlace Plane -sampling-factor 4:2:0 \
           -quality "$q" -resize "${w}x" "$pj"
      else
        IM "$png" -strip -interlace Plane -sampling-factor 4:2:0 \
           -quality "$q" -resize "${w}x" "$pj"
      fi
      PAGE_JPGS+=("$pj")
    done
  }

  for q in "${QUALITY_STEPS[@]}"; do
    attempt_dir="$tmpdir/attempt_q${q}"; mkdir -p "$attempt_dir"
    compress_pages_to "$q" "$WIDTH" 0 "$attempt_dir"
    candidate="$attempt_dir/candidate.pdf"
    IM "${PAGE_JPGS[@]}" "$candidate"

    size=$(stat -c%s "$candidate")
    log "  quality=$q -> $((size/1024)) KB ($npages page(s))"
    if [ "$size" -le "$MAX_BYTES" ]; then
      mv "$candidate" "$OUT"
      log "Compressed to $((size/1024)) KB at quality=$q"
      success=1
      break
    fi
  done

  if [ "$success" -ne 1 ]; then
    log "Target not reached with normal quality steps; trying fallback reductions..."
    fallback_width=$(( WIDTH < 900 ? WIDTH : 900 ))
    fallback_dir="$tmpdir/attempt_fallback"; mkdir -p "$fallback_dir"
    compress_pages_to "$FALLBACK_QUALITY" "$fallback_width" "$GRAYSCALE_FALLBACK" "$fallback_dir"

    if [ "$JPEGOPTIM_AVAILABLE" -eq 1 ]; then
      per_page_kb=$(( TARGET_KB / npages ))
      [ "$per_page_kb" -lt 1 ] && per_page_kb=1
      jpegoptim --size="${per_page_kb}k" --strip-all "${PAGE_JPGS[@]}" >/dev/null 2>&1 || true
    fi

    IM "${PAGE_JPGS[@]}" "$OUT"
    size=$(stat -c%s "$OUT")
    log "Fallback compression -> $((size/1024)) KB"
  fi

else
  # -------------------------------------------------------------------------
  # Image output: stack every page into one flattened image (as before),
  # then step down JPEG quality until it's under the size target.
  # -------------------------------------------------------------------------
  combined="$tmpdir/combined.png"
  if [ "${#PAGE_PNGS[@]}" -eq 1 ]; then
    cp "${PAGE_PNGS[0]}" "$combined"
  else
    append_flag="-append"
    [ "$MERGE_MODE" = "horizontal" ] && append_flag="+append"
    IM "${PAGE_PNGS[@]}" $append_flag "$combined"
  fi
  log "Combined image ready ($MERGE_MODE merge)."

  final_tmp="$tmpdir/final_tmp.jpg"
  success=0

  for q in "${QUALITY_STEPS[@]}"; do
    IM "$combined" -strip -interlace Plane -sampling-factor 4:2:0 \
       -quality "$q" -resize "${WIDTH}x" "$final_tmp"

    size=$(stat -c%s "$final_tmp")
    log "  quality=$q -> $((size/1024)) KB"
    if [ "$size" -le "$MAX_BYTES" ]; then
      mv "$final_tmp" "$OUT"
      log "Compressed to $((size/1024)) KB at quality=$q"
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
    log "Fallback compression -> $((size/1024)) KB"
  fi
fi

# ---------------------------------------------------------------------------
# Final size check
# ---------------------------------------------------------------------------
final_size=$(stat -c%s "$OUT")
log "Wrote '$OUT' ($((final_size/1024)) KB)"
if [ "$final_size" -gt "$MAX_BYTES" ]; then
  log "Warning: still above target (${TARGET_KB} KB). Try lowering -d (DPI) or -w (WIDTH), narrowing -p (page range), or adding -g for grayscale."
  exit 2
fi

exit 0
