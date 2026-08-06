# MenuKit — Build Handoff

**Status:** Phases 1–3 complete and reviewed. Phase 4 not started.
**Repo:** `C:\GodotProjects\MenuKit` (standalone, own git history — not a Workingfile subtree)
**HEAD:** `f028cb8`
**Engine:** Godot 4.7 (`C:\GodotProjects\Installer\Godot_v4.7-stable_win64_console.exe`)
**Plan (authoritative spec):** `c:\GodotProjects\Workingfile\docs\plans\menukit_asset_extraction_plan.md` — rev 9, 1233 lines
**Written:** 2026-08-06

This file supersedes `Workingfile\docs\plans\menukit_build_handoff.md`, which is frozen at the
Phase 2 state (Workingfile was declared never-edit for the Phase 3 session). Same format; the
Phase 1–2 material below is carried forward unchanged where still true.

---

## 1. Where the build is

| Phase | Scope | State |
|---|---|---|
| 1 | Shell: theme system, modal stack, data-driven nav, `MKRoot`, tooling, demo | **Done.** 6 adversarial review rounds |
| 2 | Six shipped backend defaults, `MKSettingsService` autoload, JSON persistence | **Done.** 2 review rounds |
| 3 | Settings schema + panel, brightness controller, D14 revert countdown | **Done.** 7 adversarial review rounds (majors 4→3→2→1→1→0→0; round 7 terminal, zero findings) |
| 4–9 | Rebinding, profiles/preview, pause menu, server browser, input polish, handoff | Not started |

**Current metrics:** 68 compiled scripts/scenes, 13 test suites, ~560 executed assertions.
Gate: `compile=pass smokes=13/13 isolation=pass exit=0`.

Ship gates 1 and 2 still pass: isolation scan clean (no out-of-addon `res://` even in comments,
zero `add_theme_*_override`), and the addon's four shipped settings pages build warning-free
against an empty project (Audio Master-only, Controls no-KEYBIND — the §3.1 intersection held).

### Commit history (each review round its own commit, deliberately)

```
f028cb8 fix(phase3): act on the sixth review; the behaviour held, the words did not
139f428 fix(phase3): act on the fifth review; disposal is deferred to the layer
e24fd25 fix(phase3): act on the fourth review; the residual was not acceptable
777452a fix(phase3): act on the third review; the orphan machinery stops touching the stack
6da3b5b fix(phase3): act on the second review; two of three majors were round 1's own
adf7222 fix(phase3): act on the Phase 3 adversarial review
ffcccaa feat(phase3): schema-driven settings, brightness controller, D14 revert countdown
c22e40a … (Phase 2 head; earlier history in the Phase 2 handoff)
```

The commit messages remain long on purpose: each records *why* a defect existed. The Phase 3
sequence is a worked example of the §8 process — five of the seven rounds found defects inside
the previous round's own fixes.

---

## 2. How to verify anything

Unchanged from Phase 2: `./tools/check.ps1 -Smokes -Isolation` from the repo root; final line is
machine-readable. `-Filter <substr>` for iteration (a filtered run is not proof).

Visual checks now include the settings panel:

```
./tools/capture_scene.ps1 -Scene res://demo/demo_main.tscn -Rig res://tools/capture_rigs/settings_rig.gd -Out settings.png
```

`settings_rig.gd` honours two env vars: `MK_CAPTURE_TAB` (a tab title, e.g. `Gameplay`) and
`MK_CAPTURE_FOCUS_ROW` (a row shell name, `Row_<id with / as _>`, focused before the shot — the
slider focus ring only draws while focused). **Read the PNG.** The count of visual-only defects
caught by eyeball this phase: three (0px slider grooves, a stale slider on external write, focus
ring absence) — all invisible to every headless assertion.

---

## 3. What the gate catches that assertions cannot

Carried forward from Phase 2 verbatim in spirit; two Phase 3 additions:

- **`MKLog.observer`** (`mk_log.gd`) — an opt-in static Callable fed by every log level
  (including debug, outside the verbose gate). It exists because several §4.3 contracts are
  stated as warning COUNTS ("zero warnings on the shipped pages", "one warning per panel, not
  per row", "the missing bus is NAMED") and were unassertable without an observation point.
  Testing seam, documented as one, same idiom as `MKSettingsService.override_backend_slot`.
- **`MKSettingsPanel.window_mode_probe`** — a test-only Callable standing in for
  `DisplayServer.window_get_mode`, because the window-beats-store decision in `_is_windowed`
  is headlessly unobservable (no window to diverge) and its reversion stayed green until the
  seam existed. Same convention, documented on the member.

The mutation-testing discipline is now formalized: **every fix ships with something that fails
when the fix is reverted, and the reviewer re-runs the claimed mutations.** Round 4 caught one
false "verified red" claim (a no-op refactor); rounds 5–7 had every claim reproduce.

---

## 4. Traps that cost real time (Phase 3 additions)

- **`bool(null)` / `float(null)` are script errors, not coercions.** Any Variant-carrying seam
  (`MKSettingDef.default_value`) needs explicit null fallbacks at every consumption site — the
  build paths had them, the sync path added later did not, and the shared `_display_value`
  helper is the fix pattern.
- **Comparing Variants of different types can be a script error** (`int == String`,
  `Vector2i == String`). Gate every dedup/lookup on `typeof` first. Hit twice: the backend's
  `set_value` dedup and the panel's `_index_of_value`.
- **`is_queued_for_deletion()` is set only by `queue_free`, and only on the node it was called
  on.** `change_scene_to_*` memdeletes the outgoing scene; engine shutdown frees the root — no
  flag either way, and descendants of a queued node read false (walk ancestors). Teardown
  detection built on that flag alone is half-blind.
- **Godot drops a deferred call whose target died in the same delete cascade** — measured
  across five teardown shapes (see `139f428`). This is load-bearing: `reap_modal` disposal is
  deferred to the layer precisely so memdelete teardown is safe by construction. Also measured:
  the MessageQueue flushes BEFORE the delete queue within a frame, so a queued-but-attached
  target still receives the call — that is what `reap_modal`'s ancestor-walk guard is for.
- **A manual `_process(delta)` call in a test bypasses `set_process(false)`** — a test driving
  `_process` directly can never prove a process flag was cleared. Assert `is_processing()`.
- **`OptionButton.select()` emits nothing** — a test that selects programmatically and expects
  the write must emit `item_selected` itself, or it is vacuous.
- **PowerShell 5.1 native-arg quoting mangles embedded double quotes** — `git commit -m` with a
  quoted phrase inside a here-string split into pathspecs. Write commit messages to a file and
  `git commit -F`.

---

## 5. Architecture decisions made during the build (Phase 3)

- **Instant apply is targeted:** `MKSettingsBackend.apply_one(id)` beside `apply_all()`, so a
  slider drag does not re-push every InputMap override per tick. The JSON backend's `_apply_*`
  helpers are factored to serve both; every entry point re-checks headless individually.
- **CUSTOM rows are NEVER auto-synced.** The panel's external-write sync
  (`_on_setting_changed` → `_sync_control`) covers built-in row types only; a CUSTOM root owns
  its backend relationship end-to-end and subscribes `setting_changed` itself if it wants
  liveness — `mk_example_custom_row` demonstrates the pattern. (A CUSTOM root may legally BE a
  LineEdit/CheckBox/HSlider; auto-syncing it assigned uncoerced Variants — a script error.)
- **Unconfirmed means not kept (D14):** a live revert countdown whose panel or dialog leaves
  the tree resolves as REVERTED. The panel tracks its live countdowns; disposal of a
  still-stacked dialog is handed to `MKModalLayer.reap_modal` via `call_deferred`, which makes
  the teardown-vs-surviving-shell distinction by mechanism (dropped deferred calls) plus one
  reap-time ancestor-walk guard. The corpse frame (marked, inert dialog until the flush) is a
  tested contract. `reap_modal` DESTROYS what it is handed — ownership exception to
  `pop_modal`, stated in its doc.
- **Same-id countdown replacement chains the original previous:** A→B→C with neither confirmed
  lapses back to A. Different ids stay independent.
- **`_is_windowed`: the window beats the store** wherever a real display exists; the stored
  mode is consulted only headless. Enablement re-checks on build, the setting edge, and
  `visibility_changed`; a mode change while the page sits open and untouched is a stated gap.
- **Brightness ownership per plan §4.3:** `MKSettingsService` creates the controller
  (autoload path); `MKRoot` only on the standalone no-service tier; a duck-typed
  `get_brightness_controller()` guard makes two controllers impossible. ENVIRONMENT mode
  captures and restores the host's prior adjustment state, including the already-enabled case.
- **Shared persisted id ⇒ shared type and range** across addon and demo page sets; only
  DEFAULTS may differ, with a `.tres` comment saying so. For an ENUM row the candidate list IS
  the range. (The demo lost its Adaptive/Mailbox vsync flavour to this rule — restoring it
  needs a distinct id, not a distinct type.)
- **Resolution rows use authored labels positionally** (formatted `Vector2i` fallback);
  authoring slips in either direction (surplus labels, duplicate sizes) are debug-logged
  naming the def.
- **`MKConfig.SETTINGS_SERVICE_NAME/_PATH`** is the single spelling of the autoload path;
  `plugin.gd`, `MKRoot`, and the panel all derive from it (a renamed autoload silently
  degraded into a double backend + double brightness controller).
- The dead `MKTheme.FOCUS_RING` variation from the Phase 2 open items is now CONSUMED (slider
  focus ring). `palette.scrim` remains unread (still open, below).

---

## 6. Known open items

Carried forward or new; the starred item gates a later phase:

- ★ **JSON `int` → `float` on round trip** (unchanged from Phase 2). **Decide before Phase 5
  designs creation payloads:** extend the `__mk_type` envelope to the profile backend, or state
  in `INTEGRATION.md` that payload numerics are floats after a reload. Flagged to the owner;
  needs their call.
- **`palette.scrim` is still unread** — `MKModalLayer` uses its own `scrim_color`; a palette
  swap does not change the dim. Ship gate 3 hole. (Phase 2 item, untouched by Phase 3.)
- **`MKPalette.font_size_title`** still generated-but-unconsumed (`FOCUS_RING` is closed).
- **`mk_modal_layer.tscn` / `mk_confirm_dialog.tscn`** still shipped-but-unreferenced.
- **Slider/enum column drift** (~28px, round-2 NIT-7): slider rows' controls start left of enum
  rows'. Cosmetic; Phase 8 polish.
- **Diagnostics re-emit on every rebuild/sync**, not once per build — accepted policy
  (debug-level), noted round 7.
- **Editor-side behaviour remains unverified** (plugin enable/disable cycle, theme bake) —
  needs an interactive editor session; every phase has flagged this.

## 6a. Human-only checklist (Phase 3 items requiring F5 / a display / a controller)

1. **Brightness (gate 4c preview):** cold-drop or demo boot with a display — drag the slider,
   confirm the image visibly changes and the calibration swatch appears on focus AND drag;
   persisted brightness applies on a boot that never opens a menu.
2. **Resolution row on a real display:** change window mode via the row (countdown appears;
   let it lapse once — the mode reverts); alt-enter OUT of windowed with the settings page
   open, switch away and back to Video, confirm the resolution row disables with its tooltip.
3. **D14 under pause:** deferred to Phase 6 as planned (the countdown-under-`paused` property
   is headlessly tested; the pause-menu gesture path is Phase 6's exit criterion).
4. **Keyboard-only traversal** of all four settings tabs (tab strip → rows → sliders/dropdowns;
   slider focus ring visible — capture-verified, feel is not). Gamepad traversal is Phase 8's
   gate but a smoke-pass now would de-risk it.
5. **Editor session:** enable/disable plugin cycle, `menu_kit/config_path` survival across an
   editor restart, theme bake menu item.

---

## 7. Next step: Phase 4

Per the plan's §5 row — rebinding: capture widget, conflict modal, reset-to-default,
persistence, the `_input`/`_unhandled_input` priority rule. Sized 4–7 days; the plan's largest
single risk. Read plan §4.4 in full before starting — the abort-per-device table, the
mechanism-based reserved keys, and the cancel precedence ladder each overturned a plausible
design during plan review. The KEYBIND row type and `action_name` field already exist
(reserved in the closed enum); the panel warns-and-skips them today — that branch is the
Phase 4 insertion point, and the demo's Controls page is where the demo KEYBIND rows land
(§3.1: never the addon's).

Two Phase 3 seams Phase 4 will lean on: `MKSettingsBackend.snapshot_input_defaults` (already
booted in the right order everywhere) and the `MKLog.observer` seam for warning-count
contracts.

---

## 8. Process that worked (updated)

Phase 3 ran the §8 process at full discipline: parallel Opus implementation legs on disjoint
files (no Godot runs in parallel legs — the import cache collides) → integration by one owner
→ a dedicated test leg against the integrated code → adversarial review → fix leg → re-review
until a round introduces nothing new. Major counts per round: **4 → 3 → 2 → 1 → 1 → 0 → 0**
(round 6 was comment/coverage only; round 7 terminal, zero findings at any severity).

What earned its keep this phase:

- **Reviewer-run mutation testing, both directions.** Fix legs claim reds; reviewers re-run
  them. One false claim was caught (round 4). The iron rule — every fix exercised by something
  that fails when it is reverted — is what turned rounds 6–7 from defect-hunts into audits.
- **The capture-then-read step.** Three visual-only defects, zero of them assertable headless.
- **Measuring engine behaviour instead of reasoning about it.** The deferred-call teardown
  matrix (round 5) and the detach-then-queue correction (round 6) were both settled by probe,
  and both overturned a confident written claim.
- The recurring defect signature remains §8's: *a confident comment defending code that does
  not do what it says.* It appeared in every round through 6, including inside fixes whose
  behaviour was correct.

---

## 9. Scope reminders

Unchanged: Workingfile is read-only (this phase treated even its plan-docs directory as
frozen — hence this file's location); no LICENSE ships (D15); no third-party art/audio/fonts;
nothing under `addons/menu_kit/` may reference an external `res://` path, including comments.

One plan-doc drift to record since the plan itself is frozen: `default_config.tres` now ships
a SECOND nav page (Settings → `settings/mk_settings_panel.tscn`) beside Welcome, so §3.1's
"MKWelcomePage is the one page the addon ships" row is stale, and the Settings page + panel
scene have no §3.1 rows of their own. Their gate answers, for the record: gate 1 — addon paths
only; gate 2 — builds warning-free against an empty project (Master-only audio, no KEYBIND,
curated resolutions, zero-warning assertion in `test_settings_schema.gd`). Whoever next edits
the plan should fold these rows in.
