@tool
class_name MKRebindRow
extends HBoxContainer
## One [constant MKSettingDef.RowType.KEYBIND] row: it shows an action's current binding, captures a
## new one, and commits it through [MKSettingsBackend] (plan §4.4).
##
## Built entirely in code, like every other MenuKit row — there is no [code].tscn[/code] for it, so
## the scene can never drift from the structure this script indexes into. [MKSettingsPanel]
## constructs one, names it, and calls [method setup]; nothing else is required of the host.
##
## [b]Styling is type variations only.[/b] Not one [code]add_theme_*_override[/code] anywhere in this
## file (plan §1.2, ship gate 1): an override beats the [Theme], so a row using one could never be
## re-skinned by swapping an [MKPalette].
##
## [b]The priority rule.[/b] While this row is listening it reads input in [method Node._input] and
## marks EVERY event class it inspects handled, via
## [method Viewport.set_input_as_handled]. That is not tidiness — [code]MKRoot[/code] reads
## [code]ui_cancel[/code] in [method Node._unhandled_input], and unhandled input runs strictly after
## [code]_input[/code] and after GUI dispatch. Consuming here is therefore the ONLY thing that stops
## a capture keystroke from also closing the menu, activating the focused button, or reaching
## gameplay. Two consequences follow by construction and are relied on below:
## [br]- This row never uses [method Node._unhandled_input] and never references [code]MKRoot[/code].
## [br]- GUI dispatch does not run for consumed events, so the Cancel button cannot be clicked
##   normally while listening — the mouse abort is a manual hit-test against its rect instead.
##
## [b]The abort table (plan §4.4), reproduced because getting it wrong is silent.[/b] Abort is
## decided PER DEVICE and never through the [code]ui_cancel[/code] action:
## [codeblock]
## Keyboard   physical Escape (keycode Escape only when physical_keycode is 0)
##            -> aborts, consumed, binding unchanged
## Gamepad    NO special case. Joypad B arrives at the RECORD path, is refused there as a
##            reserved event ("Reserved by the menu") and ends listening — one gesture doing
##            both jobs.
## Mouse      a press inside the Cancel button's global rect aborts; a press anywhere else is
##            RECORDED as a mouse binding.
## Any        the listen timeout (see listen_timeout) lapses -> abort.
## [/codeblock]
## An action-level abort was rejected in review for exactly one reason: [code]ui_cancel[/code]
## normally carries joypad B as well as Escape, so testing the ACTION would have swallowed the pad's
## B press before the reserved check could refuse and explain it — the row would look dead to a
## controller player pressing the one button that is not bindable.
##
## [b]A capture REPLACES the row's whole event list (single-slot).[/b]
## [method MKSettingsBackend.set_action_events] is called with exactly the captured event, so an
## action bound to both W and Up-arrow ends up bound to the one key the user just pressed. That is
## what a player rebinding a control expects to see in the row afterwards, and the multi-event stock
## binding is never lost: it is still in the boot snapshot, and the per-row Reset button
## ([method reset_to_default]) puts all of it back.

## Emitted when capture starts and when it ends, however it ends (commit, abort, timeout, reserved
## refusal, leaving the tree). A panel uses it to keep two rows from listening at once and tests
## assert against it rather than against widget text.
signal capture_state_changed(listening: bool)

## Emitted after any write this row pushes at the input store — its own commit, AND the strip a
## Replace performs on the LOSING action. The panel listens and redraws every rebind row, because the
## row that just displayed the stolen key is some OTHER row this one cannot see: without the relay,
## Replace leaves that row showing a binding the store no longer gives it, with a Reset button whose
## enabled state is equally stale.
signal binding_changed(action: StringName)

## Width reserved for the row label, matching [constant MKSettingsPanel.LABEL_COLUMN_WIDTH] so a
## keybind row lines up with the toggle and slider rows above it. Duplicated as a literal rather than
## referenced, because a rebind row must build correctly when a host uses it outside the shipped
## panel — and the value is a layout rhythm, not a palette constant (plan §1.2).
const LABEL_COLUMN_WIDTH := 260.0

## How far the focus ring is grown beyond the binding button's rect. Same rhythm as
## [constant MKSettingsPanel.FOCUS_RING_GROW]; the ring's colour and thickness come from the palette
## through [constant MKTheme.FOCUS_RING].
const FOCUS_RING_GROW := 4.0

## Deadzone for [InputEventJoypadMotion]. Below this a stick is resting or drifting, and binding a
## drifting axis would produce an action that fires forever with nothing touching the pad.
const AXIS_DEADZONE := 0.5

## Shown while a capture is live.
const LISTEN_TEXT := "Press any key…"

## Shown when an action has no events at all. Not an error: an unbound action is a legitimate state
## a user can reach by resetting a project whose stock binding list is empty.
const UNBOUND_TEXT := "Unbound"

## The two captions this row can show. Both are transient — cleared the next time capture starts.
const CAPTION_RESERVED := "Reserved by the menu"
const CAPTION_UI_OVERLAP := "Also used by menu navigation"

## Seconds before an unanswered capture gives up. A listening row swallows the whole keyboard, so a
## player who walked away (or who started a capture by accident and cannot guess that Escape gets
## out) must not be stuck in it.
##
## It is [b]the backstop, not the primary path[/b] (plan §4.4): Escape, the Cancel button and the pad's
## reserved refusal are how a capture is meant to end, and this only catches the player who left. Ten
## seconds rather than five because the real gesture is "click, then decide" — a user reading the row
## to work out which key they want is doing the intended thing, and having the prompt expire under
## them reads as the menu dropping their input.
@export var listen_timeout := 10.0

var _def: MKSettingDef
var _backend: MKSettingsBackend
var _modal_layer: MKModalLayer
## Answers [code]() -> Array[StringName][/code] with every KEYBIND-managed action, for the conflict
## scan. A [Callable] rather than an array so a panel that rebuilds its rows does not have to push a
## new list into each of them.
var _managed_actions_provider := Callable()
## Events that may never be bound — in practice the stock non-keyboard [code]ui_cancel[/code] events
## (joypad B), widened by the host. Supplied by the panel; this row does not derive it, because the
## question "what does this shell use to back out" belongs to the shell.
var _reserved_events: Array[InputEvent] = []

var _action: StringName = &""
## False when [method InputMap.has_action] said no at setup. The row still builds — see [method setup]
## for why a missing action must be visible rather than absent — but cannot capture.
var _action_known := false

var _listening := false

var _label: Label
var _binding_button: Button
var _reset_button: Button
var _cancel_button: Button
var _hint_label: Label
var _caption_label: Label
var _focus_ring: Panel
var _timeout_timer: Timer

var _built := false


# --- Build --------------------------------------------------------------------

## Godot re-enables input processing at NOTIFICATION_READY for any script that overrides _input —
## measured, not read: the set_process_input(false) in _build lands before the row enters the tree,
## and without this override the engine's ready-time re-enable silently wins and every idle row is
## dispatched every event for the row's whole life (harmless, because _input guards on _listening,
## but it falsifies both the "idle rows cost nothing" claim and any test asserting
## is_processing_input()). _listening rather than false, for the one legitimate reordering: a row
## whose capture began before it entered the tree must not have that capture's input taken away.
func _ready() -> void:
	set_process_input(_listening)

## Wires the row and builds its controls. Safe to call again (a panel rebuilding its pages): the
## widgets are built once and re-pointed at the new def.
##
## [param managed_actions_provider] answers [code]() -> Array[StringName][/code]; [param
## reserved_events] is the never-bindable set. Both may be empty/invalid, which simply disables the
## checks that consume them rather than refusing to build — a row that vanishes because its panel
## forgot one argument reads as a missing resource.
##
## [b]An action this project does not define still gets a row.[/b] The binding button is disabled and
## ONE warning names the def. Dropping the row instead would hide the mistake: the symptom would be a
## controls page that is simply missing a line, with nothing anywhere to say which resource named a
## dead action. The backend keeps overrides for unknown actions for the same reason — renaming an
## action back restores the user's binding rather than losing it.
func setup(def: MKSettingDef, backend: MKSettingsBackend, modal_layer: MKModalLayer,
		managed_actions_provider: Callable, reserved_events: Array[InputEvent]) -> void:
	# A live capture belongs to the OLD def. Ended before anything is repointed, so the abort path
	# restores a display that still matches what it is about to be replaced with.
	if _listening:
		_stop_listening()

	_def = def
	_backend = backend
	_modal_layer = modal_layer
	_managed_actions_provider = managed_actions_provider
	_reserved_events = reserved_events

	_action = def.action_name if def != null else &""
	_action_known = _action != &"" and InputMap.has_action(_action)

	_build()

	# On the row AND the button: the label is the larger hit area, and a tooltip only reachable over a
	# narrow button is one most users never find.
	#
	# Assigned UNCONDITIONALLY, so an empty tooltip CLEARS. setup() is re-callable by contract (a panel
	# rebuilding its pages re-points one row at a new def), and skipping the write for an empty string
	# left the PREVIOUS def's tooltip hovering over a row that is now about something else — the one
	# state where a tooltip is worse than none.
	var tooltip := _def.tooltip if _def != null else ""
	tooltip_text = tooltip
	_binding_button.tooltip_text = tooltip

	if _backend == null:
		MKLog.warn("%s: rebind row '%s' has no MKSettingsBackend — it renders disabled and nothing is captured"
			% [MKLog.context(_def, "action_name"), _action])
	elif not _action_known:
		# ONCE, here, and not from refresh_display(): that runs on every commit and every external
		# change, and a per-refresh warning would bury the rest of the log for one bad resource.
		MKLog.warn("%s: action '%s' is not defined by this project — the row is shown but cannot be rebound"
			% [MKLog.context(_def, "action_name"), _action])

	refresh_display()


func _build() -> void:
	if _built:
		return
	_built = true

	_label = Label.new()
	_label.name = "RowLabel"
	_label.custom_minimum_size = Vector2(LABEL_COLUMN_WIDTH, 0.0)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MKTheme.set_variation(_label, MKTheme.ROW_LABEL)
	add_child(_label)

	_binding_button = Button.new()
	_binding_button.name = "Binding"
	MKTheme.set_variation(_binding_button, MKTheme.PANEL_BUTTON)
	# Godot's own button activation covers BOTH gestures the plan requires to start a capture: a mouse
	# click and ui_accept on the focused button both emit `pressed`. No input handling of our own is
	# needed to start listening — only to conduct it.
	_binding_button.pressed.connect(begin_listen)
	add_child(_binding_button)

	_add_focus_ring(_binding_button)

	_reset_button = Button.new()
	_reset_button.name = "Reset"
	_reset_button.text = "Reset"
	MKTheme.set_variation(_reset_button, MKTheme.PANEL_BUTTON)
	_reset_button.pressed.connect(reset_to_default)
	add_child(_reset_button)

	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = "Cancel"
	MKTheme.set_variation(_cancel_button, MKTheme.PANEL_BUTTON)
	# Genuinely connected, and genuinely reachable: while listening this row consumes mouse presses
	# before GUI dispatch, so the click route is the rect hit-test in _input — but the button is a real
	# button and stays clickable through this signal on any path where input is NOT being consumed
	# (a host that pauses the capture, a test pressing it directly). One handler serves both.
	_cancel_button.pressed.connect(_abort_listen)
	_cancel_button.visible = false
	add_child(_cancel_button)

	_hint_label = Label.new()
	_hint_label.name = "CancelHint"
	_hint_label.text = "Esc to cancel"
	# Beside the Cancel button rather than inside its label: the button already says Cancel, and a
	# button captioned "Cancel (Esc to cancel)" reads as a stutter. Keyboard is the only device the
	# hint applies to — the pad's abort is the reserved refusal, which explains itself in the caption.
	MKTheme.set_variation(_hint_label, MKTheme.ROW_LABEL)
	_hint_label.visible = false
	add_child(_hint_label)

	_caption_label = Label.new()
	_caption_label.name = "Caption"
	MKTheme.set_variation(_caption_label, MKTheme.ROW_LABEL)
	_caption_label.text = ""
	add_child(_caption_label)

	# A Timer child rather than a `_process` accumulator: the abort paths must be able to STOP the
	# countdown, and a stopped Timer is one call and no residual state. It inherits this row's process
	# mode, which inside an MKRoot is PROCESS_MODE_ALWAYS (plan §4.2a) — so a capture started from the
	# pause menu still times out instead of hanging forever under SceneTree.paused.
	_timeout_timer = Timer.new()
	_timeout_timer.name = "ListenTimeout"
	_timeout_timer.one_shot = true
	_timeout_timer.timeout.connect(_on_listen_timeout)
	add_child(_timeout_timer)

	# Idle rows cost nothing: _input is enabled only for the duration of a capture (and a test can
	# assert is_processing_input() to tell the two states apart without reading widget text). This
	# call alone is NOT enough — see _ready for the half the engine undoes.
	set_process_input(false)

	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)


## Gives the binding button a visible focus indicator, the same way [MKSettingsPanel] does for its
## sliders: a [Panel] child carrying [constant MKTheme.FOCUS_RING], toggled on focus. Buttons DO have
## a focus StyleBox, but this row's button is the thing a keyboard player is about to hand the whole
## keyboard to, so it gets the loudest indicator the vocabulary has.
##
## Parented to the button so the ring tracks the CONTROL's rect rather than the whole labelled line,
## and [constant Control.MOUSE_FILTER_IGNORE] so it never eats the click that starts a capture.
func _add_focus_ring(button: Button) -> void:
	_focus_ring = Panel.new()
	_focus_ring.name = "FocusRing"
	MKTheme.set_variation(_focus_ring, MKTheme.FOCUS_RING)
	_focus_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_focus_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_focus_ring.offset_left = -FOCUS_RING_GROW
	_focus_ring.offset_top = -FOCUS_RING_GROW
	_focus_ring.offset_right = FOCUS_RING_GROW
	_focus_ring.offset_bottom = FOCUS_RING_GROW
	_focus_ring.visible = false
	button.add_child(_focus_ring)
	button.focus_entered.connect(func() -> void: _focus_ring.visible = true)
	button.focus_exited.connect(func() -> void: _focus_ring.visible = false)


# --- Display ------------------------------------------------------------------

## Repaints the row from the backend: the label, the binding text, and the Reset button's enabled
## state. Called after every commit, after a reset, and by a panel reacting to an external change.
##
## Does nothing to the binding button's text while a capture is live — that text is the capture
## prompt, and overwriting it mid-listen would tell the user the gesture had already been taken.
func refresh_display() -> void:
	if not _built:
		return
	_label.text = _label_text()
	if not _listening:
		_binding_button.text = _binding_text()
	_binding_button.disabled = _backend == null or not _action_known
	# Disabled unless there is something to undo. The backend is the only thing that knows whether an
	# override exists, so this is asked rather than tracked — a row rebuilt over a store loaded from
	# disk gets the right answer without replaying how it got there.
	#
	# _action_known is part of the condition, and reachable: the backend KEEPS overrides for actions
	# the project does not define (on purpose — renaming an action back restores the user's binding
	# rather than losing it), so an unknown action can carry an override, and gating on the override
	# alone lit an enabled Reset on a row whose reset_to_default() early-returns on exactly that
	# check. The override surviving is the feature; a button that pretends to work while the action is
	# missing is not.
	_reset_button.disabled = _backend == null or not _action_known \
		or not _backend.has_action_override(_action)


func _label_text() -> String:
	if _def == null:
		return String(_action)
	if not _def.label.is_empty():
		return _def.label
	# Falls back to the ACTION rather than the def's id, because on a keybind row the action is what
	# the reader is trying to identify.
	return String(_action) if _action != &"" else String(_def.id)


## The current binding(s), joined. Read through the backend rather than off [InputMap] so the row
## shows the STORE's truth: the two agree once apply has run, but the store is what persists and what
## a reset is measured against.
func _binding_text() -> String:
	if _backend == null:
		return UNBOUND_TEXT
	var events := _backend.get_action_events(_action)
	var parts: Array[String] = []
	for event in events:
		var text := _event_label(event)
		if text.is_empty():
			continue
		parts.append(text)
	if parts.is_empty():
		return UNBOUND_TEXT
	return ", ".join(parts)


## A human label for one event, or "" for an event class this row cannot describe (which is also the
## set the persisted format cannot carry, so such an event can never have come from the store).
func _event_label(event: InputEvent) -> String:
	if event is InputEventKey:
		return _key_label(event as InputEventKey)
	if event is InputEventMouseButton:
		return _mouse_label((event as InputEventMouseButton).button_index)
	if event is InputEventJoypadButton:
		return _joypad_button_label((event as InputEventJoypadButton).button_index)
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return "Axis %d %s" % [int(motion.axis), "+" if motion.axis_value >= 0.0 else "-"]
	return ""


## Bindings are stored by PHYSICAL keycode (the backend's format decision, plan §4.4) so they stay
## under the same finger on an AZERTY layout — but a physical code is a POSITION, and printing it
## raw would label the AZERTY player's key by its QWERTY name. [method
## DisplayServer.keyboard_get_keycode_from_physical] maps the position back through the ACTIVE
## layout, which is what the player sees on the keycap.
##
## Two fallbacks to the plain keycode, both reachable: a synthetic event carries physical_keycode 0
## (nothing to map), and the mapping itself answers 0 on drivers with no layout information — the
## headless driver among them, where every row would otherwise read as a blank binding.
func _key_label(key: InputEventKey) -> String:
	var physical := int(key.physical_keycode)
	# The headless driver is skipped BEFORE the call, not diagnosed after it: keyboard_get_keycode_from_
	# physical there both answers 0 and prints an engine ERROR line per call, and the suite's noise gate
	# treats engine ERRORs as failures. With no layout to consult, the physical code IS the best
	# available name — OS.get_keycode_string reads it as the QWERTY position, which for a headless run
	# (tests, a server) is a log label rather than a keycap.
	if physical != 0 and DisplayServer.get_name() != "headless":
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(physical as Key)
		if int(mapped) != 0:
			return OS.get_keycode_string(mapped)
	if physical != 0:
		return OS.get_keycode_string(physical as Key)
	return OS.get_keycode_string(int(key.keycode) as Key)


## The three buttons every mouse has get their names; the rest are numbered. "Mouse 4" is what a
## player with a side button expects to read, and Godot's own enum names for them
## (WHEEL_UP, XBUTTON1) are not.
func _mouse_label(index: int) -> String:
	match index:
		MOUSE_BUTTON_LEFT:
			return "Mouse Left"
		MOUSE_BUTTON_RIGHT:
			return "Mouse Right"
		MOUSE_BUTTON_MIDDLE:
			return "Mouse Middle"
	return "Mouse %d" % index


## [method Input.get_joy_button_string] gives the pad-appropriate name ("A", "Cross"). It is queried
## through [method Object.has_method] because it is an engine API this addon does not control the
## availability of across 4.x builds, and a missing one must degrade to a number rather than take the
## page down — that is a genuine capability probe, not a guard against our own classes.
func _joypad_button_label(index: int) -> String:
	if Input.has_method("get_joy_button_string"):
		var name: Variant = Input.call("get_joy_button_string", index)
		if name is String and not (name as String).is_empty():
			return name as String
	return "Pad %d" % index


# --- Capture ------------------------------------------------------------------

func is_listening() -> bool:
	return _listening


## Ends a live capture without changing the binding; a no-op when none is live. Public because the
## one-listener-at-a-time rule belongs to the PANEL — two rows cannot see each other, so the shell
## that built them is what ends row A's capture when row B starts one. Everything the private abort
## guarantees (timer stopped, display restored, nothing written) holds here too: this is the same
## funnel.
func abort_listen() -> void:
	_abort_listen()


## Starts a capture. Also the binding button's [signal BaseButton.pressed] handler, so a mouse click
## and ui_accept on the focused button both arrive here.
##
## Refused silently when there is nothing to capture INTO (no backend, an action this project does
## not define). Both cases already warned once at [method setup] and both leave the button disabled,
## so a press that reaches here at all is a host driving the row directly — repeating the warning per
## press would be noise.
func begin_listen() -> void:
	if _listening or not _built:
		return
	if _backend == null or not _action_known:
		return
	# The previous refusal is history the moment the user tries again. Cleared here rather than on the
	# commit, so it also clears for a capture that goes on to be aborted.
	_set_caption("")
	_listening = true
	_binding_button.text = LISTEN_TEXT
	_cancel_button.visible = true
	_hint_label.visible = true
	set_process_input(true)
	if listen_timeout > 0.0:
		_timeout_timer.start(listen_timeout)
	capture_state_changed.emit(true)


## Ends a capture without changing the binding, and puts the display back. Every abort route —
## Escape, the Cancel rect, the timeout, leaving the tree, being hidden — funnels through here, so
## "an abort never writes" is a property of one function rather than of five call sites.
func _abort_listen() -> void:
	if not _listening:
		return
	_stop_listening()


## The bookkeeping half of ending a capture. Separated from [method _abort_listen] because the COMMIT
## path also ends listening and must not be mistaken for an abort by a future reader.
func _stop_listening() -> void:
	_listening = false
	set_process_input(false)
	if _timeout_timer != null and is_instance_valid(_timeout_timer):
		_timeout_timer.stop()
	if _cancel_button != null and is_instance_valid(_cancel_button):
		_cancel_button.visible = false
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.visible = false
	refresh_display()
	capture_state_changed.emit(false)


func _on_listen_timeout() -> void:
	_abort_listen()


## A row that is hidden mid-capture is a page the user navigated away from. Aborting rather than
## listening on is the only safe reading: an invisible row holding the whole keyboard is
## indistinguishable, from the player's side, from the game having frozen.
func _on_visibility_changed() -> void:
	if _listening and not is_visible_in_tree():
		_abort_listen()


## Leaving the tree ends a capture too, and it must: [method Node.set_process_input] and a running
## [Timer] are state on a node that is about to be reparented or freed, and a row that comes back
## still flagged listening would be showing the capture prompt with no input processing behind it.
##
## [constant Node.NOTIFICATION_EXIT_TREE] rather than [method Node.is_queued_for_deletion]: this
## fires for a reparent and for a real teardown alike, which is exactly the set of departures that
## invalidate a live capture, and it fires at the moment of departure rather than one frame later.
func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE and _listening:
		_abort_listen()


## The capture reader. See the class doc's priority rule for why this is [method Node._input] and why
## it consumes: nothing here may reach GUI dispatch or [code]MKRoot._unhandled_input[/code].
##
## Event classes this row does not inspect are left entirely alone — not consumed, not read — so
## touch, gestures and everything else keep working around a listening row. [InputEventMouseMotion]
## is called out explicitly because it is the one that would be tempting to consume for symmetry:
## consuming it kills hover feedback (including the Cancel button's) for the whole capture.
func _input(event: InputEvent) -> void:
	if not _listening:
		return
	if event is InputEventMouseMotion:
		return

	if event is InputEventKey:
		_consume()
		var key := event as InputEventKey
		# Releases and auto-repeat echoes are consumed and dropped: they belong to the gesture already
		# being handled, and letting a release through leaks a half-gesture into gameplay.
		if not key.pressed or key.echo:
			return
		if _is_escape(key):
			_abort_listen()
			return
		_record(_fresh_key(key))
		return

	if event is InputEventMouseButton:
		_consume()
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		# The manual hit-test the class doc's priority rule forces. global_position is in the same
		# coordinate space as get_global_rect() for a Control under the shell's CanvasLayer-free tree,
		# which is where MenuKit puts this row; a host embedding it under a transformed CanvasLayer
		# would need a transform here, and the Cancel button's own `pressed` signal is the route that
		# still works there.
		if _cancel_button.visible and _cancel_button.get_global_rect().has_point(button.global_position):
			_abort_listen()
			return
		_record(_fresh_mouse(button))
		return

	if event is InputEventJoypadButton:
		_consume()
		var pad := event as InputEventJoypadButton
		if not pad.pressed:
			return
		# NO B-button special case here, deliberately — see the abort table in the class doc. B reaches
		# _record, is refused as reserved, and ends the capture with a caption explaining itself.
		_record(_fresh_joypad_button(pad))
		return

	if event is InputEventJoypadMotion:
		_consume()
		var motion := event as InputEventJoypadMotion
		# Consumed but ignored below the deadzone: a resting stick emits a stream of small values, and
		# binding one of them produces an action that fires forever with nothing touching the pad.
		if absf(motion.axis_value) < AXIS_DEADZONE:
			return
		_record(_fresh_joypad_motion(motion))
		return


## Marks the current event handled. Guarded on the viewport because [method Node._input] can be
## reached during teardown frames where [method Node.get_viewport] answers null.
func _consume() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


## Escape is matched PHYSICALLY, so the abort key is the top-left key on every layout rather than
## whatever the active layout maps to the Escape symbol. The keycode fallback covers synthetic events
## only — those carry physical_keycode 0, and treating 0 as "no match" would make the row un-abortable
## from a test that injects one.
func _is_escape(key: InputEventKey) -> bool:
	if int(key.physical_keycode) != 0:
		return int(key.physical_keycode) == KEY_ESCAPE
	return int(key.keycode) == KEY_ESCAPE


# --- Fresh events -------------------------------------------------------------

## [b]Every fresh event sets [code]device = -1[/code], and each builder below says so again.[/b] -1
## is Godot's "all devices", which is what [code]project.godot[/code] authors for stock bindings and
## what a rebind made by the local user MEANS: "this control", not "this control on the controller
## index that happened to deliver the press". [InputMap] matching is device-aware, so keeping the
## captured index would give a pad player a binding that stops working the moment their controller
## re-enumerates as joypad 1. It has to be explicit because the class defaults are NOT -1 (measured
## on 4.7: [InputEventJoypadButton] 0, [InputEventKey] 16, [InputEventMouseButton] 32).
const BIND_ALL_DEVICES := -1

## A captured key is rebuilt rather than stored, and the MODIFIERS ARE CLEARED. Godot stamps the
## modifier state of the moment onto every key event, so binding "S" while Shift happened to be held
## — because the user was holding it for an unrelated reason, or because they are on a layout where
## the character needs it — would persist a Shift+S binding that then refuses to fire on a plain S.
##
## Modifier KEYS themselves stay bindable: pressing Shift produces an event whose own
## physical_keycode is Shift, and that is what is copied. Only the accompanying state flags are
## dropped.
##
## Both codes are copied because the persisted format carries both: physical is the binding, keycode
## is its fallback for events whose physical code is 0.
func _fresh_key(key: InputEventKey) -> InputEventKey:
	var out := InputEventKey.new()
	out.physical_keycode = key.physical_keycode
	out.keycode = key.keycode
	out.alt_pressed = false
	out.shift_pressed = false
	out.ctrl_pressed = false
	out.meta_pressed = false
	# All devices, never the capturing one — see BIND_ALL_DEVICES. A fresh InputEventKey defaults to
	# device 16, which would bind this key to one keyboard index.
	out.device = BIND_ALL_DEVICES
	# `pressed` is left false, matching the shape the backend's deserializer produces for a stored
	# binding. InputMap matches an action event on its button/key identity, not on this flag, so the
	# two shapes behave identically — keeping them identical is what stops a captured binding and a
	# reloaded one from comparing differently.
	return out


func _fresh_mouse(button: InputEventMouseButton) -> InputEventMouseButton:
	var out := InputEventMouseButton.new()
	# Index only: position, click count and modifiers are all properties of the MOMENT, and a binding
	# that carried the pixel it was captured at would match nothing.
	out.button_index = button.button_index
	# All devices — see BIND_ALL_DEVICES. A fresh InputEventMouseButton defaults to device 32.
	out.device = BIND_ALL_DEVICES
	return out


func _fresh_joypad_button(pad: InputEventJoypadButton) -> InputEventJoypadButton:
	var out := InputEventJoypadButton.new()
	out.button_index = pad.button_index
	# All devices — see BIND_ALL_DEVICES. This is the case that BITES: a fresh InputEventJoypadButton
	# defaults to device 0, so without this line a pad rebind works on controller 0 only.
	out.device = BIND_ALL_DEVICES
	return out


## The axis VALUE is normalised to ±1.0 rather than kept. A stick pushed to 0.73 and one pushed to
## 1.0 are the same binding — the direction is the whole meaning — and storing the captured magnitude
## would persist a binding whose meaning depends on how hard the user happened to be pushing.
func _fresh_joypad_motion(motion: InputEventJoypadMotion) -> InputEventJoypadMotion:
	var out := InputEventJoypadMotion.new()
	out.axis = motion.axis
	out.axis_value = signf(motion.axis_value)
	# All devices — see BIND_ALL_DEVICES, and the joypad-button note for why a pad event in particular
	# cannot keep the index it arrived on.
	out.device = BIND_ALL_DEVICES
	return out


# --- Matching -----------------------------------------------------------------

## The ONE event-equality rule in this file. Reserved checks, the [code]ui_*[/code] scan and the
## conflict scan all route through it, so there is a single answer to "are these the same binding".
##
## [b]Not [method InputEvent.is_match], and not [code]==[/code].[/b] [code]==[/code] on two
## [InputEvent] instances compares REFERENCES, and every event compared here was built or
## deserialised separately, so it is false for identical bindings. [method InputEvent.is_match]
## brings modifier semantics and an exact-match flag whose behaviour differs per event class — and
## since [method _fresh_key] deliberately strips modifiers while a stored binding may carry them,
## delegating to it would make a plain-S capture and a stored Shift+S compare as different bindings
## and then silently double-bind the key.
##
## [b]Keys compare LIKE AGAINST LIKE, never a physical code against a plain keycode.[/b] Both
## physicals nonzero -> compare physicals (the format's own key). Otherwise compare KEYCODES, and
## only when both of those are nonzero. The earlier rule substituted one side's physical for the
## other side's keycode when either physical was 0, which is reachable and wrong rather than
## theoretical: stock [code]ui_*[/code] bindings are authored in keycode form (physical 0) while a
## captured event carries both codes, and on AZERTY a stored keycode-A vs a captured physical-A /
## keycode-Q compared EQUAL — the overlap warning and the conflict scan both fired on the wrong key.
## The cost of the honest rule is stated too: a stored physical-only binding and a stored
## keycode-only binding for the same key now do NOT match, because with one code each there is no
## layout-independent way to tell whether they are the same key at all.
##
## Buttons compare by index. Motion compares axis AND direction, because the two ends of one stick
## axis are two different bindings.
##
## [b][code]device[/code] is deliberately NOT compared.[/b] Two presses of the same face button on
## two different pads are the same BINDING for every question this function answers — is it
## reserved, does it collide with menu navigation, is another managed action already on it — and
## treating them as distinct would let a player bind the menu-back button on controller 1 past the
## reserved check.
func _events_match(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	if a is InputEventKey and b is InputEventKey:
		var ka := a as InputEventKey
		var kb := b as InputEventKey
		var pa := int(ka.physical_keycode)
		var pb := int(kb.physical_keycode)
		if pa != 0 and pb != 0:
			return pa == pb
		var ca := int(ka.keycode)
		var cb := int(kb.keycode)
		return ca != 0 and ca == cb
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return int((a as InputEventMouseButton).button_index) \
			== int((b as InputEventMouseButton).button_index)
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return int((a as InputEventJoypadButton).button_index) \
			== int((b as InputEventJoypadButton).button_index)
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		var ma := a as InputEventJoypadMotion
		var mb := b as InputEventJoypadMotion
		return int(ma.axis) == int(mb.axis) \
			and is_equal_approx(signf(ma.axis_value), signf(mb.axis_value))
	# Different classes are different bindings. Stated as a return rather than left to fall out of the
	# chain, because "a key never equals a mouse button" is a decision and not an omission.
	return false


# --- Record -------------------------------------------------------------------

## The captured-event pipeline, in the order plan §4.4 fixes: reserved, then [code]ui_*[/code] (warn,
## do not refuse), then managed conflicts (ask), then commit.
##
## The order is the whole design. Reserved comes first because a reserved event must never reach a
## dialog — the pad's B is how a controller player expects to back OUT of a capture, so it has to end
## the capture rather than open something that then needs backing out of as well.
func _record(event: InputEvent) -> void:
	if _is_reserved(event):
		# Refused AND ends the capture: one gesture, both jobs (see the abort table). The caption is
		# what makes it legible — without it a pad player pressing B sees the prompt vanish with no
		# binding changed and no reason given, which reads as a dropped input.
		_set_caption(CAPTION_RESERVED)
		_stop_listening()
		return

	# WARN, never refuse (plan §4.4). A player who genuinely wants Enter on an in-game action is
	# entitled to it; what they are not entitled to is being surprised when the menu also reacts. The
	# caption says so and the capture continues.
	if _collides_with_ui_action(event):
		_set_caption(CAPTION_UI_OVERLAP)

	var other := _find_conflicting_action(event)
	if other != &"":
		# Listening ends BEFORE the dialog opens. A modal that steals focus while this row still holds
		# _input would consume the dialog's own keyboard — its buttons would be unreachable by anything
		# but the mouse, on a screen whose entire purpose is keyboard configuration.
		_stop_listening()
		_open_conflict_dialog(event, other)
		return

	_commit(event)


func _is_reserved(event: InputEvent) -> bool:
	for reserved in _reserved_events:
		if _events_match(event, reserved):
			return true
	return false


## True when [param event] is currently bound to any [code]ui_*[/code] action. Read off [InputMap]
## rather than the backend, because the built-in navigation actions are engine state a host may have
## changed in Project Settings and are not part of the KEYBIND-managed set the backend tracks.
func _collides_with_ui_action(event: InputEvent) -> bool:
	for action in InputMap.get_actions():
		if not String(action).begins_with("ui_"):
			continue
		for bound in InputMap.action_get_events(action):
			if _events_match(event, bound):
				return true
	return false


## The first managed action other than this row's that already carries [param event], or [code]&""[/code].
##
## Scanned through [method MKSettingsBackend.get_action_events], not [InputMap]: that is the
## POST-OVERRIDE truth, and it is the same source the other row is displaying. Reading InputMap
## instead would miss a conflict with an override that has been stored but not yet applied.
##
## First collision wins and the scan stops. Reporting several at once would need a dialog that can
## express "and also", and the second conflict is still there to be found on the next capture if the
## user resolves this one and re-binds.
func _find_conflicting_action(event: InputEvent) -> StringName:
	if not _managed_actions_provider.is_valid():
		return &""
	var raw: Variant = _managed_actions_provider.call()
	if not (raw is Array):
		MKLog.warn("%s: managed-actions provider returned %s, not an Array — the conflict scan is skipped for this capture"
			% [MKLog.context(_def, "action_name"), type_string(typeof(raw))])
		return &""
	for entry in raw as Array:
		if entry == null:
			continue
		var other := StringName(entry)
		if other == _action or other == &"":
			continue
		if _backend == null:
			return &""
		for bound in _backend.get_action_events(other):
			if _events_match(event, bound):
				return other
	return &""


## The conflict modal. [MKConfirmDialog] rather than a dialog of this row's own: a second,
## near-identical confirm script is exactly the parallel-code duplication that class exists to
## prevent, and it already carries no settings vocabulary.
##
## Three outcomes, all connected, because two of them are silent if left out:
## [br]- [b]Replace[/b] — the matching event(s) leave the OTHER action first, then the capture
##   commits here. In that order: committing first would leave both actions bound for the window
##   between the two writes, and a host reacting to the first apply would see the double-bind.
## [br]- [b]Keep both[/b] — commits here and leaves the other action alone. A legitimate choice: two
##   actions sharing a key in different contexts (a map screen and a gameplay screen) is a normal
##   design, and refusing it would be the addon overruling the game.
## [br]- [b]Cancel[/b] — nothing changes. Connected rather than left to the default, because the
##   capture has already ended by the time the dialog opens; the connection is what documents that
##   "nothing changes" is a decision and not a missing branch.
##
## The dialog frees itself ([method MKConfirmDialog.open]'s contract), so nothing here owns cleanup.
## A null return means there was no modal layer to show it on — the capture is then abandoned rather
## than committed, because committing a conflict the user was never asked about is the one outcome
## none of the three buttons produces.
func _open_conflict_dialog(event: InputEvent, other: StringName) -> void:
	var body := "%s is already bound to %s." % [_event_label(event), String(other)]
	var dialog := MKConfirmDialog.open(_modal_layer, "Binding Conflict", body, "Replace", "Cancel",
		false, "Keep both")
	if dialog == null:
		MKLog.warn("%s: '%s' conflicts with action '%s' but no MKModalLayer is reachable — the new binding was NOT applied"
			% [MKLog.context(_def, "action_name"), _event_label(event), other])
		return
	dialog.confirmed.connect(func() -> void:
		_strip_event_from(other, event)
		_commit(event)
	)
	dialog.alternate.connect(func() -> void: _commit(event))
	dialog.cancelled.connect(func() -> void:
		# The caption goes with the abandoned capture. A ui_* overlap caption raised on the way to this
		# dialog describes the event the user just declined to bind, so leaving it up labels a row whose
		# binding did not change with a warning about a key it does not carry. The Replace and Keep-both
		# branches deliberately leave it: there the binding DID land here, and the caption is still true.
		_set_caption("")
		MKLog.debug("rebind of '%s' cancelled at the conflict with '%s' — nothing changed"
			% [_action, other])
	)


## Removes every event matching [param event] from [param other] and applies the result.
##
## The REMAINING events are written back rather than the action being cleared: the other action may
## legitimately carry several bindings, and only the colliding one is what the user agreed to give
## up. Applied immediately, because the store and the live [InputMap] disagreeing between here and
## the next apply is a window in which the old key still does the old thing.
func _strip_event_from(other: StringName, event: InputEvent) -> void:
	if _backend == null:
		return
	var remaining: Array[InputEvent] = []
	for bound in _backend.get_action_events(other):
		if _events_match(event, bound):
			continue
		remaining.append(bound)
	_backend.set_action_events(other, remaining)
	_backend.apply_action(other)
	# The action just changed belongs to ANOTHER row — see binding_changed's doc for why the emit is
	# the only way that row finds out.
	binding_changed.emit(other)


## Writes the binding and pushes it at the engine.
##
## SINGLE-SLOT: the whole event list is replaced by the one captured event (see the class doc). Store
## first, then apply — the store is the truth and the engine call is its consequence, the same order
## [MKSettingsPanel] uses for values.
func _commit(event: InputEvent) -> void:
	if _backend == null:
		return
	var events: Array[InputEvent] = [event]
	_backend.set_action_events(_action, events)
	_backend.apply_action(_action)
	# The DIRECT capture path arrives here still listening, and committing is one of the ways a capture
	# ends (the class doc and capture_state_changed both say so). Guarded, because the two conflict-
	# dialog paths also land here AFTER listening already ended — an unguarded stop would re-emit
	# capture_state_changed(false) for a capture that finished when the dialog opened.
	if _listening:
		_stop_listening()
	# _stop_listening's refresh runs while _listening was already cleared, so the binding text repaints
	# there; this one covers the dialog paths and re-asks has_action_override(), which is what enables
	# the Reset button that was disabled a moment ago.
	refresh_display()
	binding_changed.emit(_action)


## Per-row reset: drop this action's override and put its stock bindings back.
##
## [method MKSettingsBackend.reset_action_to_default] restores the boot snapshot — the MULTI-event
## stock list, which is what a single-slot capture replaced. The apply is called anyway, even though
## the shipped backend's reset restores the live InputMap itself: the abstract contract only promises
## the store, and a backend that defers application would otherwise leave the engine on the binding
## the user just asked to undo.
##
## An in-flight capture is ended first. Resetting under a live listen would leave the row showing the
## capture prompt over a binding that had already changed beneath it.
func reset_to_default() -> void:
	if _listening:
		_abort_listen()
	if _backend == null or not _action_known:
		return
	_set_caption("")
	_backend.reset_action_to_default(_action)
	_backend.apply_action(_action)
	refresh_display()
	# Two defs MAY name one action (the panel dedups actions, not rows); the emit keeps any sibling
	# displaying this action honest, same as the commit paths.
	binding_changed.emit(_action)


## The inline caption. Empty text hides the label outright rather than leaving a blank gap in the
## row, so the layout does not shift when a message appears and disappears.
func _set_caption(text: String) -> void:
	if _caption_label == null or not is_instance_valid(_caption_label):
		return
	_caption_label.text = text
	_caption_label.visible = not text.is_empty()
