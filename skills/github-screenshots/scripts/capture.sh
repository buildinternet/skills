#!/usr/bin/env bash
# Capture a webpage screenshot to a local PNG via headless Playwright (Chromium).
# Optionally pipe straight into upload.sh with --upload.
#
# Engine: Playwright (Chromium, headless). No global install required — the
# script resolves the playwright package via npx's local cache (downloaded
# automatically on first use). NODE_PATH is set so the inline Node script can
# require('playwright') from that cached copy. If Chromium is absent the
# script exits with a clear `npx playwright install chromium` hint.
#
# Design: the actual browser work is a small inline Node ESM script written to
# a temp file and run with `node --input-type=module`. No package.json in the
# skill is needed; everything stays self-contained in this single file.
#
# See ../SKILL.md for the full workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: capture.sh <url> [options]

Capture a webpage screenshot (PNG) via headless Playwright (Chromium).

Options:
  --selector <css>       Capture only the matched element (cropped); default: full viewport.
  --out <path>           Output PNG path; default: /tmp/screenshot-<timestamp>.png
                         The resolved absolute path is always printed last on stdout.
  --width <px>           Viewport width  (default: 1280)
  --height <px>          Viewport height (default: 720)
  --full-page            Capture the full scrollable page (not just the viewport).
  --wait <selector|ms>   Before capturing, wait for a CSS selector to appear OR
                         sleep a fixed number of milliseconds.
  --eval <js>            Run arbitrary JavaScript in the page before capturing.
                         Useful for setting form values, toggling state, etc.

                         IMPORTANT — React controlled inputs: React intercepts
                         native DOM value assignments, so
                           document.querySelector('#field').value = 'foo'
                         has no effect. Instead, use the native value setter and
                         dispatch synthetic events:
                           const el = document.querySelector('#field');
                           Object.getOwnPropertyDescriptor(
                             window.HTMLInputElement.prototype, 'value'
                           ).set.call(el, 'foo');
                           el.dispatchEvent(new Event('input',  { bubbles: true }));
                           el.dispatchEvent(new Event('change', { bubbles: true }));

  --upload               After capturing, forward the PNG to upload.sh and print
                         its output (public URL + markdown). Pass --repo, --ref,
                         --alt, and --img-width through to upload.sh (see below).
  --repo  <owner/repo>   Forwarded to upload.sh (for key namespacing).
  --ref   <pr|branch>    Forwarded to upload.sh (for key namespacing).
  --alt   "text"         Forwarded to upload.sh (alt text for the markdown embed).
  --img-width <px>       Forwarded to upload.sh as --width (rendered image width).
  -h, --help             Show this help and exit.

Examples:
  # Full-viewport screenshot of example.com:
  capture.sh https://example.com

  # Capture only the nav element, wait for it to appear:
  capture.sh https://example.com --selector nav --wait nav

  # Capture, then upload and embed in a PR in one command:
  capture.sh https://myapp.example.com \
    --selector ".card" --wait ".card" \
    --out /tmp/card.png \
    --upload --repo myorg/myapp --ref 42 --alt "New card design" --img-width 700

  # Set a React-controlled input before capturing:
  capture.sh https://myapp.example.com \
    --eval "
      const el = document.querySelector('#search');
      Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value')
        .set.call(el,'hello');
      el.dispatchEvent(new Event('input',{bubbles:true}));
    " \
    --wait 500

First-time setup (downloads ~95 MB Chromium browser, once):
  npx playwright install chromium

EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
URL=""
SELECTOR=""
OUT=""
VP_WIDTH=1280
VP_HEIGHT=720
FULL_PAGE=false
WAIT_FOR=""
EVAL_JS=""
DO_UPLOAD=false
UPLOAD_REPO=""
UPLOAD_REF=""
UPLOAD_ALT=""
UPLOAD_IMG_WIDTH=""

if [ $# -eq 0 ]; then usage; exit 2; fi
case "$1" in -h|--help) usage; exit 0;; esac

# First positional arg is the URL (if it doesn't start with --)
if [[ "$1" != --* ]]; then
  URL="$1"; shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    # Value-taking options: guard $2 before reading it so a missing value gives
    # a clean error rather than a `set -u` "unbound variable" message.
    --selector|--out|--width|--height|--wait|--eval|--repo|--ref|--alt|--img-width)
      if [ $# -lt 2 ]; then
        echo "error: $1 requires a value" >&2; usage; exit 2
      fi
      case "$1" in
        --selector)    SELECTOR="$2";;
        --out)         OUT="$2";;
        --width)       VP_WIDTH="$2";;
        --height)      VP_HEIGHT="$2";;
        --wait)        WAIT_FOR="$2";;
        --eval)        EVAL_JS="$2";;
        --repo)        UPLOAD_REPO="$2";;
        --ref)         UPLOAD_REF="$2";;
        --alt)         UPLOAD_ALT="$2";;
        --img-width)   UPLOAD_IMG_WIDTH="$2";;
      esac
      shift 2;;
    --full-page)   FULL_PAGE=true;  shift;;
    --upload)      DO_UPLOAD=true;  shift;;
    -h|--help)     usage; exit 0;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2;;
  esac
done

if [ -z "$URL" ]; then
  echo "error: <url> is required" >&2; usage; exit 2
fi

# --width/--height are embedded verbatim (unquoted) into the generated JS, so
# require plain integers to avoid breakage / injection from arbitrary input.
if ! [[ "$VP_WIDTH" =~ ^[0-9]+$ ]]; then
  echo "error: --width must be a positive integer (got: $VP_WIDTH)" >&2; exit 2
fi
if ! [[ "$VP_HEIGHT" =~ ^[0-9]+$ ]]; then
  echo "error: --height must be a positive integer (got: $VP_HEIGHT)" >&2; exit 2
fi

# ---------------------------------------------------------------------------
# Sanity-check: node must be available
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "error: 'node' not found in PATH. Install Node.js (https://nodejs.org) and re-run." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve playwright module location
#
# Resolution order (first hit wins):
#   1. NODE_PATH already set in the environment (lets callers inject a custom location)
#   2. A local node_modules in the skill directory or any ancestor
#   3. The npx cache (~/.npm/_npx/) — populated automatically by `npx playwright`
#   4. Global npm root
#
# After locating it we export NODE_PATH so `node` can require('playwright').
# ---------------------------------------------------------------------------
find_playwright_dir() {
  # Already loadable? (NODE_PATH set, or resolvable from cwd / a local install.)
  # Resolve its actual location and pin NODE_PATH to that node_modules, so the
  # capture script — which runs from /tmp, a different cwd — can require it too.
  local resolved
  resolved="$(node -e "try{process.stdout.write(require.resolve('playwright'))}catch(e){process.exit(1)}" 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    export NODE_PATH="${resolved%%/playwright/*}"
    return 0
  fi

  # Walk up from the skill dir looking for node_modules/playwright
  local dir="$SCRIPT_DIR"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/node_modules/playwright" ]; then
      export NODE_PATH="$dir/node_modules"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  # Scan the npx cache for the newest playwright install
  local npx_cache="${npm_config_cache:-${HOME}/.npm}/_npx"
  if [ -d "$npx_cache" ]; then
    local newest
    newest="$(find "$npx_cache" -maxdepth 3 -name "playwright" -type d 2>/dev/null \
              | sort -r | head -1)"
    if [ -n "$newest" ]; then
      export NODE_PATH="$(dirname "$newest")"
      return 0
    fi
  fi

  # Global npm root
  local global_root
  global_root="$(npm root -g 2>/dev/null || true)"
  if [ -d "${global_root}/playwright" ]; then
    export NODE_PATH="$global_root"
    return 0
  fi

  return 1
}

echo ">> checking Playwright / Chromium …" >&2
if ! find_playwright_dir; then
  echo "" >&2
  echo "error: Playwright package not found." >&2
  echo "" >&2
  echo "Install it (downloads ~95 MB Chromium browser, once):" >&2
  echo "  npx playwright install chromium" >&2
  echo "" >&2
  echo "Then re-run this script." >&2
  exit 1
fi

# Verify the browser binary is actually present (common failure: package found but
# browsers not downloaded yet). executablePath() is synchronous in modern Playwright.
if ! node -e "
const { chromium } = require('playwright');
const fs = require('fs');
try {
  const p = chromium.executablePath();
  if (!p || !fs.existsSync(p)) process.exit(1);
} catch(e) { process.exit(1); }
" 2>/dev/null; then
  echo "" >&2
  echo "error: Playwright is installed but the Chromium browser is missing." >&2
  echo "" >&2
  echo "Download it with:" >&2
  echo "  npx playwright install chromium" >&2
  exit 1
fi
echo ">> Playwright OK" >&2

# ---------------------------------------------------------------------------
# Resolve output path
# ---------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
if [ -z "$OUT" ]; then
  OUT="${TMPDIR:-/tmp}/screenshot-${TS}.png"
fi
case "$OUT" in
  /*) ;;            # already absolute
  *)  OUT="$(pwd)/${OUT}";;
esac

# ---------------------------------------------------------------------------
# Build and execute the inline Playwright Node script
# ---------------------------------------------------------------------------
TMPJS="$(mktemp /tmp/capture-XXXXXX.js)"
trap 'rm -f "$TMPJS"' EXIT

# Safely encode bash values as JSON strings for embedding in JS.
# We use node itself for this — the most reliable approach.
js_str() {
  node -e "process.stdout.write(JSON.stringify(String(process.argv[1])))" -- "$1"
}

JS_URL="$(js_str "$URL")"
JS_OUT="$(js_str "$OUT")"
JS_SELECTOR="$(js_str "$SELECTOR")"
JS_WAIT="$(js_str "$WAIT_FOR")"
JS_EVAL="$(js_str "$EVAL_JS")"
JS_FULL_PAGE="$( [ "$FULL_PAGE" = true ] && echo 'true' || echo 'false' )"
JS_VP_W="$VP_WIDTH"
JS_VP_H="$VP_HEIGHT"

cat > "$TMPJS" <<JSEOF
// Inline Playwright capture — generated by capture.sh
'use strict';
const { chromium } = require('playwright');

const url      = ${JS_URL};
const outPath  = ${JS_OUT};
const selector = ${JS_SELECTOR};
const waitFor  = ${JS_WAIT};
const evalJs   = ${JS_EVAL};
const fullPage = ${JS_FULL_PAGE};
const vpWidth  = ${JS_VP_W};
const vpHeight = ${JS_VP_H};

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const context = await browser.newContext({
      viewport: { width: vpWidth, height: vpHeight },
    });
    const page = await context.newPage();

    // Navigate — try networkidle first, fall back to load on timeout (some
    // apps have persistent WebSocket/polling that prevents networkidle).
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
    } catch (e) {
      if (e.constructor && e.constructor.name === 'TimeoutError') {
        await page.goto(url, { waitUntil: 'load', timeout: 30000 });
      } else {
        throw e;
      }
    }

    // Optional wait: CSS selector OR fixed millisecond delay
    if (waitFor) {
      const ms = parseInt(waitFor, 10);
      if (!isNaN(ms) && String(ms) === waitFor.trim()) {
        await page.waitForTimeout(ms);
      } else {
        await page.waitForSelector(waitFor, { timeout: 15000 });
      }
    }

    // Optional JS evaluation (e.g. populate form fields, toggle state)
    if (evalJs) {
      await page.evaluate(evalJs);
      await page.waitForTimeout(200);  // let React/Vue re-render settle
    }

    // Screenshot: element crop vs. full-page vs. viewport
    if (selector) {
      const el = await page.waitForSelector(selector, { timeout: 10000 });
      await el.screenshot({ path: outPath });
    } else {
      await page.screenshot({ path: outPath, fullPage });
    }

  } finally {
    await browser.close();
  }
})().catch(err => {
  console.error('capture error:', err.message || err);
  process.exit(1);
});
JSEOF

echo ">> navigating to:  $URL" >&2
echo ">> output path:    $OUT" >&2
[ -n "$SELECTOR" ]     && echo ">> element:        $SELECTOR" >&2
[ -n "$WAIT_FOR" ]     && echo ">> waiting for:    $WAIT_FOR" >&2
[ -n "$EVAL_JS" ]      && echo ">> running --eval JS in page …" >&2
[ "$FULL_PAGE" = true ] && echo ">> full-page capture" >&2

node "$TMPJS"

# Verify the file was produced and is non-empty
if [ ! -f "$OUT" ] || [ ! -s "$OUT" ]; then
  echo "error: capture failed — output file is missing or empty: $OUT" >&2
  exit 1
fi

SIZE="$(du -h "$OUT" | cut -f1)"
echo ">> captured: $OUT  ($SIZE)" >&2

# ---------------------------------------------------------------------------
# Optional: pipe straight into upload.sh
# ---------------------------------------------------------------------------
if [ "$DO_UPLOAD" = true ]; then
  UPLOAD_SCRIPT="${SCRIPT_DIR}/upload.sh"
  if [ ! -x "$UPLOAD_SCRIPT" ]; then
    echo "error: upload.sh not found or not executable: $UPLOAD_SCRIPT" >&2
    exit 1
  fi
  echo "" >&2
  echo ">> uploading via upload.sh …" >&2
  UPLOAD_ARGS=("$OUT")
  [ -n "$UPLOAD_REPO" ]      && UPLOAD_ARGS+=(--repo  "$UPLOAD_REPO")
  [ -n "$UPLOAD_REF" ]       && UPLOAD_ARGS+=(--ref   "$UPLOAD_REF")
  [ -n "$UPLOAD_ALT" ]       && UPLOAD_ARGS+=(--alt   "$UPLOAD_ALT")
  [ -n "$UPLOAD_IMG_WIDTH" ] && UPLOAD_ARGS+=(--width "$UPLOAD_IMG_WIDTH")
  # upload.sh prints URL and MARKDOWN on stdout — pass through directly.
  "$UPLOAD_SCRIPT" "${UPLOAD_ARGS[@]}"
else
  # Print the absolute output path as the final stdout line so callers can
  # capture it with: OUT=$(capture.sh <url> ...)
  echo "$OUT"
fi
