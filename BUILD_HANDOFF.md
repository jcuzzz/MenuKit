# MenuKit — Build Handoff

**Status:** Phases 1–4 complete and reviewed. Phase 5 not started — and it is GATED on an owner
decision (the starred JSON int→float item in §6; read it before designing creation payloads).
**Repo:** `C:\GodotProjects\MenuKit` (standalone, own git history — not a Workingfile subtree)
**HEAD:** `31e2e85`
**Engine:** Godot 4.7 (`C:\GodotProjects\Installer\Godot_v4.7-stable_win64_console.exe`)
**Plan (authoritative spec):** `c:\GodotProjects\Workingfile\docs\plans\menukit_asset_extraction_plan.md` — rev 9, 1233 lines
**Written:** 2026-08-06 (Phase 3 sections carried forward; Phase 4 sections added same day)

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
| 4 | Rebinding: `MKRebindRow` capture widget, conflict modal, per-row + global reset, persistence, the `_input`/`_unhandled_input` priority rule, axis binding (descope valve NOT needed) | **Done.** Test leg + 2 adversarial review rounds (see the round table below) |
| 5–9 | Profiles/preview, pause menu, server browser, input polish, handoff | Not started |

**Current metrics:** 70 compiled scripts/scenes, 14 test suites (~190 assertions in `test_rebind.gd`
alone), gate: `compile=pass smokes=14/14 isolation=pass exit=0`.

### Phase 4 defect-count table (test leg, then review rounds)

| Stage | Majors | Minors | Notes |
|---|---|---|---|
| Test leg (pre-review) | 2 | 1 + 1 doc | Commit-never-ends-listening; Replace never redraws the loser; demo reserved list derived empty; false idle-cost comment |
| Review round 1 | 2 | 3 | `device` dropped from the persisted event format (InputMap matching IS device-aware — measured); the `_ready` fix guarded by nothing (the test declined the assertion on a false premise); AZERTY cross-form match; dead-but-enabled Reset; double warn |
| Review round 2 | 0 | 0 | **TERMINAL** — 9/9 round-1 mutation claims reproduced red; findings were three wrong attributions in comments, one dead line, visual NITs |

The recurring defect signature held again: every substantive round found a confident comment
defending code that does not do what it says — including one inside the TEST suite (round 1's M2),
which is the first time the signature appeared in the file whose job is catching it.

Ship gates 1 and 2 still pass: isolation scan clean (no out-of-addon `res://` even in comments,
zero `add_theme_*_override`), and the addon's four shipped settings pages build warning-free
against an empty project (Audio Master-only, Controls no-KEYBIND — the §3.1 intersection held).

### Commit history (each review round its own commit, deliberately)

```
31e2e85 fix(phase4): act on the second review; the behaviour held, the attributions did not
7600424 fix(phase4): act on the first adversarial review; the format was device-blind
318ae1c feat(phase4): input rebinding — capture row, conflict modal, reset, targeted apply
38f4da9 docs: Phase 3 build handoff
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

Phase 4 additions:

- **`InputMap` matching is DEVICE-aware, and `InputEvent` class-default devices are not -1.**
  Measured on 4.7: `InputEventJoypadButton.new().device == 0`, `InputEventKey` 16,
  `InputEventMouseButton` 32; a binding stored with device 0 does not answer a joypad-1 press.
  Any code that rebuilds or round-trips an event MUST carry `device` explicitly (the serializer
  stores it; absent reads as -1 = all devices; fresh captured events pin -1). The engine's own
  builtin `ui_*` key/mouse defaults ship device 16/32 — a device-CLASS namespacing, faithful in a
  snapshot, not corruption.
- **The engine re-enables input processing at NOTIFICATION_READY for any script overriding
  `_input`** — a `set_process_input(false)` made before the node enters the tree is silently
  undone; restate it in `_ready`. And assert it directly (`is_processing_input()`), because the
  behaviour-only assertion stayed green when the restatement was deleted.
- **Never compare a physical keycode against a plain keycode.** They coincide numerically on QWERTY
  and diverge on AZERTY — a test can ride the coincidence for weeks. Physicals against physicals,
  keycodes against keycodes, both-nonzero required (`MKRebindRow._events_match`).
- **A pushed mouse event never reaches GUI dispatch under the headless driver** (`push_input` does
  reach `_input`). Button *clicks* cannot be simulated headless; button *handlers* and the row's
  manual rect hit-test can. Keyboard activation (`ui_accept` on a focused button) works.
- **`DisplayServer.keyboard_get_keycode_from_physical` under headless answers 0 AND prints an
  engine ERROR per call** — the noise gate fails the run. Guard on
  `DisplayServer.get_name() != "headless"` before calling.

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

Phase 4 additions:

- **The capture priority rule is mechanism, not flags:** a listening `MKRebindRow` reads input in
  `_input` and marks every inspected event class handled; `MKRoot` reads `ui_cancel` in
  `_unhandled_input`. No `is_capturing` boolean anywhere. Consequences by construction: Escape is
  unbindable (the row's abort sees it first), one Escape cannot both abort and pop the page, and
  the Cancel button is un-clickable while listening — its mouse abort is a manual rect hit-test.
- **Abort is per-device (plan §4.4 table, reproduced in the row's class doc).** Joypad-B has NO
  special case in `_input` — it reaches the record path, is refused as reserved, and that refusal
  ends listening: one gesture, both jobs. The reserved list is derived from the BOOT-DEFAULT
  non-keyboard `ui_cancel` events plus the panel's exported `extra_reserved_events`; the demo's
  `project.godot` restates `ui_cancel` with a pad-B binding, without which the derived list is
  empty and the guard inert (test-leg finding D3 — a HOST must do the same or widen the export).
- **Single-slot capture:** a commit replaces the action's whole event list with the one captured
  event; the multi-event stock list survives in the boot snapshot and returns on Reset. Captured
  keys strip modifier FLAGS (modifier keys themselves stay bindable); captured motion normalises
  to ±1.0; every fresh event pins `device = -1`.
- **KEYBIND rows are CUSTOM-shaped to the panel:** registered for dup-id/visibility, excluded from
  `_sync_control`/`_display_value`/D14 outright (their state lives in the input store, keyed by
  action, not the value store keyed by id). `requires_confirm` on a KEYBIND def is ignored with a
  debug line. The six input-store methods are non-abstract base defaults on `MKSettingsBackend`
  (inert, degrade-visible) so pre-Phase-4 host subclasses keep parsing; `apply_action(action)` is
  the targeted push (base delegates to `apply_all`; the JSON backend targets one action, and its
  no-override branch re-applies the boot snapshot — that branch is what makes Reset take live
  effect).
- **Cross-row consistency is a panel job:** one-capture-at-a-time (`_end_other_captures` off
  `capture_state_changed`) and the `binding_changed` relay → `_refresh_rebind_rows` (a conflict
  Replace rewrites an action some OTHER row displays; rows cannot see each other).
- **Conflict modal is `MKConfirmDialog` verbatim** (`Replace`/`Keep both`/`Cancel` via
  confirm/alternate/cancel); listening ends BEFORE the dialog opens or the dialog's own keyboard
  would be consumed by the row. A cancelled conflict clears the transient caption. No new theme
  variation: the listening state is button text (`Press any key…`) + the slider-style focus ring.

---

## 6. Known open items

Carried forward or new; the starred item gates a later phase:

- ★ **JSON `int` → `float` on round trip** (unchanged from Phase 2, re-flagged at Phase 4's
  close). **This is now the NEXT decision on the critical path: Phase 5 designs creation payloads
  and must not start until the owner picks** — extend the `__mk_type` envelope to the profile
  backend, or state in `INTEGRATION.md` that payload numerics are floats after a reload. Needs
  the owner's call; nothing in Phase 4 touched or prejudged it.
- **The `device` field in the persisted `input` event dicts must appear in Phase 9's CHANGELOG
  initial-format statement.** Added in `7600424` (absent = -1 for compatibility); no
  `FORMAT_VERSION` bump because the format has never shipped — but it is a format field and the
  §4.8 versioning rule applies from `0.1.0` onward.
- **Binding-button column alignment** (round-2 visual NIT): the seven binding buttons' widths
  follow their labels, so their left edges are ragged and the column does not align with the
  slider/enum control column. Phase 8 polish, same family as the Phase 3 ~28px drift.
- **Unchecked `CheckBox` rows render near-invisible on the dark panel** (pre-existing Phase 3;
  noticed on the Controls page's Invert Vertical Look). Phase 8.
- **Non-keybind rows keep the conditional-tooltip write** (`_wrap`) that n3 removed on the rebind
  row — latent only (fresh rows per rebuild); asymmetry recorded as a decision, not an oversight.
- **`_events_match`'s stated cost:** a stored physical-only event and a stored keycode-only event
  for the same key never match. Unreachable through shipped paths (captured events carry both
  codes); reachable for a host seeding keycode-only events via `set_action_events`. Documented on
  the method.
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

Phase 4 items (rebinding is input-hardware work; these are genuinely un-headless):

6. **Real-hardware rebind smoke:** rebind a key (e.g. Jump off Space onto F), press it in-window,
   confirm the action fires; restart, confirm it survived. Same with a pad button on controller 0
   AND a second controller if available (the device -1 fix is measured headless via
   `event_is_action`, but a real press through the OS driver is the honest proof — round 1's M1
   named this check explicitly).
7. **Mouse capture gestures:** click a binding button to start listening (headless cannot reach
   GUI dispatch with a synthetic click); click the Cancel button's rect — capture aborts; click
   anywhere else — Mouse Left/Right records as the binding.
8. **Gamepad full pass:** navigate to the Controls page and trigger Reset All Bindings with NO
   keyboard (ship-gate-4 recovery clause); press B while a row listens — see "Reserved by the
   menu" AND listening end in that one press; bind a pad button and an analog-stick direction
   (axis capture is live code) and feel both in use.
9. **AZERTY / non-QWERTY layout** (or OS keyboard-layout switch): binding labels show the LAYOUT's
   keycap (the `_key_label` physical→layout mapping is headless-unreachable), and a rebind made on
   one layout lands on the same physical key on the other.
10. **Listening-state visuals:** `Press any key…` prompt, the `Esc to cancel` hint, the Cancel
    button appearing only while listening, captions ("Reserved by the menu" / "Also used by menu
    navigation") appearing and clearing. The capture rig cannot press the button, so no PNG of the
    listening state exists — eyeball it once.
11. **Timeout feel:** start a capture and wait — 10s lapse aborts cleanly, display restores.

---

## 7. Next step: Phase 5 — AFTER the owner's int→float call

Per the plan's §5 row — profiles + preview slot: character select, confirm dialog, creation
host, Name/Archetype/Appearance/Point-buy steps, `MKPreviewViewport` (own_world_3d, F10).
**Blocked at the design stage on the starred §6 item:** the creation payload goes verbatim to
`MKProfileBackend.create_profile(payload)` and round-trips JSON, so whether payload ints survive
as ints (envelope) or are documented floats (INTEGRATION.md) shapes the payload contract every
built-in step writes. Get the owner's decision FIRST.

Phase 4 seams Phase 5 can lean on: `MKConfirmDialog` (already carries the three-button shape;
Phase 5's delete-confirm is its third consumer), the modal layer's focus trap, and the
`test_rebind.gd` viewport-push idiom for driving real input through built UI.

---

## 8. Process that worked (updated)

Phase 3 ran the §8 process at full discipline: parallel Opus implementation legs on disjoint
files (no Godot runs in parallel legs — the import cache collides) → integration by one owner
→ a dedicated test leg against the integrated code → adversarial review → fix leg → re-review
until a round introduces nothing new. Major counts per round: **4 → 3 → 2 → 1 → 1 → 0 → 0**
(round 6 was comment/coverage only; round 7 terminal, zero findings at any severity).

Phase 4 ran the same shape and converged faster (majors **2 → 2 → 0**: test leg, round 1,
round 2 terminal), with three refinements worth keeping:

- **The dedicated test leg found the first two majors BEFORE any review round** — a suite that
  drives real InputEvents through the viewport (never widget methods) caught
  commit-never-ends-listening within minutes of existing. Write the deep suite before the first
  review, not after.
- **Reviewer-run engine probes beat reasoning again:** round 1's device finding
  (`InputMap.event_is_action` is device-aware; class-default devices are 0/16/32, not -1) was
  invisible to every assertion that read `action_get_events` — the reviewer asked the engine the
  question the tests didn't. When a review claim is about engine behaviour, demand the probe
  output in the report.
- **The iron rule caught its biggest fish inside the test suite itself:** round 1's M2 was a test
  COMMENT confidently declining an assertion on a false premise, leaving a fix guarded by
  nothing. Reviewers must mutation-test the fixes (round 2 re-ran all nine claims: 9/9 red), and
  must read test comments as claims too.

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

Local-state note: `git stash@{0}` ("pre-phase4: Godot editor resave noise") holds ~440 lines of
editor-resave churn (comment stripping + uid injection across 12 files) found uncommitted at the
Phase 4 session start — verified free of semantic change and set aside rather than committed,
because the stripped `.tres` header comments are load-bearing house style. Drop it once confirmed,
and prefer not to re-save those resources from the editor without re-adding the comments.

One plan-doc drift to record since the plan itself is frozen: `default_config.tres` now ships
a SECOND nav page (Settings → `settings/mk_settings_panel.tscn`) beside Welcome, so §3.1's
"MKWelcomePage is the one page the addon ships" row is stale, and the Settings page + panel
scene have no §3.1 rows of their own. Their gate answers, for the record: gate 1 — addon paths
only; gate 2 — builds warning-free against an empty project (Master-only audio, no KEYBIND,
curated resolutions, zero-warning assertion in `test_settings_schema.gd`). Whoever next edits
the plan should fold these rows in.
