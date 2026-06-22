#!/usr/bin/env bash
# Upload an image to a Cloudflare R2 bucket and print a public URL +
# ready-to-paste GitHub markdown. See ../SKILL.md for setup and usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SKILL_ENV="${SKILL_DIR}/.env"

# Config + credentials resolve in this order: the environment wins, then a .env in
# the skill folder (gitignored — copy example.env to .env and fill it in). For auth
# you can instead `wrangler login` to the Cloudflare account that owns the bucket.
KNOWN_KEYS="CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID R2_SCREENSHOTS_BUCKET R2_SCREENSHOTS_PUBLIC_BASE"
load_env_softly() {
  local f="$1" k v
  [ -f "$f" ] || return 0
  for k in $KNOWN_KEYS; do
    if [ -n "${!k:-}" ]; then continue; fi   # environment already set it — don't override
    v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "$f" 2>/dev/null | tail -1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${k}=//" || true)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"   # strip optional surrounding quotes
    if [ -n "$v" ]; then export "$k=$v"; fi
  done
}
load_env_softly "$SKILL_ENV"

# Target bucket + its public base URL. No defaults are committed — point these at
# YOUR R2 bucket and its public custom domain (set both, so the printed URL matches
# where the object actually lands). Validated after --help below.
BUCKET="${R2_SCREENSHOTS_BUCKET:-}"
PUBLIC_BASE="${R2_SCREENSHOTS_PUBLIC_BASE:-}"
PUBLIC_BASE="${PUBLIC_BASE%/}"  # tolerate a trailing slash

usage() {
  cat <<'EOF'
Usage: upload.sh <local-file> [options]

Options:
  --repo  <owner/repo>          Used to namespace the key (default: derived from cwd git remote)
  --ref   <pr|issue|branch>     Used to namespace the key (default: today's date)
  --alt   "description"         Alt text for the emitted markdown (default: file basename)
  --width <px>                  Emit an <img width=...> tag instead of ![](); good for large shots
  --key   <explicit/key.ext>    Override the auto-generated object key entirely
  -h, --help                    Show this help

Examples:
  upload.sh /tmp/feed.png --repo myorg/myapp --ref 1722 --alt "New feed cards" --width 700
  upload.sh ./diagram.png --key docs/architecture/flow.png
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0;; esac

FILE="$1"; shift
REPO=""; REF=""; ALT=""; WIDTH=""; KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2;;
    --ref)   REF="$2"; shift 2;;
    --alt)   ALT="$2"; shift 2;;
    --width) WIDTH="$2"; shift 2;;
    --key)   KEY="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 1; }

# --- validate config (after --help so help always works without setup) ---
if [ -z "$BUCKET" ] || [ -z "$PUBLIC_BASE" ]; then
  echo "error: set R2_SCREENSHOTS_BUCKET and R2_SCREENSHOTS_PUBLIC_BASE" >&2
  echo "       (in the environment or $SKILL_ENV — copy example.env to .env)." >&2
  exit 1
fi
# Credentials are a soft check: if no token is present we let wrangler use its own
# auth (e.g. an interactive 'wrangler login'). Only nudge if nothing is configured.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "note: CLOUDFLARE_API_TOKEN not set — relying on wrangler's own auth." >&2
  echo "      If the upload fails, set CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID" >&2
  echo "      (copy example.env to .env) or run 'wrangler login'." >&2
fi

# --- content type from extension ---
ext="${FILE##*.}"; ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
case "$ext_lc" in
  png)        CT="image/png";;
  jpg|jpeg)   CT="image/jpeg";;
  gif)        CT="image/gif";;
  webp)       CT="image/webp";;
  svg)        CT="image/svg+xml";;
  mp4)        CT="video/mp4";;
  *)          CT="application/octet-stream";;
esac

# --- derive the object key if not given explicitly ---
if [ -z "$KEY" ]; then
  if [ -z "$REPO" ]; then
    # derive the repo name from the git remote (portable: no sed lazy quantifiers).
    # strip a trailing .git, then take the last path component.
    REPO="$(git config --get remote.origin.url 2>/dev/null || true)"
    REPO="${REPO%.git}"; REPO="${REPO##*/}"
  fi
  repo_name="${REPO##*/}"; repo_name="${repo_name:-misc}"
  segment="${REF:-$(date +%Y-%m-%d)}"
  base="$(basename "$FILE")"; stem="${base%.*}"
  # short content hash keeps repeated names from colliding
  if command -v shasum >/dev/null 2>&1; then
    short="$(shasum -a 256 "$FILE" | cut -c1-6)"
  else
    short="$(date +%H%M%S)"
  fi
  # sanitize segments to url-safe chars
  san() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }
  KEY="screenshots/$(san "$repo_name")/$(san "$segment")/$(san "$stem")-${short}.${ext_lc}"
fi

URL="${PUBLIC_BASE}/${KEY}"

echo ">> uploading $FILE  ($CT)" >&2
echo ">> key: $KEY" >&2
wrangler r2 object put "${BUCKET}/${KEY}" --file "$FILE" --content-type "$CT" --remote >&2

# --- emit results ---
[ -n "$ALT" ] || ALT="$(basename "$FILE")"
echo "" >&2
echo "URL: $URL"
if [ -n "$WIDTH" ]; then
  echo "MARKDOWN: <img width=\"${WIDTH}\" alt=\"${ALT}\" src=\"${URL}\">"
else
  echo "MARKDOWN: ![${ALT}](${URL})"
fi
