# Contributing to MenuKit

Thanks for helping. MenuKit is small, heavily tested, and held to a few strict rules — they are
what keep a re-skinnable, backend-abstracted addon correct. This page is the short version;
**[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** carries the full working notes (engine traps,
architecture decisions, the human-only checklist, the review process).

## Setup

- **Godot 4.7** (the console build on Windows, so engine output reaches the gate).
- Windows PowerShell 5.1 for the tooling under `tools/`.
- Tell the tools where Godot is: set `GODOT_BIN` to the executable, or put `godot` / `godot4` on
  `PATH` (see [tools/README.md](tools/README.md)).

Open the repository in Godot and press **F5** to run the demo.

## Verify every change

From the repo root:

```powershell
./tools/check.ps1                      # compile every .gd/.tscn — run for any change
./tools/check.ps1 -Smokes -Isolation   # the full gate — run before every PR
```

The final line is machine-readable (`VERIFY_RESULT … exit=0`). `-Filter <substr>` runs a subset
for iteration; **a filtered run is not proof**.

The gate **fails any test whose output carries an engine `ERROR` line or leaks nodes** — an engine
complaint during a test is a failing test. A test that provokes one deliberately declares it with
`MKTest.expect_engine_error(narrowest_substring)`; an unmatched declaration also fails.

**Visual changes get looked at, not assumed.** Capture the scene and read the PNG:

```powershell
./tools/capture_scene.ps1 -Scene res://demo/demo_main.tscn -Rig res://tools/capture_rigs/settings_rig.gd
```

Green suites with broken renders have happened; for a visual change the capture is the test.
Attach before/after captures to the PR.

## Hard rules

- **Every fix ships with something that fails when the fix is reverted.** Reviewers re-run the
  claimed mutation: revert the fix, watch the test go red, restore. Say in the PR what you
  mutated and what failed.
- **Nothing under `addons/menu_kit/` may reference a `res://` path outside it — comments
  included.** `-Isolation` scans raw tokens.
- **Zero theme-override calls in the addon** (`add_theme_*_override`). All styling flows from
  `MKPalette` → the generated `Theme`; that is what makes a palette swap re-skin everything.
- **The addon ships no art, fonts, audio or third-party assets, and no `.cs` files.** The demo may
  carry CC0 art with its license file beside it (D19).
- **No authored comments in `.tres`/`.tscn` under `addons/`** — the editor wipes them on resave.
- **`MK` prefix on every `class_name`** in the addon.
- **C# hosts reach backends through the adapters** in `addons/menu_kit/backends/interop/` (D20),
  never by loosening `MKBackendSlot.validate_against`.
- **When you change a mechanism, grep its claim family across the whole repo** — docs, comments,
  tests — and fix every stale sentence in the same PR. Stale prose mirrors are this repo's
  most common defect.
- **Code comments are short and say why**, not what or how — contracts, invariants, engine traps.

## Compatibility

Backend contracts, exported `Resource` field names, `Theme` type-variation names, shipped page
ids, `RowType` values and persisted JSON keys are **public surface**. Changing any of them is
Breaking — see the rule at the top of [CHANGELOG.md](CHANGELOG.md). The decision ids (`D1`…)
cited in comments are defined in [docs/DECISIONS.md](docs/DECISIONS.md).

## Pull requests

- One logical change per PR, with an entry under `[Unreleased]` in `CHANGELOG.md`.
- Update the docs that describe what you changed (`docs/API.md` for any public signature).
- For a larger slice, add a plan under `docs/plans/` first and keep its status header truthful
  (shipped plans say IMPLEMENTED and record departures).
- Commit messages explain **why** — what the defect was and why it existed, not only what
  changed.
- Anything that needs a real display, controller, keyboard layout or the editor UI to verify
  belongs in the human-only checklist (DEVELOPMENT.md §6a); say which rows you walked.

## Reporting bugs

Open an issue with your Godot version, MenuKit version, and the output of
`MKRoot.dump_diagnostics()`. Security issues: see [SECURITY.md](SECURITY.md).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
