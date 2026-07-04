---
name: Lint the docs against the code
description: Drift check for Supacool's documentation. Use when asked to lint/audit the docs, when docs "feel stale", after a big refactor, or as a periodic (roughly monthly) maintenance pass. Compares doc claims against the actual code and reports or fixes what drifted.
---

# docs-lint — keep the wiki honest

The documentation system (see `AGENTS.md` § Documentation system) only works if drift is
caught. This skill is the **lint** operation: verify what the docs claim against what the
code does, then report — and, if asked, fix.

## Scope

Check these, in priority order:

1. `AGENTS.md` (schema + index — the two tables, the "What's in / out" lists, repo layout)
2. `docs/agent-guides/features.md` (every row: files exist? feature description current?)
3. `docs/agent-guides/*.md` (each page's concrete claims)
4. `.claude/skills/*/SKILL.md` (commands, paths, and workflow rules in skills)

## The checks

For each doc, extract its **verifiable claims** and test them cheaply:

- **Paths & names**: every file path, type name, function name, key name, env var, and
  CLI command the doc mentions. Verify with `fd` / `rg` — a name with zero hits in the
  codebase is drift (moved, renamed, or deleted).
- **Build/test invocations**: project (`supacool.xcodeproj`), scheme (`supacool`), test
  target (`supacoolTests`), Make targets. A doc telling an agent to run a nonexistent
  scheme is the worst class of drift — it fails on first use.
- **"Planned"/"future" labels**: anything a doc calls future or unbuilt — check whether
  it shipped (implementation + tests present). Also the reverse: features described as
  current that were removed.
- **Scope claims**: `out-of-scope.md` entries that say "X doesn't exist" — verify X still
  doesn't exist. A scope doc that forbids something already shipped will make agents
  refuse greenlit work.
- **Coverage gaps**: subsystems that exist in code but appear in no doc and have no
  `features.md` row. Heuristics: top-level dirs under `Supacool/Features/` and
  `Supacool/Clients/`, reducers over ~300 lines, anything with its own test file cluster.
- **Inventory lists**: docs that enumerate ("covered types", "persistence paths", the
  feature index) — diff the enumeration against reality (e.g. `fd -e swift . Supacool
  --full-path | rg Persistence`, `ls ~/.supacool/`).

## Output

Produce a ranked drift report: each finding = doc file:line, the stale claim, the current
reality (with code evidence), and severity (fails-on-first-use > misleads > incomplete).

- If the user asked to **fix**: apply the corrections directly (follow
  `docs/agent-guides/` style — synthesis, why-decisions, real file names), then show the
  report as the change summary. Commit per repo workflow rules.
- If the user asked to **check**: report only, no edits.

## Tips

- Parallelize: one Explore sweep per doc cluster (guides vs skills vs AGENTS.md) is much
  faster than serial reading.
- Don't nitpick prose or style — this lint is about *facts*. A doc that reads awkwardly
  but is accurate passes.
- When a fix needs knowledge you can't verify from code alone (why a decision was made),
  flag it as a question for Comandante instead of guessing.
