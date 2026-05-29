<#
.SYNOPSIS
    Generate tiered markdown reports from an ESLint JSON output.

.DESCRIPTION
    Produces five report files:
      01-summary.md           Totals (warnings/errors/files/rules/categories)
      02-by-category.md       Rollup by rule category
      03-by-rule.md           Rollup by specific ruleId
      04-by-file.md           Per-file counts, sorted by total desc
      05-file-detail/         One file per source file with grouped issues (category > rule > line:col)

    All paths in reports are workspace-relative for portability.

.PARAMETER InputPath
    ESLint JSON output (from `eslint --format json -o ...`).

.PARAMETER OutputDir
    Directory to write reports into. Created if missing.

.PARAMETER RepoRoot
    Workspace root used to make paths relative. Defaults to the current working directory.

.EXAMPLE
    .\generate-lint-report.ps1 -InputPath lint-output.json -OutputDir docs/lint-reports/2026-05-29
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputPath)) { throw "Input not found: $InputPath" }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$detailDir = Join-Path $OutputDir '05-file-detail'
if (-not (Test-Path $detailDir)) { New-Item -ItemType Directory -Path $detailDir -Force | Out-Null }

Write-Host "[report] Loading $InputPath ..."
$results = Get-Content $InputPath -Raw | ConvertFrom-Json

$repoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
function Get-RelPath([string]$p) {
    if (-not $p) { return $p }
    $full = [System.IO.Path]::GetFullPath($p)
    if ($full.StartsWith($repoRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($repoRootFull.Length).TrimStart('\','/').Replace('\','/')
    }
    return $p.Replace('\','/')
}

function Get-RuleCategory([string]$rule) {
    if ($rule -like '@typescript-eslint/*')         { return 'TypeScript' }
    if ($rule -like '@angular-eslint/template/*')   { return 'Angular Template' }
    if ($rule -like '@angular-eslint/*')            { return 'Angular' }
    if ($rule -like 'skyux-eslint-template/*')      { return 'SkyUX Template' }
    if ($rule -like 'skyux-*')                      { return 'SkyUX' }
    if ($rule -like '@stylistic/*')                 { return 'Stylistic' }
    if ($rule -like 'rxjs/*')                       { return 'RxJS' }
    if ($rule -like 'import/*')                     { return 'Import' }
    if ($rule -like 'jsdoc/*')                      { return 'JSDoc' }
    if ($rule -like 'sonarjs/*')                    { return 'SonarJS' }
    if ($rule -like 'unicorn/*')                    { return 'Unicorn' }
    if ($rule -like 'prettier/*')                   { return 'Prettier' }
    if ($rule -eq '(parse-error)')                  { return 'Parse Error' }
    return 'Core ESLint'
}

function Get-SafeFileName([string]$relPath) {
    $sanitized = $relPath -replace '[\\/:]', '__' -replace '[^A-Za-z0-9_.\-]', '_'
    return $sanitized + '.md'
}

# Flatten
$all = New-Object System.Collections.Generic.List[object]
$filesWithIssues = 0
$totalFiles = $results.Count
foreach ($f in $results) {
    if (-not $f.messages -or $f.messages.Count -eq 0) { continue }
    $filesWithIssues++
    $rel = Get-RelPath $f.filePath
    foreach ($m in $f.messages) {
        $rule = if ($m.ruleId) { [string]$m.ruleId } else { '(parse-error)' }
        $sev = if ($m.severity -eq 2) { 'error' } else { 'warning' }
        $all.Add([pscustomobject]@{
            File     = $rel
            Rule     = $rule
            Category = Get-RuleCategory $rule
            Severity = $sev
            Line     = [int]$m.line
            Column   = [int]$m.column
            Message  = ([string]$m.message).Trim()
        })
    }
}
$totalWarnings = ($all | Where-Object Severity -eq 'warning').Count
$totalErrors   = ($all | Where-Object Severity -eq 'error').Count

Write-Host "[report] Files: $totalFiles, with-issues: $filesWithIssues, warnings: $totalWarnings, errors: $totalErrors"

# Rollups
$byRule = $all | Group-Object Rule | ForEach-Object {
    [pscustomobject]@{
        Rule     = $_.Name
        Category = Get-RuleCategory $_.Name
        Warnings = ($_.Group | Where-Object Severity -eq 'warning').Count
        Errors   = ($_.Group | Where-Object Severity -eq 'error').Count
        Total    = $_.Count
        Files    = ($_.Group.File | Sort-Object -Unique).Count
    }
} | Sort-Object Total -Descending

$byCategory = $byRule | Group-Object Category | ForEach-Object {
    [pscustomobject]@{
        Category = $_.Name
        Rules    = $_.Count
        Warnings = ($_.Group | Measure-Object Warnings -Sum).Sum
        Errors   = ($_.Group | Measure-Object Errors -Sum).Sum
        Total    = ($_.Group | Measure-Object Total -Sum).Sum
    }
} | Sort-Object Total -Descending

$byFile = $all | Group-Object File | ForEach-Object {
    [pscustomobject]@{
        File     = $_.Name
        Warnings = ($_.Group | Where-Object Severity -eq 'warning').Count
        Errors   = ($_.Group | Where-Object Severity -eq 'error').Count
        Total    = $_.Count
        Rules    = ($_.Group.Rule | Sort-Object -Unique).Count
    }
} | Sort-Object Total -Descending

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

# 01: Summary
$s = [System.Text.StringBuilder]::new()
[void]$s.AppendLine("# ESLint Inventory - Summary")
[void]$s.AppendLine("")
[void]$s.AppendLine("_Generated: ${timestamp}_")
[void]$s.AppendLine("")
[void]$s.AppendLine("| Metric | Count |")
[void]$s.AppendLine("|---|---:|")
[void]$s.AppendLine("| Total warnings | $totalWarnings |")
[void]$s.AppendLine("| Total errors | $totalErrors |")
[void]$s.AppendLine("| Total issues | $($totalWarnings + $totalErrors) |")
[void]$s.AppendLine("| Files scanned | $totalFiles |")
[void]$s.AppendLine("| Files with issues | $filesWithIssues |")
[void]$s.AppendLine("| Distinct rules | $($byRule.Count) |")
[void]$s.AppendLine("| Distinct categories | $($byCategory.Count) |")
[void]$s.AppendLine("")
[void]$s.AppendLine("## Top 10 Rules")
[void]$s.AppendLine("")
[void]$s.AppendLine("| Rule | Category | Total | Files |")
[void]$s.AppendLine("|---|---|---:|---:|")
foreach ($r in ($byRule | Select-Object -First 10)) {
    [void]$s.AppendLine("| ``$($r.Rule)`` | $($r.Category) | $($r.Total) | $($r.Files) |")
}
$s.ToString() | Out-File (Join-Path $OutputDir '01-summary.md') -Encoding utf8

# 02: By category
$s = [System.Text.StringBuilder]::new()
[void]$s.AppendLine("# Issues by Category")
[void]$s.AppendLine("")
[void]$s.AppendLine("_Generated: ${timestamp}_")
[void]$s.AppendLine("")
[void]$s.AppendLine("| Category | Rules | Warnings | Errors | Total |")
[void]$s.AppendLine("|---|---:|---:|---:|---:|")
foreach ($c in $byCategory) {
    [void]$s.AppendLine("| $($c.Category) | $($c.Rules) | $($c.Warnings) | $($c.Errors) | $($c.Total) |")
}
$s.ToString() | Out-File (Join-Path $OutputDir '02-by-category.md') -Encoding utf8

# 03: By rule
$s = [System.Text.StringBuilder]::new()
[void]$s.AppendLine("# Issues by Rule")
[void]$s.AppendLine("")
[void]$s.AppendLine("_Generated: ${timestamp}_")
[void]$s.AppendLine("")
[void]$s.AppendLine("| Rule | Category | Warnings | Errors | Total | Files |")
[void]$s.AppendLine("|---|---|---:|---:|---:|---:|")
foreach ($r in $byRule) {
    [void]$s.AppendLine("| ``$($r.Rule)`` | $($r.Category) | $($r.Warnings) | $($r.Errors) | $($r.Total) | $($r.Files) |")
}
$s.ToString() | Out-File (Join-Path $OutputDir '03-by-rule.md') -Encoding utf8

# 04: By file
$s = [System.Text.StringBuilder]::new()
[void]$s.AppendLine("# Issues by File")
[void]$s.AppendLine("")
[void]$s.AppendLine("_Generated: ${timestamp}_")
[void]$s.AppendLine("")
[void]$s.AppendLine("All $filesWithIssues files with issues, sorted by total count descending.")
[void]$s.AppendLine("")
[void]$s.AppendLine("| File | Warnings | Errors | Distinct Rules | Total |")
[void]$s.AppendLine("|---|---:|---:|---:|---:|")
foreach ($f in $byFile) {
    [void]$s.AppendLine("| $($f.File) | $($f.Warnings) | $($f.Errors) | $($f.Rules) | $($f.Total) |")
}
$s.ToString() | Out-File (Join-Path $OutputDir '04-by-file.md') -Encoding utf8

# 05: Per-file detail (one file per source file)
$byFileGrouped = $all | Group-Object File
foreach ($g in $byFileGrouped) {
    $relFile = $g.Name
    $messages = $g.Group | Sort-Object Line, Column
    $catGroups = $messages | Group-Object Category | Sort-Object Count -Descending

    $s = [System.Text.StringBuilder]::new()
    [void]$s.AppendLine("# $relFile")
    [void]$s.AppendLine("")
    [void]$s.AppendLine("_Generated: ${timestamp}_")
    [void]$s.AppendLine("")
    [void]$s.AppendLine("**Totals:** $($g.Count) issues " +
        "($((($g.Group | Where-Object Severity -eq 'warning').Count)) warnings, " +
        "$((($g.Group | Where-Object Severity -eq 'error').Count)) errors) " +
        "across $((($g.Group.Rule | Sort-Object -Unique).Count)) distinct rules.")
    [void]$s.AppendLine("")

    [void]$s.AppendLine("## Category overview")
    [void]$s.AppendLine("")
    [void]$s.AppendLine("| Category | Count |")
    [void]$s.AppendLine("|---|---:|")
    foreach ($c in $catGroups) {
        [void]$s.AppendLine("| $($c.Name) | $($c.Count) |")
    }
    [void]$s.AppendLine("")

    foreach ($c in $catGroups) {
        [void]$s.AppendLine("## $($c.Name)")
        [void]$s.AppendLine("")
        $ruleGroups = $c.Group | Group-Object Rule | Sort-Object Count -Descending
        foreach ($r in $ruleGroups) {
            [void]$s.AppendLine("### ``$($r.Name)`` ($($r.Count))")
            [void]$s.AppendLine("")
            [void]$s.AppendLine("| Line:Col | Severity | Message |")
            [void]$s.AppendLine("|---:|---|---|")
            foreach ($m in ($r.Group | Sort-Object Line, Column)) {
                $msg = $m.Message -replace '\|','\|' -replace "`r?`n",' '
                [void]$s.AppendLine("| $($m.Line):$($m.Column) | $($m.Severity) | $msg |")
            }
            [void]$s.AppendLine("")
        }
    }

    $outFile = Join-Path $detailDir (Get-SafeFileName $relFile)
    $s.ToString() | Out-File $outFile -Encoding utf8
}

# Worklist JSON for verifier
$worklist = $all | Select-Object File, Line, Column, Rule, Severity
$worklist | ConvertTo-Json -Depth 4 | Out-File (Join-Path $OutputDir 'worklist.json') -Encoding utf8

Write-Host "[report] Wrote reports to $OutputDir"
Write-Host "[report]   01-summary.md, 02-by-category.md, 03-by-rule.md, 04-by-file.md"
Write-Host "[report]   05-file-detail/ ($filesWithIssues files)"
Write-Host "[report]   worklist.json (for verifier)"
