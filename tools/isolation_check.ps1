# Ship gate 1 (plan §6): the addon must be self-contained and Theme-driven.
#
#   ./tools/isolation_check.ps1
#
# Two automated scans over addons/menu_kit/:
#   1. No file references a res:// path outside res://addons/menu_kit/.
#   2. No add_theme_*_override call exists — an override beats the Theme and would make the
#      palette swap (gate 3) a lie. See plan §1.2.
#
# Final line is machine-readable:
#   ISOLATION_RESULT paths=pass overrides=pass exit=0

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$AddonDir = Join-Path $RepoRoot "addons\menu_kit"

if (-not (Test-Path $AddonDir)) {
    Write-Output "ISOLATION_RESULT paths=error overrides=error exit=2  # addon dir not found: $AddonDir"
    exit 2
}

$files = [System.IO.Directory]::GetFiles($AddonDir, "*.*", [System.IO.SearchOption]::AllDirectories) |
    Where-Object { $_ -match '\.(gd|tscn|tres|gdshader|cfg)$' }

# --- Scan 1: foreign res:// paths -------------------------------------------
$pathViolations = @()
$pathRe = [regex]'res://[^"''\s\)\]]+'
foreach ($f in $files) {
    $rel = $f.Substring($RepoRoot.Length + 1)
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        $lineNo++
        foreach ($m in $pathRe.Matches($line)) {
            $p = $m.Value
            if (-not $p.StartsWith("res://addons/menu_kit/")) {
                $pathViolations += "{0}:{1}: {2}" -f $rel, $lineNo, $p
            }
        }
    }
}

# --- Scan 2: add_theme_*_override -------------------------------------------
$overrideViolations = @()
# Two forms, because the scan covers two file types and they spell it differently. In .gd it is the
# call; in .tscn Godot serialises an override as a PROPERTY (theme_override_colors/font_color = ...)
# and never emits the call name — so a call-only regex made the scene half of this gate dead, and a
# panel scene with baked overrides would have passed while being unre-skinnable.
$ovRe = [regex]'add_theme_\w+_override|theme_override_\w+/'
foreach ($f in ($files | Where-Object { $_ -match '\.(gd|tscn)$' })) {
    $rel = $f.Substring($RepoRoot.Length + 1)
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        $lineNo++
        if ($ovRe.IsMatch($line)) {
            $overrideViolations += "{0}:{1}: {2}" -f $rel, $lineNo, $line.Trim()
        }
    }
}

foreach ($v in $pathViolations) { Write-Output ("FOREIGN_PATH: " + $v) }
foreach ($v in $overrideViolations) { Write-Output ("THEME_OVERRIDE: " + $v) }

$pathsField = if ($pathViolations.Count -eq 0) { "pass" } else { "fail($($pathViolations.Count))" }
$ovField = if ($overrideViolations.Count -eq 0) { "pass" } else { "fail($($overrideViolations.Count))" }
$exit = if ($pathViolations.Count -eq 0 -and $overrideViolations.Count -eq 0) { 0 } else { 1 }

Write-Output ("ISOLATION_RESULT paths={0} overrides={1} exit={2}" -f $pathsField, $ovField, $exit)
exit $exit
