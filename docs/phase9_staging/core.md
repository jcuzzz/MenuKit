# Phase 9 staging — knowledge displaced from `addons/menu_kit/core/*.gd`

Written during the Phase 8a comment diet (leg 1: core). Each bullet is knowledge that was removed
from, or compressed out of, a source comment and that a **host** needs — it belongs in
`INTEGRATION.md`, `API.md`, `THEMING.md`, or `SETTINGS_SCHEMA.md`. The "handoff candidates" section
at the end is maintainer-relevant instead and belongs in `BUILD_HANDOFF.md` §4 (traps) if it is not
already there.

## Host-facing (for INTEGRATION.md / API.md / THEMING.md / SETTINGS_SCHEMA.md)

- **`mk_menu_page_def.gd`, `mk_nav_bar.gd`, `mk_config.gd` — navigation is DATA, and that is the
  upgrade story.** The menu this package was extracted from declared its tab list as a `const` in
  the nav bar, so "add a Credits page" meant forking the nav bar — which breaks the pin-a-tag
  upgrade path the versioning plan is built on. In MenuKit, `MKConfig.pages` is an
  `Array[MKMenuPageDef]`, `MKNavBar` builds tabs from it, and `MKRoot` drives its page state machine
  off the same ids: a host appends, reorders, or hides entries with **zero addon edits**, so it can
  keep pinning a tag and still ship its own pages. `MKMenuPageDef.id` is the payload of
  `MKNavBar.page_selected` and the argument to `MKRoot.go_to_page()`, so a host's deep links are
  written against it — renaming one is a host-visible break, not a cosmetic edit.

- **`mk_backdrop_catalog.gd` — backdrops resolve from an authored array, never from the
  filesystem.** The source implementation scanned a hardcoded game data directory with `DirAccess`
  (including a `.remap` workaround that is fragile in exported builds) and read the active id from a
  game autoload. All three are gone: the list is an exported array (inspector-authored, export-safe,
  no resource path pointing outside the addon), resolution is pure data with no autoload lookup (so
  the addon cold-drops into an empty project and loads headlessly), and a miss warns through `MKLog`
  naming the resource and field rather than silently blanking. `MKBackdropCatalog.has_backdrop()`
  exists so a host can probe a stored id without tripping the miss warning.

- **`mk_backdrop.gd` — `apply_def(null)` CLEARS the layer.** Null is not ignored: it is how a host
  turns the backdrop off (because it supplies its own 3D background) through the same call it uses
  to set one. Backdrops with no texture render a generated gradient, so the shipped catalog
  references no external image.

- **`mk_backend_slot.gd` — why `params` exists, and why shipped backends name no paths.** Backends
  are `Script` references rather than `Resource` instances because they need scene-tree access
  (scene changes, `DisplayServer` calls, timers, a multiplayer peer's lifetime) and must not
  serialize runtime state. A runtime-instantiated `Script` only ever receives its export
  *defaults*, so without `params` a host would have to subclass a backend to say "start **this**
  scene". No addon backend names a scene path of its own — the shipped `default_config.tres` leaves
  those params empty and the host supplies real scenes from its own `.tres`, which is what keeps
  every addon file free of host/demo paths. An empty slot is **valid config**, not an error: the
  shipped config leaves the network slot empty precisely so a cold drop has no server browser and
  emits no warnings.

- **`mk_json_codec.gd` — the persisted JSON envelope is a format surface with a versioning rule.**
  Adding a tag is additive (an old reader meets an unknown tag as a plain dictionary, exactly as it
  already treated any object it did not recognise); RENAMING or repurposing one is **Breaking** and
  belongs in the CHANGELOG as such, because files already on users' disks carry the old spelling.
  Decoding is deliberately tolerant of BOTH tags regardless of which backend is reading — the bytes
  on disk are the authority, not the flag the current caller passes — which is what lets a file
  written by one configuration be read by another with no migration step. The `envelope_ints`
  split: `MKJsonSettingsBackend` passes `false` (its format predates the int envelope and every
  application site in that class coerces with an explicit `int(...)` — window mode, vsync, max FPS,
  resolution components — so enveloping would change bytes for no behavioural gain and make every
  already-written settings file a mixed-format file); `MKJsonProfileBackend` passes `true` (its
  payloads are opaque **host** dictionaries stored and handed back verbatim, so MenuKit cannot know
  which fields are meant to be ints and cannot coerce at the read site — the only alternative to int
  fidelity would be a silent lossy conversion of the host's own data). The `__mk_type` discriminator
  carries the `__mk_` prefix so it cannot collide with a host payload field by accident.

- **`mk_log.gd` — `MKLog.observer` is a testing seam, not a host feature.** Several MenuKit
  contracts are stated as *counts of warnings* ("the shipped default pages build with zero
  warnings", "a panel with no backend warns ONCE for the page rather than once per row", "a missing
  audio bus is named"), and none is assertable without an observation point. `MKLog.debug` reaches
  the observer even when `verbose` is false, deliberately: some behaviours are DEFINED as "the panel
  keeps the widget as it is and says so" (an ENUM sync with no matching option, a slider snapping an
  off-step write), and the saying-so is the assertable half. Default is an empty `Callable`, so
  nothing shipped pays for it and no host is expected to set it. Every misconfiguration message
  names the offending resource path AND field (`MKLog.context`), never a bare "invalid setting".

- **`mk_theme.gd`, `mk_palette.gd`, `mk_theme_generator.gd` — two published name vocabularies.**
  The `MKTheme` type-variation names and the `MKPalette` field names are the contract every panel,
  the generator, and a host's alternate palettes are written against; renaming one is a CHANGELOG
  **Breaking** entry. MenuKit ships ZERO `add_theme_*_override` calls: an override beats the
  `Theme`, so a package that used them could never be re-skinned by swapping an `MKPalette`. Dynamic
  state (a nav tab going active) is a `theme_type_variation` swap, never a StyleBox written onto a
  control. A palette field earns its place only if more than one control reads it, or if a
  re-skinner would obviously reach for it.

- **`mk_theme_generator.gd` — the focus audit, and the one genuine hole.** `Button` and its four
  variations, `OptionButton`, `LineEdit` and the `TabContainer` tab strip all carry a `focus`
  StyleBox with the same content margins as their own `normal` box; `SpinBox` takes focus through
  its internal `LineEdit`. `HSlider`/`VSlider` are the exception and it is the **engine's**: a
  Slider defines no focus StyleBox at all, so there is nothing for the generator to write. That is
  why `MKSettingsPanel` and `MKRebindRow` parent an `MKTheme.FOCUS_RING` `Panel` to the control
  instead — the ring is the vocabulary's answer for any control that cannot own a focus box, it is
  themed, and it re-skins with everything else. A host adding a slider-like control owes it the same
  ring.

- **`mk_theme_generator.gd` — the CheckBox glyph is generated, `CheckButton` is not.** `CheckBox`
  `checked`/`unchecked` (and their `_disabled` variants) are rasterised from palette colours at
  generation time, so a palette swap re-colours them for free and no image file ships. `CheckButton`
  is deliberately left on the engine's art (its icon is a SWITCH — a different shape with different
  states), and the `radio_*` icons are untouched because a `CheckBox` only draws them when it
  carries a `ButtonGroup`, which no MenuKit row assigns.

- **`mk_brightness_controller.gd` / `mk_settings_service.gd` / `mk_root.gd` — brightness ownership
  has two tiers, and only one is supported.** Godot has no global or OS gamma control, so brightness
  cannot be "applied by a backend"; a live controller node is required. `MKSettingsService` (the
  autoload) owns it, because a host may boot straight into gameplay without ever instancing a
  MenuKit scene and a controller owned by a per-scene `MKRoot` would not exist on that path — the
  user would calibrate in the menu, press Play, and watch the image snap back. `MKRoot` builds its
  own controller **only** in the standalone no-service configuration, and that tier is honestly
  weaker: it dies with its per-scene root, so brightness gaps across scene transitions and reaches
  gameplay only if the game scene also hosts an `MKRoot`. Either way the row writes a plain value
  through the settings backend, so a host setting `MKConfig.manage_brightness = false` and consuming
  the value itself loses nothing.

- **Documented gap (owed a sentence in INTEGRATION.md): two service-less shells mounted
  SIMULTANEOUSLY each build their own brightness controller and stack two gamma passes.** No shipped
  configuration mounts two service-less shells at once (the demo uses the autoload; scenes swap
  rather than coexist), so the gap is documented rather than guarded. A host running that shape owns
  brightness itself or mounts the service.

- **`mk_brightness_controller.gd` — `Mode.ENVIRONMENT` caveats are inherent to the approach.** It
  drives the **active** `Environment`, and MenuKit never owns one, so either the host names its
  `WorldEnvironment` through `world_environment_path` or the controller walks the current viewport's
  `World3D` and finds nothing in a 2D or menu-only scene; it crushes rather than lifts true blacks
  at extremes, so the dark end of the slider behaves differently from `Mode.OVERLAY`; adjustment
  support varies by renderer; and it does not affect the UI, so the "adjust until the logo is barely
  visible" calibration convention does not apply. The value is applied directly as
  `adjustment_brightness` (a multiplier) rather than as a gamma exponent, so a given slider position
  does not look identical in the two modes — both are neutral at 1.0, which is the part that
  matches.

- **`mk_settings_service.gd` — the autoload is OPTIONAL, and here is the supported substitute.** A
  host that refuses third-party autoloads disables it in Project Settings and makes the same three
  calls from its main scene `_ready()`, **in this order**: `snapshot_input_defaults()` (capture stock
  bindings BEFORE any override, or "Reset to Defaults" silently resets to the user's own overrides),
  `load()`, `apply_all()`. What is *not* supported is skipping it and expecting rebinds to apply.
  Note also that the service flushes the store in its own `_exit_tree` — without that flush every
  panel write would apply immediately, live in memory, and never reach the file. A host wanting an
  earlier flush calls `MKSettingsBackend.save()` itself.

- **`mk_settings_service.gd` / `mk_root.gd` — the single-instance rule.** Two settings backends over
  one JSON file means the revert countdown snapshots one while a panel writes the other, and the
  last `save()` silently wins. `MKRoot` therefore checks for `/root/MKSettingsService` and adopts
  `get_settings_backend()` rather than building its own; **the method name is the contract** for a
  host substituting its own service-shaped node (as is `get_brightness_controller()`). A config
  naming a different settings-backend script than the service already built is a misconfiguration
  and is reported as one — the service's instance is kept. On the adopt path the slot's `params` are
  IGNORED; configure the service's slot instead.

- **`mk_root.gd` — the cancel/ESC precedence ladder** is: rebind capture -> modal stack top -> page
  back stack -> pause rung -> root quit-confirm. Rebind capture is handled by mechanism (a listening
  row consumes in `_input` and calls `set_input_as_handled()`), which is what makes Escape
  unbindable without a blacklist. The pause rung is PAGE-AWARE: it resumes only when the shell is
  showing the page `open_pause_menu()` opened, and otherwise navigates back to that page.

- **`mk_root.gd` — unsupported host gestures, each with a why.** (a) Reparenting a LIVE shell: a
  reparent runs `_exit_tree` on an instance that then survives it, so pause and nav state is
  discarded with no `pause_menu_toggled(false)` and the host is never told — close the pause menu
  first. (b) Assigning `config` at runtime: it re-runs nothing, rebuilds no nav, and restyles
  nothing (swapping `MKConfig.palette` **is** supported — that goes through `Resource.changed`).
  (c) Programmatic `go_to_page()` while the pause menu is open: nothing refuses it, but the ESC
  ladder will treat it as a divergence and navigate back to the recorded pause page.

- **`mk_root.gd` — hiding the shell IS closing the pause menu.** The documented in-game gesture is
  `visible = open` on a shell parked inside the game scene; a host that hides it directly (a
  cutscene, a death screen, its own menu key) would otherwise strand the whole suspension — world
  paused, cursor free, counter at one, and no visible surface to unwind it from.

- **`mk_root.gd` — `host_content_process_mode`.** Page content is PAUSABLE by default so a host's
  page does not keep animating during pause and behave differently there than in-game. The pause
  menu's own page is the exception a host MUST be able to make: a PAUSABLE control reports
  `can_process()` false and Godot does not dispatch GUI input to it, so under a tree pause policy its
  Resume button would be dead. An `MKRoot` hosting the pause page sets this to `PROCESS_MODE_ALWAYS`.

- **`mk_root.gd` — `pause_menu_toggled` matters under a no-pause policy.** The world keeps running
  while the cursor is freed, and host mouselook will keep consuming relative motion unless the host
  acts on this signal.

- **`mk_root.gd` — `dump_diagnostics()` is the bug-report surface** and deliberately carries the
  resolved `user://` store path of any backend exposing `get_file_path()`: "settings don't persist"
  is usually a question about WHICH file was written, and without it the answer costs a round trip
  with the reporter. It also carries the creation-flow counts (archetypes, steps, point-buy on/off),
  which are invisible from a screenshot — an empty archetype step and a step whose defs were dropped
  look identical.

- **`mk_root.gd` — `show_backdrop` and the in-game pause configuration.** The backdrop is main-menu
  scenery; an opaque backdrop on a pause shell hides the very world the pause menu sits on top of,
  and the paused game behind the panel is what tells the player this is a pause and not a scene
  change.

- **`mk_modal_layer.gd` — ownership rules a host must not confuse.** `pop_modal`/`remove_modal`
  return ownership to whoever pushed (so a cached dialog can be reused); `reap_modal` **destroys**
  what it is handed and exists only for resolved corpses whose owner is already dead — a host
  reusing a cached dialog must never route it through it. `reap_modal` must ALWAYS be called
  deferred (`layer.call_deferred(&"reap_modal", dialog)`): the deferral is the mechanism that lets
  the two teardown shapes decide themselves. Never reach around the layer (reparenting and freeing a
  stacked modal directly) — the entry stays in the stack, `is_empty()` reports false forever, the
  scrim stays up over nothing, and `MKRoot` swallows every cancel gesture from then on.

- **`mk_modal_layer.gd` — a modal may implement two optional methods.** `handle_cancel() -> bool`
  returning `true` keeps the cancel gesture and stays open (a rebind row that is listening, a wizard
  step that goes back one step); anything else is closed by popping. `_mk_layer_teardown()` is called
  during `clear_for_teardown()` so a modal that would normally free itself on `modal_popped` (which
  teardown does not emit) can dispose of itself — the layer still never decides ownership.

- **`mk_focus.gd` — what the helpers guarantee.** `trap()` wraps focus on BOTH axes and is safe to
  call defensively (a second trap is a no-op, not a re-grab). When every focusable under a modal is
  disabled, `trap()` wires the ring over the DISABLED set rather than returning null: focus then
  sits on a control that cannot be activated, but every key and stick direction stays inside the
  modal, which is the property that makes it modal. `release()` must be called on pop; a control
  that keeps a trap's wrap-around ring while being reused as ordinary page content is a region focus
  can enter and never leave.

- **`mk_input_glyphs.gd` — a host mounting its own tracker owes it the LAST sibling position.** The
  dispatch-order contract (kept in full in the class doc) is the single source three sites reference;
  `MKSettingsPanel._place_input_glyphs_last` is the shipped implementation. `MKInputGlyphs` never
  marks an event handled — it observes. Prompts are TEXT, not textures, and
  `MKInputGlyphs.JOY_BUTTON_NAMES` holds SDL **positions**, not the legend printed on the player's
  pad (`JOY_BUTTON_A` is "the bottom face button" — Cross on a PlayStation pad);
  `Input.get_joy_button_string` is preferred precisely because it can do better.

- **`mk_input_glyphs.gd` — bindings are stored by PHYSICAL keycode** so they stay under the same
  finger on an AZERTY layout, and the label is mapped back through the ACTIVE layout for display.
  A prompt reads `InputMap` (the live, post-override truth an actual press is matched against); a
  settings row asks the STORE instead. The two agree once apply has run, and only the store survives
  a restart.

- **`mk_preview_viewport.gd` — it deliberately inherits PAUSABLE.** Under an `MKRoot` page a preview
  inside a paused page stops spinning, which is the required behaviour. Setting
  `PROCESS_MODE_ALWAYS` inside the addon would look like a bug fix and silently break it; a host that
  wants an always-spinning preview sets the mode on ITS instance.

- **`mk_preview_viewport.gd` — the `SubViewport` owns its own `World3D` by default, and sharing leaks
  BOTH ways.** This node's key/fill/rim lights would light the running game, and the game's
  `WorldEnvironment` and sun would light the preview — so the same preview looks different over a
  night map than over a day map, and the game visibly brightens while a character sheet is open. It
  is an opt-out precisely because the leak is invisible until somebody notices the game got
  brighter. The rig is neutral three-point white with shadows off, so a host's material shows as
  authored; hosts wanting mood attach their own `WorldEnvironment` to the content scene.

- **`mk_preview_viewport.gd` — swap semantics.** A swap re-CENTRES on the new content's bounds but
  keeps the user's yaw, pitch and zoom, so cycling a character list preserves the chosen angle. Only
  the FIRST content fits the distance. A host whose content differs in scale by an order of
  magnitude, or whose content grows meshes after instancing (an equipped weapon appears, a rig
  streams in), calls `frame_content()` — that is the one call that refits distance unconditionally.
  The stable child names (`ContentPivot`, `PreviewCamera`, `KeyLight`, `FillLight`, `RimLight`) are
  a public surface; renaming one is a public-surface change.

- **`mk_config.gd` — validation reports EVERYTHING at once**, on purpose: a first-time integrator
  gets one list to work through instead of a fix-run-fix loop. Slot *absence* is never a problem.
  `MKConfig.SETTINGS_SERVICE_NAME` / `SETTINGS_SERVICE_PATH` are the one place the autoload name is
  written down — three runtime sites resolve it, and a rename that reaches only some of them fails
  SILENTLY into a second settings backend over the same JSON file plus a second brightness
  controller.

- **`mk_config.gd` — creation-flow defaults.** `creation_steps` empty means "not authored", never
  "no steps" — `MKCharacterCreate` falls back to its built-in Name -> Archetype -> Appearance order.
  `point_buy_schema` null (the default) disables point-buy entirely, and any point-buy step def is
  dropped: a game with no stat concept must not be handed a stat screen it has to work out how to
  remove.

## Handoff candidates (maintainer knowledge, for BUILD_HANDOFF.md §4 if not already there)

- **Godot re-enables input processing at `NOTIFICATION_READY`** for any script overriding `_input`,
  so a `set_process_input()` written before tree entry is silently undone (`mk_input_glyphs.gd`
  restates it in `_ready` for that reason).
- **`DisplayServer.keyboard_get_keycode_from_physical` on the headless driver** both answers 0 and
  prints an engine ERROR line per call, which a noise-gated suite reads as a failure — hence the
  driver check BEFORE the call rather than a diagnosis after it (`mk_input_glyphs.key_label`).
- **`clampf` on an inverted min/max pair collapses every input onto one of the two ends** — it
  raises to the minimum FIRST and then lowers to the maximum, so `clampf(3, 5, 1)` is 5 and
  `clampf(8, 5, 1)` is 1. `MKPreviewViewport._clamp_zoom` orders the pair rather than trusting it.
- **A `SubViewportContainer` with `stretch` enabled OWNS its `SubViewport`'s size** and drives it to
  the container's pixel rect every layout pass; the engine actively refuses a manual size write in
  that configuration, one WARNING per attempt. So no resized hook and no size sync is correct.
- **Flipping `own_world_3d` on a live `SubViewport` nulls its 3D instances' scenario mid-flight**
  (renderer error `Parameter "scenario" is null`). Detach the viewport, flip, re-add.
- **A call deferred onto a node that is memdeleted before the next `MessageQueue` flush never
  arrives.** That is the mechanism `MKModalLayer.reap_modal` relies on to tell "the shell was
  destroyed with the dialog still stacked" from "only the owner died".
- **Leaving the tree fires `NOTIFICATION_EXIT_TREE` and NO visibility notification**, even though
  `is_visible_in_tree()` answers false afterwards — which is why `MKRoot`'s hide-is-close hook
  cannot be reached by teardown.
- **A node left parented to the root when `SceneTree.quit()` runs receives
  `NOTIFICATION_EXIT_TREE`** before it is deleted (shutdown frees the root through the tree, so
  autoloads exit it rather than being dropped where they stand). That is what makes
  `MKSettingsService`'s save-on-exit work.
- **A typed `Array[Control]` REFUSES to hand back an element whose object has been freed** ("Trying
  to assign invalid previously freed instance"), and `as Control` on a freed instance prints "Trying
  to cast a freed object" — hence `MKModalLayer._stack`/`_focus_memory` being untyped and uncast.
  Relatedly, `is_instance_valid` MUST precede an `is` test: the `is` operator itself errors on a
  previously freed instance.
- **`Array.sort_custom` is not a stable sort** — both `MKNavBar.set_pages` and
  `MKConfig.get_visible_pages` decorate with the original index, because the same array feeds both
  the tab order and the boot page.
- **CSG (and any procedurally built) meshes report a ZERO `get_aabb()` on the frame they are
  added**, which is why every framing pass in `MKPreviewViewport` runs immediately AND deferred, and
  why the immediate pass is silent about zero bounds.
- **Registering a real autoload needs an editor session**, so a headless test cannot reach
  `MKSettingsService` through the shipped path — hence its `override_backend_slot` seam. A script
  registered as an autoload must NOT also declare a matching `class_name`, or it fails to parse at
  every boot ("Class ... hides an autoload singleton") and the autoload never instantiates, while
  tests that mount the node directly stay green.
- **The isolation scan matches the forbidden `add_theme_*_override` call name even inside prose**,
  which is why `mk_theme_generator.gd` spells it with a wildcard in one comment and avoids spelling
  it at all in another. Any future comment naming that call must do the same.
- **`_built` in `MKPreviewViewport` does not survive an editor script reload** — a reload re-runs
  `_ready` on a re-created script instance and the children ARE rebuilt on top of the previous set.
  What it covers is a second `_ready`/`_build` on the SAME instance. Left to the editor's own node
  rebuild rather than defended with a name scan.
