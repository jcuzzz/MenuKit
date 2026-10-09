# Visual capture tool — renders ONE scene via tools/capture_scene.gd (real renderer, brief
# window flash) and saves a PNG under .agent_tmp/captures/ for layout inspection. The agent-side
# answer to "this UI change needs an eyeball" — see docs/tooling/visual_capture.md for the
# ruleset, rig contract, and limits (layout judgment only; F5 still owns interaction/feel).
#
#   ./tools/capture_scene.ps1 -Scene res://scenes/ui/hud/bars_hud.tscn -Rig res://tools/capture_rigs/bars_hud_rig.gd
#   ./tools/capture_scene.ps1 -Scene res://scenes/ui/settings_menu.tscn
#   ./tools/capture_scene.ps1 -Scene res://scenes/ui/hud/bars_hud.tscn -Out my_name.png -Width 1920 -Height 1080
#
# Final line is machine-readable (mirrors check.ps1):
#   CAPTURE_RESULT status=ok scene=... out=... size=1280x720 exit=0
#
# Invoke bare (no pipes/redirects) — allowlists match on command shape. Engine resolution
# (GODOT_BIN, then PATH) is shared with check.ps1.
#
# user:// isolation is OWNED BY THIS WRAPPER, exactly as check.ps1 owns it for the test sweep: the
# child engine runs with APPDATA redirected into a repo-local profile that is wiped at the START of
# every run, so a rig that seeds a roster (characters_rig's MK_CAPTURE_SEED) writes into .agent_tmp
# and never into the developer's real user://. Without it a capture that seeds three characters left
# them in the demo's real profile store, which the next F5 run then showed. The redirect is an
# environment variable only — it does not affect the window the renderer still needs.
param(
    [Parameter(Mandatory = $true)][string]$Scene,
    [string]$Rig = "",
    [string]$Out = "",
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$Frames = 8,
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "godot_bin.ps1")
$Godot = Resolve-GodotBin
if (-not $Godot) {
    Write-Output "CAPTURE_RESULT status=error exit=2  # Godot binary not found (set GODOT_BIN, or put godot on PATH)"
    exit 2
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

$CapDir = Join-Path $RepoRoot ".agent_tmp\captures"
New-Item -ItemType Directory -Force -Path $CapDir | Out-Null

if ($Out -eq "") {
    $Out = [System.IO.Path]::GetFileNameWithoutExtension($Scene) + ".png"
}
$OutAbs = Join-Path $CapDir $Out
# Godot-side path wants forward slashes.
$OutGodot = $OutAbs -replace "\\", "/"

$GodotArgs = @(
    "--path", $RepoRoot,
    "--windowed", "--resolution", "${Width}x${Height}",
    "--script", "tools/capture_scene.gd",
    "--",
    "scene=$Scene", "out=$OutGodot", "frames=$Frames", "width=$Width", "height=$Height"
)
if ($Rig -ne "") { $GodotArgs += "rig=$Rig" }

$StdOut = Join-Path $CapDir "_capture_stdout.log"
$StdErr = Join-Path $CapDir "_capture_stderr.log"

# Wrapper-owned user:// isolation, copied from check.ps1's smoke sweep: wiped at the START of the
# run so a crashed capture still starts clean, and restored in a finally so a failure cannot leak the
# redirect into the caller's session.
$CaptureProfile = Join-Path $RepoRoot ".agent_tmp\godot_capture_profile"
if (Test-Path $CaptureProfile) { Remove-Item $CaptureProfile -Recurse -Force }
New-Item -ItemType Directory -Force -Path $CaptureProfile | Out-Null

$origAppData = $env:APPDATA
$env:APPDATA = $CaptureProfile
try {
    $p = Start-Process -FilePath $Godot -ArgumentList $GodotArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
}
finally {
    $env:APPDATA = $origAppData
}
if ($timedOut) {
    $p.Kill()
    Write-Output "CAPTURE_RESULT status=error exit=3  # timed out after ${TimeoutSec}s (see $StdErr)"
    exit 3
}

# Surface the harness's own CAPTURE_RESULT line (it carries status/size); fall back to a
# synthesized error line if the process died before printing one.
$resultLine = (Select-String -Path $StdOut -Pattern "^CAPTURE_RESULT" | Select-Object -Last 1)
if ($null -ne $resultLine) {
    Write-Output $resultLine.Line
    if ($resultLine.Line -match "status=ok") { exit 0 } else { exit 1 }
}
Write-Output "CAPTURE_RESULT status=error exit=$($p.ExitCode)  # no result line; engine log: $StdErr"
exit ([int]$p.ExitCode)
