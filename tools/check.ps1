# The ONE command that proves a MenuKit change is green. Owns class-cache reimport, user://
# isolation, cleanup, and git hygiene internally so callers never need separate commands.
#
#   ./tools/check.ps1                     # fast: (reimport if class cache stale) + compile gate
#   ./tools/check.ps1 -Smokes             # also run every tests/test_*.gd in an isolated user:// profile
#   ./tools/check.ps1 -Isolation          # also run tools/isolation_check.ps1 (ship gate 1)
#   ./tools/check.ps1 -NoImport           # skip the class-cache reimport step
#   ./tools/check.ps1 -Smokes -Filter rebind,navigation   # iteration: run only matching tests
#
# -Filter is a comma-separated list of substrings matched against test filenames; a filtered run is
# a SUBSET, not full proof — VERIFY_RESULT carries a `filter=...` field so it can't be mistaken for
# the whole suite. Always run the full -Smokes gate before committing a phase.
#
# Final line is machine-readable, e.g.:
#   VERIFY_RESULT compile=pass smokes=11/11 git=clean exit=0
#
# Git-hygiene policy (hybrid):
#   - git diff --check failure (whitespace/conflict markers) -> FAIL
#   - gate-introduced tracked drift (before/after delta)      -> FAIL
#   - pre-existing dirty tree (your WIP) only                 -> PASS, reported
param(
    [switch]$Smokes,
    [switch]$Isolation,
    [switch]$NoImport,
    [string[]]$Filter = @(),
    [int]$SmokeTimeoutSec = 120
)

$ErrorActionPreference = "Stop"
# GODOT_BIN env var overrides the default engine path (CI / other machines / version bumps).
$Godot = if ($env:GODOT_BIN) { $env:GODOT_BIN } else { "C:\GodotProjects\Installer\Godot_v4.7-stable_win64_console.exe" }
if (-not (Test-Path $Godot)) {
    Write-Output "VERIFY_RESULT compile=error smokes=skipped git=unknown exit=2  # Godot binary not found: $Godot (set GODOT_BIN)"
    exit 2
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

$TmpDir = Join-Path $RepoRoot ".agent_tmp"
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

$GitBefore = @(git status --porcelain)

function Test-NeedsImport {
    $cache = Join-Path $RepoRoot ".godot\global_script_class_cache.cfg"
    if (-not (Test-Path $cache)) { return $true }
    $cacheTime = (Get-Item $cache).LastWriteTimeUtc
    if ((Get-Item (Join-Path $RepoRoot "project.godot")).LastWriteTimeUtc -gt $cacheTime) { return $true }
    $roots = @("addons", "demo", "tests", "tools") | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path $_ }
    $gd = Get-ChildItem -Path $roots -Recurse -Filter *.gd -File -ErrorAction SilentlyContinue
    foreach ($f in $gd) {
        if ($f.LastWriteTimeUtc -le $cacheTime) { continue }
        if (Select-String -Path $f.FullName -Pattern '^\s*class_name' -Quiet) { return $true }
    }
    return $false
}

# --- Class-cache self-heal -------------------------------------------------
if (-not $NoImport -and (Test-NeedsImport)) {
    Write-Output "IMPORT: class cache stale -> reimporting..."
    $importLog = Join-Path $TmpDir "import.log"
    Start-Process -FilePath $Godot `
        -ArgumentList @("--headless", "--path", ".", "--import") `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $importLog -RedirectStandardError "$importLog.err" | Out-Null
}

# --- Tier 1: compile / scene gate ------------------------------------------
$compileLog = Join-Path $TmpDir "compile.log"
$cproc = Start-Process -FilePath $Godot `
    -ArgumentList @("--headless", "--path", ".", "--script", "tools/check_compile.gd") `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $compileLog -RedirectStandardError "$compileLog.err"
$compileExit = $cproc.ExitCode
$compileStatus = if ($compileExit -eq 0) { "pass" } else { "fail" }

$compileLines = @()
if (Test-Path $compileLog) { $compileLines += Get-Content $compileLog }
if (Test-Path "$compileLog.err") { $compileLines += Get-Content "$compileLog.err" }
$compileLines | Where-Object { $_ -match '^(COMPILE:|\[FAIL\])' } | ForEach-Object { Write-Output $_ }

# --- Tier 2: isolated test sweep -------------------------------------------
$smokesField = "skipped"
$smokesFailed = $false
$failNames = @()

if ($Smokes) {
    if ($compileExit -ne 0) {
        $smokesField = "aborted"
    }
    elseif (-not (Test-Path (Join-Path $RepoRoot "tests"))) {
        $smokesField = "0/0"
        Write-Output "SMOKES: no tests/ directory yet"
    }
    else {
        # Wrapper-owned user:// isolation: child user data lands in a repo-local profile, wiped at the
        # START of every run so a crashed sweep still starts clean. Real user:// is untouched.
        $SmokeProfile = Join-Path $TmpDir "godot_test_profile"
        if (Test-Path $SmokeProfile) { Remove-Item $SmokeProfile -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $SmokeProfile | Out-Null

        $filterPats = @()
        foreach ($item in $Filter) {
            foreach ($p in ([string]$item).Split(",")) {
                $t = $p.Trim()
                if ($t -ne "") { $filterPats += $t }
            }
        }
        $smokeFiles = @()
        foreach ($f in ([System.IO.Directory]::GetFiles((Join-Path $RepoRoot "tests"), "test_*.gd") | Sort-Object)) {
            $fname = [System.IO.Path]::GetFileName($f)
            if ($filterPats.Count -gt 0) {
                $matched = $false
                foreach ($p in $filterPats) { if ($fname -like "*$p*") { $matched = $true; break } }
                if (-not $matched) { continue }
            }
            $smokeFiles += $f
        }
        $pass = 0

        $origAppData = $env:APPDATA
        $env:APPDATA = $SmokeProfile
        $sweepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            foreach ($sf in $smokeFiles) {
                $name = [System.IO.Path]::GetFileName($sf)
                $base = [System.IO.Path]::GetFileNameWithoutExtension($sf)
                $rel = "tests/" + $name
                $log = Join-Path $SmokeProfile ($base + ".log")
                $proc = Start-Process -FilePath $Godot `
                    -ArgumentList @("--headless", "--path", ".", "--script", $rel) `
                    -NoNewWindow -PassThru `
                    -RedirectStandardOutput $log -RedirectStandardError "$log.err"
                # PS 5.1: without -Wait, ExitCode reads $null unless the handle is cached BEFORE exit.
                $null = $proc.Handle
                $timedOut = -not $proc.WaitForExit($SmokeTimeoutSec * 1000)
                if ($timedOut) {
                    try { $proc.Kill() } catch {}
                    $proc.WaitForExit()
                    $failNames += "$name(TIMEOUT_${SmokeTimeoutSec}s)"
                }
                elseif ($proc.ExitCode -eq 0) { $pass++ }
                else { $failNames += $name }
            }
        }
        finally {
            $env:APPDATA = $origAppData
            $sweepWatch.Stop()
        }

        $total = $smokeFiles.Count
        $smokesField = "$pass/$total"
        if ($failNames.Count -gt 0) { $smokesFailed = $true }
        $note = if ($filterPats.Count -gt 0) { " [SUBSET filter=$($filterPats -join ',') -- NOT full proof]" } else { "" }
        Write-Output ("SMOKES: {0}/{1} PASS in {2}s{3}" -f $pass, $total, [math]::Round($sweepWatch.Elapsed.TotalSeconds), $note)
        foreach ($fn in $failNames) { Write-Output ("FAIL: tests/" + $fn) }
    }
}

# --- Isolation scan (opt-in; ship gate 1) ------------------------------------
$isoField = ""
$isoFailed = $false
if ($Isolation) {
    & (Join-Path $PSScriptRoot "isolation_check.ps1")
    if ($LASTEXITCODE -ne 0) { $isoFailed = $true; $isoField = " isolation=fail" } else { $isoField = " isolation=pass" }
}

# --- Git hygiene (hybrid policy) -------------------------------------------
$gitField = "clean"
$gitFail = $false
$insideGit = (Test-Path (Join-Path $RepoRoot ".git"))
if ($insideGit) {
    # PowerShell 5.1 turns a native command's stderr into a terminating NativeCommandError under
    # $ErrorActionPreference = "Stop" — and git writes routine notices (line-ending normalisation,
    # advice) to stderr. Relaxing the preference around the git calls keeps a whitespace notice from
    # failing the whole verification gate. Do NOT reintroduce a `2>$null` redirect here; that is what
    # triggers the wrapping in the first place.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = git diff HEAD --check
        $diffCheckFailed = ($LASTEXITCODE -ne 0)
        $gitAfter = @(git status --porcelain)
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $beforeSet = @{}
    foreach ($l in $GitBefore) { $beforeSet[$l] = $true }
    $drift = @()
    foreach ($l in $gitAfter) { if (-not $beforeSet.ContainsKey($l)) { $drift += $l } }

    if ($diffCheckFailed) {
        $gitField = "diff_check_failed"; $gitFail = $true
        Write-Output "GIT_HYGIENE: diff-check failed"
    }
    elseif ($drift.Count -gt 0) {
        $gitField = "gate_drift"; $gitFail = $true
        $names = ($drift | ForEach-Object { $_.Substring([Math]::Min(3, $_.Length)).Trim() }) -join ", "
        Write-Output ("GIT_HYGIENE: gate introduced {0} worktree change(s): {1}" -f $drift.Count, $names)
    }
    elseif ($GitBefore.Count -gt 0) {
        $gitField = "preexisting_dirty"
        Write-Output ("GIT_HYGIENE: preexisting tracked changes: {0}" -f $GitBefore.Count)
    }
    else {
        Write-Output "GIT_HYGIENE: clean"
    }
}
else {
    $gitField = "no_repo"
}

# --- Final verdict ---------------------------------------------------------
$fail = ($compileExit -ne 0) -or $smokesFailed -or $gitFail -or $isoFailed
$exit = if ($fail) { 1 } else { 0 }

$filterField = if ($Smokes -and $Filter.Count -gt 0) { " filter=" + ($Filter -join ',') } else { "" }
$failedField = if ($smokesFailed) { " failed=" + ($failNames -join ",") } else { "" }
Write-Output ("VERIFY_RESULT compile={0} smokes={1}{2}{3}{4} git={5} exit={6}" -f $compileStatus, $smokesField, $filterField, $failedField, $isoField, $gitField, $exit)
exit $exit
