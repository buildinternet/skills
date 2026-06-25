# github-screenshots: relocate config out of the skill folder

**Date:** 2026-06-25
**Status:** Approved, ready for implementation planning

## Problem

The skill reads its configuration and credentials from a `.env` file **inside
the skill folder** (`skills/github-screenshots/.env`). Because this skill is
distributed and used in several ways — installed as a plugin (lives under
`~/.claude/plugins/cache/...`), cloned and used in place, etc. — the skill
folder is a managed directory that gets replaced or refreshed on update,
re-clone, or `git pull`. Any user-created `.env` there is overwritten and lost.

Storing user-owned state inside the program's own install directory is the root
anti-pattern. CLIs avoid this by keeping config in a stable, user-owned location
*outside* the install dir.

## Goal

Move all configuration to a stable, user-owned location following established
CLI conventions (`gh`, `git`, `wrangler`), so config survives every install
method. No backwards compatibility with the old skill-local `.env` is required —
it is removed outright.

## Design

### Config resolution order (first match wins, per key)

1. **Environment variables** — if a `GH_SCREENSHOTS_*` var is already exported,
   it wins. Covers CI and one-off `GH_SCREENSHOTS_BUCKET=x ./upload.sh`
   overrides.
2. **`--env-file <path>`** — explicit file path passed on the command line
   (overrides the default config location). Handy for testing and power users.
3. **`$BUILDINTERNET_CONFIG`** — env var holding an explicit shared config file
   path, if set. Shared across all buildinternet skills, not skill-specific.
4. **XDG config file** — `${XDG_CONFIG_HOME:-$HOME/.config}/buildinternet/config`,
   the default home for the file.
5. **`wrangler login`** — for Cloudflare auth only, if no token is found by the
   steps above. (`wrangler`'s own auth resolution, untouched.)

The resolver keeps the existing per-key "environment already set wins" behavior
(the current `load_env_softly` logic) — it just points at the new file
location(s) instead of the skill-local `.env`.

### Shared `buildinternet` config location

The config file lives under a repo-wide `buildinternet` namespace
(`~/.config/buildinternet/config`) rather than a per-skill folder, so future
skills in this repo reuse the same file. Collision is avoided because every
key is already prefixed per skill (`GH_SCREENSHOTS_*` here; a future skill uses
its own prefix). A user sets up one file once and each skill reads only the keys
it owns. The `$BUILDINTERNET_CONFIG` override and the XDG default are both
shared, not skill-scoped.

### Config keys (unified `GH_SCREENSHOTS_*` prefix)

| Old | New |
|---|---|
| `R2_SCREENSHOTS_BUCKET` | `GH_SCREENSHOTS_BUCKET` |
| `R2_SCREENSHOTS_PUBLIC_BASE` | `GH_SCREENSHOTS_PUBLIC_BASE` |
| `CLOUDFLARE_API_TOKEN` | `GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN` |
| `CLOUDFLARE_ACCOUNT_ID` | `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID` |

Required: `GH_SCREENSHOTS_BUCKET`, `GH_SCREENSHOTS_PUBLIC_BASE`.
Optional (falls through to `wrangler login` if absent):
`GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN`, `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID`.

### Credential namespacing — the footgun fix

`wrangler` natively reads the un-prefixed `CLOUDFLARE_API_TOKEN` /
`CLOUDFLARE_ACCOUNT_ID` from the environment. If a user has those exported for a
*different* Cloudflare account, the skill would silently authenticate as the
wrong identity.

Fix: the resolver **only ever reads `GH_SCREENSHOTS_*`** — it never reads ambient
`CLOUDFLARE_*`. When (and only when) the namespaced token is set, the script
maps it to the names wrangler expects, scoped to the wrangler subprocess:

```bash
CLOUDFLARE_API_TOKEN="$GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN" \
CLOUDFLARE_ACCOUNT_ID="$GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID" \
  wrangler r2 object put ...
```

**Unset-token behavior (chosen: fall-through):** if
`GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN` is not set, the script does not touch the
environment and lets `wrangler` use its own auth (which includes `wrangler login`,
and ambient `CLOUDFLARE_*` if the user has it). The namespacing already removes
the *silent* part of the footgun — the skill never reads the ambient token on
its own — so hard-isolation (actively unsetting ambient `CLOUDFLARE_*`) is not
implemented, to avoid overriding setups a user may intend.

### First-run experience

When no bucket config is found anywhere, the validation error prints the exact
path to create and the keys to put in it, so setup is copy-paste:

```
error: GH_SCREENSHOTS_BUCKET and GH_SCREENSHOTS_PUBLIC_BASE are not set.
       Create ~/.config/buildinternet/config with:
         GH_SCREENSHOTS_BUCKET=your-bucket
         GH_SCREENSHOTS_PUBLIC_BASE=https://media.example.com
       (optional) GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN / _ACCOUNT_ID, or run 'wrangler login'.
```

(The printed XDG path should respect `$XDG_CONFIG_HOME` when set.)

## Changes

- **`scripts/upload.sh`**
  - Remove `SKILL_ENV="${SKILL_DIR}/.env"` and the skill-local lookup.
  - Implement the resolution order above (env → `--env-file` → `$BUILDINTERNET_CONFIG`
    → XDG `~/.config/buildinternet/config`). Reuse the per-key soft-load logic.
  - Add a `--env-file <path>` flag.
  - Rename all internal references to the new `GH_SCREENSHOTS_*` keys.
  - Map `GH_SCREENSHOTS_CLOUDFLARE_*` → `CLOUDFLARE_*` scoped to the wrangler
    invocation, only when the namespaced token is set.
  - Update the validation error to print the first-run hint with the resolved
    XDG path.
- **`scripts/capture.sh`** — no config logic of its own; verify the `--upload`
  passthrough still works unchanged (it shells out to `upload.sh`).
- **`example.env`** — delete it; replace with a `config.example` template in the
  skill folder (same KEY=VALUE format, new key names) that documents what to copy
  into `~/.config/buildinternet/config`.
- **`.gitignore`** (skill-local) — delete it. Its only purpose was to ignore the
  skill-local `.env` while keeping `example.env`; with no sensitive file living
  in the skill folder anymore, it has nothing to do.
- **`SKILL.md`** — rewrite the "One-time setup" section: new config path,
  resolution order, new key names, credential namespacing note, and the
  `wrangler login` fallback.

## Out of scope (YAGNI)

- Project-local config walk-up (a `.github-screenshots` discovered by walking up
  from `cwd`). Not added unless a concrete multi-bucket-per-project need appears.
- Backwards compatibility with the old `R2_SCREENSHOTS_*` names or the
  skill-local `.env`. Removed outright.
- Hard isolation that unsets ambient `CLOUDFLARE_*`.

## Acceptance criteria

- With config only in `~/.config/buildinternet/config`, `upload.sh`
  resolves the bucket, public base, and (if present) credentials, and uploads
  successfully.
- Re-installing / re-cloning the skill does not disturb the config (it lives
  outside the skill folder).
- Exported `GH_SCREENSHOTS_*` env vars override the config file per key.
- `--env-file <path>` and `$BUILDINTERNET_CONFIG` are honored.
- The skill never reads ambient `CLOUDFLARE_*`; with no namespaced token set,
  `wrangler login` still authenticates uploads.
- Running `upload.sh` with no config prints the copy-paste first-run hint with
  the correct XDG path.
- No `.env` or `example.env` remains in the skill folder; `SKILL.md` documents
  the new location and keys.
