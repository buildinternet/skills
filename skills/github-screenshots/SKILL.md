---
name: github-screenshots
description: >-
  Capture a webpage screenshot (Playwright) and host it for embedding in a GitHub
  pull request or issue. Use this when you need a visual of a live UI — screenshot
  a URL, crop a selector, before/after of a running app — and put the image in a
  PR description, issue body, or comment. Triggers include "screenshot this page",
  "capture the UI", "before/after of the live site", "include a screenshot of …",
  or when you've changed something visual and a representative shot would make the
  PR clearer. Prefers the uploads CLI for hosting when configured; falls back to
  direct R2. For hosting an already-saved local file without capture, use the
  uploads CLI (`uploads put` / `uploads attach`) when available.
---

# Capturing screenshots and embedding them in GitHub

## Why this skill exists

GitHub's native image hosting (`github.com/user-attachments/…`) only works from an
authenticated **browser session**. There is no `gh` CLI or REST API for it. Any
image URL in a PR/issue body written with `gh … --body-file` must already point at
something publicly hosted.

This skill covers two steps agents need:

1. **Capture** a reliable PNG of a live page (Playwright), with a known local path.
2. **Host** that file (or any local image) and get a public URL + markdown snippet.

Hosting prefers the **`uploads` CLI** when it is installed and a token is configured
(stable PR keys, image optimize, managed attachment comments). If not, it falls back
to a **Cloudflare R2 bucket you configure** (S3-compatible API or wrangler).

## One-time setup

### Preferred — uploads CLI

```bash
npm install --global @buildinternet/uploads
uploads login          # short-lived enrollment code from an admin
uploads doctor         # verify health + auth
```

Config is written to `~/.config/buildinternet/config` (or
`$XDG_CONFIG_HOME/buildinternet/config`). You can also set `UPLOADS_TOKEN` /
`UPLOADS_API_URL` / `UPLOADS_WORKSPACE` in the environment or via `--env-file`.

When `uploads` is on `PATH` and `UPLOADS_TOKEN` resolves, `upload.sh` uses it
automatically (`GH_SCREENSHOTS_BACKEND=auto`).

### Fallback — direct R2

If you are not using the uploads CLI, configure a public R2 bucket. Copy keys from
`config.example` into the shared config file:

```
~/.config/buildinternet/config
```

Required:

- `GH_SCREENSHOTS_BUCKET` — R2 bucket name
- `GH_SCREENSHOTS_PUBLIC_BASE` — public base URL, e.g. `https://media.example.com`

**Credentials — pick one path** (S3 recommended for least privilege):

- **Recommended — bucket-scoped S3 credentials:** `GH_SCREENSHOTS_R2_ACCESS_KEY_ID`
  + `GH_SCREENSHOTS_R2_SECRET_ACCESS_KEY`, plus `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID`
  (derives `https://<account-id>.r2.cloudflarestorage.com`) or
  `GH_SCREENSHOTS_R2_ENDPOINT`. Create an **Object Read & Write** token from
  **R2 → Manage API Tokens**, scoped to this bucket.

- **Fallback — wrangler / REST API:** `GH_SCREENSHOTS_CLOUDFLARE_API_TOKEN` +
  `GH_SCREENSHOTS_CLOUDFLARE_ACCOUNT_ID`, or `wrangler login`. Uses
  `wrangler r2 object put` (needs an **Admin Read & Write** R2 token — bucket-scoped
  tokens are rejected by the REST API).

When both S3 and wrangler credentials are set, the S3 path wins.

Optional: `GH_SCREENSHOTS_DEFAULT_WIDTH` (e.g. `700`) so embeds get a width without
passing `--width` every time. `GH_SCREENSHOTS_BACKEND=auto|uploads|r2` forces a
backend (same as `--backend`).

Config resolution (per key, first match wins): environment → `--env-file` →
`$BUILDINTERNET_CONFIG` → `~/.config/buildinternet/config`.

Requires Node.js. The wrangler fallback also needs the
[`wrangler`](https://developers.cloudflare.com/workers/wrangler/) CLI. The bucket
needs a
[public custom domain](https://developers.cloudflare.com/r2/buckets/public-buckets/).

## The three steps

1. **Capture** the image to a local file (or use an existing file).
2. **Upload** it → get a public URL + markdown.
3. **Embed** the URL in your PR/issue markdown with good alt text.

### 1. Capture

Use the bundled `capture.sh` for headless Playwright (Chromium). It writes a PNG
and prints that path on stdout (or uploads and prints URL/markdown when
`--upload` is set).

```bash
<skill-dir>/scripts/capture.sh <url> [options]
```

**Key flags:**

| Flag | Description |
|---|---|
| `--selector <css>` | Capture only that element. Default: full viewport. |
| `--out <path>` | Output PNG path. Default: `/tmp/screenshot-<timestamp>.png`. |
| `--width <px>` / `--height <px>` | Viewport size (default 1280×720). |
| `--full-page` | Entire scrollable page, not just the viewport. |
| `--wait <selector\|ms>` | Wait for a selector, or sleep N ms, before capturing. |
| `--eval <js>` | Run JS in the page before capturing. |
| `--upload` | After capture, run `upload.sh` (see flags below). |
| `--repo`, `--ref`, `--alt`, `--img-width` | Forwarded to `upload.sh`. |
| `--pr`, `--issue`, `--comment` | Forwarded (stable keys + attachments comment; uploads backend). |
| `--destination`, `--no-optimize`, `--frame`, `--frame-url` | Forwarded (uploads backend). |
| `--format`, `--backend`, `--env-file` | Forwarded to `upload.sh`. |

**Capture + upload one-liner (PR attachment):**

```bash
./scripts/capture.sh https://myapp.example.com \
  --selector ".card" --wait ".card" \
  --upload --pr 42 --alt "New card design" --img-width 700
```

**React controlled-input gotcha** — setting `.value` does nothing; use the native
setter and synthetic events:

```js
// Pass this to --eval:
const el = document.querySelector('#my-input');
Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
  .set.call(el, 'my value');
el.dispatchEvent(new Event('input',  { bubbles: true }));
el.dispatchEvent(new Event('change', { bubbles: true }));
```

**Prerequisites:** Node.js + Playwright Chromium.

```bash
npx playwright install chromium
```

If the browser is missing, `capture.sh` exits with a clear install hint.

**Other capture methods:** interactive browser tools, terminal screenshots, or any
local file — skip to step 2 when you already have a path.

### 2. Upload

```bash
<skill-dir>/scripts/upload.sh <local-file> [options]
```

Example:

```bash
./scripts/upload.sh /tmp/live-feed.png \
  --repo myorg/myapp --ref 1722 --alt "New live feed cards" --width 700
```

**Stable PR/issue keys** (uploads backend — re-upload overwrites, URL stays fixed):

```bash
./scripts/upload.sh ./after.png --pr 123 --alt "Dashboard after" --comment
```

Human progress goes to stderr; URL and markdown (or other `--format`) to stdout.

| Flag | Purpose |
|---|---|
| `--repo` / `--ref` | Auto key segments (default: git remote / today's date). |
| `--alt` / `--width` | Markdown embed. |
| `--key` | Explicit object key (skips auto-naming). |
| `--pr` / `--issue` | Stable `gh/…` attachment keys (uploads backend). |
| `--comment` | Create/update the managed attachments comment (needs `gh`). |
| `--destination` | `screenshots` \| `gh` \| `f` (uploads backend). |
| `--no-optimize` / `--frame` | Pass through to uploads CLI. |
| `--format human\|url\|markdown\|json` | Stdout shape (default: `URL:` + `MARKDOWN:` lines). |
| `--backend auto\|uploads\|r2` | Force a hosting path. |
| `--env-file` | Config file override. |

**Key naming (R2 / default uploads put):**  
`screenshots/<repo-name>/<ref-or-date>/<basename>-<shorthash>.<ext>`.  
With `--pr`/`--issue` (uploads): `gh/<owner>/<repo>/pull|issues/<num>/<name>` —
no content hash, safe to hard-code in a PR body and re-upload later.

**Backend cascade**

1. `uploads` CLI when on `PATH` and `UPLOADS_TOKEN` is set (`auto` default).
2. Else R2 via S3 credentials, or wrangler as last resort.

Force with `--backend` or `GH_SCREENSHOTS_BACKEND`. Flags like `--pr` and
`--comment` require the uploads backend; on pure R2 they error with a clear hint.

### 3. Embed in the PR/issue

Write markdown to a file and use `gh … --body-file`:

```markdown
![New live feed cards](https://storage.uploads.sh/…/live-feed.webp)
```

**Best practices**

- **Meaningful alt text** always.
- **Constrain width** on large shots (`--width` or `GH_SCREENSHOTS_DEFAULT_WIDTH`).
  Markdown can't size images — the script emits `<img width="…">` when width is set.
- **Before/after** side by side:

  ```markdown
  | Before | After |
  |---|---|
  | <img width="380" src="…/before.png"> | <img width="380" src="…/after.png"> |
  ```

- **One short caption** when context isn't obvious.
- **GIFs** upload the same way. Heavy motion: prefer GIF or still+link over MP4
  (GitHub markdown won't autoplay MP4 URLs).

If you only need hosting (no capture) and the uploads CLI is installed, prefer:

```bash
uploads put ./shot.png --pr 123 --alt "…" --width 700
uploads attach ./before.png ./after.png   # infers current PR when possible
```

## Notes

- Uploads are **public** until deleted. Don't include secrets, tokens, sensitive
  dashboards, or customer PII — crop/redact first.
- **Cache:** the uploads API uses a short `Cache-Control` (~1 minute), so overwrites
  show up quickly. Custom R2 domains may cache longer at the edge.
- **Delete (R2 path):**  
  `wrangler r2 object delete "$GH_SCREENSHOTS_BUCKET/<key>" --remote`  
  With uploads: `uploads delete <key>` (needs `files:delete` on the token).
- Hosted URLs work in issues, PR comments, discussions, and plain markdown docs.
- Diagnose uploads setup with `uploads doctor`.
