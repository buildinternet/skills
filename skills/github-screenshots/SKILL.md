---
name: github-screenshots
description: >-
  DEPRECATED — this skill has moved to the buildinternet/uploads repo and this
  copy is a pointer only. Do not use it for screenshots, uploads, or GitHub
  embeds. Install the current version instead:
  `npx skills add buildinternet/uploads` (or `uploads install`).
---

# Moved to buildinternet/uploads

This skill is now maintained in the
[uploads repo](https://github.com/buildinternet/uploads) alongside the
`uploads` CLI it drives, and this copy is retired. The bundled Playwright
capture and direct-R2 upload scripts that used to live here have been removed
— the CLI replaced them.

Install the current skills (the `github-screenshots` workflow skill plus the
`uploads-cli` reference):

```bash
npx skills add buildinternet/uploads
```

Or, with the CLI already installed:

```bash
npm install --global @buildinternet/uploads
uploads install
```

If this deprecated copy is still installed alongside the new one, uninstall it
— the two share the `github-screenshots` name and this one should lose.
