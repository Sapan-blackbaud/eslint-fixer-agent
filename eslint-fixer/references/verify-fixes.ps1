<#
.SYNOPSIS
    Verify a batch of ESLint fixes actually landed and produced no regressions.

.DESCRIPTION
    Compares a baseline lint result, a current (post-fix) lint result, and a worklist
    of issues that were SUPPOSED to be fixed. Asserts:

      1. Every (File, Line ±LineTolerance, Rule) in -Expected is GONE from -Current.
      2. No NEW (File, Rule) pairs appear in -Current that weren't in -Baseline
         for the same File (regression guard, scoped to touched files).

    Exits 0 on success, 1 on any assertion failure (with detailed diff to stdout).

.PARAMETER BaselinePath
    Original full eslint --format json output captured before fixes.

.PARAMETER CurrentPath
    Re-lint output AFTER fixes were applied (typically scoped to touched files).

.PARAMETER ExpectedPath
    Worklist JSON (subset of baseline messages) the batch was supposed to fix.
    Use the worklist.json emitted by generate-lint-report.ps1, filtered to scope.

.PARAMETER LineTolerance
    Allowed line drift after edits. Default 1. ESLint reports may shift by ±1
    after a fix on the previous line.

.PARAMETER RepoRoot
    Workspace root for path normalization. Defaults to current directory.

.EXAMPLE
    .\verify-fixes.ps1 -BaselinePath lint-output.json -CurrentPath .lint-verify.json `
                       -ExpectedPath worklist-batch01.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaselinePath,
    [Parameter(Mandatory = $true)][string]$CurrentPath,
    [Parameter(Mandatory = $true)][string]$ExpectedPath,
    [int]$LineTolerance = 1,
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$repoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
function Get-RelPath([string]$p) {
    if (-not $p) { return $p }
    $full = [System.IO.Path]::GetFullPath($p)
    if ($full.StartsWith($repoRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($repoRootFull.Length).TrimStart('\','/').Replace('\','/')
    }
    return $p.Replace('\','/')
}

function Read-Messages([string]$path) {
    $bag = New-Object System.Collections.Generic.List[object]
    $data = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($f in $data) {
        if (-not $f.messages) { continue }
        $rel = Get-RelPath $f.filePath
        foreach ($m in $f.messages) {
            $bag.Add([pscustomobject]@{
                File = $rel
                Rule = if ($m.ruleId) { [string]$m.ruleId } else { '(parse-error)' }
                Line = [int]$m.line
                Column = [int]$m.column
                Severity = if ($m.severity -eq 2) { 'error' } else { 'warning' }
                Message = [string]$m.message
            })
        }
    }
    return ,$bag
}

Write-Host "[verify] Loading baseline / current / expected ..."
$baseline = Read-Messages $BaselinePath
$current  = Read-Messages $CurrentPath
$expectedRaw = Get-Content $ExpectedPath -Raw | ConvertFrom-Json
$expected = foreach ($e in $expectedRaw) {
    [pscustomobject]@{
        File = $e.File.Replace('\','/')
        Rule = [string]$e.Rule
        Line = [int]$e.Line
        Column = [int]$e.Column
    }
}

$touchedFiles = $expected.File | Sort-Object -Unique

# Build lookup of current messages by file
$currentByFile = @{}
foreach ($m in $current) {
    if (-not $currentByFile.ContainsKey($m.File)) {
        $currentByFile[$m.File] = New-Object System.Collections.Generic.List[object]
    }
    $currentByFile[$m.File].Add($m)
}

# ---- Assertion 1: every expected fix is gone ----
$notFixed = New-Object System.Collections.Generic.List[object]
foreach ($exp in $expected) {
    $candidates = $currentByFile[$exp.File]
    if (-not $candidates) { continue }  # whole file is clean of this issue, good
    $still = $candidates | Where-Object {
        $_.Rule -eq $exp.Rule -and [math]::Abs($_.Line - $exp.Line) -le $LineTolerance
    }
    if ($still) {
        $notFixed.Add([pscustomobject]@{
            File = $exp.File
            Rule = $exp.Rule
            ExpectedLine = $exp.Line
            StillAt = ($still | ForEach-Object { "$($_.Line):$($_.Column)" }) -join ', '
        })
    }
}

# ---- Assertion 2: no NEW (File, Rule) regressions in touched files ----
$baselineByFile = @{}
foreach ($m in $baseline) {
    if (-not $baselineByFile.ContainsKey($m.File)) {
        $baselineByFile[$m.File] = New-Object 'System.Collections.Generic.HashSet[string]'
    }
    [void]$baselineByFile[$m.File].Add($m.Rule)
}

$regressions = New-Object System.Collections.Generic.List[object]
foreach ($file in $touchedFiles) {
    $cur = $currentByFile[$file]
    if (-not $cur) { continue }
    $baseRules = $baselineByFile[$file]
    foreach ($m in $cur) {
        $isNewRuleForFile = -not ($baseRules -and $baseRules.Contains($m.Rule))
        if ($isNewRuleForFile) {
            $regressions.Add([pscustomobject]@{
                File = $m.File
                Rule = $m.Rule
                Line = $m.Line
                Column = $m.Column
                Message = $m.Message
            })
        }
    }
}

# ---- Report ----
$ok = $true

Write-Host ""
Write-Host "=== Fix Verification ==="
Write-Host "Expected to fix: $($expected.Count) message(s) across $($touchedFiles.Count) file(s)"
Write-Host "Line tolerance:  ±$LineTolerance"
Write-Host ""

if ($notFixed.Count -gt 0) {
    $ok = $false
    Write-Host "[FAIL] $($notFixed.Count) expected fixes are STILL PRESENT:" -ForegroundColor Red
    foreach ($n in $notFixed) {
        Write-Host "  - $($n.File) :: $($n.Rule) :: expected gone at line $($n.ExpectedLine), still at $($n.StillAt)" -ForegroundColor Red
    }
} else {
    Write-Host "[PASS] All $($expected.Count) expected fixes are gone." -ForegroundColor Green
}

if ($regressions.Count -gt 0) {
    $ok = $false
    Write-Host ""
    Write-Host "[FAIL] $($regressions.Count) NEW rule violations in touched files (regressions):" -ForegroundColor Red
    foreach ($r in $regressions | Select-Object -First 50) {
        Write-Host "  + $($r.File):$($r.Line):$($r.Column) :: $($r.Rule) :: $($r.Message)" -ForegroundColor Red
    }
    if ($regressions.Count -gt 50) {
        Write-Host "  ... and $($regressions.Count - 50) more" -ForegroundColor Red
    }
} else {
    Write-Host "[PASS] No new rules introduced in touched files." -ForegroundColor Green
}

Write-Host ""
if ($ok) {
    Write-Host "Verification OK." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Verification FAILED. Do NOT advance the batch." -ForegroundColor Red
    exit 1
}
