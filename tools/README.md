# MenuKit tooling

Maintainer tooling. Everything here runs from the repo root, bare (`./tools/check.ps1` — no
per-command execution-policy flags), and everything that writes runs against isolated state
under `.agent_tmp/`, never the developer's real `user://`.

## Finding the engine

Every wrapper resolves Godot 4.7 the same way (`tools/godot_bin.ps1`): `$env:GODOT_BIN` if set,
otherwise the first `godot` / `godot4` executable on `PATH`. Point it at the **console** build on
Windows so engine output reaches the gate (`Godot_v4.7-stable_win64_console.exe`). With neither,
each script exits 2 with a machine-readable `…_RESULT … exit=2` line naming the fix.

The tooling is Windows PowerShell 5.1-shaped (it is what CI runs, on `windows-latest`).

## check.ps1 — the gate

- `./tools/check.ps1` — compile every `.gd`/`.tscn` (reimports first when the class cache is
  stale).
- `-Smokes` — also run every `tests/test_*.gd` (recursive glob; no registry) in an isolated
  profile. Per-suite logs land in `.agent_tmp/godot_test_profile/<name>.log` (+ `.log.err`).
  The runner fails a suite on script errors, `ERROR:` lines, or leaked instances — tests that
  deliberately provoke an engine ERROR declare the narrowest matching substring via
  `MKTest.expect_engine_error`. WARNINGs are outside that noise gate; assert expected warns
  through the `MKLog.observer` seam instead.
- `-Isolation` — also run `tools/isolation_check.ps1` (ship gate 1): no `res://` reference
  outside `res://addons/menu_kit/` in any addon file, and no theme-override call anywhere in
  the addon. The scan matches raw tokens, comments included — write prose about the forbidden
  call with a wildcard, never the literal name.
- `-Filter <substr>` — subset run for iteration; the final line says SUBSET because a filtered
  run is not proof.
- Final line is machine-readable: `VERIFY_RESULT compile=... smokes=N/N ... exit=0`.

## cold_drop.ps1 — ship gate 2

Copies `addons/menu_kit/` into a freshly generated empty project under `.agent_tmp/cold_drop/`
and runs three headless passes: import (which executes the EditorPlugin), a standalone-tier
boot of `mk_root.tscn`, and a service-tier boot with the autoload registered. Fails on ANY
error or warning line; the allowlist ships EMPTY (measured on 4.7.stable — nothing needed
exempting), and any future entry must carry a comment proving the line is engine-unavoidable.
Harness limitation, documented in the header: a headless import runs `plugin.gd` but does not
persist `add_autoload_singleton`, so the script writes the autoload line itself — from a
HAND-COPIED literal name and script path, because a `.ps1` harness cannot import addon constants.
Renaming `MKConfig.SETTINGS_SERVICE_NAME` or moving `mk_settings_service.gd` therefore leaves the
gate registering the OLD name and still passing; update the script in the same commit. The real
enable/disable cycle stays a manual editor check.

## comment_diff.ps1 — the Phase 8a token gate

String-aware GDScript comment stripper + whitespace-collapsed SHA manifest over every `.gd`.
`-Snapshot` baselines the worktree; `-Compare` refuses any token drift. Use it to prove an
edit pass is comment-only; a cleanup that changes one token is a behaviour change.

## capture_scene.ps1 + capture_rigs/

Renders a scene to `.agent_tmp/captures/*.png` (brief window flash; needs a display). Layout
verification only — read the PNG; interaction and feel stay F5. Rig contract: a `RefCounted`
with `setup(node, tree)` and optional `wait_frames() -> int`; the harness takes the LARGER of
its own frame count and the rig's, so a rig can only raise the wait. Frames elapse at the
display's refresh rate — size every wait that guards a resolved-state guarantee for **240 Hz**,
not 60 Hz and not 165, or that guarantee silently inverts on a fast panel.

Rigs and their env vars:

- `settings_rig.gd` — `MK_CAPTURE_TAB` (tab title), `MK_CAPTURE_FOCUS_ROW`
  (`Row_<id with / as _>`), `MK_CAPTURE_PALETTE` (palette `.tres` path — shoots the
  re-skinned panel; the alt-skin proof shot).
- `characters_rig.gd` — walks the creation flow on timers; see its header for the arithmetic.
- `servers_rig.gd` — `MK_CAPTURE_CONNECT=<server id|1>` (connect first; `mk_stub_far` is the
  always-failing entry, which is how the FAILED caption gets a picture).
- `pause_rig.gd` — shoots the pause menu over the demo game's 3D world.
- `modal_rig.gd` — a destructive confirm dialog over the shell.
