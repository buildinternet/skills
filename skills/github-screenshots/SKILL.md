---
name: github-screenshots
description: >-
  Host an image on a Cloudflare R2 bucket you configure and embed it in a GitHub
  pull request or issue. Use this whenever you want to put a screenshot, diagram,
  before/after comparison, GIF, or any image into a PR description, issue body, or
  PR/issue comment — including when the user says "include a screenshot", "show what
  it looks like", "add a screenshot of the UI", "attach an image", or when you've
  just built/changed something visual and a representative shot would make the PR
  clearer. Reach for this instead of trying to drag-and-drop or use the GitHub API
  for uploads (which an agent cannot do).
---

# Embedding screenshots in GitHub PRs and issues

## Why this skill exists

GitHub's native image hosting — the `github.com/user-attachments/...` URLs you get
from drag-and-dropping into the web editor — is only reachable through an
authenticated **browser session**. There is no supported `gh` CLI or REST API
endpoint for it; the web UI signs the upload with a session cookie, not a token.
So when you write a PR/issue body with `gh ... --body-file`, any image URL must
already point at something publicly hosted.

The fix: upload the image to a **Cloudflare R2 bucket you control** that serves
publicly over a custom domain, then reference that `https://<your-domain>/<key>` URL
in the markdown. No repo bloat, no browser, no session — and stable URLs.

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

## The three steps

1. **Capture** the image to a local file.
2. **Upload** it with the bundled script → get a public URL.
3. **Embed** the URL in your PR/issue markdown with good alt text.

### 1. Capture

Use the bundled `capture.sh` script for reliable headless Playwright (Chromium)
captures. It writes a PNG to a known path and prints that path on stdout — no
"where did the file go?" ambiguity.

```bash
<skill-dir>/scripts/capture.sh <url> [options]
```

**Key flags:**

| Flag | Description |
|---|---|
| `--selector <css>` | Capture only that element (element crop). Default: full viewport. |
| `--out <path>` | Output PNG path. Default: `/tmp/screenshot-<timestamp>.png` (path printed on stdout). |
| `--width <px>` / `--height <px>` | Viewport size (default 1280×720). |
| `--full-page` | Capture the entire scrollable page, not just the viewport. |
| `--wait <selector\|ms>` | Wait for a CSS selector to appear, or sleep N milliseconds, before capturing. |
| `--eval <js>` | Run arbitrary JS in the page before capturing (e.g. populate form fields). |
| `--upload` | After capturing, pipe straight into `upload.sh` — capture + upload in one command. |
| `--repo`, `--ref`, `--alt`, `--img-width` | Forwarded to `upload.sh` when using `--upload`. |

**One-liner capture + upload:**

```bash
./scripts/capture.sh https://myapp.example.com \
  --selector ".card" --wait ".card" \
  --upload --repo myorg/myapp --ref 42 --alt "New card design" --img-width 700
```

**React controlled-input gotcha** — setting `.value` on a React input does
nothing because React intercepts the native DOM property. Use the native value
setter and dispatch synthetic events instead:

```js
// Pass this to --eval:
const el = document.querySelector('#my-input');
Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
  .set.call(el, 'my value');
el.dispatchEvent(new Event('input',  { bubbles: true }));
el.dispatchEvent(new Event('change', { bubbles: true }));
```

**Prerequisites:** Node.js + Playwright Chromium.  
First-time setup:
```bash
npx playwright install chromium
```
If the browser is missing, `capture.sh` exits with a clear install hint.

**Other capture methods (alternatives):**

- **Interactive browser tool** (e.g. Claude-in-Chrome): works, but the tool may
  not surface the saved file path — prefer `capture.sh` when you need a known path.
- **Terminal / CLI output:** capture a terminal screenshot separately.
- Already have a file? Skip to step 2.

### 2. Upload

Use the bundled script — it handles auth, content-type, key naming, and prints
ready-to-paste markdown:

```bash
<skill-dir>/scripts/upload.sh <local-file> \
  [--repo <owner/repo>] [--ref <pr-number|issue|branch>] \
  [--alt "description"] [--width <px>] [--key <explicit/key.png>]
```

Example:

```bash
./scripts/upload.sh /tmp/live-feed.png \
  --repo myorg/myapp --ref 1722 --alt "New live feed cards" --width 700
```

It prints the public URL and a markdown snippet. The underlying command is just:

```bash
wrangler r2 object put "$GH_SCREENSHOTS_BUCKET/<key>" --file <local-file> \
  --content-type image/png --remote
# → $GH_SCREENSHOTS_PUBLIC_BASE/<key>
```

**Key naming:** keep uploads namespaced so they don't collide and stay
discoverable. The script defaults to
`screenshots/<repo-name>/<ref-or-date>/<basename>-<shorthash>.<ext>`. Override with
`--key` only when you have a reason to.

### 3. Embed in the PR/issue

Write the markdown to a file and reference the hosted URLs (cleaner than inline
HEREDOCs for `gh ... --body-file`):

```markdown
![New live feed cards](https://media.example.com/screenshots/myapp/1722/live-feed-a1b2c3.png)
```

**Best practices**

- **Always write meaningful alt text** — it's what readers with images disabled (and
  search) see, and it documents intent.
- **Constrain width** for large shots so they don't dominate the page. Markdown can't
  size images, so use an HTML tag:
  `<img width="700" alt="..." src="https://media.example.com/...">`.
- **Before/after** reads best side by side in a table:

  ```markdown
  | Before | After |
  |---|---|
  | <img width="380" src="…/before.png"> | <img width="380" src="…/after.png"> |
  ```

- **One short caption line** under each image when context isn't obvious.
- **GIFs** work the same way — upload the `.gif`, embed with `![...](url)`. (For heavy
  GIFs prefer an MP4, but GitHub markdown won't autoplay an MP4 URL, so a GIF or a
  still-with-link is usually the right call for an embed.)

## Notes

- These uploads are **public and permanent** until someone deletes them. Don't upload
  anything with secrets, tokens, internal dashboards with sensitive data, or customer
  PII visible in the shot. Crop/redact first.
- To remove one later:
  `wrangler r2 object delete "$GH_SCREENSHOTS_BUCKET/<key>" --remote`. Note the public
  URL is CDN-cached (commonly a few hours `max-age`), so it may keep serving a deleted
  object from the edge until the cache expires — the object itself is gone from R2
  immediately.
- This is host-agnostic — the same hosted URLs work in GitHub issues, PR comments,
  discussions, and markdown docs.
