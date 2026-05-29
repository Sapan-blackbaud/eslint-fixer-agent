# eslint-fixer-agent

A VS Code GitHub Copilot **agent + skill** that systematically eliminates ESLint warnings and errors from a TypeScript / Angular repository.

- **Never silences rules.** No `eslint-disable`, no `@ts-ignore`, no `as any`.
- **Verifies every fix** at the line ESLint reported (±1 line tolerance for formatter drift).
- **Tight feedback loop** — scoped re-lint + `tsc --noEmit` + targeted unit tests between batches.
- **Tiered markdown reports** so you can pick scope (by rule, by category, or by file).
- **Stops on uncertainty** rather than guessing a type or behavior change.

Tested against a real Angular 19 / SkyUX 12 SPA with 10,000+ lint findings.

---

## Requirements

- VS Code with GitHub Copilot (Chat + agent mode)
- PowerShell 7+ (`pwsh`) — the helper scripts are PowerShell
- Node.js + npm (for `eslint`, `tsc`, optionally `ng test`)

> Works on Windows out of the box. macOS/Linux works if you have `pwsh` installed (`brew install --cask powershell` or distro package).

---

## Install

Clone this repo and copy the files into your user-global agents folder.

### PowerShell (Windows / macOS / Linux)

```powershell
git clone https://github.com/Sapan-blackbaud/eslint-fixer-agent.git
cd eslint-fixer-agent

$agents = "$HOME/.agents"
New-Item -ItemType Directory -Force "$agents/agents", "$agents/skills" | Out-Null

Copy-Item -Recurse -Force ./eslint-fixer "$agents/skills/"
Copy-Item -Force ./eslint-fixer.agent.md "$agents/agents/"
```

### bash (macOS / Linux / Git Bash)

```bash
git clone https://github.com/Sapan-blackbaud/eslint-fixer-agent.git
cd eslint-fixer-agent

mkdir -p ~/.agents/agents ~/.agents/skills
cp -r ./eslint-fixer ~/.agents/skills/
cp ./eslint-fixer.agent.md ~/.agents/agents/
```

Restart VS Code (or reload the Copilot Chat window) so it picks up the new agent and skill.

---

## Use

In Copilot Chat (agent mode), invoke the agent:

```
@eslint-fixer clean up lint warnings in this repo
```

Or just describe the intent — the skill description matches phrases like “fix lint warnings”, “clean up eslint”, “reduce lint debt”.

On the first turn the agent will ask:

1. Which repo (local path / workspace folder / git URL).
2. Branch policy (refuse if dirty / stash / new branch / current branch).
3. After producing the inventory: scope (by rule, by category, or by file).

Then it loops: autofix → manual fix → verify → re-report.

---

## Repo layout

```
eslint-fixer-agent/
├─ README.md
├─ LICENSE
├─ eslint-fixer.agent.md            # agent definition (Copilot picks this up)
└─ eslint-fixer/
   ├─ SKILL.md                      # the 9-step workflow playbook
   └─ references/
      ├─ fix-recipes.md             # per-rule fix patterns + anti-patterns
      ├─ generate-lint-report.ps1   # ESLint JSON → 5 markdown reports + worklist.json
      └─ verify-fixes.ps1           # asserts fixes landed, no regressions
```

---

## What it explicitly does NOT do

- Modify `eslint.config.*` or `tsconfig.*`
- Add `eslint-disable` / `@ts-ignore` / `@ts-expect-error` / `as any` / `as unknown as X`
- Change rule severity
- Commit, push, or open PRs (leaves changes staged for review)
- Migrate components to standalone, or other architectural rewrites
- Touch files outside the chosen scope

If you need any of these, you have to opt in explicitly per session.

---

## License

MIT — see [LICENSE](./LICENSE).
