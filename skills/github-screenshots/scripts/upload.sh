#!/usr/bin/env bash
# Upload an image to a Cloudflare R2 bucket and print a public URL +
# ready-to-paste GitHub markdown. See ../SKILL.md for setup and usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This skill owns only GH_SCREENSHOTS_* keys, so it never reads ambient
# CLOUDFLARE_* by accident. Config resolves per key, first match wins:
#   1. environment (already-exported GH_SCREENSHOTS_* win)
#   2. --env-file <path>            (explicit, parsed below)
#   3. $BUILDINTERNET_CONFIG        (shared override path)
#   4. ~/.config/buildinternet/config   (XDG default, shared across buildinternet skills)
# Credentials may instead come from `wrangler login`.
KNOWN_KEYS="GH_SCREENSHOTS_BUCKET GH_SCREENSHOTS_PUBLIC_BASE GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID"

default_config_path() {
  printf '%s/buildinternet/config' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

load_env_softly() {
  local f="$1" k v
  [ -f "$f" ] || return 0
  for k in $KNOWN_KEYS; do
    if [ -n "${!k:-}" ]; then continue; fi   # environment already set it — don't override
    v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "$f" 2>/dev/null | tail -1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${k}=//" || true)"
    # Strip surrounding quotes and any inline comment. For a quoted value, the
    # value is exactly what sits between the first pair of quotes — anything after
    # the closing quote (e.g. a trailing ` # comment`) is dropped, while a `#`
    # inside the quotes is preserved. For an unquoted value, a `#` that follows
    # whitespace begins an inline comment; a `#` with no leading space (e.g. a URL
    # fragment) stays part of the value.
    case "$v" in
      '"'*'"'*) v="${v#\"}"; v="${v%%\"*}" ;;          # "double quoted"
      "'"*"'"*) v="${v#\'}"; v="${v%%\'*}" ;;          # 'single quoted'
      *)
        v="${v%%[[:space:]]#*}"                        # drop a whitespace-led inline comment
        v="${v%"${v##*[![:space:]]}"}" ;;              # trim resulting trailing whitespace
    esac
    if [ -n "$v" ]; then export "$k=$v"; fi
  done
}

# Run wrangler with the namespaced credentials mapped to the names it expects,
# scoped to the subprocess — and only when our token is set. When it is unset we
# leave the environment untouched so wrangler uses its own auth (wrangler login).
run_wrangler() {
  local -a envv=()
  [ -n "${GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN:-}" ]  && envv+=("CLOUDFLARE_API_TOKEN=$GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN")
  [ -n "${GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID:-}" ] && envv+=("CLOUDFLARE_ACCOUNT_ID=$GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID")
  if [ ${#envv[@]} -gt 0 ]; then
    env "${envv[@]}" wrangler "$@"
  else
    wrangler "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage: upload.sh <local-file> [options]

Options:
  --repo  <owner/repo>          Used to namespace the key (default: derived from cwd git remote)
  --ref   <pr|issue|branch>     Used to namespace the key (default: today's date)
  --alt   "description"         Alt text for the emitted markdown (default: file basename)
  --width <px>                  Emit an <img width=...> tag instead of ![](); good for large shots
  --key   <explicit/key.ext>    Override the auto-generated object key entirely
  --env-file <path>             Read config from this file instead of the default
  -h, --help                    Show this help

Examples:
  upload.sh /tmp/feed.png --repo myorg/myapp --ref 1722 --alt "New feed cards" --width 700
  upload.sh ./diagram.png --key docs/architecture/flow.png
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0;; esac

FILE="$1"; shift
REPO=""; REF=""; ALT=""; WIDTH=""; KEY=""; ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="$2"; shift 2;;
    --ref)      REF="$2"; shift 2;;
    --alt)      ALT="$2"; shift 2;;
    --width)    WIDTH="$2"; shift 2;;
    --key)      KEY="$2"; shift 2;;
    --env-file) ENV_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

[ -f "$FILE" ] || { echo "error: file not found: $FILE" >&2; exit 1; }

# --- resolve the config file, then soft-load any keys not already in the env ---
# An explicit --env-file must exist: a typo there should fail loudly rather than
# silently fall through to the XDG default and surface a confusing "bucket not
# set" error. $BUILDINTERNET_CONFIG and the XDG default still soft-miss — a
# missing default config is normal and handled by the first-run hint below.
if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
  echo "error: --env-file not found: $ENV_FILE" >&2
  exit 1
fi
if [ -n "$ENV_FILE" ]; then
  CONFIG_FILE="$ENV_FILE"
elif [ -n "${BUILDINTERNET_CONFIG:-}" ]; then
  CONFIG_FILE="$BUILDINTERNET_CONFIG"
else
  CONFIG_FILE="$(default_config_path)"
fi
load_env_softly "$CONFIG_FILE"

BUCKET="${GH_SCREENSHOTS_BUCKET:-}"
PUBLIC_BASE="${GH_SCREENSHOTS_PUBLIC_BASE:-}"
PUBLIC_BASE="${PUBLIC_BASE%/}"  # tolerate a trailing slash

# --- validate config (after --help so help always works without setup) ---
if [ -z "$BUCKET" ] || [ -z "$PUBLIC_BASE" ]; then
  {
    echo "error: GH_SCREENSHOTS_BUCKET and GH_SCREENSHOTS_PUBLIC_BASE are not set."
    echo "       Create $CONFIG_FILE with:"
    echo "         GH_SCREENSHOTS_BUCKET=your-bucket"
    echo "         GH_SCREENSHOTS_PUBLIC_BASE=https://media.example.com"
    echo "       (optional) GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN / _ACCOUNT_ID, or run 'wrangler login'."
    echo "       Override the path with --env-file <path> or \$BUILDINTERNET_CONFIG."
  } >&2
  exit 1
fi
# Credentials are a soft check: if no namespaced token is present we let wrangler
# use its own auth (e.g. 'wrangler login'). Only nudge if nothing is configured.
if [ -z "${GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "note: GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN not set — relying on wrangler's own auth." >&2
  echo "      If the upload fails, set GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN + GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID" >&2
  echo "      (in $CONFIG_FILE) or run 'wrangler login'." >&2
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
run_wrangler r2 object put "${BUCKET}/${KEY}" --file "$FILE" --content-type "$CT" --remote >&2

# --- emit results ---
[ -n "$ALT" ] || ALT="$(basename "$FILE")"
echo "" >&2
echo "URL: $URL"
if [ -n "$WIDTH" ]; then
  echo "MARKDOWN: <img width=\"${WIDTH}\" alt=\"${ALT}\" src=\"${URL}\">"
else
  echo "MARKDOWN: ![${ALT}](${URL})"
fi
