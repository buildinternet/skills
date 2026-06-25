#!/usr/bin/env bash
# Regression tests for upload.sh config resolution. Uses a fake `wrangler` on
# PATH that records its received env + args, so nothing hits the network.
# NOTE: no `set -u` — bash 3.2 errors on "${arr[@]}" for an empty array under -u.
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPLOAD="$REPO_ROOT/skills/github-screenshots/scripts/upload.sh"

PASS=0; FAIL=0
ok()   { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL - %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing [$3] in: $2)";; esac; }

# Build an isolated sandbox: fake wrangler + a sample PNG + a clean HOME/XDG.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/xdg" "$SANDBOX/home"
WRANGLER_LOG="$SANDBOX/wrangler.log"

cat > "$SANDBOX/bin/wrangler" <<EOF
#!/usr/bin/env bash
{
  echo "ARGS: \$*"
  echo "CLOUDFLARE_API_TOKEN=\${CLOUDFLARE_API_TOKEN:-}"
  echo "CLOUDFLARE_ACCOUNT_ID=\${CLOUDFLARE_ACCOUNT_ID:-}"
} > "$WRANGLER_LOG"
exit 0
EOF
chmod +x "$SANDBOX/bin/wrangler"

# A non-empty fake file so the file-exists / non-empty checks pass. upload.sh
# does not validate image bytes, and --key skips the shasum step, so any
# non-empty content works.
printf 'fake-png-bytes' > "$SANDBOX/shot.png"

# run_upload <extra-env-assignments...> -- <upload args...>
# Runs upload.sh with PATH pointing at the fake wrangler and a clean config env.
run_upload() {
  [ $# -gt 0 ] || { echo "run_upload: missing -- separator" >&2; return 2; }
  local envassigns=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envassigns+=("$1"); shift; done
  [ "$1" = "--" ] || { echo "run_upload: missing -- separator" >&2; return 2; }
  shift
  rm -f "$WRANGLER_LOG"
  env -i \
    PATH="$SANDBOX/bin:/usr/bin:/bin" \
    HOME="$SANDBOX/home" \
    XDG_CONFIG_HOME="$SANDBOX/xdg" \
    "${envassigns[@]}" \
    bash "$UPLOAD" "$@" 2>"$SANDBOX/stderr" 1>"$SANDBOX/stdout"
  return $?
}

# --- Case 1: no config anywhere → error + first-run hint, no wrangler call ---
run_upload -- "$SANDBOX/shot.png" --key screenshots/x/y.png ; rc=$?
check "no-config exits 1" "$rc" "1"
contains "no-config hint names buildinternet path" "$(cat "$SANDBOX/stderr")" "buildinternet/config"
contains "no-config hint lists bucket key" "$(cat "$SANDBOX/stderr")" "GH_SCREENSHOTS_BUCKET"
[ -f "$WRANGLER_LOG" ] && bad "no-config must not call wrangler" || ok "no-config does not call wrangler"

# --- Case 2: config via XDG file → upload runs, URL uses PUBLIC_BASE ---
mkdir -p "$SANDBOX/xdg/buildinternet"
cat > "$SANDBOX/xdg/buildinternet/config" <<'CFG'
GH_SCREENSHOTS_BUCKET=mybucket
GH_SCREENSHOTS_PUBLIC_BASE=https://media.example.com
CFG
run_upload -- "$SANDBOX/shot.png" --key screenshots/x/y.png ; rc=$?
check "xdg-config exits 0" "$rc" "0"
contains "xdg-config prints public URL" "$(cat "$SANDBOX/stdout")" "https://media.example.com/screenshots/x/y.png"
contains "xdg-config calls wrangler with bucket/key" "$(cat "$WRANGLER_LOG")" "mybucket/screenshots/x/y.png"

# --- Case 3: env var overrides the file, per key ---
run_upload GH_SCREENSHOTS_PUBLIC_BASE=https://cdn.override.test -- \
  "$SANDBOX/shot.png" --key screenshots/x/y.png ; rc=$?
check "env-override exits 0" "$rc" "0"
contains "env overrides file public base" "$(cat "$SANDBOX/stdout")" "https://cdn.override.test/screenshots/x/y.png"

# --- Case 4: --env-file beats the XDG default ---
# CROSS-CASE DEPENDENCY: the XDG config from Case 2 (mybucket / media.example.com)
# is still on disk and intentionally differs from alt.config. Seeing
# altbucket/alt.example.com proves --env-file genuinely won over the XDG default
# rather than just happening to match it — these assertions would fail if
# --env-file were ignored. Do not reorder this before Case 2.
cat > "$SANDBOX/alt.config" <<'CFG'
GH_SCREENSHOTS_BUCKET=altbucket
GH_SCREENSHOTS_PUBLIC_BASE=https://alt.example.com
CFG
run_upload -- "$SANDBOX/shot.png" --env-file "$SANDBOX/alt.config" --key k/z.png ; rc=$?
check "env-file exits 0" "$rc" "0"
contains "env-file used for bucket" "$(cat "$WRANGLER_LOG")" "altbucket/k/z.png"
contains "env-file used for public base" "$(cat "$SANDBOX/stdout")" "https://alt.example.com/k/z.png"

# --- Case 5: namespaced token is mapped to CLOUDFLARE_* and beats ambient ---
# CROSS-CASE DEPENDENCY: BUCKET/PUBLIC_BASE are supplied by the Case 2 XDG config
# still on disk (this case sets only credentials), so the upload reaches wrangler.
# Do not reorder this before Case 2.
run_upload \
  CLOUDFLARE_API_TOKEN=DECOY \
  GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN=REALTOKEN \
  GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID=ACCT123 \
  -- "$SANDBOX/shot.png" --key k/z.png ; rc=$?
check "cred-map exits 0" "$rc" "0"
contains "namespaced token mapped to CLOUDFLARE_API_TOKEN" "$(cat "$WRANGLER_LOG")" "CLOUDFLARE_API_TOKEN=REALTOKEN"
contains "namespaced account mapped" "$(cat "$WRANGLER_LOG")" "CLOUDFLARE_ACCOUNT_ID=ACCT123"

# --- Case 6: no namespaced token → fall through (wrangler keeps its own auth) ---
# CROSS-CASE DEPENDENCY: like Case 5, BUCKET/PUBLIC_BASE come from the Case 2 XDG
# config still on disk (this case sets only an ambient token). Note Case 7 below
# removes that XDG file, so this must stay ahead of Case 7. Do not reorder.
run_upload CLOUDFLARE_API_TOKEN=AMBIENT -- "$SANDBOX/shot.png" --key k/z.png ; rc=$?
check "fallthrough exits 0" "$rc" "0"
contains "fallthrough notes wrangler auth" "$(cat "$SANDBOX/stderr")" "relying on wrangler's own auth"
contains "fallthrough leaves ambient token untouched" "$(cat "$WRANGLER_LOG")" "CLOUDFLARE_API_TOKEN=AMBIENT"

# --- Case 7: resolver does not treat ambient CLOUDFLARE_* as config ---
# (only ambient CLOUDFLARE_* set, no GH_SCREENSHOTS_* anywhere) → still the
# missing-bucket error, proving ambient creds are not mistaken for config.
rm -f "$SANDBOX/xdg/buildinternet/config"
run_upload CLOUDFLARE_API_TOKEN=AMBIENT CLOUDFLARE_ACCOUNT_ID=AMB -- \
  "$SANDBOX/shot.png" --key k/z.png ; rc=$?
check "ambient-only still errors on missing bucket" "$rc" "1"

# --- Case 8: $BUILDINTERNET_CONFIG tier is used when no --env-file is given ---
# XDG config was removed in Case 7, so a working upload here can only come from
# BUILDINTERNET_CONFIG — proving that resolution tier.
cat > "$SANDBOX/bi.config" <<'CFG'
GH_SCREENSHOTS_BUCKET=bibucket
GH_SCREENSHOTS_PUBLIC_BASE=https://bi.example.com
CFG
run_upload BUILDINTERNET_CONFIG="$SANDBOX/bi.config" -- \
  "$SANDBOX/shot.png" --key k/z.png ; rc=$?
check "buildinternet-config exits 0" "$rc" "0"
contains "buildinternet-config used for bucket" "$(cat "$WRANGLER_LOG")" "bibucket/k/z.png"
contains "buildinternet-config used for public base" "$(cat "$SANDBOX/stdout")" "https://bi.example.com/k/z.png"

# --- Case 9: inline `# comment` stripped on unquoted values; `#` preserved
#     inside a quoted value (so URL fragments survive). Uses --env-file so it is
#     independent of any prior case's config. ---
cat > "$SANDBOX/comment.config" <<'CFG'
GH_SCREENSHOTS_BUCKET=cleanbucket   # prod bucket — note the inline comment
GH_SCREENSHOTS_PUBLIC_BASE="https://media.example.com/#cdn"   # quoted, # is part of the value
CFG
run_upload -- "$SANDBOX/shot.png" --env-file "$SANDBOX/comment.config" --key k/z.png ; rc=$?
check "inline-comment exits 0" "$rc" "0"
contains "inline comment stripped from unquoted bucket" "$(cat "$WRANGLER_LOG")" "cleanbucket/k/z.png"
contains "hash inside quoted value preserved" "$(cat "$SANDBOX/stdout")" "https://media.example.com/#cdn/k/z.png"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
