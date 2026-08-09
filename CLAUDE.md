# CLAUDE.md — MenuKit

Standalone Godot 4.7 menu addon (GDScript-only, own git history). Built through nine reviewed
phases plus post-0.1.0 slices; the culture below is what kept it correct — follow it, don't
re-derive it.

## Read first

- **`BUILD_HANDOFF.md`** — the build-state doc: §2 how to verify, §3 what the gate catches that
  assertions cannot, §4 the traps that cost real time (engine behaviour, PowerShell, teardown —
  read before writing GDScript here), §6a the human-only checklist, §8 the review process.
- **`docs/`** — INTEGRATION (host wiring incl. §10 C# hosts), API (every public surface),
  SETTINGS_SCHEMA, CREATION_STEPS, THEMING, DECISIONS (D-numbered, binding). CHANGELOG.md is the
  post-0.1.0 slice ledger.
- `docs/plans/` — one plan doc per slice, status headers kept truthful (shipped plans say
  IMPLEMENTED and record departures).

## Verification

One command, from THIS repo's root (`Set-Location` first — a stale cwd has gated the wrong repo):

- `./tools/check.ps1` — compile every `.gd`/`.tscn` (fast; run for any change).
- `./tools/check.ps1 -Smokes` — the full suite in an isolated `user://` (`.agent_tmp/`).
  `-Filter <substr>` for iteration; **a filtered run is not proof**.
- `./tools/check.ps1 -Isolation` — ship gate: no `res://` path escapes the addon (comments
  included), zero `add_theme_*_override`.

The gate FAILS any test whose output carries engine ERROR lines or leaked nodes — an engine
complaint during a test IS a failing test. `MKTest.expect_engine_error(narrowest_substring)`
declares a deliberate one; an unmatched declaration fails the run.

**Visual changes get eyeballed, not assumed:** `./tools/capture_scene.ps1 -Scene res://… [-Rig
res://tools/capture_rigs/….gd]` → READ the PNG in `.agent_tmp/captures/`. Green suites with
broken renders have happened; the capture is the test. `characters_rig.gd` honours
`MK_CAPTURE_SEED` / `MK_CAPTURE_CREATE`.

## Hard rules

- **Nothing under `addons/menu_kit/` may reference a `res://` path outside it — including in
  comments** (the scanner does not exempt them). The addon ships no art, no third-party assets,
  no `.cs` files; the demo may carry CC0 art with its license file beside the asset (D19).
- **Every fix ships with something that fails when the fix is reverted** (the iron rule). Reviews
  re-run claimed mutations. When a mechanism changes, grep its CLAIM FAMILY across the whole repo
  in the same sitting — stale prose mirrors are this repo's recurring defect.
- Resource files (`.tres`/`.tscn`) under `addons/` carry no authored comments (the editor wipes
  them on resave); demo scene files may carry teaching comments.
- Backend contracts are public surface — changes are Breaking per the CHANGELOG's rule. C# hosts
  reach backends through `addons/menu_kit/backends/interop/` adapters (D20), never by loosening
  `MKBackendSlot.validate_against`.
- Commit messages: no AI attribution trailers, ever. Long-form messages recording WHY a defect
  existed are the house style — each review round is its own commit.

## Engine

`C:\GodotProjects\Installer\Godot_v4.7-stable_win64_console.exe`. The repo's gate cannot run C# —
the real-C# proof lives out-of-repo at `C:\GodotProjects\MenuKitCSharpProof\` (BUILD_HANDOFF
§6a-28; re-run `proof.gd` there after any interop change).
