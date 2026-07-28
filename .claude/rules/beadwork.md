<!-- agent-rules: generated v0.14.0 -->
---
description: Work tracking with bw (beadwork). Persists plans, progress, and decisions to git across sessions.
---

## Mandate

ALWAYS run `bw prime` before starting work. Without it, you're missing workflow context, current state, and repo hygiene warnings. Work done without priming often conflicts with in-progress changes.

Committing, closing issues, and syncing are part of completing a task — not separate actions requiring additional permission.

## Common Commands

- `bw prime` — current status of in-flight implementation work
- `bw list --grep "..."` — find tasks (e.g. by spec subject)
- `bw show <task>` — read a task's full description
- `bw close <task>` — close a task once verification passes

## Beadwork ↔ Specled Linking

Every beadwork task that implements behavior includes an `Advances:` field listing the specled subject IDs it advances:

```
Advances: <subject.id>[, <subject.id>...]
```

- To find tasks for a subject: `bw list --grep "Advances:.*<subject.id>"`
- To find specs for a task: read the `Advances:` line, then open `.spec/specs/<subject>.spec.md`

See `specled.md` for what to do with those subjects once you've found them.
