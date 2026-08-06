@tool
class_name MKRoot
extends Control
## The MenuKit shell: page state machine, back stack, backend ownership, and the two contracts an
## FPS host hits on day one — process mode and mouse capture (plan §4.2, §4.2a, §4.7a).
##
## [b]Per-scene instance, not a persistent singleton.[/b] Counters are per-instance and reset
## naturally on a scene change, which is only safe because of the teardown rule in
## [method _exit_tree].
##
## [b]The whole subtree runs [constant Node.PROCESS_MODE_ALWAYS].[/b] Backends, the revert
## countdown, the modal layer, tweens and the audio player are all Nodes and would otherwise freeze
## under [member SceneTree.paused] — the D14 confirm-or-revert dialog would hang forever with no
## failing write to reveal it. This is unconditional and must never become policy-dependent: it
## costs nothing under a no-pause policy and it is what keeps the countdown alive.
## Host-supplied content is forced back to [constant Node.PROCESS_MODE_PAUSABLE] on add, so a
## host's preview scene does not keep animating during pause and behave differently there than
## in-game.

## Emitted after a page change completes, for hosts driving their own state off navigation.
signal page_changed(id: StringName)

## Emitted when the pause menu opens/closes, so a host can gate its own camera input. Under a
## no-pause policy the world keeps running while the cursor is freed, and mouselook will keep
## consuming relative motion unless the host acts on this.
signal pause_menu_toggled(open: bool)

const CONFIG_PATH_SETTING := "menu_kit/config_path"
const DEFAULT_CONFIG_PATH := "res://addons/menu_kit/default_config.tres"
const SETTINGS_SERVICE_PATH := "/root/MKSettingsService"

## Assigned in the scene, or resolved from the [code]menu_kit/config_path[/code] project setting when
## left null — the same key the settings-service autoload reads, so a host that repoints one
## repoints both.
@export var config: MKConfig

## Process mode applied to instantiated page content.
##
## [constant Node.PROCESS_MODE_PAUSABLE] is the right default: a host's page should not keep
## animating during pause and behave differently there than in-game. The pause menu's own page is
## the exception — a PAUSABLE control reports [method Node.can_process] false, and Godot does not
## dispatch GUI input to it, so under a tree pause policy its Resume button would be dead. An
## [MKRoot] hosting the pause page sets this to [constant Node.PROCESS_MODE_ALWAYS].
@export var host_content_process_mode: Node.ProcessMode = Node.PROCESS_MODE_PAUSABLE

@export_group("Audio hooks")
## Optional; no audio files ship (licensing). All four play through one internal player.
@export var hover_sfx: AudioStream
@export var click_sfx: AudioStream
@export var back_sfx: AudioStream
@export var error_sfx: AudioStream

var _nav_bar: MKNavBar
var _page_host: Control
var _backdrop: MKBackdrop
var _modal_layer: MKModalLayer
var _sfx_player: AudioStreamPlayer

var _menu_backend: MKMenuBackend
var _profile_backend: MKProfileBackend
var _settings_backend: MKSettingsBackend
var _network_backend: MKNetworkBackend
var _pause_policy: MKPausePolicy
## True when the settings backend came from the autoload rather than this node, so teardown does not
## free something it does not own.
var _adopted_settings := false
## Non-null only in the standalone no-service configuration. See [method _boot_own_brightness].
var _brightness_controller: MKBrightnessController

var _page_id: StringName = &""
var _back_stack: Array[StringName] = []
var _current_page_node: Node
## The palette currently wired to [method _apply_theme], so a swap can unsubscribe the old one.
var _themed_palette: MKPalette

## Counts MenuKit surfaces that require the world suspended and the cursor free. One counter, owned
## here: policies carry no depth state, so every custom policy inherits correct counting for free.
var _suspend_depth := 0
## How many of the current suspensions came from modals. See [method _on_modal_pushed].
var _modal_suspensions := 0
var _saved_mouse_mode := Input.MOUSE_MODE_VISIBLE
## Whether the policy's [code]enter_menu[/code] actually ran, so its [code]exit_menu[/code] is paired
## with that call rather than with a re-query of [code]can_pause()[/code]. See [method _push_suspend].
var _policy_entered := false
var _pause_menu_open := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Engine.is_editor_hint():
		return
	_resolve_config()
	_apply_theme()
	_build_shell()
	_instantiate_backends()
	_populate_nav()
	_open_initial_page()


## Teardown, and the reason a quit-to-menu from a paused game does not leave the next game frozen.
##
## Two things this deliberately does NOT do:
## [br]- It never calls [method MKPausePolicy.exit_menu]. [constant Node.NOTIFICATION_EXIT_TREE]
##   propagates children first, so the policy is already out of the tree here and its
##   [method Node.get_tree] is null — the cross-node call would crash the shipped default on every
##   quit-while-paused. Each policy undoes its own effects in its own [method Node._exit_tree].
## [br]- It never restores the [i]saved[/i] mouse mode. That value was captured from gameplay, so
##   restoring it here would re-capture the cursor on the main menu. Teardown discards; only a
##   normal close restores.
func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var was_suspended := _suspend_depth > 0
	# DISCARD the stack; do not pop it. A real pop here reaches _pop_suspend's 1→0 edge and calls
	# exit_menu on a policy that is already out of the tree — the crash this function's contract
	# exists to prevent — and restores the gameplay cursor onto the main menu. An earlier revision
	# popped here and did both.
	if _modal_layer != null and is_instance_valid(_modal_layer):
		_modal_layer.clear_for_teardown()
	_suspend_depth = 0
	_modal_suspensions = 0
	_policy_entered = false
	_pause_menu_open = false
	# Only touch the cursor if we were actually holding it, and set it VISIBLE rather than restoring
	# the saved value: that value was captured from gameplay, so restoring it would re-capture the
	# cursor on the main menu.
	if was_suspended and config != null and config.manage_mouse_mode:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Cancel is consumed by the innermost open thing. Precedence is
## rebind capture → modal stack top → page back stack → root quit-confirm.
##
## Rebind capture does not appear here by name because it is handled by mechanism: a listening row
## consumes input in [method Node._input] and calls
## [method Viewport.set_input_as_handled], so a live capture never reaches
## [method Node._unhandled_input] at all. That is what makes Escape unbindable without a blacklist,
## and what stops one Escape from both aborting a capture and popping the Controls page.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _modal_layer != null and not _modal_layer.is_empty():
		if _modal_layer.handle_cancel():
			get_viewport().set_input_as_handled()
		else:
			_modal_layer.pop_modal()
			get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	if not _back_stack.is_empty():
		pop_page()
		return
	request_quit_confirm()


# --- Navigation ---------------------------------------------------------------

## Lateral move: clears the back stack, the way a tab press should. Sub-panels use
## [method push_page] instead.
func go_to_page(id: StringName) -> void:
	_back_stack.clear()
	_show_page(id)


## Enters a sub-panel, remembering where to return. Modals are popped by [method _show_page], which
## every navigation route funnels through — duplicating the call here would just be a second place to
## keep in sync.
func push_page(id: StringName) -> void:
	var previous := _page_id
	if not previous.is_empty():
		_back_stack.push_back(previous)
	if not _show_page(id) and not previous.is_empty():
		# Do not leave a return address for a page we never left.
		_back_stack.pop_back()


## Returns whether anything was popped, so callers can distinguish "went back" from "already at the
## root" without inspecting the stack.
func pop_page() -> bool:
	if _back_stack.is_empty():
		return false
	_play(back_sfx)
	_show_page(_back_stack.pop_back())
	return true


func get_page_id() -> StringName:
	return _page_id


func get_back_depth() -> int:
	return _back_stack.size()


## Cancel at the root. A quit gesture with nothing to go back to should ask rather than fall through
## to nothing, which is what the source menu did.
func request_quit_confirm() -> void:
	if _modal_layer == null:
		return
	var dialog := MKConfirmDialog.open(_modal_layer, "Quit", "Quit to desktop?", "Quit", "Cancel",
		true)
	if dialog == null:
		return
	dialog.confirmed.connect(func() -> void:
		if _menu_backend != null:
			_menu_backend.quit()
		else:
			MKLog.warn("quit requested but no menu_backend is assigned")
			get_tree().quit()
	)


## Returns whether the page actually changed. Callers that took an action conditional on navigation
## succeeding — [method open_pause_menu] raises a suspension first — need to unwind when it did not.
func _show_page(id: StringName) -> bool:
	if config == null:
		return false
	# Every page change pops the modal stack — INCLUDING one that fails on a bad id. This lives here
	# rather than in push_page because go_to_page is the path nav tabs and open_pause_menu take:
	# leaving it out stranded a modal above the new page AND stranded its suspend count, since the
	# modal that owned the count was no longer reachable to dismiss. Under a tree pause policy that is
	# a permanently paused world. Popping before the id check keeps the two routes identical on a bad
	# id rather than leaving one of them holding a stranded modal.
	if _modal_layer != null:
		_modal_layer.pop_all()
	var def := config.get_page(id)
	if def == null:
		MKLog.warn("page '%s' is not in %s — navigation refused"
			% [id, MKLog.context(config, "pages")])
		return false
	if _current_page_node != null:
		# remove_child before queue_free: a queued node stays in the tree until end of frame, so the
		# old and new pages would both draw for a frame and both answer focus queries.
		_page_host.remove_child(_current_page_node)
		_current_page_node.queue_free()
		_current_page_node = null
	if def.scene == null:
		MKLog.warn("%s: page '%s' has no scene — the page host will be empty"
			% [MKLog.context(def, "scene"), id])
	else:
		var inst := def.scene.instantiate()
		# Host-supplied content must not keep animating under pause and behave differently there than
		# in-game (plan §4.2a). The pause menu's own page is the exception a host must be able to
		# make: a PAUSABLE control has can_process() false, and Godot does not dispatch GUI input to
		# it, so under a tree pause policy its Resume button would not respond.
		inst.process_mode = host_content_process_mode
		_page_host.add_child(inst)
		if inst is Control:
			var c := inst as Control
			c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_current_page_node = inst
	_page_id = id
	if _nav_bar != null:
		_nav_bar.set_active(id)
	# Focus something on every page change, or the shell is a gamepad dead end: gate 4 requires the
	# whole demo be completable with a gamepad alone, and a page that focuses nothing has no entry
	# point. Deferred so the new page's own _ready has run and its controls exist. Falls back to the
	# nav bar when a page has no focusable content of its own.
	_focus_page_content.call_deferred()
	page_changed.emit(id)
	return true


func _focus_page_content() -> void:
	if _current_page_node != null and is_instance_valid(_current_page_node):
		if MKFocus.focus_first(_current_page_node) != null:
			return
	if _nav_bar != null and is_instance_valid(_nav_bar):
		_nav_bar.focus_active()


# --- Pause and mouse capture --------------------------------------------------

## The single entry point for the pause gesture: policy, mouse mode, and page state change together
## in a fixed order, in one place. The host forwards the ESC/Start gesture and nothing more.
## Returns whether the pause menu opened. It refuses — and unwinds its own suspension — when the
## named page does not exist: suspending the world and freeing the cursor to display nothing is
## strictly worse than not pausing, and the bare call defaults to a page id no shipped config defines
## yet.
func open_pause_menu(page_id: StringName = &"pause") -> bool:
	if _pause_menu_open:
		return false
	_pause_menu_open = true
	_push_suspend(&"pause")
	if not _show_page(page_id):
		_pause_menu_open = false
		_pop_suspend(&"pause")
		return false
	_back_stack.clear()
	pause_menu_toggled.emit(true)
	return true


func close_pause_menu() -> void:
	if not _pause_menu_open:
		return
	_pause_menu_open = false
	if _modal_layer != null:
		_modal_layer.pop_all()
	_pop_suspend(&"pause")
	pause_menu_toggled.emit(false)


func is_pause_menu_open() -> bool:
	return _pause_menu_open


func get_suspend_depth() -> int:
	return _suspend_depth


## Raises the suspension count, and on the 0→1 edge only, tells the policy and frees the cursor.
##
## Modals do not call this directly — see [method _on_modal_pushed] for the rule that governs them.
func _push_suspend(reason: StringName) -> void:
	_suspend_depth += 1
	if _suspend_depth != 1:
		return
	# Latch whether enter_menu actually ran. _pop_suspend must NOT re-ask can_pause(): a policy whose
	# answer changes while a menu is open — the stated multiplayer story, where a session can start
	# mid-menu — would skip its own exit_menu and leave the world paused with no menu on screen and no
	# diagnostic. exit_menu is the counterpart of an enter that happened, not of a condition that
	# still holds.
	if _pause_policy != null and _pause_policy.can_pause():
		# Latched before the call as a matter of ordering hygiene — the flag means "enter_menu was
		# invoked", and setting it after would briefly disagree with that. (It is not load-bearing
		# against a policy erroring mid-call: a GDScript runtime error aborts only the innermost
		# function, so the assignment would run either way.)
		_policy_entered = true
		_pause_policy.enter_menu(reason)
	elif _pause_policy != null:
		# can_pause() false means the menu still opens and the world keeps running. It is never a
		# veto: a menu you cannot open is not the right answer to "the world cannot pause".
		MKLog.debug("pause policy declined to suspend (reason '%s')" % reason)
	if config != null and config.manage_mouse_mode:
		_saved_mouse_mode = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _pop_suspend(reason: StringName) -> void:
	if _suspend_depth == 0:
		return
	_suspend_depth -= 1
	if _suspend_depth != 0:
		return
	if _policy_entered and _pause_policy != null:
		_pause_policy.exit_menu(reason)
	_policy_entered = false
	if config != null and config.manage_mouse_mode:
		Input.mouse_mode = _saved_mouse_mode


# --- Modals -------------------------------------------------------------------

func get_modal_layer() -> MKModalLayer:
	return _modal_layer


# --- Backends -----------------------------------------------------------------

func get_menu_backend() -> MKMenuBackend:
	return _menu_backend


func get_profile_backend() -> MKProfileBackend:
	return _profile_backend


func get_settings_backend() -> MKSettingsBackend:
	return _settings_backend


## This scene's own brightness controller, or null — null is the [b]normal[/b] result when the
## settings service owns one (plan §4.3). Ask the service first when you need "the live controller".
func get_brightness_controller() -> MKBrightnessController:
	return _brightness_controller


func get_network_backend() -> MKNetworkBackend:
	return _network_backend


func get_pause_policy() -> MKPausePolicy:
	return _pause_policy


## One call to paste into a bug report (plan §4.8).
func dump_diagnostics() -> String:
	var lines := PackedStringArray()
	lines.append(MKVersion.version_string())
	lines.append("config: %s" % MKLog.context(config))
	lines.append("page: %s  back_stack: %s" % [_page_id, _back_stack])
	lines.append("suspend_depth: %d  pause_menu_open: %s  mouse_mode: %d"
		% [_suspend_depth, _pause_menu_open, Input.mouse_mode])
	lines.append("modal_depth: %d" % (_modal_layer.depth() if _modal_layer != null else -1))
	for pair in [
		["menu", _menu_backend], ["profile", _profile_backend],
		["settings", _settings_backend], ["network", _network_backend],
		["pause_policy", _pause_policy],
	]:
		var node: Node = pair[1]
		var desc := "<none>"
		if node != null:
			var s := node.get_script() as Script
			desc = s.resource_path if s != null else node.get_class()
			# §4.8 requires the dump to carry resolved user:// paths, and ship gate 9 checks for them:
			# "settings don't persist" is usually a question about WHICH file was written, and without
			# this the answer costs a round trip with the reporter.
			if node.has_method("get_file_path"):
				desc += "  store: %s" % node.call("get_file_path")
		lines.append("backend %s: %s" % [pair[0], desc])
	lines.append("settings backend adopted from autoload: %s" % _adopted_settings)
	if config != null:
		lines.append("pages: %d visible of %d" % [config.get_visible_pages().size(), config.pages.size()])
	return "\n".join(lines)


# --- Boot ---------------------------------------------------------------------

func _resolve_config() -> void:
	if config == null:
		var path := DEFAULT_CONFIG_PATH
		if ProjectSettings.has_setting(CONFIG_PATH_SETTING):
			path = String(ProjectSettings.get_setting(CONFIG_PATH_SETTING))
		config = ResourceLoader.load(path) as MKConfig
		if config == null:
			MKLog.error("no MKConfig assigned and none loadable from '%s' — the shell will boot empty"
				% path)
			return
	MKLog.verbose = MKLog.verbose or config.verbose
	# Regenerate when the config swaps its palette. _apply_theme subscribes to the palette itself for
	# per-field edits, but nothing re-invoked it when config.palette was REASSIGNED — so the disconnect
	# logic there guarded a state it could never reach, and swapping a palette was a no-op at runtime.
	# No unsubscribe-the-old-config branch here: _resolve_config runs once, from _ready, so there is
	# no second entry point at which a previous config could exist. Assigning `config` at runtime is
	# NOT a supported gesture — it re-runs nothing, rebuilds no nav, and restyles nothing. The
	# palette-level equivalent below is different precisely because the `changed` signal gives it a
	# second entry point.
	if not config.changed.is_connected(_apply_theme):
		config.changed.connect(_apply_theme)
	# Report every problem at once: a first-time integrator gets one list to work through instead of
	# a fix-run-fix loop.
	for problem in config.validate():
		MKLog.error(problem)


func _apply_theme() -> void:
	# Unsubscribe FIRST, before any early return. Behind the null-palette check, setting
	# config.palette = null left the discarded palette wired to this root, so every later edit to it
	# re-entered here and emitted another "no MKPalette assigned" warning.
	var next_palette: MKPalette = config.palette if config != null else null
	if _themed_palette != null and is_instance_valid(_themed_palette) \
			and _themed_palette != next_palette \
			and _themed_palette.changed.is_connected(_apply_theme):
		_themed_palette.changed.disconnect(_apply_theme)
	_themed_palette = next_palette
	if next_palette == null:
		MKLog.warn("no MKPalette assigned — panels will fall back to the engine default theme")
		return
	# Rebuild whenever the palette changes. Without this subscription every per-field emit_changed()
	# in MKPalette has no listener, and editing a palette at runtime restyles nothing — the shipped
	# Theme is a one-shot snapshot taken at boot. Re-skinning is the package's core promise, so the
	# live path has to work, not just the editor bake.
	if not next_palette.changed.is_connected(_apply_theme):
		next_palette.changed.connect(_apply_theme)
	var generated := MKThemeGenerator.build(next_palette)
	if generated == null:
		return
	if not MKTheme.theme_defines_all(generated):
		MKLog.error("%s: generated Theme is missing type variations — panels using them render unstyled"
			% MKLog.context(next_palette))
	theme = generated


func _build_shell() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_backdrop = MKBackdrop.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	if config != null and config.backdrop_catalog != null:
		_backdrop.apply_from_catalog(config.backdrop_catalog, config.backdrop_id)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(column)

	_nav_bar = MKNavBar.new()
	_nav_bar.name = "NavBar"
	_nav_bar.page_selected.connect(_on_nav_page_selected)
	column.add_child(_nav_bar)

	_page_host = Control.new()
	_page_host.name = "PageHost"
	_page_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_page_host)

	# LOAD-BEARING ORDERING: the modal layer is a Control (not a CanvasLayer — see its class doc,
	# theming propagates down the Control tree only), so its draw order is sibling order. It must be
	# added AFTER the backdrop, the nav/page column, and any future shell child, or a modal renders
	# behind the page. Its z_index reinforces this; do not rely on one alone. Anything added below
	# here must be a non-drawing node (the audio player is).
	_modal_layer = MKModalLayer.new()
	_modal_layer.name = "ModalLayer"
	add_child(_modal_layer)
	_modal_layer.modal_pushed.connect(_on_modal_pushed)
	_modal_layer.modal_popped.connect(_on_modal_popped)

	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.name = "SfxPlayer"
	add_child(_sfx_player)

	# Belt and braces: the .tscn sets ALWAYS on the root and children inherit, but shell children are
	# built in code here and an inherited default is easy to lose in a later refactor.
	for child in _all_descendants(self):
		if child.process_mode == Node.PROCESS_MODE_INHERIT:
			continue
		child.process_mode = Node.PROCESS_MODE_ALWAYS


func _instantiate_backends() -> void:
	if config == null:
		return
	_menu_backend = _make_backend(config.menu_backend, MKMenuBackend, "menu_backend")
	_profile_backend = _make_backend(config.profile_backend, MKProfileBackend, "profile_backend")
	_network_backend = _make_backend(config.network_backend, MKNetworkBackend, "network_backend")
	_pause_policy = _make_backend(config.pause_policy, MKPausePolicy, "pause_policy")
	_settings_backend = _resolve_settings_backend()


## Adopt-or-instantiate (plan §4.2). Two settings-backend instances over one JSON file means the
## revert countdown snapshots one while the panel writes the other, and last-save silently wins — a
## bug that is near-impossible to diagnose from a bug report. So when the autoload exists it owns the
## instance and this node borrows it.
func _resolve_settings_backend() -> MKSettingsBackend:
	var service := get_node_or_null(SETTINGS_SERVICE_PATH)
	if service == null:
		return _boot_own_settings_backend()
	var live: MKSettingsBackend = null
	if service.has_method("get_settings_backend"):
		live = service.call("get_settings_backend")
	if live == null:
		# Debug, not warn: the service treats an unassigned settings slot as valid config and stays
		# deliberately inert, so warning here would give the same fact two verdicts and put a warning
		# in front of a host that configured nothing wrong.
		MKLog.debug("%s is present but inert — this scene builds and owns its own settings backend"
			% SETTINGS_SERVICE_PATH)
		return _boot_own_settings_backend()
	_adopted_settings = true
	# The service lives outside this subtree, so it does not inherit the ALWAYS process mode — and the
	# D14 revert countdown runs on it. Left PAUSABLE, that countdown freezes under a tree pause policy
	# and the confirm-or-revert dialog hangs forever with no failing write to reveal it.
	live.process_mode = Node.PROCESS_MODE_ALWAYS
	# A scene naming a different script than the service already built is a misconfiguration, not a
	# reason to double-instantiate. Keep the service's instance and say so, naming both scripts.
	var slot := config.settings_backend
	if slot != null and slot.is_assigned():
		var live_script := live.get_script() as Script
		if live_script != null and live_script != slot.backend_script:
			MKLog.error("settings backend mismatch: %s built '%s' but %s names '%s'. Keeping the service's instance."
				% [SETTINGS_SERVICE_PATH, live_script.resource_path,
					MKLog.context(config, "settings_backend"), slot.backend_script.resource_path])
	return live


## Builds this scene's own settings backend AND boots it.
##
## The three calls are what make a settings store mean anything, and in a service-less configuration
## nothing else makes them: [MKRoot] used to instantiate the backend and never load it, so a stored
## resolution was never read and a stored rebind was never applied. Every panel then reads an empty
## store, and the symptom — "my settings don't stick" — looks like a bug in whatever panel the user
## happened to be on.
##
## The order matches [code]MKSettingsService[/code] exactly and is load-bearing: the snapshot must
## precede the load, or the captured "defaults" are the user's own overrides and Reset to Defaults
## silently resets to them.
func _boot_own_settings_backend() -> MKSettingsBackend:
	var backend := _make_backend(config.settings_backend, MKSettingsBackend, "settings_backend") \
		as MKSettingsBackend
	if backend == null:
		return null
	backend.snapshot_input_defaults()
	backend.load()
	backend.apply_all()
	_boot_own_brightness(backend)
	return backend


## The standalone brightness tier (plan §4.3) — reached only from [method _boot_own_settings_backend],
## i.e. only when no settings service owns the store.
##
## [b]Be honest about this tier: it is closer to the floor than to the autoload behaviour.[/b] This
## controller is a child of a [b]per-scene[/b] [MKRoot], so it dies with the root: brightness gaps
## across every scene transition and reaches gameplay only if the game scene also hosts an [MKRoot].
## The [code]MKSettingsService[/code] autoload is the supported configuration for brightness, and
## [code]INTEGRATION.md[/code] says so. This exists so the no-autoload configuration is not a dead
## slider, not because it is equivalent.
##
## [b]Two controllers must never coexist[/b] — each applies its own gamma pass and the image would be
## corrected twice. The adopt path never reaches this method, and the belt-and-braces check below
## also covers the case where a service exists but is inert (unassigned settings slot) while still
## owning a controller of its own.
func _boot_own_brightness(backend: MKSettingsBackend) -> void:
	if config == null or not config.manage_brightness:
		return
	var service := get_node_or_null(SETTINGS_SERVICE_PATH)
	if service != null and service.has_method("get_brightness_controller") \
			and service.call("get_brightness_controller") != null:
		return
	_brightness_controller = MKBrightnessController.new()
	_brightness_controller.name = "BrightnessController"
	add_child(_brightness_controller)
	_brightness_controller.set_brightness(
		float(backend.get_value(MKBrightnessController.SETTING_ID, 1.0)))
	backend.setting_changed.connect(_on_brightness_setting_changed)


func _on_brightness_setting_changed(id: StringName, value: Variant) -> void:
	if id != MKBrightnessController.SETTING_ID:
		return
	if _brightness_controller == null or not is_instance_valid(_brightness_controller):
		return
	if not (value is float or value is int):
		# The store is JSON-backed, so a hand-edited file can hold a string here. Warn rather than
		# crash inside a signal handler at boot.
		MKLog.warn("%s: brightness value '%s' is not a number — ignoring"
			% [MKLog.context(config, "settings_backend"), value])
		return
	_brightness_controller.set_brightness(float(value))


## Instantiates a slot's script as a child Node, handing it its params first.
##
## [param params] reach the backend through [code]_mk_configure(params) -> Array[String][/code],
## which returns the keys it consumed. Only the backend knows its keys and only this node knows the
## slot's identity, so the leftover-key warning can be produced by neither alone — a silently ignored
## typo in a config dictionary is otherwise a bad afternoon.
func _make_backend(slot: MKBackendSlot, base: Script, field: String) -> Node:
	if slot == null or not slot.is_assigned():
		return null
	var reason := slot.validate_against(base)
	if not reason.is_empty():
		# A backend that does not extend its base is a contract violation, not a recoverable
		# misconfiguration — every later call against it would fail obscurely.
		MKLog.error("%s -> %s" % [MKLog.context(config, field), reason])
		return null
	var inst: Object = slot.backend_script.new()
	var node := inst as Node
	if node == null:
		MKLog.error("%s: backend script '%s' did not produce a Node"
			% [MKLog.context(config, field), slot.backend_script.resource_path])
		return null
	node.name = field
	node.process_mode = Node.PROCESS_MODE_ALWAYS
	if node.has_method("_mk_configure"):
		var consumed: Array = node.call("_mk_configure", slot.params)
		for key in slot.params.keys():
			if not consumed.has(String(key)):
				MKLog.warn("%s: nothing consumed param '%s' — check the spelling against %s"
					% [MKLog.context(slot, "params"), key, slot.backend_script.resource_path])
	elif not slot.params.is_empty():
		MKLog.warn("%s: params are set but '%s' implements no _mk_configure"
			% [MKLog.context(slot, "params"), slot.backend_script.resource_path])
	add_child(node)
	return node


func _populate_nav() -> void:
	if config == null or _nav_bar == null:
		return
	_nav_bar.set_pages(config.get_visible_pages())


func _open_initial_page() -> void:
	if config == null:
		return
	var target := config.initial_page
	if target.is_empty():
		var visible_pages := config.get_visible_pages()
		if visible_pages.is_empty():
			MKLog.warn("%s: no visible pages — the shell has nothing to show"
				% MKLog.context(config, "pages"))
			return
		target = visible_pages[0].id
	go_to_page(target)


func _on_nav_page_selected(id: StringName) -> void:
	_play(click_sfx)
	go_to_page(id)


## A modal suspends only when there is something to suspend [i]from[/i].
##
## Two contexts qualify, and getting the test wrong breaks one genre or the other:
## [br]- [b]Already suspended[/b] — over the pause menu a modal pushes 1→2, so dismissing it does not
##   restore mouse capture underneath a still-open menu.
## [br]- [b]The cursor is captured[/b] — a dialog raised over live gameplay that never went through
##   [method open_pause_menu] (connection lost, an in-game confirm). Depth is 0 there too, but a
##   Doom-like runs [constant Input.MOUSE_MODE_CAPTURED], so skipping the push would leave the dialog
##   literally unclickable. An earlier revision keyed purely on depth and did exactly that.
##
## What is excluded is the main menu: nothing is suspended and the cursor is already free, so a
## confirm dialog must not pause the tree — otherwise a [code]MKTreePausePolicy[/code] would freeze a
## host's animated menu background, and (page content being PAUSABLE) leave the page under the dialog
## input-dead.
##
## [member _modal_suspensions] records how many pushes actually counted, so the pops stay symmetric.
## Deriving it at pop time from the depth instead would double-decrement: by then the depth already
## reflects this modal's own contribution.
func _on_modal_pushed(_control: Control) -> void:
	if not _modal_should_suspend():
		return
	_modal_suspensions += 1
	_push_suspend(&"modal")


## [param mouse_mode] is a parameter purely so tests can drive the captured-cursor branch: under
## [code]--headless[/code] the dummy DisplayServer never leaves [constant Input.MOUSE_MODE_VISIBLE],
## so that branch is otherwise unreachable from the suite and the regression it guards had no test.
func _modal_should_suspend(mouse_mode: int = Input.mouse_mode) -> bool:
	if _suspend_depth > 0:
		return true
	# Deliberately NOT gated on config.manage_mouse_mode. That flag means "MenuKit does not write the
	# cursor", not "the world is not live" — a host with its own cursor manager still has a running
	# world behind an in-game dialog, and conflating the two put the pause policy back to sleep for
	# exactly the configuration an FPS studio is most likely to pick. The flag gates the mouse-mode
	# WRITE in _push_suspend/_pop_suspend, which is the only thing it should ever gate.
	return mouse_mode != Input.MOUSE_MODE_VISIBLE


func _on_modal_popped(_control: Control) -> void:
	if _modal_suspensions == 0:
		return
	_modal_suspensions -= 1
	_pop_suspend(&"modal")


func _play(stream: AudioStream) -> void:
	if stream == null or _sfx_player == null:
		return
	_sfx_player.stream = stream
	_sfx_player.play()


func _all_descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_descendants(child))
	return out
