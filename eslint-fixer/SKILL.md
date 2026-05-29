---
name: eslint-fixer
description: "Systematically eliminate ESLint warnings/errors from a TypeScript/Angular repo. Use when: cleaning up lint debt, reducing warning counts, fixing eslint issues across a codebase, migrating to stricter lint config. Workflow: clone/pull → install → full lint → tiered report (totals/category, per-file, file×category) → user picks scope (rule, category, or file) → autofix-first → manual fix with line/column verification → scoped re-lint + tsc + targeted unit tests → loop until zero. NEVER disables rules; fixes or stops to ask."
---

# ESLint Fixer Skill

## When to Use

- User asks to "fix lint warnings", "clean up eslint", "reduce lint debt", "knock out warnings" in a repo
- User wants to systematically eliminate ESLint findings (not a single ad-hoc fix)
- Workflow needs to be autonomous, verifiable, and resumable

## Prime Directives

1. **Never silence rules** — no `eslint-disable`, no rule-disable in config, no `// @ts-ignore`, no `as any`. Fix the underlying issue, or stop and ask the user.
2. **Verify each fix at the exact line/column ESLint reported.** A fix is only "done" when:
   a. The file edit lands on the reported line ±1 (compiler/formatter may shift by 1).
   b. A scoped re-lint of that file no longer reports the original `(ruleId, line)` pair.
3. **Tight feedback loop** — re-lint only touched files, not the whole repo, between iterations.
4. **No regressions** — touched files must pass `tsc --noEmit` and targeted unit tests before the batch is considered complete.
5. **Once the user commits to a scope (rule / category / file), do not stop until that scope is zero or genuinely blocked.** Blockers must be reported with concrete reasons.

## Workflow

```
[1] Bootstrap    → ask repo, pull master, npm i
[2] Inventory    → full eslint --format json → 3 markdown reports
[3] Negotiate    → ask user: by rule, by category, or by file?
[4] Plan batch   → pick a slice (usually one rule across N files, or one file end-to-end)
[5] Autofix      → eslint --fix per rule (safe rules only)
[6] Manual fix   → for each remaining message, edit at reported line and verify
[7] Verify       → scoped re-lint + tsc --noEmit + ng test --include (touched scope)
[8] Loop or commit decision → user policy (no commit by default)
[9] Update report → recompute deltas, present, return to [3]
```

---

## [1] Bootstrap

Ask the user (once per session):

- **Repo source**: (a) local folder path, (b) name of an already-open workspace folder, or (c) git URL → clone to temp dir.
- **Branch policy**: ask each time — "Working tree dirty (or not). Should I (i) refuse, (ii) stash, (iii) checkout a new fix branch off `master`/`main`, (iv) work on current branch?"
- **Package manager**: detect from lockfile (`package-lock.json` → npm, `yarn.lock` → yarn, `pnpm-lock.yaml` → pnpm). Confirm.

Then:

```powershell
# Detect default branch
git remote show origin | Select-String 'HEAD branch'
git checkout <default-branch>
git pull --ff-only
npm ci   # prefer ci over install when lockfile is present
```

Verify the lint command exists in `package.json#scripts.lint`. If absent, check `npx eslint --version` works.

---

## [2] Inventory — full lint + tiered reports

Always use the **JSON formatter** — never parse stylish output. Use `--cache` and `--concurrency auto` for speed when supported.

```powershell
npx eslint . --format json -o lint-output.json
# Exit code 1 with no errors = warnings present; exit code 2 = config error (fail loud)
```

If the repo's `ng lint` doesn't accept ESLint flags directly (older Angular CLI), call `eslint` directly. Use `node_modules/.bin/eslint` to ensure the project's own version is used.

Run `[fixer]/references/generate-lint-report.ps1 -InputPath lint-output.json -OutputDir docs/lint-reports/<timestamp>/` to produce **three reports** (the script handles all sectioning):

1. **`01-summary.md`** — totals: warnings, errors, files scanned, files with issues, distinct rules, distinct categories.
2. **`02-by-category.md` + `03-by-rule.md`** — category and rule rollups (warnings, errors, total, files affected).
3. **`04-by-file.md`** — every file with counts (sorted by total desc).
4. **`05-file-detail/<sanitized-path>.md`** — **one file per source file**, each containing that file's issues grouped by category then by rule, with line:column for every message. This is what the agent reads when working a single file.

Reports use **workspace-relative paths only** so they're stable across machines.

Resolve `[fixer]` to this skill's directory: typically `~/.agents/skills/eslint-fixer/`.

---

## [3] Negotiate scope with the user

Present the top of `02-by-category.md` and `03-by-rule.md` (just the top 10 rules + all categories). Then ask **exactly one question** with options:

- **By rule** (recommended for bulk wins, e.g. an autofixable rule with 1000+ hits)
- **By category** (e.g. all `@typescript-eslint/no-unsafe-*` together — share fix techniques)
- **By file** (recommended when a file dominates the list or is being actively refactored)

If the user picks **by file**, follow up: "Within this file, fix all categories at once, or one category at a time?"

If the user picks **by rule** or **by category**, follow up: "Process all affected files at once (batched), or one file at a time with interim review?"

Defaults if the user says "just start": pick the highest-count rule that is fully autofixable, and run autofix across all files.

---

## [4] Plan the batch

Build a deterministic worklist:

```
batch = [(file, line, column, ruleId, message), ...] filtered to chosen scope
```

Sort by `(file, line, column)` so edits within a file flow top-to-bottom (avoids stale line numbers after prior edits).

For large batches (>50 messages), chunk into **groups of ≤30 messages** with a verify step between chunks. This keeps the feedback loop tight and limits blast radius.

---

## [5] Autofix first (cheap wins)

For each rule in scope that has a known auto-fixer, run targeted autofix **per rule, per file**:

```powershell
npx eslint <files...> --rule "<ruleId>: error" --fix --no-error-on-unmatched-pattern
```

Why per-rule: prevents one rule's fixer from creating new issues for another rule and obscuring causes. Why `--rule` override: even if the rule is set to `warn` in config, autofix only runs for active rules — bumping to `error` here is safe because we're not gating on exit code.

After autofix, re-lint just those files (see [7]). Any remaining messages for that rule go to [6].

**Rules to never autofix** (per typescript-eslint guidance and project experience):
- `@typescript-eslint/no-explicit-any` (no safe automated replacement)
- `@typescript-eslint/no-unsafe-*` (requires type understanding)
- `@angular-eslint/template/no-inline-styles` (needs SCSS file decisions)
- `@typescript-eslint/no-deprecated` (replacement API choice is contextual)
- `skyux-eslint-template/*` (project-specific, often needs human design)

See [`references/fix-recipes.md`](./references/fix-recipes.md) for per-rule strategies.

---

## [6] Manual fix loop (the hard part)

For each `(file, line, column, ruleId)`:

1. **Read** ~10 lines around `line` from the file.
2. **Apply** the recipe for `ruleId` from [`references/fix-recipes.md`](./references/fix-recipes.md). If no recipe exists, infer one from the rule's purpose; do not guess at semantics.
3. **Edit** using exact-string replacement (not regex). Include 3–5 lines of context above and below to ensure uniqueness within the file.
4. **Self-verify the edit landed on the right line**:
   - Re-read the file at `[reportedLine - 2, reportedLine + 2]`.
   - Confirm the original offending token at `column` is gone (or transformed as the recipe predicts).
5. **Move to next message** in the worklist.

### Critical: never edit blindly

If the file at `line` no longer matches what the lint message describes (perhaps a previous edit shifted it), do not edit. Re-lint the file to get fresh `(line, column)` data, then resume.

### Critical: stop on uncertainty

If the recipe requires a domain decision (e.g. "what type should this `any` really be?") and the answer isn't obvious from the surrounding code, **stop and ask the user**. Don't substitute `unknown` to "make it green" — that's silencing the rule.

---

## [7] Verify (scoped, fast)

After each chunk (≤30 messages), run **three checks scoped to touched files only**:

### 7a. Scoped re-lint

```powershell
npx eslint <touched-files...> --format json -o .lint-verify.json
```

Then verify with [`references/verify-fixes.ps1`](./references/verify-fixes.ps1):

```powershell
& "$skillDir/references/verify-fixes.ps1" `
    -BaselinePath lint-output.json `
    -CurrentPath .lint-verify.json `
    -ExpectedFixed <worklist.json>
```

The script asserts:
- Every `(file, line±1, ruleId)` from the worklist is no longer present.
- No **new** rule violations have appeared in touched files (regression guard).

If either assertion fails, the chunk is **not done**. Investigate and re-fix; do not move on.

### 7b. TypeScript compile (touched scope)

```powershell
npx tsc --noEmit -p tsconfig.json
```

For Angular projects, use the app's tsconfig (e.g. `tsconfig.app.json`). If too slow on large repos, fall back to `tsc --noEmit --incremental` with a project-specific tsconfig. Fail loud on any new TS error.

### 7c. Unit tests (touched scope)

For Angular/Karma:

```powershell
ng test --watch=false --browsers=ChromeHeadless --include="src/**/<touched>.spec.ts"
```

If a touched file has no spec, log it but don't fail (it was already untested). If a spec exists and fails, **revert the file's edits for that test's source** and re-plan with the user — do not adjust the spec to make it pass.

---

## [8] Commit / staging policy

Default: **do not commit**. Leave changes in the working tree for the user to review and stage. Print a one-line summary:

```
Batch complete: 47 messages fixed across 12 files. 0 regressions. Working tree changes staged for review.
```

If the user explicitly opts in to commits, use one commit per (rule, batch) with message:
```
chore(lint): fix <count> <ruleId> occurrences in <N> files
```

---

## [9] Update report and loop

After verify passes:

1. Move `lint-output.json` to `lint-output.previous.json`.
2. Re-run the full lint (use `--cache` to keep it fast) **once per N batches**, not every batch — full lint is the most expensive step. Scoped re-lint already proved the targeted fixes work; the full re-lint just refreshes the inventory.
3. Regenerate the 3 reports.
4. Show the user a delta: "Was 10,249, now 9,802 (−447). Top remaining: ..."
5. Return to [3].

---

## Failure modes & how to handle them

| Symptom | Cause | Action |
|---|---|---|
| Same lint message re-appears after fix | Edit landed in wrong place, OR fixer reverted (e.g. format-on-save) | Re-read file, confirm edit, disable auto-format for this run |
| New rule violations after a fix | Recipe was wrong, or autofix cascaded | Revert the chunk via `git checkout -- <files>`, re-plan |
| `tsc` errors after fix | Type-level change too aggressive | Narrow the type or revert; never `as any` to silence |
| Tests fail | Behavior change | Revert source for that test, ask user |
| `eslint --cache` returns stale data | File modification time unchanged | Use `--cache-strategy content` or delete `.eslintcache` |
| Parse errors counted as warnings | File excluded from project tsconfig | Report to user; do not "fix" by adding to tsconfig without consent |
| Rule has no autofix and recipe says "manual" but is high-count | E.g. `no-explicit-any` × 1000 | Recommend by-file scope instead; chip away one file at a time |

---

## Quality guardrails (mandatory)

Before declaring a session complete:

- [ ] Total warning count is **strictly lower** than baseline (delta ≥ 0, but ideally what was committed in scope).
- [ ] **No new rules** appear in the report that weren't there before.
- [ ] No `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `as any`, `as unknown as X` introduced by the agent.
- [ ] Working tree compiles (`tsc --noEmit` exit 0).
- [ ] All touched files' spec files (where they exist) pass.

A grep before completion:

```powershell
git diff | Select-String -Pattern 'eslint-disable|@ts-ignore|@ts-expect-error|\bas any\b'
```

Any hit → report to user and ask for confirmation before claiming done.

---

## Performance tips (typescript-eslint guidance)

- Use `--cache` always; `--cache-strategy content` if file mtimes are unreliable.
- Use `--concurrency auto` if ESLint ≥ 9.x (single-thread otherwise; safe to omit).
- Avoid `--fix` across all rules at once — per-rule autofix is more diagnosable.
- For typed rules, ensure `tsconfig.json` doesn't use `**/*` includes (slows pre-parse).
- Single-file lint is **dramatically faster** than full repo lint — exploit this for verification.
- Don't run `eslint-plugin-prettier` formatting via lint — use `prettier --check` separately.

---

## Reference files

- [Per-rule fix recipes](./references/fix-recipes.md) — patterns for the rules you'll encounter
- [Report generator](./references/generate-lint-report.ps1) — produces the 3-tier markdown reports
- [Fix verifier](./references/verify-fixes.ps1) — confirms fixes landed on reported lines and no regressions

---

## What this skill explicitly does NOT do

- Does not modify `eslint.config.*` to disable rules.
- Does not add `// eslint-disable-*` comments.
- Does not change rule severity (warn ↔ error) in project config.
- Does not run formatters (Prettier) as part of fix loop — fixes only what ESLint reports.
- Does not assume the user wants commits — staging only by default.
- Does not push, open PRs, or modify CI.

If any of these are needed for a particular run, ask the user first.
