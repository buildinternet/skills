# Build Internet Skills

[![skills.sh](https://skills.sh/b/buildinternet/skills)](https://skills.sh/buildinternet/skills)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

Agent skills for development. Each lives in [`skills/`](./skills) as a self-contained folder with a `SKILL.md`.

## Install

Works with Claude Code, Cursor, Codex, Gemini CLI, and ~50 other agents via the
[`vercel-labs/skills`](https://github.com/vercel-labs/skills) installer:

```bash
npx skills add buildinternet/skills
```

This detects your agent(s) and installs the skills into the right directory. Pass
`--global` to install for all projects, or `--list` to pick individual skills.

## Skills

| Skill | What it does |
|---|---|
| [`github-screenshots`](./skills/github-screenshots) | Host an image on a Cloudflare R2 bucket and embed it in a GitHub PR or issue (agents can't drag-and-drop into the GitHub uploader). |

Per-skill setup and usage live in each skill's `SKILL.md`. The `github-screenshots`
skill needs a Cloudflare R2 bucket + `wrangler`; see its
[`config.example`](./skills/github-screenshots/config.example).

## License

[MIT](./LICENSE)
