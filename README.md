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
| [`github-screenshots`](./skills/github-screenshots) | **Deprecated — moved to [buildinternet/uploads](https://github.com/buildinternet/uploads).** Install the current version with `npx skills add buildinternet/uploads` (workflow skill + `uploads-cli` reference). This copy is a pointer only. |

Per-skill setup and usage live in each skill's `SKILL.md`.

## License

[MIT](./LICENSE)
