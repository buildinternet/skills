#!/usr/bin/env bash
# Upload an image and print a public URL + ready-to-paste GitHub markdown.
# See ../SKILL.md for setup and usage.
#
# Backend cascade (GH_SCREENSHOTS_BACKEND, default: auto):
#   auto     — prefer the uploads CLI when configured, else R2 (S3/wrangler)
#   uploads  — require the uploads CLI + token
#   r2       — direct R2 only (S3-compatible API or wrangler)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This skill owns GH_SCREENSHOTS_* keys (and soft-reads UPLOADS_* only to detect
# whether the uploads backend is available). Config resolves per key, first match:
#   1. environment (already-exported vars win)
#   2. --env-file <path>
#   3. $BUILDINTERNET_CONFIG
#   4. ~/.config/buildinternet/config
KNOWN_KEYS="GH_SCREENSHOTS_BUCKET GH_SCREENSHOTS_PUBLIC_BASE GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID GH_SCREENSHOTS_R2_ACCESS_KEY_ID GH_SCREENSHOTS_R2_SECRET_ACCESS_KEY GH_SCREENSHOTS_R2_ENDPOINT GH_SCREENSHOTS_BACKEND GH_SCREENSHOTS_DEFAULT_WIDTH UPLOADS_TOKEN UPLOADS_API_URL UPLOADS_WORKSPACE"

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

has_s3_creds() {
  [ -n "${GH_SCREENSHOTS_R2_ACCESS_KEY_ID:-}" ] && [ -n "${GH_SCREENSHOTS_R2_SECRET_ACCESS_KEY:-}" ]
}

has_uploads_cli() {
  command -v uploads >/dev/null 2>&1
}

has_uploads_token() {
  [ -n "${UPLOADS_TOKEN:-}" ]
}

r2_s3_endpoint() {
  if [ -n "${GH_SCREENSHOTS_R2_ENDPOINT:-}" ]; then
    printf '%s' "${GH_SCREENSHOTS_R2_ENDPOINT%/}"
    return 0
  fi
  if [ -n "${GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    printf 'https://%s.r2.cloudflarestorage.com' "$GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID"
    return 0
  fi
  return 1
}

run_s3_upload() {
  local endpoint
  endpoint="$(r2_s3_endpoint)" || {
    echo "error: S3 credentials are set but no R2 endpoint is configured." >&2
    echo "       Set GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID (endpoint is derived as" >&2
    echo "       https://<account-id>.r2.cloudflarestorage.com) or set" >&2
    echo "       GH_SCREENSHOTS_R2_ENDPOINT explicitly." >&2
    exit 1
  }
  local s3_script="${GH_SCREENSHOTS_S3_UPLOADER:-$SCRIPT_DIR/put-r2-s3.mjs}"
  node "$s3_script" \
    --endpoint "$endpoint" \
    --bucket "$BUCKET" \
    --key "$KEY" \
    --file "$FILE" \
    --content-type "$CT" \
    --access-key-id "$GH_SCREENSHOTS_R2_ACCESS_KEY_ID" \
    --secret-access-key "$GH_SCREENSHOTS_R2_SECRET_ACCESS_KEY"
}

usage() {
  cat <<'EOF'
Usage: upload.sh <local-file> [options]

Upload a local file and print a public URL + GitHub-ready markdown.

Backend (default: auto):
  Prefer the `uploads` CLI when it is installed and a token is configured;
  otherwise upload directly to R2 (S3-compatible API or wrangler).
  Force with --backend uploads|r2 or GH_SCREENSHOTS_BACKEND.

Options:
  --repo  <owner/repo>          Key namespacing (default: cwd git remote)
  --ref   <pr|issue|branch>     Key namespacing (default: today's date)
  --alt   "description"         Alt text for the emitted markdown (default: file basename)
  --width <px>                  Emit an <img width=...> tag (or GH_SCREENSHOTS_DEFAULT_WIDTH)
  --key   <explicit/key.ext>    Override the auto-generated object key entirely
  --pr    <num>                 Stable PR attachment key (uploads backend; implies gh/)
  --issue <num>                 Stable issue attachment key (uploads backend; implies gh/)
  --comment                     With --pr/--issue: create/update the attachments comment
                                (uploads backend; requires authenticated `gh`)
  --destination <id>            Typed root: screenshots | gh | f (uploads backend)
  --no-optimize                 Skip client-side image optimization (uploads backend)
  --frame <id>                  Device/browser chrome before upload (uploads backend)
  --frame-url <url>             Address bar text for --frame browser
  --format human|url|markdown|json  Stdout shape (default: human — URL + MARKDOWN lines)
  --backend auto|uploads|r2     Force a backend (default: auto / GH_SCREENSHOTS_BACKEND)
  --env-file <path>             Read config from this file instead of the default
  -h, --help                    Show this help

Examples:
  upload.sh /tmp/feed.png --repo myorg/myapp --ref 1722 --alt "New feed cards" --width 700
  upload.sh ./after.png --pr 123 --alt "Dashboard after" --comment
  upload.sh ./diagram.png --key docs/architecture/flow.png
  upload.sh ./shot.png --backend r2 --repo myorg/myapp --ref 42
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0;; esac

FILE="$1"; shift
REPO=""; REF=""; ALT=""; WIDTH=""; KEY=""; ENV_FILE=""
PR=""; ISSUE=""; COMMENT=false; DESTINATION=""; NO_OPTIMIZE=false
FRAME=""; FRAME_URL=""; FORMAT=""; BACKEND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--ref|--alt|--width|--key|--env-file|--pr|--issue|--destination|--frame|--frame-url|--format|--backend)
      if [ $# -lt 2 ]; then
        echo "error: $1 requires a value" >&2; usage; exit 2
      fi
      case "$1" in
        --repo)        REPO="$2";;
        --ref)         REF="$2";;
        --alt)         ALT="$2";;
        --width)       WIDTH="$2";;
        --key)         KEY="$2";;
        --env-file)    ENV_FILE="$2";;
        --pr)          PR="$2";;
        --issue)       ISSUE="$2";;
        --destination) DESTINATION="$2";;
        --frame)       FRAME="$2";;
        --frame-url)   FRAME_URL="$2";;
        --format)      FORMAT="$2";;
        --backend)     BACKEND="$2";;
      esac
      shift 2;;
    --comment)     COMMENT=true; shift;;
    --no-optimize) NO_OPTIMIZE=true; shift;;
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

# Default width from config when the caller did not pass --width.
if [ -z "$WIDTH" ] && [ -n "${GH_SCREENSHOTS_DEFAULT_WIDTH:-}" ]; then
  WIDTH="$GH_SCREENSHOTS_DEFAULT_WIDTH"
fi

# --- flag validation shared by both backends ---
if [ -n "$PR" ] && [ -n "$ISSUE" ]; then
  echo "error: --pr and --issue are mutually exclusive" >&2
  exit 2
fi
if { [ -n "$PR" ] || [ -n "$ISSUE" ]; } && { [ -n "$KEY" ] || [ -n "$REF" ]; }; then
  echo "error: --pr/--issue cannot be combined with --key or --ref" >&2
  exit 2
fi
if [ "$COMMENT" = true ] && [ -z "$PR" ] && [ -z "$ISSUE" ]; then
  echo "error: --comment requires --pr or --issue" >&2
  exit 2
fi
if [ -n "$FORMAT" ]; then
  case "$FORMAT" in
    human|url|markdown|json) ;;
    *) echo "error: invalid --format: $FORMAT (use human|url|markdown|json)" >&2; exit 2;;
  esac
fi

# --- resolve backend ---
if [ -z "$BACKEND" ]; then
  BACKEND="${GH_SCREENSHOTS_BACKEND:-auto}"
fi
case "$BACKEND" in
  auto|uploads|r2) ;;
  *) echo "error: invalid --backend: $BACKEND (use auto|uploads|r2)" >&2; exit 2;;
esac

resolve_backend() {
  case "$BACKEND" in
    uploads)
      if ! has_uploads_cli; then
        echo "error: --backend uploads requires the \`uploads\` CLI on PATH." >&2
        echo "       Install: npm install --global @buildinternet/uploads" >&2
        exit 1
      fi
      if ! has_uploads_token; then
        echo "error: --backend uploads requires UPLOADS_TOKEN (env, --env-file, or config)." >&2
        echo "       Run: uploads login   (or uploads doctor to diagnose)" >&2
        exit 1
      fi
      printf 'uploads'
      ;;
    r2)
      printf 'r2'
      ;;
    auto)
      if has_uploads_cli && has_uploads_token; then
        printf 'uploads'
      else
        printf 'r2'
      fi
      ;;
  esac
}

CHOSEN="$(resolve_backend)"

# ---------------------------------------------------------------------------
# Backend: uploads CLI
# ---------------------------------------------------------------------------
if [ "$CHOSEN" = "uploads" ]; then
  UPLOADS_ARGS=(put "$FILE")
  [ -n "$REPO" ]        && UPLOADS_ARGS+=(--repo "$REPO")
  [ -n "$REF" ]         && UPLOADS_ARGS+=(--ref "$REF")
  [ -n "$ALT" ]         && UPLOADS_ARGS+=(--alt "$ALT")
  [ -n "$WIDTH" ]       && UPLOADS_ARGS+=(--width "$WIDTH")
  [ -n "$KEY" ]         && UPLOADS_ARGS+=(--key "$KEY")
  [ -n "$PR" ]          && UPLOADS_ARGS+=(--pr "$PR")
  [ -n "$ISSUE" ]       && UPLOADS_ARGS+=(--issue "$ISSUE")
  [ "$COMMENT" = true ] && UPLOADS_ARGS+=(--comment)
  [ -n "$DESTINATION" ] && UPLOADS_ARGS+=(--destination "$DESTINATION")
  [ "$NO_OPTIMIZE" = true ] && UPLOADS_ARGS+=(--no-optimize)
  [ -n "$FRAME" ]       && UPLOADS_ARGS+=(--frame "$FRAME")
  [ -n "$FRAME_URL" ]   && UPLOADS_ARGS+=(--frame-url "$FRAME_URL")
  [ -n "$FORMAT" ]      && UPLOADS_ARGS+=(--format "$FORMAT")

  GLOBAL_ARGS=()
  [ -n "$ENV_FILE" ] && GLOBAL_ARGS+=(--env-file "$ENV_FILE")

  echo ">> uploading $FILE" >&2
  echo ">> via: uploads CLI" >&2
  # Human progress on stderr; URL/markdown/json on stdout — pass through.
  exec uploads "${GLOBAL_ARGS[@]}" "${UPLOADS_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Backend: direct R2 (S3 or wrangler)
# ---------------------------------------------------------------------------

# Flags that only the uploads backend implements.
uploads_only_used=false
if [ -n "$PR" ] || [ -n "$ISSUE" ] || [ "$COMMENT" = true ] || [ -n "$DESTINATION" ] \
  || [ "$NO_OPTIMIZE" = true ] || [ -n "$FRAME" ] || [ -n "$FRAME_URL" ]; then
  uploads_only_used=true
fi
if [ "$uploads_only_used" = true ]; then
  {
    echo "error: --pr/--issue/--comment/--destination/--no-optimize/--frame require the uploads backend."
    if [ "$BACKEND" = "r2" ]; then
      echo "       You forced --backend r2 (or GH_SCREENSHOTS_BACKEND=r2). Drop that flag,"
      echo "       or omit the uploads-only options for a plain R2 upload."
    else
      echo "       Install and configure the uploads CLI (uploads login), or set"
      echo "       GH_SCREENSHOTS_BACKEND=uploads / --backend uploads."
      if ! has_uploads_cli; then
        echo "       (uploads CLI not found on PATH — npm install --global @buildinternet/uploads)"
      elif ! has_uploads_token; then
        echo "       (UPLOADS_TOKEN not set — run uploads login or uploads doctor)"
      fi
    fi
  } >&2
  exit 2
fi

BUCKET="${GH_SCREENSHOTS_BUCKET:-}"
PUBLIC_BASE="${GH_SCREENSHOTS_PUBLIC_BASE:-}"
PUBLIC_BASE="${PUBLIC_BASE%/}"  # tolerate a trailing slash

# --- validate config (after --help so help always works without setup) ---
if [ -z "$BUCKET" ] || [ -z "$PUBLIC_BASE" ]; then
  {
    echo "error: no upload backend is ready."
    echo ""
    echo "Preferred — uploads CLI (stable PR keys, optimize, managed comments):"
    echo "  npm install --global @buildinternet/uploads"
    echo "  uploads login"
    echo "  uploads doctor"
    echo ""
    echo "Or configure direct R2 in $CONFIG_FILE:"
    echo "  GH_SCREENSHOTS_BUCKET=your-bucket"
    echo "  GH_SCREENSHOTS_PUBLIC_BASE=https://media.example.com"
    echo "  (recommended) GH_SCREENSHOTS_R2_ACCESS_KEY_ID / _R2_SECRET_ACCESS_KEY + _CLOUDFLARE_ACCOUNT_ID"
    echo "  (fallback) GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN / _ACCOUNT_ID, or run 'wrangler login'."
    echo "Override the path with --env-file <path> or \$BUILDINTERNET_CONFIG."
  } >&2
  exit 1
fi
# Credentials are a soft check for the wrangler path only. When S3 creds are set
# we prefer that narrower-scope upload path and skip wrangler auth nudges.
if has_s3_creds; then
  :
elif [ -z "${GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "note: GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN not set — relying on wrangler's own auth." >&2
  echo "      For least-privilege uploads, set GH_SCREENSHOTS_R2_ACCESS_KEY_ID + GH_SCREENSHOTS_R2_SECRET_ACCESS_KEY" >&2
  echo "      (bucket-scoped Object Read & Write token). Otherwise set GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN + GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID" >&2
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
if has_s3_creds; then
  echo ">> via: R2 S3-compatible API (bucket-scoped credentials)" >&2
  run_s3_upload >&2
else
  echo ">> via: wrangler r2 object put (REST API)" >&2
  run_wrangler r2 object put "${BUCKET}/${KEY}" --file "$FILE" --content-type "$CT" --remote >&2
fi

# --- emit results ---
[ -n "$ALT" ] || ALT="$(basename "$FILE")"
if [ -n "$WIDTH" ]; then
  MD="<img width=\"${WIDTH}\" alt=\"${ALT}\" src=\"${URL}\">"
else
  MD="![${ALT}](${URL})"
fi

case "${FORMAT:-human}" in
  url)
    echo "$URL"
    ;;
  markdown)
    echo "$MD"
    ;;
  json)
    # Minimal JSON without requiring jq.
    node -e '
      const [url, markdown, key] = process.argv.slice(1);
      process.stdout.write(JSON.stringify({ url, markdown, key }) + "\n");
    ' -- "$URL" "$MD" "$KEY"
    ;;
  human|*)
    echo "" >&2
    echo "URL: $URL"
    echo "MARKDOWN: $MD"
    ;;
esac
