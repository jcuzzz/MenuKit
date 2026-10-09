# MenuKit — Development Notes

The working knowledge behind MenuKit's code: how to verify a change, what the gate catches, the
engine traps that cost real time, the architecture decisions made during the build, known open
items, the checklist of things only a human with a display and a controller can verify, and the
review process that kept the package correct. [CONTRIBUTING.md](../CONTRIBUTING.md) is the short
version; read this before writing non-trivial GDScript here.

---

## 1. Reading this document

MenuKit was built in numbered phases (1–9, plus 8a) under a written plan, each phase closed by
adversarial review rounds. The sections below keep that structure — "Phase 4 additions" is the
batch of traps or decisions that phase surfaced — because the commit history is organised the
same way: `git log` shows each phase's implementation commits followed by one commit per review
round, with long messages recording why each defect existed.

References of the form **plan §N** or **row N** point at that original build plan, which is not
part of this repository; the sentence around each reference states the constraint it cites.
**Gate N** refers to the ship gates summarised in §7. Section numbers here are stable — tests and
docs cite them (`§6a-28`, `§6a row 26`).

---

## 2. How to verify anything

Unchanged from Phase 2: `./tools/check.ps1 -Smokes -Isolation` from the repo root; final line is
machine-readable. `-Filter <substr>` for iteration (a filtered run is not proof).

Visual checks now include the settings panel:

```
./tools/capture_scene.ps1 -Scene res://demo/demo_main.tscn -Rig res://tools/capture_rigs/settings_rig.gd -Out settings.png
```

Phase 6 adds the pause composition — the one shot no other rig can produce, a MenuKit surface
over a live 3D world:

```
./tools/capture_scene.ps1 -Scene res://demo/demo_game.tscn -Rig res://tools/capture_rigs/pause_rig.gd -Out pause_menu.png
```

Expected content (verified twice this phase): grey-box world filling the frame (floor, boxes,
sky), NO nav strip, no backdrop, the centred "Paused" panel with the focus ring on Resume. The
phase's first capture showed the opposite (an opaque backdrop wall) and is why `show_backdrop`
exists — the defect class remains invisible to every headless assertion.

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

Phase 5 additions:

- **CSG meshes build DEFERRED: `get_aabb()` is ZERO on the frame the node is added.** Any
  bounds-derived math must run once immediately AND once a frame later. Corollary for tests: a
  MeshInstance fixture (bounds immediate) does not share a CSG asset's failure mode — test the
  SHIPPED asset.
- **`call_deferred` is FIFO, and content added later enqueues its own deferred work later** — a
  boolean "one pending pass" de-dup runs the pass before the second content exists. Use a
  generation counter; stale passes self-identify.
- **`_ready` runs ONCE per node lifetime** — it cannot be the re-initialise hook for a node that
  leaves and re-enters the tree (pooling, reparent). `NOTIFICATION_ENTER_TREE` fires every entry
  (and BEFORE `_ready` on the first, so one `_readied` flag distinguishes them).
- **A SubViewportContainer with `stretch` on OWNS its SubViewport's size** — a manual size write
  is refused with an engine WARNING per attempt. And **flipping `own_world_3d` on a live viewport
  errors** ("Parameter 'scenario' is null") — detach, flip, re-add.
- **`clampf` raises to its minimum FIRST, then lowers to its maximum** — an inverted (min>max)
  pair collapses inputs onto one of the two ends. Order the pair (`minf`/`maxf`) at ONE helper;
  this repo shipped two mutually contradictory false descriptions of this builtin in one commit
  before measuring it.
- **A GDScript `set =` accessor does NOT re-enter on self-assignment** — re-entrancy guards for
  that case are dead code. And **`LineEdit.max_length` truncates PROGRAMMATIC assignment too** —
  a length check "for hosts assigning text in code" above the cap is unreachable.
- **A const named `TYPE_*` shadows `@GlobalScope`'s enum script-wide** — `typeof(x) == TYPE_INT`
  silently compares against your String. Name codec tags `TAG_*`.

Phase 6 additions:

- **A GDScript lambda captures locals BY VALUE.** A `var count := 0` incremented inside a
  signal-connected closure is a copy the test's later read never sees — a permanently-zero
  counting assertion that looks like a product bug. Use a one-element Array or a member.
- **`NOTIFICATION_VISIBILITY_CHANGED` fires on ENTERING the tree** (with `is_visible_in_tree()`
  already true) and on ancestor hide/show — but NOT on leaving the tree by any route
  (remove_child, reparent, free). Measured across all shapes. Two consequences are load-bearing:
  MKRoot's hide==close cannot re-enter during teardown, and any guard on that notification must
  branch on the direction, not the arrival.
- **`visible` and `is_visible_in_tree()` diverge exactly when an ANCESTOR is hidden** — and a
  mutant swapping one for the other survives every test that drives visibility on the node
  itself. Three MKRoot sites draw the distinction deliberately (`_unhandled_input`,
  `_focus_page_content`, the hide-close guard); each needed an ancestor-driven test to pin it.
- **`check.ps1`'s noise gate counts ERRORs, not WARNINGs** — an `expect_engine_error`
  declaration for a warning is UNMATCHED and fails the run by itself.
- **Exit order at quit and scene-free protects D14 by construction:** children run `_exit_tree`
  before their parents, and the scene tree unwinds before autoloads — so a live revert
  countdown's panel reverts the store BEFORE either save-on-exit owner writes it. Measured, both
  paths; any future save site must preserve this ordering property.
- **`git checkout -- <file>` during inline mutation testing restores HEAD, not your working
  state** — it wiped the integrator's own uncommitted fixes in the same file as the mutation.
  Mutate only files with no pending edits, or stash/re-apply deliberately.

Consolidated at Phase 9 (the staging files' candidates, folded in before the staging
directory was deleted):

- **`ProjectSettings.set_setting` mutates memory only** — without an explicit
  `ProjectSettings.save()` the key evaporates on the next editor launch (a second-run-only bug
  signature). `EditorPlugin.add_autoload_singleton` needs NO save (the editor persists autoloads
  itself); do not add one assuming symmetry. And a setting whose value equals its INITIAL value
  is omitted from `project.godot` entirely — `save()` becomes a silent no-op; the initial value
  must differ from any value you intend to persist (plugin.gd uses `""`).
- **`JSON.parse_string()` pushes an engine ERROR line; `JSON.new().parse()` does not** — the
  backends use the instance API because they fully handle the failure by quarantining, and the
  static API's noise would fail any output-scanning gate. Report parse-failure and
  wrong-root-type separately: a parsed-but-array root leaves error line/message empty.
- **`Array.duplicate()` returns an UNTYPED Array** (unsafe narrowing — use `assign()`), and an
  untyped `[]` literal is refused at runtime by an `Array[T]` parameter — build a typed local.
- **A typed `Array[Control]` refuses to hand back a freed element** and `is`/`as` on a freed
  instance error — `MKModalLayer`'s stack/focus-memory are untyped and `is_instance_valid` must
  precede any `is` test.
- **`Array.sort_custom` is not a stable sort** — decorate with the original index when the same
  array feeds two consumers (nav order + boot page).
- **An autoload's script must not declare a matching `class_name`** — it fails to parse at every
  boot ("hides an autoload singleton") while direct-mount tests stay green; and registering a
  real autoload needs an editor session, which is why `MKSettingsService` has the
  `override_backend_slot` seam.
- **`MKPreviewViewport._built` does not survive an editor script reload** (a reload re-runs
  `_ready` on a fresh instance and rebuilds children on top) — it guards a second `_ready` on the
  SAME instance only.
- **The MKInputGlyphs last-child placement INVERTS across a rebuild** unless
  `_place_input_glyphs_last()` re-asserts it — invisible on a first build (§5's Phase 8 entry has
  the contract; this line is the trap shape).
- **Sweeps for authored resource-file comments must cover `.tscn` as well as `.tres`** (two
  settings scenes carried `;` blocks the 8a rule almost missed).
- **Cross-repo doc links in tool headers rot silently** (`capture_scene.gd` pointed at a
  source-project-only doc for five phases); tools/README.md is the in-repo home now.
- **`tests/test_creation_host.gd` still carries `const F8_NOISE`** — a plan finding-id in a code
  identifier; renaming is a token change for a post-0.1.0 slice.

Phase 7 additions:

- **Godot auto-disconnects a freed node's method-bound signal connections** — a backend
  SceneTreeTimer resolving after its subscribed panel was freed emits into nothing, zero errors
  (probed). Page-per-navigation panels can therefore subscribe plainly; the cost is state RESYNC
  on re-entry, which is what the browser's `get_connect_state` duck-typed seed exists for.
- **A capture rig's `wait_frames` is refresh-rate arithmetic, not time** — frames elapse at the
  display's Hz, so a 60 Hz-sized wait silently under-waits on 144/165 Hz panels and inverts any
  "the shot shows the resolved state" guarantee. Size rig waits for the fastest common display
  and say so (`capture_scene.gd` can only RAISE a rig's wait, never cap it). `characters_rig.gd`
  carries the same softness — Phase 8a sweep item.
- **`gui_get_focus_owner()` goes NULL when the focused control is freed** (a rebuild that frees
  rows kills keyboard/gamepad outright), and a control DISABLED under its own ring keeps focus
  while eating accepts. Any panel that rebuilds or flips enablement needs a recovery seam;
  `MKServerBrowser._recover_focus` is the worked example (recover only when the owner is null,
  freed, or disabled INSIDE the panel — never steal live outside focus; `MKModalLayer`'s
  focus-pullback makes stray grabs under a modal self-correcting).

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

Phase 5 additions:

- **The `__mk_type` envelope lives in `MKJsonCodec`** (static, `TAG_*` constants), shared by both
  JSON backends with a flag: the settings backend writes Vector2i-only (its persisted bytes are
  unchanged — churning a shipped format bought nothing), the profile backend opts into int
  enveloping so payload ints survive reload as `TYPE_INT`. Decode tolerates every tag either way.
  Legacy plain-number files read unmigrated. The tag is the codec's NAMESPACE: `create_profile`
  recursively REFUSES any payload spelling `__mk_type` (accepting one wrote a file whose load
  quarantined the whole roster).
- **The profile backend is read-only under a NEWER store file** (`_read_only_newer` latch):
  create/delete refuse with one warn naming the version, the file stays byte-identical, and the
  latch follows the FILE (replace it and writes resume). A settings value is an annoyance to
  lose; a roster is not — the two backends deliberately take different positions and each says
  so. It also NORMALISES the one field it enforces its one rule over: names are stored trimmed.
- **`MKCreationHost.configure` runs three passes** — claim every step's owned keys, validate
  archetype defaults (F8: an owned-key default is refused-and-named, never seeded), THEN bind —
  because binding is not inert: the archetype step auto-selects and seeds at bind, and
  interleaving made F8 order-dependent. Ownership is disjoint by DECLARATION (nothing audits what
  `_mk_step_commit` actually writes; shipped steps honour theirs).
- **The refusal gate:** a refused `create_profile` closes BOTH doors into `_confirm` (Confirm and
  a last-step Skip); any forward MOVEMENT — commit or non-last Skip — lifts it, and on a flow
  whose refused step has no earlier step (index 0), the step ANNOUNCING a state change lifts it
  (the only fresh-attempt signal that shape can produce; "announcing, not changing" — the signal
  cannot tell an edit from a re-affirmation, and either is a distinct gesture). `REFUSAL_MESSAGE`
  names NO cause — taken name, full roster and the latch all answer the same empty dict.
- **`MKPreviewViewport` framing:** immediate pass + generation-tagged deferred pass per swap (CSG
  bounds arrive a frame late); relative pivot/content writes make re-framing idempotent, the
  swap zeroes the pivot (accumulation is per-content-lifetime); first content FITS distance,
  later swaps keep the user's zoom, `frame_content()` refits by contract; cleared-slot state
  resets in the CLEAR path (outside any tree check); `NOTIFICATION_ENTER_TREE` re-frames on
  every re-entry; all six distance writes route through `_clamp_zoom` (ordered pair). Process
  mode deliberately inherited (a paused page freezes its preview — Phase 6's own exit criterion).
- **The appearance step mounts the preview** and re-resolves the chosen archetype's
  `preview_scene` from the live payload on visibility (steps bind eagerly, before any choice
  exists). Demo archetypes carried CSG primitive preview scenes at this phase — §4.6's rotating
  primitive; the post-0.1.0 demo-character slice (D19) replaced them with tinted rigged-mannequin
  scenes under `demo/characters/`, and `demo/demo_creation/preview_vanguard.tscn` survives only as
  `test_preview_viewport`'s CSG deferred-bounds subject.
- **Select panel:** roster cards rebuilt on `roster_changed` with selection-by-id restore;
  disabled-state flips run BEFORE focus chaining (correct by construction, pinned on the
  empty→populated rebuild — first builds are ordering-blind); `MKFocus` skips disabled buttons
  for focus_first but `release()` un-wires everything and `trap()` falls back to the disabled
  set rather than stranding focus outside a modal.
- **Config-driven creation:** `MKConfig.archetypes/creation_steps/point_buy_schema` (+12
  validation rules, `creation_diagnostics()` in the root dump); empty `creation_steps` = the
  built-in name/archetype/appearance order; a null schema drops point-buy quietly (D17), an
  INVALID schema drops it with a warn naming the resource; the demo authors all four steps and
  `require_full_spend = true` (pinned as contract — the demo is the §5 deliverable).

Phase 6 additions:

- **The pause shell is the same `MKRoot`, page-based** — no second shell class. Both shipped
  configs define a hidden `&"pause"` page (`mk_pause_menu.tscn`: Resume / Settings / Quit to
  Menu; a page, not a shell — it never touches `paused`, the cursor, or the counter). The
  in-game shape is an `MKRoot` instance parked hidden and LAST in the game scene
  (`demo_game.tscn`), `host_content_process_mode = ALWAYS`, `show_backdrop = false`.
- **While the pause menu is open the shell is a PAUSE shell:** the nav bar is hidden on open and
  the RECORDED visibility restored on close (a host may run navless); `open_pause_menu` records
  `_pause_page_id`; the ESC ladder's pause rung closes only ON the pause page, recovers TO it
  from a foreign page, and a failed recovery closes rather than freezes (a resumed game with a
  warning beats a paused one with no exit). `close_pause_menu` clears the back stack — no
  return addresses into a hidden shell.
- **`open_pause_menu` refuses by PRE-CHECK** (def null OR scene null) before touching any state —
  `_show_page` returns true for a scene-less def, so a return-value refusal was provably false.
  The bare `_show_page` call after the pre-check is a containment decision, not an
  impossibility claim: the call-site comment names the two foreign-code windows and the
  recovery rung that contains them. Five prose mirrors of the old suspend-then-unwind mechanism
  had to be hunted down across four rounds; the grep-the-claim-family rule in §8 is the residue.
- **Hide == close:** `NOTIFICATION_VISIBILITY_CHANGED` closes an open pause menu when the shell
  becomes not-visible-in-tree (ancestor hides included). Direction-guarded; entry/show is a
  no-op. This is what makes the host's `visible = open` one-liner safe in both directions.
- **Quit to Menu closes the pause state BEFORE `to_main_menu()`** — the scene change is
  deferred, so close-first is safe under the shipped backend and mandatory for a custom backend
  that swaps no scene (it used to inherit a paused main menu with no nav bar). One visible
  consequence documented for Phase 9: the world runs for the remainder of the quit frame.
- **Settings persist via save-on-exit at the two OWNERS of a booted backend:**
  `MKSettingsService._exit_tree` (the supported tier) and `MKRoot._exit_tree` only when
  `not _adopted_settings` (standalone tier; the adopted case never saves at the root — one
  owner, one write). Round 2's headline: `save()` previously had NO production caller, so no
  setting, rebind, or brightness value ever reached disk. Crash/`OS.kill` still loses the
  session's writes — an accepted property for the Phase 9 CHANGELOG.
- **The adopt path notes (debug level) when it ignores a slot's non-empty params.** Warn was
  wrong by measurement: the shipped demo's service builds from the SAME slot instance, so a
  warn fired on every correct boot against gate 2's zero-warnings bar.

---

## 6. Known open items

Carried forward or new; the starred item gates a later phase:

- **JSON `int` → `float`: DECIDED and DONE** (owner's call, 2026-08-07: the envelope). Implemented
  as `MKJsonCodec` with the int tag enabled for the profile backend only; the settings backend's
  bytes are unchanged and its int→float caveat still stands there by design. The star is retired.
  Phase 9's CHANGELOG initial-format statement must cover: the `input` event dicts' `device`
  field (Phase 4), the `__mk_type` int tag + the discriminator-refusal rule, the trimmed-name
  normalisation, and the newer-store read-only latch (all pre-0.1.0, no version bumps).
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

Phase 5 open items:

- **`MKCreationHost` has no `step_changed` signal** — the appearance step re-resolves via
  `visibility_changed`, the one step that reads payload state after bind; a second such step
  would re-invent the pattern. Phase 9 API-polish candidate.
- **Empty-roster copy is centred while roster cards left-align** (round-6 NIT) — Phase 8, same
  bucket as the binding-button column and the invisible unchecked CheckBox.
- **`_camera.far` reads raw `zoom_max`** (not `_clamp_zoom`) — on an inverted export pair it uses
  the smaller value; masked by the 100.0 floor at every plausible radius. Cosmetic-at-worst;
  noted round 8.
- **Point-buy restore honours per-stat ranges but not the POOL** — an over-pool restore renders
  negative remaining and the validity gate holds (documented on `_restore`); a clamp-to-pool
  would be nicer, not needed.
- **The select panel's delete-refusal resync path is unreachable under the latch** (empty roster
  → no cards) — coherent, untriggerable; recorded so nobody hunts a repro.
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

Phase 6 open items:

- ~~**The quit-confirm dialog default-focuses its DESTRUCTIVE button**~~ — **CLOSED in Phase 8.**
  `destructive` now decides default focus by BUTTON ORDER, and `MKRoot.request_quit_confirm`
  passes `destructive = true`, so the quit dialog opens on Cancel.
- **One-frame resume during quit-to-menu:** close-before-backend means the world simulates for
  the remainder of that frame under the shipped deferred scene change. INTEGRATION.md sentence
  (Phase 9), not code.
- **Two SIMULTANEOUS service-less shells stack two gamma passes** — `_boot_own_brightness`'s
  guard covers only the service-shaped route; the gap is documented in-code (no shipped config
  mounts that shape). INTEGRATION.md sentence (Phase 9).
- **F6 alternative on record:** the adopt-ignores-params debug line could become a true-positive
  WARN by comparing identity via `service.get_config()` — Phase 9 API-polish candidate.
- **Post-recovery warn-spam:** after a failed recovery-close (pause page def gone), every ESC
  re-attempts open and warns once per press. Coherent with "running beats frozen"; recorded so
  nobody re-reports it.
- **`MKPauseMenu._find_menu_backend` resolves once at `_ready`** — a backend assigned later is
  never seen by an already-open pause page. No shipped path does this; recorded as a question,
  not a defect (the page is re-instantiated per open).
- **Reparenting a live shell is UNSUPPORTED** (class doc states it): `_exit_tree` discards pause
  and nav state without a signal; ancestor-reparent probed round 5 — same semantics, no crash,
  world unpaused by the policy's own teardown.
- **Save-on-exit loses a crashed session's writes** — accepted; must appear in the Phase 9
  CHANGELOG/INTEGRATION persistence notes alongside the format statement.

Phase 7 open items:

- **Re-entering the servers page mid-connect selects row 0, not the in-flight server** (round-2
  nit). Connect is disabled so no mis-connect is possible; cross-page selection persistence was
  never claimed. Recorded, not scheduled.
- **The seeded mid-flight status is caption-only** (no message accessor on the abstract base) —
  documented on the class; Phase 9 may add `get_connect_message()` if the API review wants it.
- **Commit 29fa619's message claims "same end state" for the `_ready` double-grab** — round 2
  probed one benign divergence on the backendless path (final owner Refresh, not Connect). The
  commit message is immutable; this line is the correction of record.
- **`characters_rig.gd` carries the frames-vs-Hz softness** servers_rig had corrected — Phase 8a
  comment sweep item.
- **Backendless Cancel is deliberately LIVE** (reaches the naming warn like Connect) — now
  documented and tested; noted here because it reads as an oversight until the carve-out comment
  is found.

Phase 8 open items:

- **`Input.get_joy_button_string` does not exist on 4.7** — every shipped pad label comes from
  the SDL-positional `JOY_BUTTON_NAMES` table (a DualShock shows "B" for Circle). A test goes
  red if a future engine restores the API; §6a-25 carries the accept-or-scope question.
- **The F2 border-floor test preconditions on the DEFAULT palette's `border_width == 1`** — a
  retune fails LOUD (named precondition), not silent-green; re-home onto a forced-1 duplicate
  palette if that ever fires.
- **The tracker's dispatch guarantee is owner-subtree-relative** (probed): an `_input`-consuming
  node a host mounts AFTER the shell at ancestor level dispatches first and can blind the
  tracker. No shipped node does (the only `_input` consumers are the row and the tracker;
  MKRoot/demo consume in `_unhandled_input`). INTEGRATION.md sentence, Phase 9.
- **Confirm's screen position swaps between dialog shapes** (destructive `Cancel | Delete`,
  non-destructive `Confirm | Cancel`) — deliberate tree-order consequence, console-convention
  aligned; §6a-23 eyeballs the muscle-memory question.
- **The 20px check glyph is fixed-size** beside host-raised font sizes — engine-consistent,
  accepted.
- **The welcome page has no focusable control** — focus stays on the nav tab; not stranded, but
  the shipped first screen has no in-page ring. Recorded (adding a control was out of scope).

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

Phase 5 items:

12. **Preview feel on a real display:** drag-to-spin + release inertia + wheel zoom on the
    appearance step's subject (since the D19 slice: the rigged mannequin, not a primitive); the
    three-point look (key/fill/rim, pure white); auto-rotate resuming after the throw decays. All
    arithmetic is headless-asserted; FEEL and LOOK are not.
13. **Full creation walk by feel:** name → archetype cards → appearance preview → point-buy to
    zero remaining → Confirm; then the refusal path for real (create a duplicate name from a
    second walk) and recover without Cancel.
14. **Gamepad-only wizard traversal:** cards, steps, footer, the point-buy -/+ cluster, Reset
    All on the Controls page — one pass with the keyboard unplugged.
15. **Delete confirm on a real display:** the destructive red Confirm, focus trap, Escape pops
    the dialog not the page.

Phase 6 items (the cursor clauses are headless-unreachable by mechanism — `Input.mouse_mode`
is pinned VISIBLE under the dummy DisplayServer, so the suites cover only the depth-edge
proxies; these rows ARE the row-6 mouse-capture evidence):

16. **Cursor round-trip:** enter the game (cursor captured), ESC — cursor releases and the
    pause menu appears; Resume — capture returns. Then: open pause, open the quit-confirm over
    it, Cancel — the cursor must STAY visible (modal-over-pause dismiss must not restore
    capture under a still-open menu); finally Quit to Menu — the main menu boots with the
    cursor visible, never captured.
17. **The MKNoPausePolicy twenty minutes** (plan row 6 names it): swap the demo config's pause
    slot to `MKNoPausePolicy`, play — the world runs behind the open menu (spinner turning),
    mouselook does NOT spin the camera while the menu is up (the demo gates it — feel this,
    the suite only asserts the handler), a D14 countdown from pause still ticks, and the ESC
    in/out rhythm feels right with the world live.
18. **Pause feel pass:** ESC in/out repeatedly (no double-open, no stuck states), Settings from
    pause → change a display setting → let the countdown lapse FROM PAUSE on a real display
    (the revert must visibly land), keyboard-only and gamepad-only walks of
    pause → settings → back → resume → quit-to-menu.
19. **Quit-frame observation:** on Quit to Menu, watch for the one visible frame of resumed
    world — confirm it reads as harmless on a real display (it is accepted and documented; this
    row exists so a future report of it is expected rather than alarming).

Phase 8 items (the row-8 exit criterion is itself a manual matrix):

20. **Gamepad-only full-demo run:** boot → Characters → full 4-step creation incl. point-buy →
    Play → pause → settings-from-pause → resume → quit-to-menu → Servers connect/cancel →
    quit-confirm, keyboard unplugged. The quit and delete dialogs must open with the ring on
    Cancel; B backs out of every rung.
21. **Keyboard-only mirror** of the same walk (Tab agreement with arrows on the reversed dialog
    row included).
22. **Device-flip hint feel:** alternate key/pad on the Controls page — "Esc to cancel"/"B to
    cancel" swap; flip devices MID-CAPTURE (the dispatch contract's gesture: the hint must land
    even while a row is listening, identically before and after a panel rebuild); rest a
    drifting stick — the hint must not flap.
23. **Travelling-accept test:** hammer A/Enter while triggering delete and quit — no
    deletion/quit may land; feel the left/right ring between Cancel and the destructive button;
    note whether the Confirm position swap (F6) trips muscle memory across quit→conflict.
24. **CheckBox eyeball on a real display:** unchecked visibility at native resolution,
    hover/pressed compositing over the white re-tint, focus boxes on CheckBox/CheckButton.
25. **Pad-legend honesty on a non-Xbox pad:** SDL-positional names only (no engine API on 4.7)
    — a DualShock reads "B" for Circle; confirm and accept, or scope a legend map for Phase 9.

Rigged demo character items (a capture is one frame — it proves pose and framing, never motion):

26. **Idle feel on a real display:** boot the demo, select a character — the mannequin on the dais
    must actually be MOVING (`Idle_FoldArms`, 2.5s, looping) rather than frozen on frame 0, the
    loop must not visibly pop at the seam, and the pace must read as ambient rather than busy
    behind the menu. Autoplay is headless-asserted; that it plays and loops on screen is not.
27. **Pause freezes the preview:** with the character showing in an `MKPreviewViewport` (the
    appearance step), get `get_tree().paused` true — the idle must FREEZE and resume on unpause.
    The viewport inherits PAUSABLE from host content and that is REQUIRED behaviour, not a bug:
    do not "fix" it. The fullscreen backdrop's copy of the same rig keeps animating instead, since
    the `MKRoot` subtree is `PROCESS_MODE_ALWAYS` — confirm the split reads as intended rather
    than as a glitch. Reaching a real pause from the creation flow may need the demo's pause rung
    to be driven deliberately; if the gesture is not reachable, say so rather than passing the row.

C# adapter item:

28. **Prove the C# adapters against a real .NET Godot build** — **SUBSTANTIALLY CLOSED
    2026-08-09** by an out-of-repo proof: a cold-drop host on Godot 4.7.1-stable mono + .NET SDK
    10.0.302 building the net8.0 target ran a headless proof script against REAL C# delegate
    nodes — `PROOF_RESULT passed=15 failed=0`. Proven for real: the INTEGRATION.md §10 example
    compiles VERBATIM as pasted and runs through the adapter; PascalCase lookup finds real C#
    methods with `Godot.Collections` marshalling intact both directions; `MkConfigure` receives
    params minus `delegate_path`; C# `[Signal]` emissions re-emit through the adapter (roster and
    settings, `string`→`StringName` coerced); the settings boot-triad replays IN ORDER against a
    late-mounted C# node and `save()` is refused before `load()`; and the character-select page
    renders a C#-served roster through a real `MKRoot`. To reproduce: copy `addons/menu_kit/`
    into a fresh .NET Godot 4.7 project, paste the §10 example, build, and drive the adapters
    headless. Remaining for any host's own project: its real autoload registration/order in
    `project.godot`, and the missing-method degrade observed against its build (proven here only
    via the GDScript stand-ins).

---

## 7. Ship gates and toward 1.0

**Ship-gate ledger at `v0.1.0`:** gates 1/4a/5/6/8/9 AUTOMATED-GREEN (isolation scan,
backend-ownership suite, cold-drop fresh profile, corrupt-file suite, the full smoke suite,
diagnostics suites); 2/3/4b/4c PARTIALLY-AUTOMATED (`cold_drop.ps1` + the §6a editor row;
alt-skin suites + capture; pause suites + §6a-17; brightness suite + §6a-1); 4 MANUAL (§6a rows
4, 6–11, 14, 20–25); 7 PASSED by simulation (the worked integration example smoked green without
plugin source); 10 SATISFIED (`MKVersion`, `plugin.cfg`, CHANGELOG and tag agree, pinned by
`test_version_agreement`).

**The §6a human checklist is the outstanding verification work** — it needs a display, a
gamepad, a second keyboard layout, and an interactive editor session. Reports from any of those
rows are welcome as issues.

**Toward `1.0.0`:** real host integrations will surface API friction no gate catches; `1.0.0` is
where the API stops moving. Candidates already recorded: `get_connect_message()` on the network
base, the F6 identity-gated warn, the `F8_NOISE` rename, a pad-legend map for non-Xbox
controllers, and `font_size_title` (the one palette field still generated-but-unconsumed).

---

## 8. The review process

Every phase ran the same loop, and it is the one contributions should expect: implementation
(parallel legs on disjoint files — never two Godot processes against one project, the import
cache collides) → integration by one owner → a dedicated test leg against the integrated code →
adversarial review → fix → re-review until a round introduces nothing new. The per-phase notes
below are what each phase taught about running it.

Phase 3 ran the §8 process at full discipline: parallel implementation legs on disjoint
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

Phase 5 ran the same shape at its largest scale yet (four parallel implementation legs, a
326-assertion test leg, EIGHT review rounds, majors 2→7→1→5→3→2→1→2→0) and taught three things:

- **Fresh eyes on unopened files beat convergence intuition.** Rounds 3 and 7 spiked the major
  count by sweeping code no earlier round had read (the preview's framing math; the profile
  backend). A terminal claim is only as good as the sweep's coverage, not the trend line.
- **Fixtures must share the shipped assets' failure modes.** The round-3 pattern — a suite green
  on MeshInstance fixtures while every shipped CSG preview silently failed — is the tested-path
  vs shipped-path divergence, and the fix is to test the actual shipped `.tres`/`.tscn` at least
  once per mechanism.
- **Fixes breed their own defects at a stable rate: rounds 4–6 were entirely findings inside the
  previous round's fixes** (a de-dup defeating what it guarded, a recovery that ran once per
  lifetime, a reset behind the wrong guard). The per-round fix legs' own reds caught two more
  before review (the accumulate-across-swap defect; the first cut of the movement rule). Plan
  for review rounds ≈ fix-generations + 2, not "one review then done".

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

Phase 6 ran the shape at speed (one session: two implementation legs on disjoint files
with a binding owner-written contract between them, owner integration, a test leg, seven
review rounds; two rounds' fixes applied integrator-inline when small and fully specified, each
audited by the NEXT round as if it were a leg's). What it taught:

- **A zero-defect test leg does not mean a clean phase.** The 150-assertion leg found nothing;
  round 1 then found five majors — every one in the INTERACTION between the new feature and
  shell machinery the tests exercised only in isolation (nav tabs during pause, a scene-less
  page def). Test legs test the deliverable; reviewers must walk the product of deliverable ×
  every existing gesture.
- **Grep the claim family, not the file.** One repudiated mechanism ("open suspends, then
  unwinds on failure") left five prose mirrors across four files; rounds 3–6 each paid for one.
  The terminal round's mirror sweep (grep for the corrected claim's vocabulary across the whole
  repo) is what earned the zero — run that sweep in the FIX leg that changes a mechanism, not
  in round N+3.
- **Surviving mutations became the phase's main currency.** Ten of the fifteen post-test-leg
  findings were "delete/invert this line, the suite stays green" — cheaper to state, harder to
  argue with, and each one converted directly into a test. Reviewers should budget mutation
  time over reading time once the code stops yielding sequence bugs.
- **Integrator-inline fixes are fine IFF the next round audits them by name.** Both inline
  rounds survived their audits, but round 5 was explicitly pointed at cecbcf2 "as if no leg
  report exists" — that pointing is the discipline, not optional.
- **One process footgun on record:** `git checkout --` to restore a mutation clobbered the
  integrator's own uncommitted comment fixes in the same file (§4 trap). Mutate clean files.
