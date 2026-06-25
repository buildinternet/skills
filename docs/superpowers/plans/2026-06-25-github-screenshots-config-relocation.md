# github-screenshots Config Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the github-screenshots skill's config out of the skill folder into a shared, user-owned `~/.config/buildinternet/config`, with namespaced `GH_SCREENSHOTS_*` keys.

**Architecture:** `upload.sh` resolves config per-key from (1) environment, (2) `--env-file`, (3) `$BUILDINTERNET_CONFIG`, (4) the XDG file `~/.config/buildinternet/config`, then falls through to `wrangler login` for auth. The skill's own keys are all `GH_SCREENSHOTS_*`; the two Cloudflare credentials are mapped to the un-prefixed names `wrangler` expects only at the wrangler call site, so the skill never reads ambient `CLOUDFLARE_*`.

**Tech Stack:** Bash (must run on macOS system bash 3.2.57), `wrangler` CLI, `git`.

## Global Constraints

- **Bash 3.2 compatible** — no associative arrays, no `${var^^}`/`${var,,}`, no `mapfile`. Indexed arrays (`local -a`), `${!var}` indirect expansion, and `env VAR=val cmd` are fine.
- **Config keys (exact names):** `GH_SCREENSHOTS_BUCKET`, `GH_SCREENSHOTS_PUBLIC_BASE`, `GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN`, `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID`.
- **Default config path:** `${XDG_CONFIG_HOME:-$HOME/.config}/buildinternet/config`.
- **Explicit-path override env var:** `BUILDINTERNET_CONFIG` (shared, not skill-specific).
- **Resolution order, first match wins per key:** env → `--env-file` → `$BUILDINTERNET_CONFIG` → XDG file → (`wrangler login` for auth only).
- **No backwards compat:** old `R2_SCREENSHOTS_*` / `CLOUDFLARE_*` config keys and the skill-local `.env` are removed outright.
- The skill resolver MUST NOT read ambient `CLOUDFLARE_*`. When the namespaced token is set, it is mapped to `CLOUDFLARE_*` scoped to the wrangler subprocess; when unset, the environment is left untouched (wrangler uses its own auth).
- Avoid "comprehensive"/"world-class"-type language in commit messages.

## File Structure

- `skills/github-screenshots/scripts/upload.sh` — **modify**: config resolver, `--env-file` flag, key renames, credential mapping, first-run hint.
- `skills/github-screenshots/scripts/capture.sh` — **unchanged**; it shells out to `upload.sh` and forwards flags. Verified, not edited.
- `tests/github-screenshots/test_upload.sh` — **create**: bash regression harness using a fake `wrangler`. Lives at repo root (outside `skills/`) so it is not distributed with the skill.
- `skills/github-screenshots/example.env` — **delete**.
- `skills/github-screenshots/config.example` — **create**: reference template documenting the new keys and path.
- `skills/github-screenshots/.gitignore` — **delete** (its only job was ignoring the skill-local `.env`).
- `skills/github-screenshots/SKILL.md` — **modify**: rewrite the "One-time setup" section.
- `README.md` — **modify**: update the `example.env` link to `config.example`.

---

### Task 1: Rewrite config resolution in `upload.sh` (with regression harness)

**Files:**
- Create: `tests/github-screenshots/test_upload.sh`
- Modify: `skills/github-screenshots/scripts/upload.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `upload.sh` reads only `GH_SCREENSHOTS_*` keys; default config path `${XDG_CONFIG_HOME:-$HOME/.config}/buildinternet/config`; supports `--env-file <path>` and `$BUILDINTERNET_CONFIG`; maps `GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN`/`_ACCOUNT_ID` → `CLOUDFLARE_API_TOKEN`/`_ACCOUNT_ID` for the `wrangler` subprocess only when the token is set. Task 2's docs describe these same names/paths.

- [ ] **Step 1: Write the failing test harness**

Create `tests/github-screenshots/test_upload.sh`:

```bash
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
  local envassigns=() ; while [ "$1" != "--" ]; do envassigns+=("$1"); shift; done; shift
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
cat > "$SANDBOX/alt.config" <<'CFG'
GH_SCREENSHOTS_BUCKET=altbucket
GH_SCREENSHOTS_PUBLIC_BASE=https://alt.example.com
CFG
run_upload -- "$SANDBOX/shot.png" --env-file "$SANDBOX/alt.config" --key k/z.png ; rc=$?
check "env-file exits 0" "$rc" "0"
contains "env-file used for bucket" "$(cat "$WRANGLER_LOG")" "altbucket/k/z.png"
contains "env-file used for public base" "$(cat "$SANDBOX/stdout")" "https://alt.example.com/k/z.png"

# --- Case 5: namespaced token is mapped to CLOUDFLARE_* and beats ambient ---
run_upload \
  CLOUDFLARE_API_TOKEN=DECOY \
  GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN=REALTOKEN \
  GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID=ACCT123 \
  -- "$SANDBOX/shot.png" --key k/z.png ; rc=$?
check "cred-map exits 0" "$rc" "0"
contains "namespaced token mapped to CLOUDFLARE_API_TOKEN" "$(cat "$WRANGLER_LOG")" "CLOUDFLARE_API_TOKEN=REALTOKEN"
contains "namespaced account mapped" "$(cat "$WRANGLER_LOG")" "CLOUDFLARE_ACCOUNT_ID=ACCT123"

# --- Case 6: no namespaced token → fall through (wrangler keeps its own auth) ---
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

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `bash tests/github-screenshots/test_upload.sh`
Expected: FAIL — the current `upload.sh` uses `R2_SCREENSHOTS_*` keys and the skill-local `.env`, so cases 1–7 fail (wrong key names, no `--env-file`, hint text mismatch).

- [ ] **Step 3: Rewrite the config block in `upload.sh`**

Replace the top config block — current lines 6–31, from `SCRIPT_DIR=...` through the `PUBLIC_BASE="${PUBLIC_BASE%/}"` line — with:

```bash
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
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"   # strip optional surrounding quotes
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
```

Note: config loading and `BUCKET`/`PUBLIC_BASE` assignment now happen *after*
argument parsing (so `--env-file` is known first) — added in Step 4. Remove the
old `SKILL_DIR`, `SKILL_ENV`, the old `load_env_softly` call, and the old
`BUCKET=...`/`PUBLIC_BASE=...` lines from this location.

- [ ] **Step 4: Add the `--env-file` flag, then resolve + validate after parsing**

In the option-parsing `while` loop (currently lines 56–66), add an `--env-file` case alongside the others:

```bash
    --repo)     REPO="$2"; shift 2;;
    --ref)      REF="$2"; shift 2;;
    --alt)      ALT="$2"; shift 2;;
    --width)    WIDTH="$2"; shift 2;;
    --key)      KEY="$2"; shift 2;;
    --env-file) ENV_FILE="$2"; shift 2;;
```

Initialize `ENV_FILE=""` next to the other `REPO=""; REF=""; ...` defaults (current line 55).

Add `--env-file <path>` to the `usage()` heredoc options list (current lines 38–43):

```
  --env-file <path>             Read config from this file instead of the default
```

Immediately after the `[ -f "$FILE" ] || { ...; exit 1; }` file-existence check (current line 68), insert config resolution + the `BUCKET`/`PUBLIC_BASE` assignment:

```bash
# --- resolve the config file, then soft-load any keys not already in the env ---
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
```

- [ ] **Step 5: Replace the validation + credential-note block with the first-run hint**

Replace the current validation block (lines 70–82, the `if [ -z "$BUCKET" ] ...` through the credentials `note:` block) with:

```bash
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
```

- [ ] **Step 6: Route the upload through `run_wrangler`**

Change the upload line (current line 122) from:

```bash
wrangler r2 object put "${BUCKET}/${KEY}" --file "$FILE" --content-type "$CT" --remote >&2
```

to:

```bash
run_wrangler r2 object put "${BUCKET}/${KEY}" --file "$FILE" --content-type "$CT" --remote >&2
```

- [ ] **Step 7: Run the harness to verify it passes**

Run: `bash tests/github-screenshots/test_upload.sh`
Expected: `PASS=N FAIL=0` and exit 0 — all seven cases pass.

- [ ] **Step 8: Commit**

```bash
git add skills/github-screenshots/scripts/upload.sh tests/github-screenshots/test_upload.sh
git commit -m "feat(github-screenshots): resolve config from shared buildinternet dir with namespaced keys"
```

---

### Task 2: Update docs, templates, and cleanup

**Files:**
- Delete: `skills/github-screenshots/example.env`
- Delete: `skills/github-screenshots/.gitignore`
- Create: `skills/github-screenshots/config.example`
- Modify: `skills/github-screenshots/SKILL.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the key names, path, and resolution order produced by Task 1.
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Delete the obsolete skill-local files**

```bash
git rm skills/github-screenshots/example.env skills/github-screenshots/.gitignore
```

- [ ] **Step 2: Create `config.example`**

Create `skills/github-screenshots/config.example`:

```bash
# github-screenshots configuration — REFERENCE ONLY.
#
# The skill does NOT read this file. Copy the keys below into your shared
# buildinternet config file and fill in the values:
#
#   ~/.config/buildinternet/config        (or $XDG_CONFIG_HOME/buildinternet/config)
#
# Other buildinternet skills share that same file; each reads only its own
# prefixed keys, so just append these lines to it.
#
# Resolution order (first match wins, per key):
#   1. environment variables (GH_SCREENSHOTS_* already exported)
#   2. --env-file <path>
#   3. $BUILDINTERNET_CONFIG
#   4. ~/.config/buildinternet/config
# Credentials may instead come from `wrangler login`.

# --- Bucket (required) ------------------------------------------------------
# The R2 bucket to upload into, and its public base URL (a custom domain bound
# to the bucket). Set both so the printed URL matches where the object lands.
GH_SCREENSHOTS_BUCKET=
GH_SCREENSHOTS_PUBLIC_BASE=

# --- Credentials (optional; or use `wrangler login`) ------------------------
# A Cloudflare API token with R2 read/write, plus the account ID. Namespaced so
# the skill never picks up an unrelated ambient CLOUDFLARE_API_TOKEN.
GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN=
GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID=
```

- [ ] **Step 3: Rewrite the "One-time setup" section of `SKILL.md`**

Replace the section spanning current lines 29–43 (from `## One-time setup` through the `public custom domain` line) with:

```markdown
## One-time setup

The script needs to know which bucket to write to and how to authenticate. Config
lives in a shared, user-owned file — **not** in this skill folder, so it survives
reinstalls and updates:

```
~/.config/buildinternet/config        # or $XDG_CONFIG_HOME/buildinternet/config
```

Copy the keys from `config.example` into that file and fill them in. Other
buildinternet skills share the same file; each reads only its own prefixed keys.

Keys (all required unless noted):

- `GH_SCREENSHOTS_BUCKET` — the R2 bucket name.
- `GH_SCREENSHOTS_PUBLIC_BASE` — the bucket's public base URL, e.g.
  `https://media.example.com`.
- `GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN` + `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID` —
  an API token with R2 read/write and the account ID. Optional if you instead
  `wrangler login` to that account. These are namespaced so the skill never
  picks up an unrelated ambient `CLOUDFLARE_API_TOKEN`.

Config resolves per key, first match wins: the environment (any exported
`GH_SCREENSHOTS_*` wins) → `--env-file <path>` → `$BUILDINTERNET_CONFIG` →
`~/.config/buildinternet/config`. For a one-off run against a different bucket,
just export the var or pass `--env-file`.

Requires the [`wrangler`](https://developers.cloudflare.com/workers/wrangler/) CLI
and a bucket with a [public custom domain](https://developers.cloudflare.com/r2/buckets/public-buckets/).
```

- [ ] **Step 4: Update the inline command example in `SKILL.md`**

In the "2. Upload" section, update the underlying-command comment block (current lines 130–133) to the new variable names:

```bash
wrangler r2 object put "$GH_SCREENSHOTS_BUCKET/<key>" --file <local-file> \
  --content-type image/png --remote
# → $GH_SCREENSHOTS_PUBLIC_BASE/<key>
```

And in the "Notes" section, update the deletion example (current line 175–176) to:

```bash
wrangler r2 object delete "$GH_SCREENSHOTS_BUCKET/<key>" --remote
```

- [ ] **Step 5: Update the `README.md` reference**

In `README.md`, the github-screenshots paragraph currently ends:

```
skill needs a Cloudflare R2 bucket + `wrangler`; see its
[`example.env`](./skills/github-screenshots/example.env).
```

Replace with:

```
skill needs a Cloudflare R2 bucket + `wrangler`; see its
[`config.example`](./skills/github-screenshots/config.example).
```

- [ ] **Step 6: Verify no stale references remain**

Run:
```bash
grep -rn -e 'R2_SCREENSHOTS_' -e 'example\.env' -e 'SKILL_ENV' \
  skills/github-screenshots README.md
```
Expected: no output (exit 1 from grep). Any hit is a missed rename — fix it before committing.

- [ ] **Step 7: Re-run the regression harness (docs changes must not break it)**

Run: `bash tests/github-screenshots/test_upload.sh`
Expected: `PASS=N FAIL=0`.

- [ ] **Step 8: Commit**

```bash
git add -A skills/github-screenshots README.md
git commit -m "docs(github-screenshots): document shared buildinternet config; drop skill-local .env"
```

---

## Self-Review Notes

- **Spec coverage:** resolution order (Task 1 Steps 3–5, tests cases 2–4), `GH_SCREENSHOTS_*` rename (Task 1 + Task 2), credential namespacing/mapping (Task 1 Steps 3/6, test cases 5–7), first-run hint (Task 1 Step 5, test case 1), delete `example.env`/`.gitignore` (Task 2 Step 1), `config.example` (Task 2 Step 2), `SKILL.md` rewrite (Task 2 Steps 3–4), README (Task 2 Step 5). `capture.sh` unchanged passthrough is covered implicitly — it calls `upload.sh` with `--repo/--ref/--alt/--width`, none of which changed.
- **Out of scope (per spec):** project-local walk-up, backwards compat, hard-unset of ambient `CLOUDFLARE_*` — none added.
- **Bash 3.2:** uses `local -a`, `${!k:-}`, `env VAR=val cmd` only.
```
