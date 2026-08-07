extends MKTest
## The device-aware prompt vocabulary: [MKInputGlyphs]'s static spellings, its device tracker, and
## the one consumer wired to it — [MKRebindRow]'s abort hint through [MKSettingsPanel].
##
## [b]The statics are asserted against LITERAL strings, not against a re-derivation.[/b] A test that
## computed "what should this key be called" the way the implementation does would agree with any
## implementation, including a broken one; the point of a single spelling is that the string itself is
## the contract, so the string is what is written down here.
##
## [b]The tracker is driven by real events through the root viewport[/b], never by calling
## [code]_input[/code]: its defining properties are that it SEES what the engine dispatches and that it
## does not consume it, and only a real push can observe either.
##
## [b]Headless boundary.[/b] [method DisplayServer.keyboard_get_keycode_from_physical] is dead under
## the dummy driver AND prints an engine ERROR per call, so [method MKInputGlyphs.key_label] skips it
## by design and the labels below are QWERTY position names. That guard is not asserted by a check()
## here because it cannot be: the failure mode is engine NOISE, which the sweep's own gate catches —
## deleting the headless guard turns this suite red as ENGINE_ERRORS rather than as a failed assertion.
## Layout is likewise only half-visible: the geometry section pins the size flags and the column
## constants (the mechanism), while what those pixels look like stays a capture question.
##
## [b][method Input.get_joy_button_string] does not exist on 4.7[/b] — measured, see
## [method _test_joypad_labels]. Every pad label below therefore comes from the
## [constant MKInputGlyphs.JOY_BUTTON_NAMES] fallback, which is the branch that actually ships today.

const PATH := "user://test_input_glyphs.json"
const SERVICE_NAME := "MKSettingsService"

## Synthetic actions, so nothing here reads the demo project's own bindings — and so the two-binding
## action the prefer_pad rule needs is authored rather than hoped for.
const ACTION_BOTH := &"mk_glyph_both"
const ACTION_KEY := &"mk_glyph_key"
const ACTION_PAD := &"mk_glyph_pad"
## Three bindings, none of them a pad one: the shape that makes "the fallback is the FIRST match" a
## falsifiable claim. Two would only distinguish first from last; three also rules out "the middle
## one", and the three keys are deliberately distinct so the assertion names a specific keycap.
const ACTION_TRIPLE := &"mk_glyph_triple"
const ACTION_ROW := &"mk_glyph_row"
const ID_ROW := &"input/mk_glyph_row"
const ACTION_ROW_B := &"mk_glyph_row_b"
const ID_ROW_B := &"input/mk_glyph_row_b"
const ID_TOGGLE := &"mk_glyph_toggle"

var _ui_cancel_stock: Array[InputEvent] = []
## Counter for [signal MKInputGlyphs.device_class_changed]. A MEMBER rather than a local captured by
## the connected lambda: GDScript closures capture locals BY VALUE, so a local counter incremented
## inside the handler is a copy this test would never see, and the assertion would read zero forever
## no matter what the tracker did.
var _flips: Array = []


func run_tests() -> void:
	var parked := _park_autoload()
	_clean()
	_seed_actions()
	_install_pad_cancel()

	_test_key_labels()
	_test_mouse_labels()
	_test_joypad_labels()
	_test_axis_labels()
	_test_unknown_event_classes_have_no_label()
	_test_action_label_prefers_a_device_and_falls_back()

	await _test_the_tracker_follows_the_device_in_use()
	await _test_the_tracker_never_consumes_the_event_it_watched()

	await _test_the_panel_owns_one_tracker_that_survives_a_rebuild()
	await _test_a_panel_with_no_keybind_rows_mounts_no_tracker()
	await _test_a_consumed_capture_event_still_reaches_the_tracker()
	await _test_the_capture_hint_names_the_device_in_use()
	await _test_a_row_with_no_tracker_keeps_the_keyboard_prose()
	await _test_the_row_geometry_is_a_column()

	_restore_ui_cancel()
	_teardown_actions()
	_clean()
	_restore_autoload(parked)


# --- 1. The static vocabulary ---------------------------------------------------

## A key event carrying both codes (real hardware on QWERTY), a PHYSICAL-only one (what a fresh
## capture produces) and a KEYCODE-only one (what `project.godot` and the engine's `ui_*` defaults
## author). All three must produce a name; the keycode-only fallback is the one that would silently
## start printing blanks if the last `return` were dropped, because every other test in the repo
## builds events with a physical code.
func _test_key_labels() -> void:
	var both := InputEventKey.new()
	both.physical_keycode = KEY_ESCAPE
	both.keycode = KEY_ESCAPE
	check_eq(MKInputGlyphs.event_label(both), "Escape",
		"a key event is spelled by its keycap name, not by its number")

	var physical_only := InputEventKey.new()
	physical_only.physical_keycode = KEY_A
	check_eq(MKInputGlyphs.event_label(physical_only), "A",
		"a physical-only event (the shape a capture stores) still gets a name — headless there is no layout to map through, so the physical position IS the label")

	var keycode_only := InputEventKey.new()
	keycode_only.keycode = KEY_B
	check_eq(MKInputGlyphs.event_label(keycode_only), "B",
		"and a keycode-only event (the shape project.godot authors) falls all the way through to the plain keycode rather than reading as an unbound row")

	check_eq(MKInputGlyphs.key_label(null), "",
		"a null key is answered, not crashed on — event_label's callers hand this straight to a Label")


func _test_mouse_labels() -> void:
	check_eq(MKInputGlyphs.event_label(_mouse(MOUSE_BUTTON_LEFT)), "Mouse Left",
		"the three buttons every mouse has are named")
	check_eq(MKInputGlyphs.event_label(_mouse(MOUSE_BUTTON_RIGHT)), "Mouse Right", "right")
	check_eq(MKInputGlyphs.event_label(_mouse(MOUSE_BUTTON_MIDDLE)), "Mouse Middle", "middle")
	check_eq(MKInputGlyphs.event_label(_mouse(MOUSE_BUTTON_XBUTTON1)), "Mouse 8",
		"and a side button is NUMBERED — the engine's own enum name (XBUTTON1) is not what a player calls it")


## [b]Measured, not assumed: [method Input.get_joy_button_string] does not exist on Godot 4.7[/b], so
## the capability probe in [method MKInputGlyphs.joypad_button_label] takes its fallback on every
## shipped build today. The probe is still correct as written (a future engine may restore it), but
## the branch a player actually sees is [constant MKInputGlyphs.JOY_BUTTON_NAMES] — which is why this
## test asserts the SDL-position names literally and records the measurement beside them.
func _test_joypad_labels() -> void:
	check(not Input.has_method("get_joy_button_string"),
		"measurement, pinned so a future engine restoring this API is noticed here rather than by a silently changed prompt: 4.7 has no Input.get_joy_button_string")

	check_eq(MKInputGlyphs.event_label(_pad(JOY_BUTTON_B)), "B",
		"the bottom-right face button reads as its SDL position name")
	check_eq(MKInputGlyphs.event_label(_pad(JOY_BUTTON_A)), "A", "and the bottom one")
	check_eq(MKInputGlyphs.joypad_button_label(JOY_BUTTON_LEFT_SHOULDER), "Left Shoulder",
		"shoulders are spelled out rather than abbreviated")
	check_eq(MKInputGlyphs.joypad_button_label(JOY_BUTTON_DPAD_UP), "D-Pad Up", "and d-pad directions")
	check_eq(MKInputGlyphs.joypad_button_label(99), "Pad 99",
		"past the table's end a button becomes a number rather than a blank")


func _test_axis_labels() -> void:
	check_eq(MKInputGlyphs.event_label(_axis(1, -1.0)), "Axis 1 -",
		"an axis carries its DIRECTION — the two halves of one stick are two different bindings")
	check_eq(MKInputGlyphs.event_label(_axis(0, 0.75)), "Axis 0 +", "and the positive half says so")
	check_eq(MKInputGlyphs.event_label(_axis(2, 0.0)), "Axis 2 +",
		"zero reads as positive: the label is a sign, and a stored binding is never zero-valued")


## The empty string is a contract, not a shrug: it is exactly the set the persisted binding format
## cannot carry, so [MKRebindRow] uses it to SKIP an event rather than printing a placeholder.
func _test_unknown_event_classes_have_no_label() -> void:
	check_eq(MKInputGlyphs.event_label(InputEventMouseMotion.new()), "",
		"a class this vocabulary cannot describe answers '' rather than inventing a name")
	check_eq(MKInputGlyphs.event_label(InputEventAction.new()), "",
		"including InputEventAction, which several tests push and no store can hold")

	check(MKInputGlyphs.is_pad_event(_pad(JOY_BUTTON_A)), "a pad button is a pad event")
	check(MKInputGlyphs.is_pad_event(_axis(0, 1.0)), "so is a stick")
	check(not MKInputGlyphs.is_pad_event(InputEventKey.new()), "a key is not")
	check(not MKInputGlyphs.is_pad_event(_mouse(MOUSE_BUTTON_LEFT)), "and neither is a mouse button")


## [b]Both directions from the SAME two-binding action[/b], because "prefers the pad" passes just as
## well against a function that always returns the pad binding — which would print a pad glyph to a
## keyboard player. The fallback halves are asserted from single-binding actions, where the preferred
## class does not exist at all: a prompt that vanished because the player picked up a controller is
## worse than a keyboard prompt, since the keyboard binding is still the only way to do the thing.
func _test_action_label_prefers_a_device_and_falls_back() -> void:
	check_eq(MKInputGlyphs.action_label(ACTION_BOTH, true), "A",
		"prefer_pad picks the PAD binding of a two-binding action")
	check_eq(MKInputGlyphs.action_label(ACTION_BOTH, false), "G",
		"and the mirror picks the keyboard one — the same action, so this cannot be a constant")

	check_eq(MKInputGlyphs.action_label(ACTION_KEY, true), "G",
		"a keyboard-only action still answers a pad session, with the binding that actually works")
	check_eq(MKInputGlyphs.action_label(ACTION_PAD, false), "A",
		"and a pad-only action answers a keyboard session the same way")

	# The fallback is the FIRST usable non-preferred binding, not the last one and not the last one
	# standing. Both single-binding actions above are silent on that — with one candidate every
	# selection rule agrees — so the claim is made against an action carrying three, none of them of
	# the preferred class. It is a sentence glyph ("%s to cancel"), and the first binding is the one a
	# project author wrote down first.
	check_eq(MKInputGlyphs.action_label(ACTION_TRIPLE, true), "G",
		"with three non-pad bindings to choose from, a pad session falls back to the FIRST — 'last wins' would print the same action's third keycap")

	check_eq(MKInputGlyphs.action_label(&"", true), "",
		"the empty action is '' — a host asking about an unconfigured slot gets no prompt rather than a crash")
	check_eq(MKInputGlyphs.action_label(&"mk_glyph_no_such_action", true), "",
		"and so is an action InputMap has never heard of")

	InputMap.add_action(&"mk_glyph_empty")
	check_eq(MKInputGlyphs.action_label(&"mk_glyph_empty", true), "",
		"a DEFINED but unbound action answers '' too — there is nothing to press")
	InputMap.erase_action(&"mk_glyph_empty")


# --- 2. The device tracker ------------------------------------------------------

## Every flip driven by a REAL event through the root viewport, and the SIGNAL counted at each step —
## the tracker's contract is "flips, and says so once", and a state-only test passes against one that
## emits on every event (re-rendering every prompt on screen per key repeat).
func _test_the_tracker_follows_the_device_in_use() -> void:
	var glyphs := MKInputGlyphs.new()
	get_root().add_child(glyphs)
	_flips = []
	glyphs.device_class_changed.connect(func(pad: bool) -> void: _flips.append(pad))
	await step_frame()

	check(glyphs.is_processing_input(),
		"the tracker processes input after _ready — restated there because the engine re-enables it at NOTIFICATION_READY for any script overriding _input, so a future 'disable when idle' written before tree entry would be silently undone and this is the only assertion that would notice")
	check_eq(glyphs.process_mode, Node.PROCESS_MODE_ALWAYS,
		"and runs while the tree is paused — a pause menu's prompts must name the device that opened it")

	check(not glyphs.is_pad_active(),
		"it starts on keyboard/mouse: a menu is reachable before any event exists, and the cursor is on screen at that moment")

	_push(_key(KEY_G))
	await step_frame()
	check(not glyphs.is_pad_active(), "a key press keeps it there")
	check_eq(_flips.size(), 0, "and emits nothing — the class did not change")

	_push(_pad(JOY_BUTTON_A, true))
	await step_frame()
	check(glyphs.is_pad_active(), "a pad button flips it to pad")
	check_eq(_flips.size(), 1, "with exactly one signal")
	check_eq(_flips[-1], true, "carrying the new class")

	_push(_pad(JOY_BUTTON_B, true))
	await step_frame()
	check(glyphs.is_pad_active(), "a SECOND pad press changes nothing")
	check_eq(_flips.size(), 1,
		"and emits nothing — a player holding a pad would otherwise re-render every prompt on screen per event")

	_push(_axis(0, 0.2))
	await step_frame()
	check(glyphs.is_pad_active(), "precondition for the deadzone pair: still pad")
	_push(_key(KEY_G))
	await step_frame()
	check(not glyphs.is_pad_active(), "a key press flips back")
	check_eq(_flips.size(), 2, "second signal")

	_push(_axis(0, 0.4))
	await step_frame()
	check(not glyphs.is_pad_active(),
		"a stick UNDER the deadzone does not flip it — a pad resting on a desk emits continuously around zero, and without the gate it would hold the tracker in pad state forever and flap it against every keystroke")
	check_eq(_flips.size(), 2, "and emits nothing")

	_push(_axis(0, MKInputGlyphs.AXIS_DEADZONE))
	await step_frame()
	check(glyphs.is_pad_active(),
		"AT the deadzone is a gesture: the gate is absf() < AXIS_DEADZONE, so the boundary value counts as use")
	check_eq(_flips.size(), 3, "third signal")

	_push(_axis(1, -0.9))
	await step_frame()
	check(glyphs.is_pad_active(), "a NEGATIVE deflection is magnitude-tested, not sign-tested")
	check_eq(_flips.size(), 3, "and is still the same class, so still silent")

	_push(InputEventMouseMotion.new())
	await step_frame()
	check(glyphs.is_pad_active(),
		"mouse MOTION is deliberately not a device statement — a bumped desk under a pad player's hand must not relabel every prompt mid-gesture")
	check_eq(_flips.size(), 3, "so nothing is emitted for it")

	_push(_mouse(MOUSE_BUTTON_LEFT, true))
	await step_frame()
	check(not glyphs.is_pad_active(),
		"a mouse BUTTON is an unambiguous statement of intent and does flip it back")
	check_eq(_flips.size(), 4, "fourth signal")

	glyphs.queue_free()
	await step_frame()


## [b]Observing must not consume.[/b] The tracker sits above a listening [MKRebindRow] in dispatch
## order, so a tracker that marked input handled would make merely MOUNTING one break the capture it
## was written to serve.
##
## [b]The handled FLAG is the assertion with teeth[/b] — measured: adding a
## [method Viewport.set_input_as_handled] to the tracker turns the two flag checks red and leaves the
## sibling counter green, because [method Node._input] dispatch had already reached a sibling added
## after the tracker by the time the flag was set. The sibling is kept anyway, as the statement of the
## consequence that matters (something below still hears the event), but it is not what would catch a
## regression on its own and this comment says so rather than implying two independent proofs.
func _test_the_tracker_never_consumes_the_event_it_watched() -> void:
	var glyphs := MKInputGlyphs.new()
	get_root().add_child(glyphs)
	var spy := InputSpy.new()
	get_root().add_child(spy)
	await step_frame()

	var handled := _push(_pad(JOY_BUTTON_A, true))
	await step_frame()
	check(glyphs.is_pad_active(), "precondition: the tracker did see the event")
	check(not handled,
		"and the viewport is NOT left holding a handled flag — marking would swallow the press of every node below it, MKRebindRow's capture first")
	check_eq(spy.seen, 1,
		"a sibling still receives the same event, which is the consequence that actually matters")

	handled = _push(_key(KEY_G))
	await step_frame()
	check(not handled, "same for a key press")
	check_eq(spy.seen, 2, "which also still reaches the sibling")

	glyphs.queue_free()
	spy.queue_free()
	await step_frame()


# --- 3. The hint swap -----------------------------------------------------------

## [b]One tracker per PANEL, and it must outlive a rebuild.[/b] Counted BY TYPE across the panel's
## whole subtree rather than by node name, so a second tracker parented anywhere is caught; and the
## rebuild half is the load-bearing one — a tracker rebuilt with the rows would reset to its keyboard
## default, silently relabelling a pad player's prompts every time the page refreshed.
func _test_the_panel_owns_one_tracker_that_survives_a_rebuild() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [
		_keybind(ID_ROW, ACTION_ROW, "Row A"),
		_keybind(ID_ROW_B, ACTION_ROW_B, "Row B"),
	])

	check_eq(_tracker_count(panel), 1,
		"two keybind rows share ONE MKInputGlyphs — seven rows each running their own _input would be seven dispatches per event to answer one question they all ask")
	var tracker := _tracker(panel)
	check(tracker != null, "and it is reachable")
	if tracker == null:
		await _drop(panel, backend)
		return

	_push(_pad(JOY_BUTTON_B, true))
	await step_frame()
	check(tracker.is_pad_active(), "precondition: the session is pad-active")

	var id_before := tracker.get_instance_id()
	panel.rebuild()
	await step_frame()
	await step_frame()

	check_eq(_tracker_count(panel), 1, "a rebuild does not add a second tracker")
	var after := _tracker(panel)
	check(after != null and after.get_instance_id() == id_before,
		"and it is the SAME instance — _clear frees the tab strip, not the tracker")
	if after != null:
		check(after.is_pad_active(),
			"so the pad session survives the rebuild: a fresh tracker would read keyboard and every prompt on the page would silently change device")
		check_eq(_hint_text(panel, ID_ROW), "B to cancel",
			"and the freshly built rows are handed the surviving tracker, not left on the default prose")

	await _drop(panel, backend)


## [b]The tracker is LAZY, and staying lazy is the claim.[/b] [method
## MKSettingsPanel._ensure_input_glyphs] says a panel with no KEYBIND rows mounts no input handler at
## all — which is every one of the addon's four shipped pages. An unconditional mount would put a
## [method Node._input] handler under every settings page in every host and be invisible to every
## other assertion in this suite, because a tracker that exists and is correct is exactly what the
## rest of the file asserts. Counted by TYPE, and BOTH before and after a rebuild: the placement rule
## runs at the end of every build and must not be the thing that summons one.
func _test_a_panel_with_no_keybind_rows_mounts_no_tracker() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_toggle(ID_TOGGLE, "A toggle")])

	check_eq(_tracker_count(panel), 0,
		"a panel built from rows that ask no device question mounts no MKInputGlyphs")

	panel.rebuild()
	await step_frame()
	await step_frame()
	check_eq(_tracker_count(panel), 0, "and a rebuild does not conjure one either")

	await _drop(panel, backend)


## [b]The dispatch-order contract, driven through a REAL capture.[/b] A listening [MKRebindRow]
## consumes every event class it inspects ([method Viewport.set_input_as_handled]), and — measured on
## 4.7 — that stops every [method Node._input] consumer which has not run yet for that same event.
## The tracker must therefore be the panel's LAST child, since [method Node._input] walks children in
## REVERSE order. [method MKSettingsPanel._place_input_glyphs_last] is what guarantees it.
##
## [b]The rebuilt panel is the half with teeth.[/b] A first build creates the tracker mid-build, after
## the tab strip, so it lands last by accident and this test passes without the rule existing at all.
## [method MKSettingsPanel._clear] then keeps the tracker and frees the tab strip, and the next
## rebuild re-adds "Pages" BELOW it — inverting the order and blinding the tracker to exactly the
## events this asserts about. Both halves are driven, in that order, against the same panel.
##
## The event is joypad B, which is the direction that matters: it is the RESERVED event, so the row
## refuses it and ends the capture, and the player's hands are now on a pad. If the tracker missed it
## the hint would go on naming Escape to someone holding a controller.
func _test_a_consumed_capture_event_still_reaches_the_tracker() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_ROW, ACTION_ROW, "Row A")])

	await _capture_a_reserved_pad_press(panel, "on a freshly built panel")

	panel.rebuild()
	await step_frame()
	await step_frame()
	await _capture_a_reserved_pad_press(panel, "and after rebuild(), where the tab strip is re-added below the surviving tracker")

	await _drop(panel, backend)


## One full capture gesture: focus the binding button, start listening with a real [code]ui_accept[/code],
## push joypad B, and assert that the row consumed it AND that the tracker saw it anyway.
func _capture_a_reserved_pad_press(panel: MKSettingsPanel, phase: String) -> void:
	var row := _row(panel, ID_ROW)
	check(row != null, "%s: the rebind row is there to capture with" % phase)
	if row == null:
		return
	var tracker := _tracker(panel)
	check(tracker != null, "%s: and the panel's tracker is reachable" % phase)
	if tracker == null:
		return

	var binding := row.get_node_or_null("Binding") as Button
	check(binding != null, "%s: the binding button is there to press" % phase)
	if binding == null:
		return
	await _activate(binding)
	check(row.is_listening(), "%s: a real ui_accept on the focused binding button starts the capture" % phase)
	check(not tracker.is_pad_active(),
		"%s: precondition — that keystroke put the tracker on keyboard, so the flip below is a flip" % phase)
	check_eq(_hint_text(panel, ID_ROW), MKRebindRow.HINT_KEYBOARD,
		"%s: precondition — the hint is the keyboard prose" % phase)

	var handled := _push(_pad(JOY_BUTTON_B, true))
	await step_frame()

	check(handled,
		"%s: the listening row CONSUMED the pad press — without this the rest is not a test of consumed events at all" % phase)
	check(tracker.is_pad_active(),
		"%s: and the tracker flipped to pad anyway, which only happens if it was dispatched BEFORE the row consumed it" % phase)
	check_eq(_hint_text(panel, ID_ROW), "B to cancel",
		"%s: so the hint names the pad's own way out, on the very press that changed the device in hand" % phase)
	check_eq(_caption_text(row), MKRebindRow.CAPTION_RESERVED,
		"%s: and the row still did its own job — B is refused as reserved" % phase)
	check(not row.is_listening(), "%s: and that refusal ended the capture" % phase)

	# Back to keyboard, so the next phase starts from the same place this one did.
	_push(_key(KEY_G))
	await step_frame()


## [b]The hint names the gesture that actually aborts on the device in hand.[/b] A controller player
## told "Esc to cancel" is being pointed at a key their hands are not on, and the pad's own way out
## goes unnamed. The pad string is derived from the RESERVED list — the same list the refusal path
## matches against — so a hint can never promise an abort that would not happen.
func _test_the_capture_hint_names_the_device_in_use() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_ROW, ACTION_ROW, "Row A")])

	check_eq(_hint_text(panel, ID_ROW), MKRebindRow.HINT_KEYBOARD,
		"a fresh panel shows the keyboard prose — the tracker starts on keyboard/mouse")

	_push(_pad(JOY_BUTTON_B, true))
	await step_frame()
	check_eq(_hint_text(panel, ID_ROW), "B to cancel",
		"a pad-active session names the reserved joypad button, spelled through the same MKInputGlyphs vocabulary the binding text uses")

	_push(_key(KEY_G))
	await step_frame()
	check_eq(_hint_text(panel, ID_ROW), MKRebindRow.HINT_KEYBOARD,
		"and a keystroke puts the keyboard prose back — the swap is a flip, not a one-way latch")

	# The hint is repainted while HIDDEN, which is what makes it correct on the frame begin_listen
	# shows it: a device flip DURING a capture (the player putting the keyboard down mid-prompt) has to
	# land too, and computing the text only at capture start would show the other device's key.
	var row := _row(panel, ID_ROW)
	check(row != null and not _hint_label(row).visible,
		"precondition: the assertions above were made against a HIDDEN label, repainted eagerly rather than at capture start")

	await _drop(panel, backend)


## [b]The degrade contract.[/b] A row with no tracker falls back to the keyboard prose — a host
## embedding [MKRebindRow] outside [MKSettingsPanel] passes nothing, and the same
## path answers a pad-active session whose reserved list carries no pad button, which is exactly the
## configuration where the pad abort would not work either.
func _test_a_row_with_no_tracker_keeps_the_keyboard_prose() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_ROW, ACTION_ROW, "Row A")])
	var row := _row(panel, ID_ROW)
	if row == null:
		await _drop(panel, backend)
		return

	_push(_pad(JOY_BUTTON_B, true))
	await step_frame()
	check_eq(_hint_text(panel, ID_ROW), "B to cancel", "precondition: the row is following the pad")

	row.set_input_glyphs(null)
	await step_frame()
	check_eq(_hint_text(panel, ID_ROW), MKRebindRow.HINT_KEYBOARD,
		"dropping the tracker reverts to the keyboard prose immediately, even mid-pad-session")
	check_eq(MKRebindRow.HINT_KEYBOARD, "Esc to cancel",
		"and that prose is Phase 4's string unchanged")

	# Re-pointing at the live tracker must pick up its CURRENT state, not wait for the next flip: the
	# signal only fires on a change, so a row that only listened would show keyboard prose to a pad
	# player until they put the pad down.
	row.set_input_glyphs(_tracker(panel))
	await step_frame()
	check_eq(_hint_text(panel, ID_ROW), "B to cancel",
		"and re-pointing the row at the tracker reads its current state rather than waiting for the next flip")

	await _drop(panel, backend)


## [b]Layout pinned at the MECHANISM, because the pixels were pinned by a capture.[/b] Two columns are
## at stake and both are size-flag decisions rather than widths: an EXPANDing label is not a column at
## all (an HBox splits LEFTOVER width between expanding children, so the label's final width — and
## therefore where the control column starts — moves with the minimum widths of everything else on the
## line, which differ per row type), and a binding button that absorbed leftover space would put the
## Reset button at a different x on every row.
func _test_the_row_geometry_is_a_column() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [
		_keybind(ID_ROW, ACTION_ROW, "Row A"),
		_keybind(ID_ROW_B, ACTION_ROW_B, "Row B"),
		_toggle(ID_TOGGLE, "A toggle"),
	])

	var xs: Array[float] = []
	for id in [ID_ROW, ID_ROW_B]:
		var row := _row(panel, id)
		if row == null:
			continue
		var binding := row.get_node_or_null("Binding") as Button
		check(binding != null, "the row has a binding button")
		if binding == null:
			continue
		check_eq(binding.custom_minimum_size.x, MKRebindRow.BINDING_COLUMN_WIDTH,
			"every binding button reserves the same column width, so 'W' and 'Mouse Middle' do not produce two different right edges")
		check_eq(binding.size_flags_horizontal, Control.SIZE_SHRINK_BEGIN,
			"and SHRINK_BEGIN, so it is exactly that wide rather than absorbing the row's leftover space")
		xs.append(binding.size.x)

		var label := row.get_node_or_null("RowLabel") as Label
		check(label != null, "and a label")
		if label != null:
			check_eq(label.size_flags_horizontal, Control.SIZE_FILL,
				"whose flags are FILL, never EXPAND_FILL — an expanding label is a share of leftover width, not a column, and a keybind row carries three more children than a toggle row so its label came out narrower")
			check_eq(label.custom_minimum_size.x, MKRebindRow.LABEL_COLUMN_WIDTH,
				"at the shared label column width")

	if xs.size() == 2:
		check_eq(xs[0], xs[1], "so two binding buttons with different text are the same width")

	# The toggle row is wrapped by the PANEL, not by the row script — the same correction, in the other
	# file, and the two must agree or the keybind page and the gameplay page are two different tables.
	var wrapped := panel._controls.get(ID_TOGGLE, null) as Control
	check(wrapped != null, "the toggle row built")
	if wrapped != null:
		var wrap_label := _first_label(wrapped.get_parent())
		check(wrap_label != null, "and MKSettingsPanel._wrap gave it a label")
		if wrap_label != null:
			check_eq(wrap_label.size_flags_horizontal, Control.SIZE_FILL,
				"which is FILL for the same reason the row's is — this is the mechanism behind the measured slider/enum column drift")
			check_eq(wrap_label.custom_minimum_size.x, MKSettingsPanel.LABEL_COLUMN_WIDTH,
				"and carries the panel's label column width unconditionally")

	await _drop(panel, backend)


# --- Fixtures -------------------------------------------------------------------

func _seed_actions() -> void:
	for action in [ACTION_BOTH, ACTION_KEY, ACTION_PAD, ACTION_TRIPLE, ACTION_ROW, ACTION_ROW_B]:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_G
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_A
	# Keyboard FIRST on the two-binding action, so "prefers the pad" cannot pass by simply returning
	# the first event in the list.
	InputMap.action_add_event(ACTION_BOTH, key)
	InputMap.action_add_event(ACTION_BOTH, pad)
	InputMap.action_add_event(ACTION_KEY, key)
	InputMap.action_add_event(ACTION_PAD, pad)
	# Keyboard-only and THREE deep, in a fixed order, for the fallback half of action_label.
	for physical in [KEY_G, KEY_H, KEY_J]:
		var triple_key := InputEventKey.new()
		triple_key.physical_keycode = physical as Key
		InputMap.action_add_event(ACTION_TRIPLE, triple_key)
	var row_key := InputEventKey.new()
	row_key.physical_keycode = KEY_H
	InputMap.action_add_event(ACTION_ROW, row_key)
	var row_key_b := InputEventKey.new()
	row_key_b.physical_keycode = KEY_J
	InputMap.action_add_event(ACTION_ROW_B, row_key_b)


## Erased at the end of the run, because [InputMap] is process-wide: an action left behind would be
## inherited by whatever ran next in the same process, and this suite's ACTION_BOTH carries a pad
## binding that would quietly change another suite's conflict scan.
func _teardown_actions() -> void:
	for action in [ACTION_BOTH, ACTION_KEY, ACTION_PAD, ACTION_TRIPLE, ACTION_ROW, ACTION_ROW_B]:
		if InputMap.has_action(action):
			InputMap.erase_action(action)


## The pad binding of [code]ui_cancel[/code] this demo project does not ship, installed for the
## duration of the run exactly as test_rebind does and for the same reason: the panel derives its
## reserved list from the BOOT SNAPSHOT of ui_cancel, so a project with no pad binding produces an
## empty list and the pad hint has nothing honest to name. Restored afterwards.
func _install_pad_cancel() -> void:
	_ui_cancel_stock = []
	for event in InputMap.action_get_events(&"ui_cancel"):
		_ui_cancel_stock.append(event)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_B
	InputMap.action_add_event(&"ui_cancel", pad)


func _restore_ui_cancel() -> void:
	InputMap.action_erase_events(&"ui_cancel")
	for event in _ui_cancel_stock:
		InputMap.action_add_event(&"ui_cancel", event)


func _make_backend() -> MKJsonSettingsBackend:
	_clean()
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": PATH})
	get_root().add_child(backend)
	# Before any override, so the reserved-event derivation reads the ui_cancel this suite installed.
	backend.snapshot_input_defaults()
	return backend


func _keybind(id: StringName, action: StringName, label: String) -> MKSettingDef:
	var def := MKSettingDef.new()
	def.id = id
	def.type = MKSettingDef.RowType.KEYBIND
	def.label = label
	def.action_name = action
	return def


func _toggle(id: StringName, label: String) -> MKSettingDef:
	var def := MKSettingDef.new()
	def.id = id
	def.type = MKSettingDef.RowType.TOGGLE
	def.label = label
	def.default_value = false
	return def


func _make_panel(backend: MKSettingsBackend, rows: Array) -> MKSettingsPanel:
	var page := MKSettingsPageDef.new()
	page.id = &"keys"
	page.title = "Keys"
	var typed_rows: Array[MKSettingDef] = []
	for row in rows:
		typed_rows.append(row)
	page.rows = typed_rows

	var panel := MKSettingsPanel.new()
	var pages: Array[MKSettingsPageDef] = [page]
	panel.pages = pages
	panel.bind_backend(backend)
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(1920, 1080)
	await step_frame()
	await step_frame()
	return panel


func _drop(panel: Node, backend: Node) -> void:
	if panel != null and is_instance_valid(panel):
		panel.queue_free()
	if backend != null and is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()


# --- Lookups --------------------------------------------------------------------

func _row(panel: MKSettingsPanel, id: StringName) -> MKRebindRow:
	return panel._controls.get(id, null) as MKRebindRow


func _hint_label(row: MKRebindRow) -> Label:
	return row.get_node_or_null("CancelHint") as Label


func _caption_text(row: MKRebindRow) -> String:
	var label := row.get_node_or_null("Caption") as Label
	return label.text if label != null else "<no caption label>"


func _hint_text(panel: MKSettingsPanel, id: StringName) -> String:
	var row := _row(panel, id)
	if row == null:
		return "<no row %s>" % id
	var label := _hint_label(row)
	return label.text if label != null else "<no hint label>"


## Counted by TYPE over the whole subtree, not by node name and not among direct children: a second
## tracker parented anywhere under the panel is the defect this asserts against.
func _tracker_count(panel: Node) -> int:
	var found := 0
	for node in _descendants(panel):
		if node is MKInputGlyphs:
			found += 1
	return found


func _tracker(panel: Node) -> MKInputGlyphs:
	for node in _descendants(panel):
		if node is MKInputGlyphs:
			return node as MKInputGlyphs
	return null


func _first_label(node: Node) -> Label:
	if node == null:
		return null
	for child in node.get_children():
		var label := child as Label
		if label != null:
			return label
	return null


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			out.append(child)
			stack.push_back(child)
	return out


# --- Input drivers --------------------------------------------------------------

func _key(physical: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = physical as Key
	event.keycode = physical as Key
	event.pressed = true
	return event


func _mouse(index: int, pressed := false) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index as MouseButton
	event.pressed = pressed
	return event


func _pad(index: int, pressed := false) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = index as JoyButton
	event.pressed = pressed
	return event


func _axis(axis: int, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.axis = axis as JoyAxis
	event.axis_value = value
	return event


## Pushes one event through the root viewport's real dispatch order and returns whether it came out
## marked handled. Returning the flag rather than a bare true is what keeps the consumption
## assertions from being tautologies.
func _push(event: InputEvent) -> bool:
	var viewport := get_root()
	viewport.push_input(event, true)
	return viewport.is_input_handled()


## Presses a button the way a keyboard/gamepad player does — focus, then a real [code]ui_accept[/code]
## press AND release through the viewport, so the engine's own GUI dispatch runs the activation.
## Emitting [signal BaseButton.pressed] directly would start a capture no player could start.
func _activate(button: Button) -> void:
	button.grab_focus()
	await step_frame()
	get_root().push_input(_key(KEY_ENTER), true)
	var release := _key(KEY_ENTER)
	release.pressed = false
	get_root().push_input(release, true)
	await step_frame()


## A plain [Node] that counts what reaches its [method Node._input]. Sits beside the tracker so
## "the tracker did not consume it" can be asserted as a consequence someone else observes, rather
## than only as a flag on the viewport.
class InputSpy extends Node:
	var seen := 0

	func _input(_event: InputEvent) -> void:
		seen += 1


# --- Housekeeping ---------------------------------------------------------------

func _park_autoload() -> Node:
	var service := get_root().get_node_or_null(SERVICE_NAME)
	if service == null:
		return null
	get_root().remove_child(service)
	return service


func _restore_autoload(service: Node) -> void:
	if service != null and is_instance_valid(service):
		get_root().add_child(service)


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
