# Integrating MenuKit

MenuKit is a Godot 4.7 menu framework: a themed shell with data-driven navigation, a settings
schema with rebinding, a character select/create flow, a pause menu, and an optional server
browser. Everything that touches your game — starting a match, saving a character, pausing the
world — goes through a **backend** you supply.

This document is self-contained. Following it alone is enough to wire a custom backend; you should
never have to read plugin source.

---

## 1. Install

1. Copy `addons/menu_kit/` into your project. Nothing outside that folder is required at runtime —
   the addon references no path outside itself.
2. **Project → Project Settings → Plugins → enable MenuKit.** Enabling registers three things:
   - the `menu_kit/config_path` project setting (how the settings autoload finds your config —
     an autoload cannot see a scene-assigned `MKConfig`),
   - the `MKSettingsService` autoload,
   - a **Project → Tools → Bake MenuKit Theme** menu entry (editor preview only; the runtime
     generates the same `Theme` at `_ready`, so the bake is never the source of truth and its
     absence changes nothing).

   The config-path setting is written **only when unset**, so re-enabling the plugin never stomps a
   path you repointed. Disabling the plugin removes the autoload and deliberately leaves the setting.

3. Instance **`res://addons/menu_kit/core/mk_root.tscn`** in your menu scene. There is no
   "add an MKRoot node" step: the plugin registers no custom type on purpose, because a custom-type
   entry would hand out a bare scripted `Control` instead of the scene, and the scene is what carries
   the shell layout.

A cold drop with the shipped `addons/menu_kit/default_config.tres` boots with **zero errors and zero
warnings**: three pages (Welcome, Settings, Characters), a working settings store, an empty roster
rendered as "No characters yet", and no server browser (the network slot ships unassigned on
purpose — an unassigned network slot hides that page entirely, which is the right first impression
for a single-player game).

---

## 2. The three integration tiers

MenuKit has one hard ordering rule, and each tier is a different way of satisfying it:

> `snapshot_input_defaults()` → `load()` → `apply_all()`, in that order, exactly once per project.

`snapshot_input_defaults()` captures the stock `InputMap` **before** any override is applied. Run
after `load()`, it captures the user's own overrides as the defaults, and "Reset to Defaults"
silently becomes a no-op — a failure with no error and no wrong value to notice.

There is a second hard rule that cuts across all three tiers:

> **Exactly one `MKSettingsBackend` instance per project.**

Two backends over one JSON file means the confirm-or-revert countdown snapshots one while the panel
writes the other, and the last `save()` silently wins.

### Tier A — the autoload service (recommended)

Enable the plugin and do nothing else. `MKSettingsService` boots at launch, resolves its slot from
the config at `menu_kit/config_path`, makes the three calls in order, and creates the brightness
controller. Every `MKRoot` in the project then **adopts** the service's backend instead of building
its own.

The service is also what makes settings apply on a host that boots straight into gameplay without
ever instancing a MenuKit scene.

**Save-on-exit.** The service flushes the store in its own `_exit_tree()`. That is what makes
settings, rebinds, and brightness survive a relaunch — without it every panel write would apply
immediately, live in memory, and never reach the file. Two consequences:

- A **crash** or `OS.kill` loses that session's writes. Call `MKSettingsBackend.save()` yourself
  at any point you want a hard flush (after a settings page closes, at a checkpoint, on focus loss).
- Writes are batched by design: a slider drag would otherwise rewrite the file per tick.

**Adopt-path caveat: the slot's `params` are IGNORED.** When `MKRoot` adopts the service's backend,
it does not re-run `_mk_configure` — the instance already exists. Configure the **service's** slot
(the one in the config at `menu_kit/config_path`), not a second slot in a scene-assigned config.
`MKRoot` notes the ignored params at debug level. A config naming a *different* settings-backend
script than the service already built is reported as a misconfiguration, and the service's instance
is kept.

`MKRoot` finds the service by name and by **method name**: `/root/MKSettingsService` answering
`get_settings_backend()` and `get_brightness_controller()`. Those two method names are the contract
if you substitute your own service-shaped node.

### Tier B — standalone `MKRoot`, no service

Disable the `MKSettingsService` autoload in Project Settings. `MKRoot` then builds its own settings
backend from its config's `settings_backend` slot, makes the three calls itself, and — if
`MKConfig.manage_brightness` is true — builds its own brightness controller.

This tier is honestly weaker and you should know how:

- The brightness controller **dies with its per-scene `MKRoot`**, so brightness gaps across scene
  transitions and reaches gameplay only if the game scene also hosts an `MKRoot`.
- **Two service-less shells mounted SIMULTANEOUSLY each build their own brightness controller and
  stack two gamma passes.** No shipped configuration mounts that shape (the demo uses the autoload;
  scenes swap rather than coexist), so this is documented rather than guarded. If you run that
  shape, either mount the service or set `MKConfig.manage_brightness = false` and consume
  `video/brightness` yourself.
- Save-on-exit happens in `MKRoot._exit_tree()` only when it was *not* adopted — one owner, one
  write.

### Tier C — manual, no autoload at all

If your project refuses third-party autoloads: disable the autoload, and make the same three calls
from your main scene's `_ready()`.

```gdscript
extends Node

@export var settings_config: MKConfig

var _settings: MKSettingsBackend


func _ready() -> void:
	_settings = MKJsonSettingsBackend.new()
	_settings.name = "MKSettingsBackend"
	add_child(_settings)

	# The order is the contract. Reversing the first two silently breaks Reset to Defaults.
	_settings.snapshot_input_defaults()
	_settings.load()
	_settings.apply_all()


func _exit_tree() -> void:
	# Nothing else flushes on this tier.
	if is_instance_valid(_settings):
		_settings.save()
```

What is *not* supported is skipping the three calls and expecting rebinds to apply. Brightness on
this tier is yours: either mount an `MKBrightnessController` or set `manage_brightness = false` and
read `video/brightness` off `setting_changed`.

---

## 3. `MKConfig`, slots, and params

`MKConfig` is the one resource a shell reads. Copy
`res://addons/menu_kit/default_config.tres` into your own project folder and edit that copy — it is
the copy-me starting point, and every value in it is chosen so a cold drop boots clean.

| Group | Field | Notes |
|---|---|---|
| Backends | `menu_backend`, `profile_backend`, `settings_backend`, `network_backend`, `pause_policy` | Five `MKBackendSlot`s. **An empty slot is valid config, never an error.** |
| Appearance | `palette`, `backdrop_catalog`, `backdrop_id` | See [THEMING.md](THEMING.md). |
| Navigation | `pages: Array[MKMenuPageDef]`, `initial_page` | Add, reorder, or hide pages with zero addon edits. |
| Character Creation | `archetypes`, `creation_steps`, `point_buy_schema` | See [CREATION_STEPS.md](CREATION_STEPS.md). |
| Behaviour | `manage_mouse_mode`, `manage_brightness`, `verbose` | |

`MKConfig.validate()` reports **every** problem at once — one list to work through instead of a
fix-run-fix loop — and every message names the offending resource path and field. `MKRoot` runs it
at `_ready`.

### Backend slots

A slot is a `Script` reference plus a `params: Dictionary`:

```gdscript
# In the inspector on your MKConfig:
#   profile_backend.backend_script = res://game/backends/my_profile_backend.gd
#   profile_backend.params         = { "file_path": "user://saves/roster.json" }
```

Backends are **Nodes instantiated from a `Script`**, not `Resource` instances, because they need
scene-tree access (scene changes, `DisplayServer` calls, timers, a multiplayer peer's lifetime) and
must not serialize runtime state. A runtime-instantiated script only ever receives its export
*defaults* — which is exactly why `params` exists. Without it, "start **this** scene" would require
subclassing a shipped backend.

`MKRoot` instantiates the slot script as a child and calls:

```gdscript
func _mk_configure(params: Dictionary) -> Array[String]
```

**first**, before anything else touches the backend. Return the keys you consumed. `MKRoot` warns by
name about any param nothing claimed — a typo in a param key is a named warning, not silence.

No shipped addon backend names a scene path of its own. `MKSceneMenuBackend` takes `game_scene` and
`menu_scene` as params, and the shipped config leaves them empty; unassigned params warn when Play is
clicked, never at boot.

### Pages

```gdscript
# MKMenuPageDef: id, title, icon, scene, visible, order
```

`MKNavBar` builds its tabs from `MKConfig.pages`; `MKRoot` drives its page state machine off the same
ids. **`MKMenuPageDef.id` is a public surface** — it is the payload of `MKNavBar.page_selected` and
the argument to `MKRoot.go_to_page()`, so your deep links are written against it. Renaming one is a
host-visible break.

`visible = false` keeps a page **off the nav bar while leaving it reachable by id** — which is what
`push_page` needs. The shipped `character_create` and `pause` pages both use it. A half-built
character reached by clicking a nav tab, and lost by clicking another, is exactly the bug the back
stack exists to avoid.

Host page content is any `PackedScene`, living outside the addon, needing no addon edit. **It wires
its own focus chain** — nothing does it for content the addon does not own:

```gdscript
extends Control

func _ready() -> void:
	MKFocus.chain_container(%Buttons)
	MKFocus.focus_first(self)
```

---

## 4. Worked example — a custom `MKProfileBackend`

`MKProfileBackend` is the character/save roster. Profiles are **opaque `Dictionary`s end to end**:
the creation flow assembles one from its steps and hands it here verbatim, and your project defines
the meaning of every field. MenuKit never interprets a payload.

### The complete contract

Four abstract methods, one non-abstract override point, one signal:

```gdscript
signal roster_changed()

@abstract func list_profiles() -> Array[Dictionary]
@abstract func create_profile(payload: Dictionary) -> Dictionary
@abstract func delete_profile(id: String) -> bool
@abstract func load_profile(id: String) -> Dictionary

func is_name_available(profile_name: String) -> bool   # default scans list_profiles()
func _mk_configure(params: Dictionary) -> Array[String]
```

Guarantees MenuKit relies on: **every entry carries at least `id` and `name`**; everything else is
yours. `MKCharacterSelect` displays one further field if present — `archetype` (type-gated) — and
otherwise treats the dictionary as opaque.

`roster_changed` must be emitted whenever the roster changes by any route, so the select panel never
has to poll or be told to refresh by whoever mutated it.

### The example

```gdscript
class_name MyProfileBackend
extends MKProfileBackend
## Roster stored in the host's own save system.

var _service_path := "user://saves/"
var _cache: Array[Dictionary] = []
var _loaded := false


## Called by MKRoot BEFORE anything else. Return the keys you consumed so unknown ones get named.
func _mk_configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	if params.has("save_dir"):
		consumed.append("save_dir")
		var raw := String(params["save_dir"])
		if raw.is_empty():
			push_warning("MyProfileBackend: save_dir is empty; keeping '%s'" % _service_path)
		else:
			_service_path = raw
	# Configuration happens before the node enters the tree, so any cached state was read from the
	# wrong place. Drop it; the next call re-reads.
	_loaded = false
	return consumed


func list_profiles() -> Array[Dictionary]:
	_ensure_loaded()
	# Copy out, so a panel holding a row cannot mutate the cache behind your back.
	var out: Array[Dictionary] = []
	for entry in _cache:
		out.append(entry.duplicate(true))
	return out


func create_profile(payload: Dictionary) -> Dictionary:
	_ensure_loaded()
	var profile_name := String(payload.get("name", "")).strip_edges()
	# Return {} to REFUSE. The creation flow shows its generic refusal message and stays open.
	if profile_name.is_empty() or not is_name_available(profile_name):
		return {}

	var entry := payload.duplicate(true)
	entry["name"] = profile_name        # store the trimmed name you checked against
	entry["id"] = _mint_id()
	_cache.append(entry)
	_write()
	roster_changed.emit()
	return entry.duplicate(true)


func delete_profile(id: String) -> bool:
	_ensure_loaded()
	for i in _cache.size():
		if String(_cache[i].get("id", "")) == id:
			_cache.remove_at(i)
			_write()
			roster_changed.emit()
			return true
	return false     # an absent id is a normal query result, not a misconfiguration


func load_profile(id: String) -> Dictionary:
	_ensure_loaded()
	for entry in _cache:
		if String(entry.get("id", "")) == id:
			return entry.duplicate(true)
	return {}


## Optional. Override when you have a real name index; the base scans list_profiles().
func is_name_available(profile_name: String) -> bool:
	_ensure_loaded()
	for entry in _cache:
		if String(entry.get("name", "")).nocasecmp_to(profile_name) == 0:
			return false
	return true


## Optional but recommended: MKRoot.dump_diagnostics() prints this, and "saves don't persist" is
## usually a question about WHICH file was written.
func get_file_path() -> String:
	return _service_path + "roster.json"


# The three private helpers are yours to shape; stubs so this excerpt parses if pasted:
func _mint_id() -> String:
	return str(Time.get_unix_time_from_system())

func _ensure_loaded() -> void:
	pass  # read _service_path + "roster.json" into _cache once

func _write() -> void:
	pass  # serialize _cache back to disk
```

Wire it by pointing the slot at the script:

```
MKConfig.profile_backend.backend_script = res://game/backends/my_profile_backend.gd
MKConfig.profile_backend.params         = { "save_dir": "user://saves/" }
```

Nothing else. `MKCharacterSelect` and `MKCharacterCreate` find it by walking up the tree (§7).

### Refusal semantics

`create_profile` returning `{}` is a **refusal**, and the creation flow handles it as a state, not
an error: it closes both doors into confirm (Confirm and a last-step Skip) and shows a generic
message that names no cause. Any forward movement in the flow lifts the refusal. Design your
refusals accordingly — a taken name, a full roster, and a read-only store all look identical to the
UI, and that is deliberate.

### If you extend `MKJsonProfileBackend` instead

Subclassing the shipped JSON backend rather than the abstract base inherits behaviours you must
know about, because they are **format and data behaviours**, not implementation detail:

- **Trimmed names.** `create_profile` stores `name` stripped of surrounding whitespace — the value
  the uniqueness rule was checked against. Storing the raw payload would make the rule bypassable
  by whitespace ("  Alice  " and "Alice" would both persist and render identically).
- **The newer-store read-only latch.** A store file written by a **newer** MenuKit is left exactly
  where it is, byte-identical, and the backend latches read-only against it: `create_profile`
  returns `{}` and `delete_profile` returns `false`, with one warning naming the version. A settings
  value is an annoyance to lose; a roster is not. The latch follows the **file** — replace it and
  writes resume.
- **Corruption policy.** An unparseable or wrong-shaped store is renamed aside to
  `<name>.corrupt-<n>.json` and defaults boot with one warning. Nothing is ever deleted.
- **Reserved keys.** `id` is minted by the backend (`p_000001`, monotonic, never reissued after a
  delete); a payload carrying it is warned about and the backend's value wins.
- **The `__mk_type` discriminator.** A payload may not itself spell `__mk_type` at any depth;
  `create_profile` refuses such a payload with a warning naming the path, because accepting it would
  write a file whose load quarantines the whole roster.
- Params: `file_path` (String) and `max_profiles` (int, 0 = unlimited).

Full format details: [SETTINGS_SCHEMA.md](SETTINGS_SCHEMA.md) § Persisted formats.

---

## 5. The pause contract

The in-game shape is a second `MKRoot` parked **hidden and LAST** in your game scene, with
`host_content_process_mode = PROCESS_MODE_ALWAYS` and `show_backdrop = false`.

Why those two:

- **`host_content_process_mode = ALWAYS` on a pause-hosting shell.** Page content is PAUSABLE by
  default so a host page does not keep animating during pause and behave differently there than
  in-game. But a PAUSABLE control reports `can_process()` false, and Godot does not dispatch GUI
  input to it — under a tree pause policy the Resume button would be dead.
- **`show_backdrop = false`.** The backdrop is main-menu scenery. An opaque backdrop over a pause
  shell hides the very world the pause menu sits on; the paused game behind the panel is what tells
  the player this is a pause and not a scene change.

The `MKRoot` subtree itself always runs `PROCESS_MODE_ALWAYS` unconditionally — backends, the revert
countdown, the modal layer and tweens are all Nodes and would otherwise freeze under
`SceneTree.paused`. Your game scene runs PAUSABLE; that asymmetry is what makes the tree pause
policy observable.

### The host's ESC flow — the whole of it

```gdscript
extends Node3D

@onready var _menu: MKRoot = $MKRoot


func _ready() -> void:
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # exactly once, at boot, and never again
	_menu.visible = false
	_menu.pause_menu_toggled.connect(_on_pause_menu_toggled)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _menu.is_pause_menu_open():
		return                       # closing is MKRoot's job — it consumes ui_cancel first
	# Visible BEFORE open. See below.
	_menu.visible = true
	if not _menu.open_pause_menu():
		_menu.visible = false        # a refused open touched nothing else
	get_viewport().set_input_as_handled()


func _on_pause_menu_toggled(open: bool) -> void:
	_menu.visible = open
	# Gate your camera and movement here.
```

If it is longer than that, MenuKit failed to own the atomicity it claims. Five rules make it work:

1. **Show the shell BEFORE calling `open_pause_menu()`.** `_show_page` defers focusing the page, and
   focus collection skips controls failing `is_visible_in_tree()` — opening while hidden focuses
   nothing and the menu is dead to a gamepad.
2. **A refused `open_pause_menu()` touched nothing.** The pre-check (page def null, or its scene
   null) runs before any suspension, so the only thing to undo is the visibility you just set.
   Without the undo, a config with no `pause` page leaves an opaque shell over the world with no way
   back.
3. **Hiding the shell IS closing the pause menu.** `visible = open` on a parked shell is the
   documented gesture, and MenuKit closes an open pause menu when the shell becomes
   not-visible-in-tree (ancestor hides included). Without it, hiding directly — a cutscene, a death
   screen, your own menu key — would strand the whole suspension: world paused, cursor free, counter
   at one, and no visible surface to unwind it from.
4. **Gating the camera and movement is the HOST's job.** MenuKit frees the cursor whenever a surface
   is up, *including* under `MKNoPausePolicy` where the world keeps running — so relative mouse
   motion keeps arriving and polled WASD does not care that a Button has focus. `pause_menu_toggled`
   is the signal to gate on; under a no-pause policy, ignoring it means mouselook spins behind the
   menu.
5. **Write `Input.mouse_mode` exactly once, at boot, and never again.** Mouse mode is depth-counted
   inside `MKRoot` (a modal over the pause menu must not restore capture on dismiss), and a host
   that also wrote it would fight the counter. If you want to own cursor state entirely, set
   `MKConfig.manage_mouse_mode = false` — then MenuKit never touches it and all of it is yours.

Any `ui_cancel` handling in your game scene is unreachable in the shipped configuration (the visible
shell is the last child and consumes it first; under a tree pause you receive no input at all). It
exists for a host that reorders its children or swaps in `MKNoPausePolicy`.

### The ESC / cancel precedence ladder

`MKRoot` resolves a cancel gesture in this order:

1. **rebind capture** (a listening row consumes in `_input` — which is what makes Escape unbindable
   without a blacklist),
2. **modal stack top**,
3. **page back stack**,
4. **pause rung**,
5. **root quit-confirm**.

The pause rung is **page-aware**: it resumes only when the shell is showing the page
`open_pause_menu()` opened, and otherwise navigates back to that page. A programmatic `go_to_page()`
while the pause menu is open is not refused, but the ladder treats it as a divergence and navigates
back to the recorded pause page.

### Pause policies

`MKPausePolicy` is the seam. Two ship:

- **`MKTreePausePolicy`** — sets `SceneTree.paused`. The single-player default.
- **`MKNoPausePolicy`** — the multiplayer answer: `can_pause()` returns false, the menu opens, and
  the world keeps running. `can_pause() == false` is **never a veto on opening the menu** — the menu
  opens, `enter_menu` is simply skipped.

`MKRoot` owns a single suspend counter and calls `enter_menu` only on the 0→1 edge and `exit_menu`
only on the 1→0 edge, so a custom policy inherits correct depth counting for free and must not count
depth itself. **Whatever a policy changes on engage it must undo in its own `_exit_tree()`**, never
expecting `MKRoot` to: `NOTIFICATION_EXIT_TREE` propagates children first, so by the time
`MKRoot._exit_tree()` runs, the policy is already out of the tree and its `get_tree()` is null.

### Quit to Menu — the one-frame resume

`MKPauseMenu` closes the pause state **before** calling `MKMenuBackend.to_main_menu()`. That order is
mandatory for a custom backend that swaps no scene (it would otherwise inherit a paused main menu
with no nav bar), and it has one visible consequence under the shipped deferred scene change: **the
world simulates for the remainder of the quit frame.** One frame, by construction.

---

## 6. Modals and dialogs

`MKRoot.get_modal_layer()` returns the shell's `MKModalLayer`. The ownership rules matter:

- `pop_modal()` / `remove_modal()` **return ownership** to whoever pushed, so a cached dialog can be
  reused.
- `reap_modal()` **DESTROYS** what it is handed. It exists only for resolved corpses whose owner is
  already dead. **If you reuse a cached dialog, never route it through `reap_modal`.**
- `reap_modal` must always be called deferred: `layer.call_deferred(&"reap_modal", dialog)`. The
  deferral is the mechanism that distinguishes "the shell was destroyed with the dialog still
  stacked" from "only the owner died".
- **Never reach around the layer.** Reparenting and freeing a stacked modal directly leaves the
  entry in the stack: `is_empty()` reports false forever, the scrim stays up over nothing, and
  `MKRoot` swallows every cancel gesture from then on.

A modal may implement two optional methods: `handle_cancel() -> bool` (return `true` to keep the
cancel gesture and stay open — a listening rebind row, a wizard step going back) and
`_mk_layer_teardown()` (called during `clear_for_teardown()`, so a modal that would normally free
itself on `modal_popped` can dispose of itself; teardown does not emit that signal).

For the generic 2–3 button dialog, see `MKConfirmDialog.open()` in [API.md](API.md).

---

## 7. How panels find your backends

`MKPauseMenu`, `MKCharacterSelect`, `MKCharacterCreate` and `MKServerBrowser` locate shell services
by a **duck-typed walk up the tree**, never a typed `MKRoot` reference. The names they call:

`push_page`, `pop_page`, `close_pause_menu`, `get_modal_layer`, `get_profile_backend`,
`get_menu_backend`, `get_network_backend`, and the `config` property.

So you may wrap the shell, or embed a panel under your own controller that forwards those calls. The
backend walks continue **past** an ancestor that answers the method but returns null.

**A null backend is never an error in a shipped panel.** Every one renders with its actions disabled
and warns once — for the page, not per row — rather than refusing to build. `MKServerBrowser` is the
deliberate exception: it does not warn at boot at all (an unassigned network slot is the shipped
default) and leaves its actions enabled, so the first press is what names the missing slot.

---

## 8. Diagnostics

`MKRoot.dump_diagnostics() -> String` is the bug-report surface: version, active backend scripts,
the resolved `user://` store path of any backend exposing `get_file_path()`, page/step/archetype
counts, and current setting values. One call to paste into a bug report.

The store path is in there deliberately — "settings don't persist" is usually a question about
*which file* was written. The creation-flow counts are there because an empty archetype step and a
step whose defs were dropped look identical from a screenshot.

Verbose logging: `MKConfig.verbose`, or the `--mk-verbose` command-line switch (which forces it on
regardless). Every misconfiguration message names the offending resource path **and** field.

---

## 9. Limitations and unsupported gestures

Each of these is a known, documented property, not a bug to report:

- **Reparenting a LIVE shell is unsupported.** A reparent runs `_exit_tree()` on an instance that
  then survives it, so pause and nav state is discarded with no `pause_menu_toggled(false)` and you
  are never told. Close the pause menu first.
- **Assigning `MKRoot.config` at runtime does nothing.** It re-runs no validation, rebuilds no nav
  and restyles nothing. Swapping `MKConfig.palette` **is** supported — that goes through
  `Resource.changed`.
- **Two simultaneous service-less shells stack two gamma passes** (§2, Tier B).
- **The adopt path ignores a slot's `params`** (§2, Tier A).
- **Save-on-exit loses a crashed session's writes.** Call `save()` yourself where it matters.
- **Quit to Menu runs the world for the remainder of that frame** (§5).
- **The `MKInputGlyphs` dispatch guarantee is owner-subtree-relative.** The device tracker must be
  the LAST sibling among its owner's children to see events a rebind row consumes. An
  `_input`-consuming node you mount *after* the shell at ancestor level dispatches first and can
  blind the tracker; no shipped node does this (the only `_input` consumers are the rebind row and
  the tracker; `MKRoot` and the demo consume in `_unhandled_input`). If you install a global `_input`
  handler, respect that ordering.
- **Pad button labels are SDL positions, not the legend on the player's pad.** On Godot 4.7 there is
  no runtime API to do better, so a DualShock shows "B" for Circle.
- **Editor-side behaviour (plugin enable/disable cycle, the theme bake) is unverified by the
  automated suite** — it needs an interactive editor session.

---

## Where to go next

| Doc | For |
|---|---|
| [API.md](API.md) | Every public class, signature, and signal |
| [THEMING.md](THEMING.md) | Palette → Theme, type variations, re-skinning |
| [SETTINGS_SCHEMA.md](SETTINGS_SCHEMA.md) | Authoring settings pages and rows; persisted formats |
| [CREATION_STEPS.md](CREATION_STEPS.md) | Character creation steps and point-buy |
| [DECISIONS.md](DECISIONS.md) | The D-id glossary used in code comments |
