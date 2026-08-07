# Phase 8a staging — addon modules (backends / settings / creation / panels / plugin)

Knowledge displaced by the comment diet in this leg. Host-relevant bullets are destined for the
Phase 9 docs set (INTEGRATION.md / API.md / SETTINGS_SCHEMA.md / CREATION_STEPS.md); the
"handoff candidates" section at the end is maintainer-relevant material not already in
`BUILD_HANDOFF.md`.

## default_config rationale (for INTEGRATION.md)

The whole of this section was authored as a `;` comment block at the top of
`addons/menu_kit/default_config.tres` and was deleted there because Godot does not round-trip
comments in resource files (any editor save strips them). It is the config's copy-me rationale
and belongs in INTEGRATION.md.

- **What the file is.** The host's copy-me starting point. Every value is chosen so that copying
  `addons/menu_kit/` alone into an empty Godot project boots with zero errors and zero warnings
  (ship gate 2) — verified by cold drop, not assumed.
- **Four backend slots are assigned; the NETWORK slot ships empty on purpose.** An unassigned
  network slot hides the server browser entirely, which is the right first impression for a
  single-player game — and `MKStubNetworkBackend` still ships as the reference implementation a
  host or the demo can point a slot at. "Shipped default" means available, not active.
- **The Settings page** is the second page the addon ships and is held to the same bar as the
  first: gate 2 cold-drops `addons/menu_kit/` alone into an empty project and requires this page
  to boot AND open with zero errors and zero warnings. That is why the panel's own default pages
  are the addon's `settings/defaults/*.tres` — a Master-only Audio page and a Controls page with
  no KEYBIND rows — because an empty project has one audio bus and only `ui_*` actions, and a row
  naming a missing bus or an absent action warns by design. The richer pages are the host's to
  author.
- **The Characters page** is the third page the addon ships, and it clears gate 2 without a
  special case: the PROFILE slot is assigned (`MKJsonProfileBackend`, one of the six shipped
  defaults), so the select panel resolves a real backend off the shell and its "no
  MKProfileBackend is reachable" warning is unreachable in the cold-drop configuration. What a
  fresh install actually sees is an empty roster, rendered as "No characters yet" with New
  Character focused. That is a state, not a warning.
- **`character_create` is a HIDDEN page** (`visible = false`), the same mechanism the demo's
  "sub" page uses: hidden keeps it off the nav bar while leaving it reachable by id, which is
  what `push_page` needs. It must not be a tab — arriving at a half-built character by clicking a
  nav tab, and losing it by clicking another, is the navigation bug the back-stack ladder exists
  to avoid.
- **One archetype ships, inline, as a sub-resource.** Inline rather than a standalone `.tres`
  because it is not a file a host is meant to edit or reference — it exists so the Archetype step
  is never an empty dead end on a fresh install. It is deliberately genre-NEUTRAL: "Traveler"
  states no setting, where a Vanguard or an Arcanist would state one the host has not chosen.
  Real archetypes are the host's to author (the demo authors three under `demo/demo_archetypes/`),
  and the moment `MKConfig.archetypes` is authored this entry is gone.
- **`creation_steps` stays EMPTY on purpose:** empty means "not authored", and
  `MKCharacterCreate` falls back to its built-in Name -> Archetype -> Appearance order. Authoring
  the same three here would be a second copy of that order to keep in sync for no gain.
- **`point_buy_schema` stays null** — D17, disabled by default. A game with no stat concept must
  not be handed a stat screen it has to work out how to remove. The demo assigns one so the
  enabled path is visible and testable out of the box.
- **`MKSceneMenuBackend`'s `params` are empty:** it names no scene, because an addon file naming
  the demo would break the isolation rule and fail gate 1 by construction. Unassigned params are
  valid config — they warn when Play is clicked, never at boot, which is what keeps gate 2
  passable.

## Host-relevant, displaced from code comments

### plugin.gd (INTEGRATION.md)
- The plugin is the delivery mechanism for integration, not a docs step: enabling it registers
  the `menu_kit/config_path` project setting, the `MKSettingsService` autoload, and a
  "Bake MenuKit Theme" tool-menu entry.
- The autoload exists so persisted settings and rebinds apply on a host that boots straight into
  gameplay without ever instancing a MenuKit scene. Hosts that refuse third-party autoloads
  disable it in Project Settings and take the documented manual path.
- There is deliberately no `add_custom_type` call: `class_name MKRoot` already registers the type
  globally, and a custom-type entry would hand out a bare scripted `Control` rather than
  `mk_root.tscn`. INTEGRATION.md must therefore say "instance
  `addons/menu_kit/core/mk_root.tscn`", not "add an MKRoot node".
- The config-path project setting is written only when unset, so re-enabling the plugin never
  stomps a host that repointed it. Disabling the plugin removes the autoload but deliberately
  leaves the setting in place.
- The theme bake is an editor-preview convenience only. The artifact is gitignored and its
  absence changes nothing at runtime; `MKRoot` generates the same Theme at `_ready`, so a cold
  drop is styled with zero manual steps.

### backends/ (API.md)
- `MKMenuBackend` / `MKProfileBackend` / `MKSettingsBackend` / `MKNetworkBackend` /
  `MKPausePolicy` are the five host extension points. A host subclasses one, points an
  `MKBackendSlot` at the script, and supplies `params` from the config. Backends are Nodes, not
  Resources, because these actions need scene-tree access; `MKRoot` instantiates the slot script
  as a child and calls `_mk_configure(params) -> Array[String]` first, warning by name about
  params nothing claimed.
- **Exactly one `MKSettingsBackend` instance per project.** Two over one JSON file means the
  revert countdown snapshots one and the panel writes the other, and the last `save()` silently
  wins. `MKRoot` adopts the `MKSettingsService` autoload's instance when present.
- **`snapshot_input_defaults()` must run BEFORE `load()` and `apply_all()`.** Run after, it
  captures the user's own overrides as the defaults and "Reset to Defaults" silently becomes a
  no-op. The autoload enforces the order; a host on the no-autoload path makes the same three
  calls itself.
- **Store-only backends are legitimate.** `apply_one`, `apply_action` and the six input-store
  methods are non-abstract with inert bodies, so a backend that only persists values still
  satisfies the contract; rebind rows over such a backend degrade visibly (every row reads
  "Unbound", Reset stays disabled) rather than wrongly. Implement the six input-store methods
  together — the read side without the write side produces rows that capture but never display.
- `MKPausePolicy` teardown contract: whatever a policy changes on engage it must undo in its own
  `_exit_tree()`, not in `MKRoot`'s — `NOTIFICATION_EXIT_TREE` propagates children first, so by
  the time `MKRoot._exit_tree()` runs the policy is already out of the tree and `get_tree()` is
  null. Policies do not count depth; `MKRoot` owns the single counter and calls `enter_menu` only
  on the 0->1 edge and `exit_menu` only on the 1->0 edge. `can_pause() == false` is never a veto
  on opening the menu — the menu opens, the world keeps running, `enter_menu` is skipped.
- `MKNoPausePolicy` is the multiplayer answer, and it hands the host a responsibility: the world
  runs while MenuKit frees the cursor, so a first-person camera keeps consuming relative mouse
  motion behind the menu. Gate camera input on `MKRoot.pause_menu_toggled`.
- `MKNetworkBackend` reports connection progress through `connect_state_changed(state, message)`
  only — never a return value — so the panel stays responsive and cancellable. The enum has no
  TIMEOUT member: a timeout is `FAILED` plus a message, which is why the browser renders both.
- `MKSceneMenuBackend` names no scene of its own; both targets arrive as slot params
  (`game_scene`, `menu_scene`). Unassigned params are valid config — they warn when Play is
  clicked, never at boot.
- **JSON persistence format.** Both shipped JSON backends persist through `MKJsonCodec`'s envelope
  `{"__mk_type": "<type>", "v": <payload>}` (the tag value is a type NAME string).
  `MKJsonSettingsBackend` writes it for `Vector2i` only; `MKJsonProfileBackend` also envelopes
  `int`, because a profile payload is opaque host data it cannot coerce at the read site. Both
  DECODE every tag the codec knows. A host payload may not itself contain the discriminator key —
  `create_profile` refuses such a payload with a warning naming the path, because accepting it
  writes a file whose load quarantines the whole roster.
- **Corruption policy.** An unparseable or wrong-shaped store is renamed aside to
  `<name>.corrupt-<n>.json` and defaults boot with one warning; nothing is ever deleted. A store
  written by a NEWER MenuKit is left exactly where it is — and `MKJsonProfileBackend` additionally
  latches READ-ONLY against it (creates return `{}`, deletes return `false`), because a roster
  cannot survive being overwritten the way a settings file can.
- `MKJsonProfileBackend` stores profiles verbatim, adding one key (`id`, from a monotonic counter
  formatted `p_000001`, never reissued after a delete) and enforcing one rule (unique `name`,
  compared and STORED trimmed).
- `MKStubNetworkBackend` ships as a reference implementation, not a live default. Its delays run
  on `SceneTreeTimer`s so they keep ticking under a tree pause.

### settings/ (SETTINGS_SCHEMA.md)
- `MKSettingDef` / `MKSettingsPageDef` are the whole authoring surface: pages own ordered rows
  (array order IS display order — there is no sort key), rows declare a `RowType`, a store `id`, a
  label, a default, and per-type extras. Adding a row is authoring one `.tres` sub-resource, never
  an addon edit.
- **The `RowType` enum is CLOSED and its values are a persisted contract** — inserting a value
  renumbers every enum already written into an existing `.tres`, which is a Breaking change.
  `RowType.CUSTOM` is the escape hatch: point `custom_scene` at a scene whose ROOT implements
  `_mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void`. A root without it is skipped
  with a named warning. `mk_example_custom_row.tscn` is the shipped reference.
- **Custom rows own their backend relationship end to end.** The panel never reads or writes a
  custom row's display, so a row that wants to stay live subscribes to `setting_changed` itself.
  The four rules the example demonstrates: read through the backend by `def.id` (never a cached
  field), tolerate a null backend, write with `set_value` then `apply_one`, and subscribe if you
  want liveness.
- **Reserved setting ids.** `MKJsonSettingsBackend` applies `video/window_mode`,
  `video/resolution`, `video/vsync`, `video/max_fps` and `audio/bus/<BusName>` to the engine, and
  the panel gives `video/window_mode`, `video/resolution` and `video/brightness` behaviour of its
  own. Every other id is a plain value the host consumes off `setting_changed` — normal operation,
  never a warning.
- A row naming a missing audio bus or an absent input action warns by design. That is why the
  addon's own shipped pages are deliberately minimal (Master-only audio, no KEYBIND rows).
- **`requires_confirm` (window mode, resolution) applies then asks**, with a countdown that
  reverts on timeout — a display change that leaves the user unable to see the screen also leaves
  them unable to click Undo. One live countdown per setting id, keeping the FIRST unconfirmed
  value; an unresolved countdown resolves as REVERTED when the dialog or its panel leaves the
  tree. `requires_confirm` on a KEYBIND row is IGNORED (with a debug line): the machinery operates
  on the value store, and a binding is not in it.
- **`visible_condition_id`** makes a row visible only while another setting's value is truthy,
  live off `setting_changed`. While the controlling setting is unset it falls back to that row's
  own `default_value`, so a default-true controller and its dependent row agree on a fresh
  install.
- **The resolution row** is a curated `Vector2i` list on the def, filtered to what fits the
  current screen, with the native size always added. Authored `options` labels are used
  positionally when present. The row is DISABLED outside windowed mode (`window_set_size` is a
  no-op in fullscreen and borderless) and the tooltip says so; the WINDOW, not the store, is the
  source of truth for which mode is current.
- **`MKRebindRow` capture priority (host-facing invariant).** While a row is listening it reads
  input in `_input` and marks EVERY event class it inspects handled via `set_input_as_handled()`.
  That is what stops a capture keystroke from also closing the menu, activating the focused
  button, or reaching gameplay — `MKRoot` reads `ui_cancel` in `_unhandled_input`, which runs
  strictly after `_input` and after GUI dispatch. Two consequences follow: the row never uses
  `_unhandled_input`, and GUI dispatch does not run for consumed events, so its Cancel button is
  reached by a manual rect hit-test rather than a click. A host installing its own global `_input`
  handler must respect that ordering.
- **Abort is decided per device**, never through the `ui_cancel` action: keyboard physical Escape
  aborts; a gamepad has NO special case (joypad B reaches the record path and is refused there as
  a reserved event, one gesture doing both jobs); a mouse press inside the Cancel rect aborts
  while a press anywhere else is RECORDED; and a listen timeout (default 10s) aborts. Testing the
  action instead would swallow the pad's B before the reserved check could explain it.
- **A capture REPLACES the row's whole event list (single-slot).** The multi-event stock binding is
  not lost — it is in the boot snapshot, and the row's Reset restores all of it. Fresh events are
  built with `device = -1` (all devices) and cleared modifiers.
- `extra_reserved_events` on `MKSettingsPanel` is the host's hook for widening the never-bindable
  set (a game whose menu also opens on Start). The derived part is the boot-default NON-keyboard
  `ui_cancel` bindings only; keyboard Escape is deliberately absent because the row's own abort
  already makes it unreachable.
- `MKRevertCountdown` runs with `PROCESS_MODE_ALWAYS` and accumulates in `_process` rather than on
  a `Timer`, so it still counts down when opened from the pause menu under a tree pause.

### creation/ (CREATION_STEPS.md)
- `MKCreationHost` runs an ordered `Array[MKCreationStepDef]` with one shared payload `Dictionary`,
  owns Back/Next/Skip/Confirm, the validation gate and the progress indicator, and emits
  `creation_confirmed` / `creation_cancelled` rather than navigating anywhere itself.
  `configure()` is the ONE entry point — there is no incremental `add_step`.
- **The step contract is four methods on the scene ROOT**, plus a `step_state_changed` signal:
  `_mk_step_owned_keys() -> Array[String]`, `_mk_step_bind(host, def, ctx)`,
  `_mk_step_is_valid() -> bool`, `_mk_step_commit(payload)`. An optional fifth,
  `_mk_step_requires_stat_schema() -> bool`, marks a step as point-buy-shaped.
  `_mk_step_owned_keys` is called BEFORE the bind and must therefore be a static declaration, not
  a function of the context.
- `ctx` carries `archetypes`, `profile_backend` (may be null), `stat_schema` (may be null) and
  `payload` — the last a DEEP COPY, so a step can only write through `_mk_step_commit`.
- **Two enabled steps claiming one payload key is an error, not a precedence question.** The host
  logs an error naming both defs and the key, and DROPS the later step. `_mk_step_commit` runs on
  Next and Confirm, never on Skip and never on Back.
- **Archetype defaults are seeded first, step commits overwrite** — and it is enforced by
  EXCLUSION: an archetype default whose key a step owns is refused at `configure` with an error
  naming both sides, so the overwrite never actually happens. Changing archetype clears exactly
  the previous choice's seeded keys and nothing else.
- **Point-buy is disabled by default (D17).** With no `MKConfig.point_buy_schema`, the point-buy
  step is dropped with a debug line; an INVALID schema (no valid stat, or non-positive
  `total_points`) drops it with a warning naming the resource.
- `MKStatSchema` / `MKStatDef`: points are spent from each stat's `min_value`, so `total_points`
  is the budget ABOVE the free starting spread; `cost_per_point` below 1 is clamped to 1;
  `require_full_spend` gates Next until the pool is empty. `effect_hint` is AUTHORED text — there
  is no expression language and MenuKit never derives a stat's meaning.
- `MKArchetype` carries `id`, `display_name`, `description`, optional `icon`, an optional
  `preview_scene` (consumed only by a preview widget, not by the host), and `payload_defaults`.
- `MKStepAppearance` is a deliberate PLACEHOLDER that owns no payload keys and commits nothing; it
  hosts `MKPreviewViewport` showing the chosen archetype's `preview_scene`, and an archetype with
  no preview scene leaves the viewport empty by design. Replacing it means pointing the step def's
  `scene` at a host scene implementing the same contract.
- `MKStepName` owns `name`: 2..24 characters (the max is enforced by the `LineEdit`'s own
  `max_length`, which also truncates programmatic writes), `^[A-Za-z0-9 _-]+$`, trimmed on commit.
  Its availability check is a PRE-CHECK, not the authority — the backend's refusal on Confirm is.

### panels/ (INTEGRATION.md)
- `MKPauseMenu`, `MKCharacterSelect`, `MKCharacterCreate` and `MKServerBrowser` locate their shell
  services by a DUCK-TYPED walk up the tree (`push_page`, `pop_page`, `close_pause_menu`,
  `get_modal_layer`, `get_profile_backend`, `get_menu_backend`, `get_network_backend`, and the
  `config` property), never a typed `MKRoot` reference. A host may therefore wrap the shell or
  embed a panel under its own controller that forwards those calls. The backend walks continue
  past an ancestor that answers the method but returns null.
- **A null backend is never an error in a shipped panel.** Every one renders with its actions
  disabled and warns ONCE, rather than refusing to build. `MKServerBrowser` is the exception that
  proves the rule: it does not warn at boot at all (an unassigned network slot is the shipped
  default) and leaves its actions ENABLED, so the first press is what names the missing slot.
- `MKPauseMenu` is a PAGE, not a shell: it never touches `SceneTree.paused`, the mouse mode or the
  suspend counter. Resume calls `MKRoot.close_pause_menu()` and nothing else; Settings uses
  `push_page` so cancel returns to the pause page rather than resuming the game; Quit to Menu
  closes the pause state FIRST, then calls `to_main_menu()` (a backend that does not change scene
  would otherwise leave a paused world and a free cursor behind).
- `MKPauseMenu` never sets its own `process_mode` — the page host assigns
  `MKRoot.host_content_process_mode` to every page, and writing one here would defeat a host that
  configured a different one.
- `MKCharacterSelect` reads profiles as opaque dictionaries: `id` and `name` are guaranteed, and
  the only optional field it displays is `archetype` (type-gated). Deletion requires a reachable
  `MKModalLayer` and is REFUSED without one rather than performed unconfirmed. New Character uses
  `push_page`, and `MKCharacterCreate` returns with the symmetric `pop_page`.
- `MKConfirmDialog.open(layer, title, body, confirm_text, cancel_text, destructive, alt_text)` is
  the generic 2-3 button modal. A dialog opened that way frees itself when popped; one built with
  `.new()` and pushed by the host stays the host's. `destructive` styles Confirm as danger AND
  reorders the row so the dialog opens focused on Cancel — focus is decided by BUTTON ORDER,
  because every focus route into a modal takes the first focusable in tree order.
- `MKWelcomePage` is the addon's shipped default page so a fresh install has something to show;
  pointing `MKConfig.pages` at host scenes replaces it with no addon edit.
- `mk_settings_panel.tscn` and `mk_example_custom_row.tscn` are ROOT-ONLY scenes on purpose (this
  was authored as a comment inside each `.tscn` and removed there, since Godot strips
  resource-file comments): the settings panel builds every tab and row at runtime from `pages`, so
  a hand-placed control would be a row a host could not remove without forking the scene; the
  custom-row example builds its children inside `_mk_bind`, because a custom row cannot know its
  own shape until it has seen the `MKSettingDef` it is bound to. The panel's `pages` default names
  the four shipped `settings/defaults/*.tres`, each self-contained and needing no host
  provisioning, so a drop into an empty project stays warning-free.

## Handoff candidates (maintainer-relevant, not already in BUILD_HANDOFF.md)

- **`ProjectSettings.set_setting` + `save()` asymmetry (plugin.gd).** `set_setting` mutates the
  in-memory map only; without an explicit `ProjectSettings.save()` the key evaporates on the next
  editor launch and the service silently falls back to the default path — a bug whose signature
  only appears on the *second* run. `EditorPlugin.add_autoload_singleton` needs no equivalent
  save (the editor persists autoloads itself); do not add one assuming symmetry.
- **Initial value must differ from the written value (plugin.gd).** Godot omits from
  `project.godot` any setting whose current value equals its initial value, so setting both to the
  same path made `save()` a silent no-op: the key never reached disk and `has_setting()` stayed
  false on every launch. The initial value is therefore `""` ("the host has not chosen one").
- **Autoload name derivation.** The autoload is registered under
  `MKConfig.SETTINGS_SERVICE_NAME` rather than a literal spelled again in `plugin.gd`.
  Registering under a name nothing resolves is the worst form of that drift: every lookup falls
  back to its no-autoload path and the host silently runs two settings backends over one JSON
  file and two brightness controllers over one screen, with no error anywhere.
- **`JSON.parse_string()` pushes an engine ERROR line; `JSON.new().parse()` does not.** Both JSON
  backends deliberately use the instance API, because the static one emits an engine-level
  "Parse JSON failed" ERROR on a path they fully handle by quarantining and booting defaults —
  which would fail any gate that scans output for ERROR lines. Also: report the parse failure and
  the wrong-root-type failure SEPARATELY; a successful parse whose root is an array leaves the
  error line and message empty, so folding them prints "(line 0: )".
- **`InputEvent` per-class `device` defaults are NOT -1** (`InputEventJoypadButton` 0,
  `InputEventKey` 16, `InputEventMouseButton` 32), so every serialised and every freshly captured
  event must set `device = -1` explicitly or the binding silently narrows to one device. The
  engine's own builtin `ui_*` defaults legitimately carry 16/32 as a device-CLASS namespacing —
  reproducing those in a snapshot is correctness, not corruption.
- **`LineEdit.max_length` truncates programmatic `text =` assignments too**, not only typing.
  `MKStepName` relies on that being the single enforcement point for its maximum, which is why it
  carries no "too long" validation branch.
- **`Array.duplicate()` returns an UNTYPED Array**, so `typed_array = other.duplicate()` is an
  unsafe narrowing; use `assign()`. Likewise, an untyped `[]` literal is refused at runtime by any
  parameter typed `Array[T]` — build a typed local first. Both traps recur across the panels.
- **Focus ordering constraint in every rebuilding panel.** `MKFocus.collect_focusables` skips
  DISABLED buttons, so selection and every enable-flag must be settled BEFORE the focus chain is
  built, or the chain wires a ring that steps over buttons that are about to become live.
  Correspondingly, a rebuild that frees the focused control leaves a null focus owner and a
  keyboard/gamepad-dead page, which is why both list panels carry an explicit focus-recovery step.
- **`MKInputGlyphs` dispatch order is a real constraint, not tidiness.** The tracker must sit
  LAST among `MKSettingsPanel`'s children so `_input`'s reverse-order walk reaches it before any
  rebind row consumes the event. It survives `_clear()` while the tab strip does not, so the order
  INVERTS across a rebuild unless `_place_input_glyphs_last()` re-asserts it — a defect that
  cannot be seen on a first build.
- **Two `.tscn` files under `settings/` carried authored `;` comment blocks**
  (`mk_settings_panel.tscn`, `mk_example_custom_row.tscn`) and were cleaned in this leg under the
  same rule as `default_config.tres`. Their content is preserved in the panels bullet above. If
  the sweep for authored resource-file comments is repeated, note that `.tscn` needs it as much as
  `.tres`.
