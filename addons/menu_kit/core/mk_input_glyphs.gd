@tool
class_name MKInputGlyphs
extends Node
## The device-aware prompt vocabulary: one spelling of "what does this event look like on screen",
## plus a tracker for which device class the player is currently using.
##
## [b]Text, not textures.[/b] Nothing here loads or draws an image. MenuKit ships no third-party art,
## and a home-drawn keycap set would be one more thing an [MKPalette] swap could not re-skin, so a
## prompt is a STRING — "Escape", "Mouse Left", "A" — rendered by whatever [Label] or [Button] the
## caller already has.
##
## [b]Two surfaces, deliberately split.[/b]
## [br]- The [b]static[/b] half ([method event_label], [method action_label]) is pure: it reads an
##   [InputEvent] or [InputMap] and needs no node, so a panel, a row or a test can call it without
##   owning anything.
## [br]- The [b]instance[/b] half tracks the last-used device CLASS from [method Node._input]. It is
##   a Node because that is what [method Node._input] requires, and it is [b]not an autoload[/b]:
##   whoever needs device tracking instantiates one and owns it. One per screen is the intended
##   density — seven rows each running their own [method Node._input] would be seven dispatches per
##   event to answer one question they all share.
##
## [b]This class never marks an event handled.[/b] It observes. Marking would make merely mounting a
## tracker swallow the input of every node below it in the dispatch order — including
## [code]MKRebindRow[/code]'s capture, which is the one consumer this class was written for.
##
## [b]The dispatch-order contract — the tracker sees EVERY event, including ones a row consumes.[/b]
## [method Node._input] is dispatched in REVERSE child order (the last child first), and
## [method Viewport.set_input_as_handled] stops every [method Node._input] consumer that has not run
## yet for that same event. So a tracker placed before a consuming sibling is blind exactly when it
## matters most — a device flip DURING a capture (the player putting the keyboard down mid-prompt, or
## pressing the pad's reserved B) is consumed by the listening [code]MKRebindRow[/code], and the
## prompt would keep naming the device that is no longer in hand.
##
## [b]The OWNER of a tracker guarantees the order by placing it LAST among its siblings.[/b] That is
## the whole mechanism; there is no flag, no priority number and nothing this class can do for
## itself. [method MKSettingsPanel._place_input_glyphs_last] is the shipped implementation and is
## called at the end of every build, because the natural order inverts across a rebuild. A host
## mounting its own tracker owes it the same placement.

## Emitted when — and only when — the tracked device class flips. Not per event: a pad player holding
## a stick would otherwise emit every frame, and every consumer would be re-rendering a prompt whose
## text did not change.
signal device_class_changed(pad: bool)

## Below this magnitude an [InputEventJoypadMotion] is a resting or drifting stick, not a gesture.
## Sticks emit continuously around zero, so without this gate a pad sitting untouched on a desk would
## hold the tracker in pad state forever — and, once it drifted back under, flap it against every
## keystroke. [code]MKRebindRow[/code] aliases this constant rather than restating the number: the
## deadzone below which a stick "is not being used" is one fact, and two copies of it would drift.
const AXIS_DEADZONE := 0.5

## Fallback names for the standard gamepad face/shoulder/d-pad layout, used when
## [method Input.get_joy_button_string] is unavailable (see [method joypad_button_label]).
##
## [b]These are SDL POSITIONS, not the legend printed on the player's pad.[/b] Godot's JoyButton enum
## is the SDL game-controller mapping, so [constant JOY_BUTTON_A] is "the bottom face button" —
## Cross on a PlayStation pad, B on a Nintendo one. Naming it "A" is the Xbox-layout reading of that
## position, which is what an unlabelled fallback can honestly offer;
## [method Input.get_joy_button_string] is preferred precisely because it can do better.
const JOY_BUTTON_NAMES := {
	JOY_BUTTON_A: "A",
	JOY_BUTTON_B: "B",
	JOY_BUTTON_X: "X",
	JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Back",
	JOY_BUTTON_GUIDE: "Guide",
	JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "Left Stick",
	JOY_BUTTON_RIGHT_STICK: "Right Stick",
	JOY_BUTTON_LEFT_SHOULDER: "Left Shoulder",
	JOY_BUTTON_RIGHT_SHOULDER: "Right Shoulder",
	JOY_BUTTON_DPAD_UP: "D-Pad Up",
	JOY_BUTTON_DPAD_DOWN: "D-Pad Down",
	JOY_BUTTON_DPAD_LEFT: "D-Pad Left",
	JOY_BUTTON_DPAD_RIGHT: "D-Pad Right",
}

## False = keyboard/mouse, true = joypad. Starts FALSE rather than "unknown": a menu is reachable
## before any input event exists (the game boots into it), and at that moment the mouse cursor is on
## screen — so keyboard/mouse is the state the player is actually looking at, and a third "unknown"
## state would only push the same choice onto every caller.
var _pad_active := false


# --- Device tracking ----------------------------------------------------------

func _init() -> void:
	# ALWAYS: this tracker is mounted inside menus that run under SceneTree.paused, and a frozen
	# tracker would answer with whatever device was in use before the game paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	# Restated here, not only in _init: the engine re-enables input processing at NOTIFICATION_READY
	# for any script overriding _input, so a set_process_input written before tree entry is silently
	# undone. This one wants it ON, so a future "disable when nobody is listening" optimisation
	# written above cannot quietly lose.
	set_process_input(true)


## The device class the last meaningful input came from. Consumers render pad prompts when true.
func is_pad_active() -> bool:
	return _pad_active


## Observes; never consumes. Ordered cheapest-first, and every branch early-outs on the state it
## already holds, so the common case (a held stick, a key repeat, a stream of pad axis noise) costs
## one class check and one boolean compare.
##
## [b][InputEventMouseMotion] is deliberately NOT tracked.[/b] It arrives per mouse-move sample, and
## treating it as a device switch means a bumped desk, or a cursor left under a pad player's hand,
## relabels every prompt on screen mid-gesture. A mouse BUTTON is an unambiguous statement of intent
## and is tracked; moving the pointer is not.
##
## What reaches here at all is the dispatch-order contract in the class doc, and it is the OWNER's
## job: nothing below decides whether this method runs.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		_set_pad_active(true)
		return
	if event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) < AXIS_DEADZONE:
			return
		_set_pad_active(true)
		return
	if event is InputEventKey or event is InputEventMouseButton:
		_set_pad_active(false)


func _set_pad_active(pad: bool) -> void:
	if _pad_active == pad:
		return
	_pad_active = pad
	device_class_changed.emit(pad)


# --- Labels -------------------------------------------------------------------

## True for the event classes a joypad produces. The ONE place the device-class split is decided, so
## "is this a pad prompt" has a single answer for the tracker, [method action_label] and any caller
## sorting a binding list.
static func is_pad_event(event: InputEvent) -> bool:
	return event is InputEventJoypadButton or event is InputEventJoypadMotion


## A human label for one event, or [code]""[/code] for a class this vocabulary cannot describe.
##
## [b]The one spelling.[/b] Every place MenuKit prints an event — the rebind row's binding text, its
## conflict dialog body, a host's prompt — goes through here, so a key can never read as "Escape" in
## one place and "Esc" two lines below it.
##
## The empty return is also the set the persisted binding format cannot carry, so an event that
## answers "" here can never have come out of the settings store.
static func event_label(event: InputEvent) -> String:
	if event is InputEventKey:
		return key_label(event as InputEventKey)
	if event is InputEventMouseButton:
		return mouse_button_label(int((event as InputEventMouseButton).button_index))
	if event is InputEventJoypadButton:
		return joypad_button_label(int((event as InputEventJoypadButton).button_index))
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return "Axis %d %s" % [int(motion.axis), "+" if motion.axis_value >= 0.0 else "-"]
	return ""


## Bindings are stored by PHYSICAL keycode so they stay under the same finger on an AZERTY layout —
## but a physical code is a POSITION, and printing it raw would label the AZERTY player's key by its
## QWERTY name. [method DisplayServer.keyboard_get_keycode_from_physical] maps the position back
## through the ACTIVE layout, which is what the player sees on the keycap.
##
## Two fallbacks to the plain keycode, both reachable: a synthetic event carries physical_keycode 0
## (nothing to map), and the mapping itself answers 0 on drivers with no layout information.
##
## The headless driver is skipped BEFORE the call, not diagnosed after it: there,
## [method DisplayServer.keyboard_get_keycode_from_physical] both answers 0 and prints an engine
## ERROR line per call. With no layout to consult the physical code IS the best available name —
## [method OS.get_keycode_string] reads it as the QWERTY position, which for a headless run is a log
## label rather than a keycap.
static func key_label(key: InputEventKey) -> String:
	if key == null:
		return ""
	var physical := int(key.physical_keycode)
	if physical != 0 and DisplayServer.get_name() != "headless":
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(physical as Key)
		if int(mapped) != 0:
			return OS.get_keycode_string(mapped)
	if physical != 0:
		return OS.get_keycode_string(physical as Key)
	return OS.get_keycode_string(int(key.keycode) as Key)


## The three buttons every mouse has get their names; the rest are numbered. "Mouse 4" is what a
## player with a side button expects to read, and Godot's own enum names for them (WHEEL_UP,
## XBUTTON1) are not.
static func mouse_button_label(index: int) -> String:
	match index:
		MOUSE_BUTTON_LEFT:
			return "Mouse Left"
		MOUSE_BUTTON_RIGHT:
			return "Mouse Right"
		MOUSE_BUTTON_MIDDLE:
			return "Mouse Middle"
	return "Mouse %d" % index


## [method Input.get_joy_button_string] is asked first because it can name the button by the
## CONNECTED pad's own legend ("Cross" rather than "A"). It is reached through
## [method Object.has_method] as a capability probe: its availability across 4.x builds is not
## something this addon controls, and a missing one must degrade rather than take the page down.
##
## The fallback is [constant JOY_BUTTON_NAMES] (SDL positions, see that constant), and only past its
## end does a button become a number.
static func joypad_button_label(index: int) -> String:
	if Input.has_method("get_joy_button_string"):
		var named: Variant = Input.call("get_joy_button_string", index)
		if named is String and not (named as String).is_empty():
			return named as String
	if JOY_BUTTON_NAMES.has(index):
		return JOY_BUTTON_NAMES[index]
	return "Pad %d" % index


## The label for [param action]'s binding on the preferred device class, falling back to the other
## class, then [code]""[/code] when the action is unbound or undefined.
##
## [b]Fallback rather than silence.[/b] A prompt that disappears because the player picked up a
## controller for an action nobody bound to a pad is worse than a keyboard prompt on a pad session:
## the keyboard binding is still true, and still the only way to perform the action.
##
## FIRST match, not a joined list: this answers "what do I print in a sentence" ("%s to cancel"),
## which is one glyph by definition. [code]MKRebindRow[/code] prints the whole list instead, through
## [method event_label] per event, because a binding EDITOR must show everything it is about to
## replace.
##
## Read off [InputMap] — the live, post-override truth an actual press is matched against — because
## a prompt describes what pressing something will do right now. A settings row asks the STORE
## instead; the two agree once apply has run, and only the store survives a restart.
static func action_label(action: StringName, prefer_pad: bool) -> String:
	if action == &"" or not InputMap.has_action(action):
		return ""
	var fallback := ""
	for event in InputMap.action_get_events(action):
		var text := event_label(event)
		if text.is_empty():
			continue
		if is_pad_event(event) == prefer_pad:
			return text
		if fallback.is_empty():
			fallback = text
	return fallback
