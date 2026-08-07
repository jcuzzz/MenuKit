@tool
class_name MKRoot
extends Control
## The MenuKit shell: page state machine, back stack, backend ownership, and the two contracts an
## FPS host hits on day one — process mode and mouse capture.
##
## [b]Per-scene instance, not a persistent singleton.[/b] Counters are per-instance and reset
## naturally on a scene change, which is only safe because of the teardown rule in
## [method _exit_tree]. Reparenting a LIVE shell is not supported for the same reason: a reparent
## runs [method _exit_tree] on an instance that then survives it, so the pause and nav state is
## discarded by design and no [signal pause_menu_toggled] is emitted — a host that must move a shell
## closes the pause menu first.
##
## [b]The whole subtree runs [constant Node.PROCESS_MODE_ALWAYS].[/b] Backends, the revert countdown,
## the modal layer, tweens and the audio player are all Nodes and would otherwise freeze under
## [member SceneTree.paused] — the confirm-or-revert dialog would hang forever with no failing write
## to reveal it. This is unconditional and must never become policy-dependent: it costs nothing under
## a no-pause policy and it is what keeps the countdown alive.
## Host-supplied content is set to [member host_content_process_mode] on add — PAUSABLE by default,
## so a host's preview scene does not keep animating during pause and behave differently there than
## in-game; a pause-hosting shell exports it as ALWAYS (the export's doc has the why).

## Emitted after a page change completes, for hosts driving their own state off navigation.
signal page_changed(id: StringName)

## Emitted when the pause menu opens/closes, so a host can gate its own camera input. Under a
## no-pause policy the world keeps running while the cursor is freed, and mouselook will keep
## consuming relative motion unless the host acts on this.
signal pause_menu_toggled(open: bool)

const CONFIG_PATH_SETTING := "menu_kit/config_path"
const DEFAULT_CONFIG_PATH := "res://addons/menu_kit/default_config.tres"
## Aliased from [constant MKConfig.SETTINGS_SERVICE_PATH] rather than re-spelled — that constant
## documents what a rename costs when only some of the three resolvers follow it.
const SETTINGS_SERVICE_PATH := MKConfig.SETTINGS_SERVICE_PATH

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

## Whether this shell draws the config's backdrop behind its pages.
##
## The backdrop is main-menu scenery. The in-game pause configuration parks a second [MKRoot] inside
## the game scene, and an opaque backdrop there hides the very world the pause menu is supposed to
## sit on top of — the paused game behind the panel is what tells a player this is a pause and not a
## scene change. The backdrop node still exists when this is off (the shell layout does not fork); it
## just displays nothing, which [MKBackdrop] treats as a supported state rather than a missing
## texture.
@export var show_backdrop := true

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
## The page id [method open_pause_menu] navigated to, recorded so the Escape ladder's pause rung can
## tell "we are ON the pause page" from "the pause menu is open but the shell has been navigated
## somewhere else". Empty whenever [member _pause_menu_open] is false.
var _pause_page_id: StringName = &""
## The nav bar's visibility as [method open_pause_menu] found it, so [method close_pause_menu]
## RESTORES that value instead of writing true — a host is entitled to run its shell with no nav bar,
## and the pause gesture must not summon a strip it hid on purpose. Meaningless while
## [member _pause_menu_open] is false.
var _nav_visible_before_pause := true


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
##   propagates children first, so the policy is already out of the tree and its
##   [method Node.get_tree] is null. Each policy undoes its own effects in its own
##   [method Node._exit_tree].
## [br]- It never restores the [i]saved[/i] mouse mode. That value was captured from gameplay, so
##   restoring it here would re-capture the cursor on the main menu. Teardown discards; only a
##   normal close restores.
func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var was_suspended := _suspend_depth > 0
	# DISCARD the stack; do not pop it. A real pop here reaches _pop_suspend's 1->0 edge and calls
	# exit_menu on a policy that is already out of the tree — the crash this function's contract
	# exists to prevent — and restores the gameplay cursor onto the main menu.
	if _modal_layer != null and is_instance_valid(_modal_layer):
		_modal_layer.clear_for_teardown()
	_suspend_depth = 0
	_modal_suspensions = 0
	_policy_entered = false
	_pause_menu_open = false
	# Zeroed with the rest of the pause state. The nav bar needs no restore: this instance is on its
	# way out. That holds for the SUPPORTED lifecycle only — a free or a scene change. Under a
	# REPARENT the instance survives its own _exit_tree and all of this is discarded rather than
	# unwound; reparenting a live shell is unsupported (see the class doc).
	_pause_page_id = &""
	_nav_visible_before_pause = true
	# Persist the settings this scene OWNS, or a value written through a panel would live in memory
	# and in nothing else. This is one of the two owners (the other is MKSettingsService, which saves
	# the instance it built in its own _exit_tree); an ADOPTED backend is deliberately not saved here,
	# because MKRoot dies on every scene change while the service outlives them all.
	if not _adopted_settings and _settings_backend != null and is_instance_valid(_settings_backend):
		_settings_backend.save()
	# Only touch the cursor if we were actually holding it, and set it VISIBLE rather than restoring
	# the saved value: that value was captured from gameplay, so restoring it would re-capture the
	# cursor on the main menu.
	if was_suspended and config != null and config.manage_mouse_mode:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Hiding the shell IS closing the pause menu.
##
## The in-game gesture MenuKit documents is [code]visible = open[/code] on a shell parked inside the
## game scene. A host that hides it directly — a cutscene, a death screen, its own menu key — would
## otherwise strand the whole suspension: world paused, cursor free, counter at one, and no visible
## surface to unwind it from. Answering the hide with a close makes the host's own
## [code]visible = open[/code] handler safe in BOTH directions.
##
## Re-entry is not a hazard: a host hiding the shell in RESPONSE to a close arrives when
## [member _pause_menu_open] is already false, and an opening host sets [code]visible = true[/code]
## BEFORE [method open_pause_menu], so the notification arrives while the flag is still false. Both
## are no-ops.
##
## Teardown cannot reach this by accident: leaving the tree fires
## [constant Node.NOTIFICATION_EXIT_TREE] and NO visibility notification, even though
## [method CanvasItem.is_visible_in_tree] answers false afterwards. So a freed shell runs
## [method _exit_tree]'s discard-don't-pop contract and never this method's real close — which is
## what it must do, because by then the pause policy is already out of the tree.
func _notification(what: int) -> void:
	if what != NOTIFICATION_VISIBILITY_CHANGED:
		return
	if Engine.is_editor_hint():
		return
	if _pause_menu_open and not is_visible_in_tree():
		close_pause_menu()


## Cancel is consumed by the innermost open thing. Precedence is
## rebind capture -> modal stack top -> page back stack -> pause rung -> root quit-confirm.
##
## The pause rung is PAGE-AWARE, not merely flag-aware: it resumes only when the shell is actually
## showing the page [method open_pause_menu] opened. While the pause menu is open on some OTHER page
## with nothing on the back stack — reachable only programmatically — the rung navigates BACK to the
## pause page instead. Resuming there would hand the player a running game under a full-screen menu
## page, and falling through would answer ESC with "Quit to desktop?" over a paused world.
##
## Rebind capture does not appear here by name because it is handled by mechanism: a listening row
## consumes input in [method Node._input] and calls [method Viewport.set_input_as_handled], so a live
## capture never reaches [method Node._unhandled_input] at all. That is what makes Escape unbindable
## without a blacklist.
##
## [b]A shell that is not visible in the tree consumes nothing.[/b] A hidden shell still runs (the
## whole subtree is [constant Node.PROCESS_MODE_ALWAYS] and [method Node._unhandled_input] ignores
## visibility), so without the check below a shell parked hidden inside a game scene would swallow
## the very ESC gesture the host needs in order to open it.
func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _modal_layer != null and not _modal_layer.is_empty():
		# The return value is deliberately not branched on: under this guard it cannot be false.
		# MKModalLayer.handle_cancel returns false ONLY for an empty stack, which this guard has already
		# excluded. The self-heal for a stale entry lives in the layer, where it can tell the difference;
		# a RESOLVED MKRevertCountdown declines its own cancel and the layer, not this method, pops it.
		_modal_layer.handle_cancel()
		get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	if not _back_stack.is_empty():
		pop_page()
		return
	# The pause rung sits between the back stack and the quit-confirm, and the order is the contract:
	# with Settings pushed over the pause page the back stack is non-empty, so Escape returns to the
	# pause page (handled above) rather than resuming the game out from under the player. Only at the
	# pause page itself — both stacks empty — does Escape resume, the gesture symmetry a player expects
	# from the key that opened the menu.
	if _pause_menu_open:
		if _page_id == _pause_page_id:
			close_pause_menu()
		else:
			# Recovery, not resume — see the ladder doc above. _show_page, not go_to_page: the back
			# stack is already empty under this branch, so clearing it again would be theatre.
			if not _show_page(_pause_page_id):
				# The recovery TARGET is gone (the page def was removed, or the config swapped, while the
				# menu was open). Doing nothing would consume every later Escape with the world suspended
				# and no page offering a way out, so resume instead: a running game with a warning in the
				# log beats a frozen one with no exit.
				close_pause_menu()
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


## Cancel at the root. A quit gesture with nothing to go back to asks rather than falling through to
## nothing.
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


## Returns whether the page actually changed, so callers can react to a refused navigation —
## [method push_page] drops the return address it pushed for a page it never left, and
## [method open_pause_menu]'s ESC recovery closes the pause state when the pause page cannot be
## re-shown. No caller unwinds a SUSPENSION off this return: open_pause_menu's pre-check refuses
## before suspending.
func _show_page(id: StringName) -> bool:
	if config == null:
		return false
	# Every page change pops the modal stack — INCLUDING one that fails on a bad id. It lives here
	# because go_to_page is the path nav tabs and open_pause_menu take: otherwise a modal is stranded
	# above the new page along with its suspend count, and under a tree pause policy that is a
	# permanently paused world.
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
		# in-game. The pause menu's own page is the exception a host must be able to make: a PAUSABLE
		# control has can_process() false and Godot does not dispatch GUI input to it, so under a tree
		# pause policy its Resume button would not respond.
		inst.process_mode = host_content_process_mode
		_page_host.add_child(inst)
		if inst is Control:
			var c := inst as Control
			c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_current_page_node = inst
	_page_id = id
	if _nav_bar != null:
		_nav_bar.set_active(id)
	# Focus something on every page change, or the shell is a gamepad dead end. Deferred so the new
	# page's own _ready has run and its controls exist. Falls back to the nav bar when a page has no
	# focusable content of its own.
	_focus_page_content.call_deferred()
	page_changed.emit(id)
	return true


func _focus_page_content() -> void:
	if _current_page_node != null and is_instance_valid(_current_page_node):
		if MKFocus.focus_first(_current_page_node) != null:
			return
	# The visibility test is not decoration: open_pause_menu hides the bar, and handing focus to a tab
	# nobody can see is a worse dead end than no focus at all — the player's next input would activate
	# an invisible Start Game.
	#
	# is_visible_in_tree(), NOT the local `visible` flag: a shell parked hidden inside a game scene
	# still leaves _nav_bar.visible true. It is also the answer MKFocus uses when collecting
	# focusables, so the two agree by construction.
	if _nav_bar != null and is_instance_valid(_nav_bar) and _nav_bar.is_visible_in_tree():
		_nav_bar.focus_active()


# --- Pause and mouse capture --------------------------------------------------

## The single entry point for the pause gesture: policy, mouse mode, and page state change together
## in a fixed order, in one place. The host forwards the ESC/Start gesture and nothing more.
## Returns whether the pause menu opened.
##
## [b]It refuses BEFORE suspending anything when the page cannot be shown.[/b] Suspending the world
## and freeing the cursor to display nothing is worse than not pausing, and the bare call defaults to
## a page id a host config need not define. Both qualifying cases are covered here rather than off
## [method _show_page]'s return, because that returns TRUE for a def whose
## [member MKMenuPageDef.scene] is null. There is no post-[method _show_page] unwind.
##
## [b]While the pause menu is open the shell is a PAUSE shell: the nav bar is hidden.[/b] A tab press
## is a lateral [method go_to_page]: it clears the back stack, leaves [member _pause_menu_open] true,
## and parks the shell on a foreign page, after which Escape hits the resume rung and hands the player
## a running game under a full settings page. The shipped tabs also reach Start Game and character
## deletion, which are main-menu gestures. Hiding is per-instance and per-open;
## [method close_pause_menu] restores it.
##
## Programmatic navigation during pause remains HOST territory — nothing here refuses a
## [method go_to_page] call — but the ladder's pause rung recovers from it by navigating back to the
## recorded pause page rather than resuming. See [method _unhandled_input].
func open_pause_menu(page_id: StringName = &"pause") -> bool:
	if _pause_menu_open:
		return false
	var def := config.get_page(page_id) if config != null else null
	if def == null or def.scene == null:
		MKLog.warn("open_pause_menu('%s'): no page with a scene under that id in %s — refusing to suspend the world for an empty page"
			% [page_id, MKLog.context(config, "pages")])
		return false
	_pause_menu_open = true
	_push_suspend(&"pause")
	# The return value is deliberately not branched on: the pre-check above established the only two
	# states _show_page reports false for. If foreign code running in between (the policy's
	# enter_menu, or _show_page's own _modal_layer.pop_all()) erases the page def, the false return
	# leaves the shell on the OLD page with _pause_page_id recorded — the divergent state the Escape
	# ladder's pause rung is page-aware for, and it closes the pause menu from there.
	_show_page(page_id)
	_pause_page_id = page_id
	_back_stack.clear()
	# The pause page is not a tab, so _show_page's set_active(page_id) matches no button and clears
	# the highlight — a legitimate state on MKNavBar.set_active, which is silent on an unknown id.
	# Hiding the bar makes that moot and is what stops a tab press defeating the whole rung; the
	# set_active call is left alone because it is already correct for a host that shows the bar itself.
	if _nav_bar != null:
		# Recorded, not assumed: close_pause_menu restores THIS value rather than writing true.
		_nav_visible_before_pause = _nav_bar.visible
		_nav_bar.visible = false
	pause_menu_toggled.emit(true)
	return true


## Drops the pause suspension and restores the shell chrome. [b]It does not navigate[/b]: the page
## stays wherever navigation left it. That is deliberate — a hidden shell's next visible page is the
## host's decision (it may be about to change scene entirely, as Quit to Menu does), and a close that
## navigated would fight the host for it.
##
## [b]It DOES clear the back stack.[/b] A pause sub-navigation (Settings from the pause page) leaves
## a return address to the pause page on the stack, and leaving it there hands the resumed shell a
## stale one: the very next Escape — a gesture the player means as "open the pause menu" — would pop
## straight to the pause PAGE with [member _pause_menu_open] false, i.e. a full-screen pause panel
## over a running game with no rung to close it.
func close_pause_menu() -> void:
	if not _pause_menu_open:
		return
	_pause_menu_open = false
	_pause_page_id = &""
	_back_stack.clear()
	if _nav_bar != null:
		_nav_bar.visible = _nav_visible_before_pause
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
	# answer changes while a menu is open (a multiplayer session starting mid-menu) would skip its own
	# exit_menu and leave the world paused with no menu on screen. exit_menu is the counterpart of an
	# enter that happened, not of a condition that still holds.
	if _pause_policy != null and _pause_policy.can_pause():
		# Latched before the call: the flag means "enter_menu was invoked".
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
## settings service owns one. Ask the service first when you need "the live controller".
func get_brightness_controller() -> MKBrightnessController:
	return _brightness_controller


func get_network_backend() -> MKNetworkBackend:
	return _network_backend


func get_pause_policy() -> MKPausePolicy:
	return _pause_policy


## One call to paste into a bug report.
func dump_diagnostics() -> String:
	var lines := PackedStringArray()
	lines.append(MKVersion.version_string())
	lines.append("config: %s" % MKLog.context(config))
	lines.append("page: %s  back_stack: %s" % [_page_id, _back_stack])
	# pause_page_id rides the pause line: it distinguishes "paused, on the pause page" from "paused,
	# navigated elsewhere" — the state the Escape ladder's recovery rung exists for, and unanswerable
	# from a bug report without it. It must read empty whenever pause_menu_open is false.
	lines.append("suspend_depth: %d  pause_menu_open: %s  pause_page_id: %s  mouse_mode: %d"
		% [_suspend_depth, _pause_menu_open, _pause_page_id, Input.mouse_mode])
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
			# The dump carries resolved user:// paths: "settings don't persist" is usually a question
			# about WHICH file was written, and without this the answer costs a round trip with the
			# reporter.
			if node.has_method("get_file_path"):
				desc += "  store: %s" % node.call("get_file_path")
		lines.append("backend %s: %s" % [pair[0], desc])
	lines.append("settings backend adopted from autoload: %s" % _adopted_settings)
	if config != null:
		lines.append("pages: %d visible of %d" % [config.get_visible_pages().size(), config.pages.size()])
		# The creation module's counts live on MKConfig (creation_diagnostics builds the line) because
		# the config owns those arrays; this dump only assembles.
		lines.append(config.creation_diagnostics())
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
	# per-field edits, but nothing re-invokes it when config.palette is REASSIGNED. There is no
	# unsubscribe-the-old-config branch: _resolve_config runs once, from _ready. Assigning `config` at
	# runtime is NOT a supported gesture — it re-runs nothing, rebuilds no nav, and restyles nothing.
	if not config.changed.is_connected(_apply_theme):
		config.changed.connect(_apply_theme)
	# Report every problem at once: a first-time integrator gets one list to work through instead of
	# a fix-run-fix loop.
	for problem in config.validate():
		MKLog.error(problem)


func _apply_theme() -> void:
	# Unsubscribe FIRST, before any early return: behind the null-palette check, setting
	# config.palette = null would leave the discarded palette wired to this root and every later edit
	# to it would re-enter here.
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
	# in MKPalette has no listener and editing a palette at runtime restyles nothing — the Theme
	# would be a one-shot snapshot taken at boot.
	if not next_palette.changed.is_connected(_apply_theme):
		next_palette.changed.connect(_apply_theme)
	var generated := MKThemeGenerator.build(next_palette)
	if generated == null:
		return
	if not MKTheme.theme_defines_all(generated):
		MKLog.error("%s: generated Theme is missing type variations — panels using them render unstyled"
			% MKLog.context(next_palette))
	theme = generated
	# The scrim is not a Theme item (the modal layer draws a plain ColorRect), so a palette swap
	# must drive it here or the alt skin dims with the old skin's colour. Shell-owned layer only —
	# a host's own MKModalLayer keeps its exported scrim_color.
	if _modal_layer != null and is_instance_valid(_modal_layer):
		_modal_layer.scrim_color = next_palette.scrim


func _build_shell() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_backdrop = MKBackdrop.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	if show_backdrop and config != null and config.backdrop_catalog != null:
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
	# _apply_theme ran before the shell existed, so the palette's scrim is applied once here; later
	# palette swaps re-drive it from _apply_theme.
	if config != null and config.palette != null:
		_modal_layer.scrim_color = config.palette.scrim

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


## Adopt-or-instantiate. Two settings-backend instances over one JSON file means the revert countdown
## snapshots one while the panel writes the other, and last-save silently wins — a bug that is
## near-impossible to diagnose from a bug report. So when the autoload exists it owns the instance and
## this node borrows it.
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
	# revert countdown runs on it. Left PAUSABLE, that countdown freezes under a tree pause policy and
	# the confirm-or-revert dialog hangs forever with no failing write to reveal it.
	live.process_mode = Node.PROCESS_MODE_ALWAYS
	# A scene naming a different script than the service already built is a misconfiguration, not a
	# reason to double-instantiate. Keep the service's instance and say so, naming both scripts.
	var slot := config.settings_backend
	if slot != null and slot.is_assigned():
		# The slot's PARAMS are ignored on this path — the service already built and configured the
		# instance from its own slot — so a config naming its own file_path would otherwise adopt the
		# service's store with no diagnostic. Debug rather than warn: a host whose config IS the one the
		# service builds from ignores nothing, and a warn would fire on every correct boot.
		if not slot.params.is_empty():
			MKLog.debug("%s: params are ignored when %s owns the backend — configure the service's slot instead"
				% [MKLog.context(slot, "params"), SETTINGS_SERVICE_PATH])
		var live_script := live.get_script() as Script
		if live_script != null and live_script != slot.backend_script:
			MKLog.error("settings backend mismatch: %s built '%s' but %s names '%s'. Keeping the service's instance."
				% [SETTINGS_SERVICE_PATH, live_script.resource_path,
					MKLog.context(config, "settings_backend"), slot.backend_script.resource_path])
	return live


## Builds this scene's own settings backend AND boots it.
##
## The three calls are what make a settings store mean anything, and in a service-less configuration
## nothing else makes them: without the load, a stored resolution is never read and a stored rebind
## never applied, every panel reads an empty store, and the symptom — "my settings don't stick" —
## looks like a bug in whatever panel the user happened to be on.
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


## The standalone brightness tier — reached only from [method _boot_own_settings_backend], i.e. only
## when no settings service owns the store.
##
## [b]This tier is closer to the floor than to the autoload behaviour.[/b] The controller is a child
## of a [b]per-scene[/b] [MKRoot], so it dies with the root: brightness gaps across every scene
## transition and reaches gameplay only if the game scene also hosts an [MKRoot]. The
## [code]MKSettingsService[/code] autoload is the supported configuration for brightness. This exists
## so the no-autoload configuration is not a dead slider, not because it is equivalent.
##
## [b]Two controllers must never coexist[/b] — each applies its own gamma pass and the image would be
## corrected twice. The adopt path never reaches this method, so the check below covers the
## service-shaped route: [code]/root/MKSettingsService[/code] is resolved duck-typed, so the node
## answering that name need not be the shipped service. A host-supplied one that owns a brightness
## controller while returning null from [code]get_settings_backend()[/code] would otherwise send this
## scene down the build-your-own path with a controller already live.
##
## What it deliberately does NOT cover: two standalone shells mounted SIMULTANEOUSLY with no service
## at all — each walks this path, sees no service, and builds its own controller, stacking two gamma
## passes. No shipped configuration mounts two service-less shells at once, so the gap is documented
## rather than guarded; a host running that shape owns brightness itself or mounts the service.
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
## slot's identity, so the leftover-key warning can be produced by neither alone.
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
##   literally unclickable.
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


## [param mouse_mode] is a parameter purely so the captured-cursor branch can be driven directly:
## under [code]--headless[/code] the dummy DisplayServer never leaves
## [constant Input.MOUSE_MODE_VISIBLE], so that branch is otherwise unreachable.
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
