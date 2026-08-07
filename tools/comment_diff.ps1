# comment_diff.ps1 — the Phase 8a token gate (plan §4.4a).
#
# Proves an edit pass is COMMENT-ONLY: strips every comment from every .gd, collapses
# whitespace, and hashes what remains. A cleanup that changes one token is a behaviour
# change smuggled past review, and this is the tool that refuses it.
#
#   ./tools/comment_diff.ps1 -Snapshot   # write .agent_tmp/comment_baseline.txt from the worktree
#   ./tools/comment_diff.ps1 -Compare    # compare the worktree against the baseline; exit 1 on drift
#
# The stripper is string-aware: '#' inside "..." / '...' / """...""" / '''...''' does not
# start a comment; backslash escapes inside single/double strings are honoured. That state
# machine is the whole tool — everything else is hashing.

param(
    [switch]$Snapshot,
    [switch]$Compare
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$baseline = Join-Path $repo ".agent_tmp\comment_baseline.txt"

function Strip-GDComments([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $text.Length
    $inString = $false
    $quote = ""
    $triple = $false
    while ($i -lt $n) {
        $c = $text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if (-not $triple -and $c -eq '\' -and $i + 1 -lt $n) {
                [void]$sb.Append($text[$i + 1]); $i += 2; continue
            }
            if ($triple) {
                if ($c -eq $quote -and $i + 2 -lt $n -and $text[$i + 1] -eq $quote -and $text[$i + 2] -eq $quote) {
                    # closing triple: append the remaining two quotes
                    [void]$sb.Append($text[$i + 1]); [void]$sb.Append($text[$i + 2])
                    $i += 3; $inString = $false; continue
                }
                # a lone quote char inside a triple string is content
            } elseif ($c -eq $quote) {
                $inString = $false
            }
            $i++; continue
        }
        if ($c -eq '"' -or $c -eq "'") {
            $inString = $true; $quote = $c
            if ($i + 2 -lt $n -and $text[$i + 1] -eq $c -and $text[$i + 2] -eq $c) {
                $triple = $true
                [void]$sb.Append($c); [void]$sb.Append($c); [void]$sb.Append($c)
                $i += 3; continue
            }
            $triple = $false
            [void]$sb.Append($c); $i++; continue
        }
        if ($c -eq '#') {
            while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }
            continue
        }
        [void]$sb.Append($c); $i++
    }
    # token-level normalisation: any whitespace run becomes one space
    return ([regex]::Replace($sb.ToString(), '\s+', ' ')).Trim()
}

function Get-Manifest {
    $files = Get-ChildItem -Path (Join-Path $repo "addons"), (Join-Path $repo "demo"), (Join-Path $repo "tests"), (Join-Path $repo "tools") -Recurse -Filter *.gd |
        Sort-Object FullName
    $lines = @()
    foreach ($f in $files) {
        $raw = [System.IO.File]::ReadAllText($f.FullName)
        $stripped = Strip-GDComments $raw
        $sha = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($stripped))).Replace("-", "")
        $rel = $f.FullName.Substring($repo.Length + 1)
        $lines += "$rel=$sha"
    }
    return $lines
}

if ($Snapshot) {
    New-Item -ItemType Directory -Force (Split-Path $baseline) | Out-Null
    Get-Manifest | Out-File -FilePath $baseline -Encoding utf8
    Write-Host "COMMENT_BASELINE: $((Get-Content $baseline).Count) files -> $baseline"
    exit 0
}

if ($Compare) {
    if (-not (Test-Path $baseline)) {
        Write-Host "COMMENT_DIFF_RESULT status=no_baseline exit=1"
        exit 1
    }
    $old = @{}
    foreach ($line in Get-Content $baseline) {
        $idx = $line.LastIndexOf("=")
        if ($idx -gt 0) { $old[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
    $drift = @()
    $new = Get-Manifest
    $seen = @{}
    foreach ($line in $new) {
        $idx = $line.LastIndexOf("=")
        $path = $line.Substring(0, $idx); $sha = $line.Substring($idx + 1)
        $seen[$path] = $true
        if (-not $old.ContainsKey($path)) { $drift += "NEW_FILE: $path" }
        elseif ($old[$path] -ne $sha) { $drift += "TOKEN_DRIFT: $path" }
    }
    foreach ($path in $old.Keys) {
        if (-not $seen.ContainsKey($path)) { $drift += "DELETED: $path" }
    }
    foreach ($d in $drift) { Write-Host $d }
    $status = if ($drift.Count -eq 0) { "identical" } else { "drift($($drift.Count))" }
    $code = if ($drift.Count -eq 0) { 0 } else { 1 }
    Write-Host "COMMENT_DIFF_RESULT status=$status files=$($new.Count) exit=$code"
    exit $code
}

Write-Host "usage: ./tools/comment_diff.ps1 -Snapshot | -Compare"
exit 1
