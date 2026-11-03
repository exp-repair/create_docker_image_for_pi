---
name: hello-skill
description: Minimal example of a workspace-persisted Pi skill (survives container restart).
---

# hello-skill

This skill lives under `/workspace/skills/hello-skill/`. On container start,
`sync-pi-skills.sh` copies it into `/root/.pi/agent/skills/hello-skill/` as a
real directory (not a symlink).

## Usage

```bash
/workspace/skills/hello-skill/scripts/x.sh
```

To remove it permanently, delete `/workspace/skills/hello-skill/` (not only the
runtime copy under `/root/.pi/agent/skills/`).
