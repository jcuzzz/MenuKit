# Ship gate 2 (plan §6): the COLD DROP. Copy addons/menu_kit/ into a brand-new empty Godot 4.7
# project, enable the plugin, instance the shell, run. Zero errors, zero warnings, zero missing
# dependencies.
#
#   ./tools/cold_drop.ps1
#   ./tools/cold_drop.ps1 -Frames 60      # hold the shell in the tree longer
#   ./tools/cold_drop.ps1 -Keep           # do not wipe the temp project afterwards (inspect it)
#
# Final line is machine-readable (mirrors check.ps1 / isolation_check.ps1):
#   COLD_DROP_RESULT status=pass import=pass boot=pass service=pass noise=0 exit=0
#
# Invoke bare (no pipes/redirects) — allowlists match on command shape. GODOT_BIN overrides the
# engine path, same as check.ps1.
#
# What makes this a COLD drop rather than a second run of the repo's own gate:
#   - The temp project's project.godot is MINIMAL. It carries config_version, an application name,
#     and the enabled-plugin entry — nothing else. In particular it does NOT carry the demo's input
#     actions, its bus layout, its display settings, or an autoload entry: the plugin registers the
#     MKSettingsService autoload itself from plugin.gd's _enter_tree, and a hand-written autoload
#     line here would hide a plugin that had stopped doing so.
#   - The addon is COPIED, so a shipped asset that resolves only because a demo/ sibling happens to
#     exist in the repo fails here.
#
# Three engine passes, all headless:
#   1. --import  — runs the editor, which is what loads an enabled EditorPlugin: this pass is where
#      plugin.gd's _enter_tree runs and writes the menu_kit/config_path project setting, exactly as a
#      host's first editor open would. It also builds .godot/ and the class cache.
#   2. --script cold_drop_boot.gd — instances res://addons/menu_kit/core/mk_root.tscn into the tree
#      for -Frames frames and quits. This is the "instance the main menu, run" half of the gate, on
#      the STANDALONE tier (no settings-service autoload; MKRoot owns its own backend).
#   3. the same boot with the MKSettingsService autoload registered — the SERVICE tier, which is what
#      a real host actually gets, and the one that writes user:// on first boot.
#
# Pass 3 needs the autoload line written by this script, and that is a HARNESS limitation rather than
# an addon defect: plugin.gd does call add_autoload_singleton, and a headless --import demonstrably
# runs it (the menu_kit/config_path key below is written by that same _enter_tree and by nothing
# else), but only ProjectSettings.save() persists to disk in that pass and add_autoload_singleton
# relies on the editor's own save. So the harness asserts the plugin ran, then emulates the one write
# the headless editor does not flush. The name and script path are the plugin's own constants.
#
# user:// isolation is owned by this wrapper, as in check.ps1: the child engines run with APPDATA
# redirected into the temp project's own profile dir, so the settings service's first-boot JSON write
# never lands in the developer's real user://.
param(
    [int]$Frames = 30,
    [int]$TimeoutSec = 180,
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
$Godot = if ($env:GODOT_BIN) { $env:GODOT_BIN } else { "C:\GodotProjects\Installer\Godot_v4.7-stable_win64_console.exe" }
if (-not (Test-Path $Godot)) {
    Write-Output "COLD_DROP_RESULT status=error import=skipped boot=skipped noise=0 exit=2  # Godot binary not found: $Godot (set GODOT_BIN)"
    exit 2
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

$AddonSrc = Join-Path $RepoRoot "addons\menu_kit"
if (-not (Test-Path $AddonSrc)) {
    Write-Output "COLD_DROP_RESULT status=error import=skipped boot=skipped noise=0 exit=2  # addon dir not found: $AddonSrc"
    exit 2
}

# Wiped at the START of every run, like the other wrappers: a crashed drop must not leave a
# half-imported project that the next run then treats as the cold one.
$DropDir = Join-Path $RepoRoot ".agent_tmp\cold_drop"
if (Test-Path $DropDir) { Remove-Item $DropDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DropDir | Out-Null
$ProjectDir = Join-Path $DropDir "project"
New-Item -ItemType Directory -Force -Path $ProjectDir | Out-Null
$ProfileDir = Join-Path $DropDir "profile"
New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

# --- the minimal project ------------------------------------------------------
# ASCII only inside .ps1 string literals (check.ps1 carries the why: PS 5.1 reads this file as ANSI).
$projectGodot = @'
config_version=5

[application]

config/name="MenuKit Cold Drop"
config/features=PackedStringArray("4.7", "Forward Plus")

[editor_plugins]

enabled=PackedStringArray("res://addons/menu_kit/plugin.cfg")
'@
Set-Content -Path (Join-Path $ProjectDir "project.godot") -Value $projectGodot -Encoding ascii

Copy-Item -Path $AddonSrc -Destination (Join-Path $ProjectDir "addons\menu_kit") -Recurse -Force

$bootScript = @'
extends SceneTree
## Cold-drop boot: instance the shell into a bare project and let it live for a few frames.
##
## Written by tools/cold_drop.ps1 into the temp project, not shipped in the addon - the addon may not
## reference a res:// path outside itself (ship gate 1), and this script is host-side by definition.

const ROOT_SCENE := "res://addons/menu_kit/core/mk_root.tscn"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var frames := 30
	for raw in OS.get_cmdline_user_args():
		if raw.begins_with("frames="):
			frames = maxi(int(raw.substr(7)), 1)
	var packed := ResourceLoader.load(ROOT_SCENE) as PackedScene
	if packed == null:
		printerr("COLD_DROP_BOOT: failed to load %s" % ROOT_SCENE)
		quit(1)
		return
	var node := packed.instantiate()
	root.add_child(node)
	for i in frames:
		await process_frame
	# Freed and drained before quit: an engine shutdown with the shell still parented reports leaked
	# RIDs, which would read as a cold-drop defect rather than a harness one.
	node.queue_free()
	await process_frame
	await process_frame
	print("COLD_DROP_BOOT: instanced %s for %d frames" % [ROOT_SCENE, frames])
	quit(0)
'@
Set-Content -Path (Join-Path $ProjectDir "cold_drop_boot.gd") -Value $bootScript -Encoding ascii

# --- noise gate ---------------------------------------------------------------
# The gate's own words are "zero errors, zero warnings, zero missing dependencies", so this matches
# WARNING as well as ERROR - which is stricter than check.ps1's smoke gate (that one deliberately
# omits WARNING because a test provokes one on purpose; nothing here provokes anything).
$NoisePattern = 'SCRIPT ERROR|ERROR|WARNING|Failed to load|missing dependenc'

# The allowlist is EMPTY, and that is a measurement rather than an aspiration: on Godot 4.7 headless
# (v4.7.stable.official.5b4e0cb0f) all three passes below produce zero matching lines on stdout and an
# empty stderr - no main-scene complaint, no driver chatter, nothing. Nothing here is exempted because
# nothing needed to be.
#
# If a future engine does emit unavoidable noise, add the NARROWEST substring plus a comment naming
# the ENGINE as its author and why no addon change removes it. An entry added to quiet a MenuKit
# message is a gate defeat, not an allowlist - that is the whole point of this gate.
$Allow = @()

function Get-Noise([string[]]$Paths) {
    $out = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        foreach ($line in Get-Content $p) {
            if ($line -notmatch $NoisePattern) { continue }
            $allowed = $false
            foreach ($a in $Allow) { if ($line.Contains($a)) { $allowed = $true; break } }
            if (-not $allowed) { $out += $line }
        }
    }
    return $out
}

function Invoke-Godot([string]$LogBase, [string[]]$GodotArgs, [int]$Timeout) {
    $proc = Start-Process -FilePath $Godot -ArgumentList $GodotArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput "$LogBase.log" -RedirectStandardError "$LogBase.err"
    # PS 5.1: cache the handle before exit or ExitCode reads $null (check.ps1 carries the same note).
    $null = $proc.Handle
    if (-not $proc.WaitForExit($Timeout * 1000)) {
        try { $proc.Kill() } catch {}
        $proc.WaitForExit()
        return 124
    }
    return $proc.ExitCode
}

$origAppData = $env:APPDATA
$env:APPDATA = $ProfileDir
try {
    $importExit = Invoke-Godot (Join-Path $DropDir "import") `
        @("--headless", "--path", $ProjectDir, "--import") $TimeoutSec
    $bootExit = 99
    $serviceExit = 99
    if ($importExit -eq 0) {
        $bootExit = Invoke-Godot (Join-Path $DropDir "boot") `
            @("--headless", "--path", $ProjectDir, "--script", "cold_drop_boot.gd", "--", "frames=$Frames") $TimeoutSec
    }
    # Pass 3: the service tier. See the header - the autoload line is the one write the headless
    # editor does not flush, and these are plugin.gd's own constants.
    $writtenProject = Join-Path $ProjectDir "project.godot"
    $pluginRan = (Test-Path $writtenProject) -and ((Get-Content $writtenProject -Raw) -match 'menu_kit')
    if ($importExit -eq 0 -and $bootExit -eq 0 -and $pluginRan) {
        Add-Content -Path $writtenProject -Encoding ascii -Value @'

[autoload]

MKSettingsService="*res://addons/menu_kit/core/mk_settings_service.gd"
'@
        $serviceExit = Invoke-Godot (Join-Path $DropDir "service") `
            @("--headless", "--path", $ProjectDir, "--script", "cold_drop_boot.gd", "--", "frames=$Frames") $TimeoutSec
    }
}
finally {
    $env:APPDATA = $origAppData
}

$noise = @()
$noise += Get-Noise @((Join-Path $DropDir "import.log"), (Join-Path $DropDir "import.err"))
$noise += Get-Noise @((Join-Path $DropDir "boot.log"), (Join-Path $DropDir "boot.err"))
$noise += Get-Noise @((Join-Path $DropDir "service.log"), (Join-Path $DropDir "service.err"))

foreach ($n in $noise) { Write-Output ("COLD_DROP_NOISE: " + $n.Trim()) }

# The plugin's _enter_tree is the only writer of the menu_kit/config_path key, so its presence is the
# proof that enabling the plugin ran plugin code at all - without it passes 2 and 3 would be testing
# a bare scene instance and calling it plugin enablement.
if (-not $pluginRan) {
    Write-Output "COLD_DROP_NOISE: plugin.gd never ran during --import (no menu_kit/config_path key was written)"
}

$importField = if ($importExit -eq 0) { "pass" } elseif ($importExit -eq 124) { "timeout" } else { "fail($importExit)" }
$bootField = if ($importExit -ne 0) { "aborted" } elseif ($bootExit -eq 0) { "pass" } elseif ($bootExit -eq 124) { "timeout" } else { "fail($bootExit)" }
$serviceField = if ($serviceExit -eq 0) { "pass" } elseif ($serviceExit -eq 124) { "timeout" } elseif ($serviceExit -eq 99) { "aborted" } else { "fail($serviceExit)" }
$ok = ($importExit -eq 0) -and ($bootExit -eq 0) -and ($serviceExit -eq 0) -and ($noise.Count -eq 0) -and $pluginRan
$status = if ($ok) { "pass" } else { "fail" }
$exit = if ($ok) { 0 } else { 1 }

if (-not $Keep) {
    # The logs are the evidence; the imported project is not. Kept on failure so a noisy line can be
    # traced back to the asset that produced it.
    if ($ok) { Remove-Item $ProjectDir -Recurse -Force }
}

Write-Output ("COLD_DROP_RESULT status={0} import={1} boot={2} service={3} noise={4} exit={5}" -f $status, $importField, $bootField, $serviceField, $noise.Count, $exit)
exit $exit
