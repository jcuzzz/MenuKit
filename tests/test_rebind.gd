extends MKTest
## Input rebinding: capture, refusal, conflict and reset (plan §4.4, Phase 4).
##
## The triangle this suite owns is [MKRebindRow] ↔ [MKSettingsPanel] ↔ [MKSettingsBackend] as driven
## by REAL [InputEvent]s. Nothing here calls the row's capture internals: every gesture is pushed at
## a [Viewport], because the row's defining behaviour is that it reads input in [method Node._input]
## and MARKS IT HANDLED — the consumption IS the contract. A test that called `_record()` directly
## would pass against a row that consumed nothing and let one Escape both abort a capture and pop the
## page underneath it, which is the exact defect the priority rule exists to prevent.
##
## The build contract for a KEYBIND row (it builds, it registers, an action-less def is skipped and
## named) belongs to test_settings_schema.gd's `_test_keybind_row_builds` and is deliberately not
## repeated here.
##
## [b]Headless boundary.[/b] [InputMap] is real under `--headless`, so every binding assertion
## observes genuine engine state. What is NOT observable here: the focus ring's legibility, the
## caption's on-screen placement, and the layout of the capture prompt — those are eyeball questions
## for the human pass on a real display. [method DisplayServer.keyboard_get_keycode_from_physical] is
## also dead headless (the row skips it deliberately), so the binding TEXT asserted below is the
## QWERTY position name; on a real AZERTY display it would read as the keycap, and that mapping is
## likewise a phase exit criterion rather than a test here.

const PATH := "user://test_rebind.json"

## Two synthetic actions, so nothing here depends on the demo project's own bindings — and so the
## multi-event stock list a single-slot capture replaces (and a Reset restores) is authored rather
## than inherited.
const ACTION_A := &"mk_rebind_a"
const ACTION_B := &"mk_rebind_b"

const ID_A := &"input/mk_rebind_a"
const ID_B := &"input/mk_rebind_b"

var _log: Array[String] = []
## [code]ui_cancel[/code] exactly as this project defines it, restored at the end of the run. See
## [method _install_pad_cancel].
var _ui_cancel_stock: Array[InputEvent] = []


func run_tests() -> void:
	# The project registers the real MKSettingsService autoload, and a settings panel resolves a
	# backend from it FIRST. Parked so every panel below is measured against the backend this suite
	# owns, on the file this suite owns.
	var parked := _park_autoload()
	_clean()
	_seed_actions()
	_install_pad_cancel()

	await _test_capture_happy_path()
	await _test_space_binds_with_a_warning_caption()
	await _test_joypad_b_is_refused_and_ends_the_capture()
	await _test_escape_aborts_the_capture_without_popping_the_page()
	await _test_mouse_cancel_rect_aborts_and_elsewhere_records()
	await _test_conflict_dialog_replace()
	await _test_conflict_dialog_keep_both()
	await _test_conflict_dialog_cancel()
	await _test_row_reset_restores_the_multi_event_stock_list()
	await _test_global_reset_restores_every_row()
	await _test_persistence_round_trip()
	await _test_a_stored_rebind_applies_with_no_panel_in_the_tree()
	await _test_axis_capture()
	await _test_only_one_row_listens_at_a_time()
	await _test_capture_times_out()
	await _test_apply_action_is_targeted()
	await _test_modifiers_are_stripped()

	_restore_ui_cancel()
	_teardown_actions()
	_clean()
	_restore_autoload(parked)


# --- 1. Capture -----------------------------------------------------------------

## The whole commit path in one gesture: a REAL activation starts the capture, a REAL key press ends
## it, and all four consequences are asserted — the store, the live [InputMap], the row's display and
## the Reset button that was disabled a moment ago.
##
## The consumption assertion is the load-bearing one: while listening the row must mark the key
## handled, or that same press also reaches GUI dispatch and [code]MKRoot._unhandled_input[/code].
func _test_capture_happy_path() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	check(row != null, "the KEYBIND row built")
	if row == null:
		await _drop(panel, backend)
		return

	check(not row.is_listening(), "an idle row is not listening")
	# Behaviour, not the `is_processing_input()` flag the row's own doc suggests: Godot re-enables
	# input processing at NOTIFICATION_READY for any script overriding `_input`, which lands AFTER the
	# row's own set_process_input(false) in `_build`. So an idle row IS dispatched (reported), and what
	# actually matters — that it takes no binding and eats no key — is what is asserted.
	var idle_handled := _push(_key(KEY_G))
	await step_frame()
	check(not idle_handled, "an idle row consumes nothing — the keyboard belongs to the rest of the shell")
	check(not _backend_has_override(backend, ACTION_A), "and an idle row binds nothing")
	check(_reset_button(row).disabled, "with Reset disabled: there is no override to undo yet")

	await _activate(_binding_button(row))
	check(row.is_listening(), "a real ui_accept on the focused binding button starts a capture")
	check(row.is_processing_input(), "and _input is armed for the duration")
	check_eq(_binding_button(row).text, MKRebindRow.LISTEN_TEXT, "the button shows the capture prompt")

	var handled := _push(_key(KEY_G))
	await step_frame()

	check(handled,
		"the capture press is CONSUMED — unconsumed it would also reach GUI dispatch and MKRoot's cancel ladder")
	_settle(row)

	var stored := backend.get_action_events(ACTION_A)
	check_eq(stored.size(), 1, "a capture REPLACES the whole event list — single slot")
	if stored.size() == 1 and stored[0] is InputEventKey:
		check_eq(int((stored[0] as InputEventKey).physical_keycode), KEY_G,
			"the store holds the captured key, by physical keycode")
	check(_action_has_physical(ACTION_A, KEY_G),
		"and the live InputMap carries it immediately — apply_action ran, so the key works without a restart")
	check(not _action_has_physical(ACTION_A, KEY_F),
		"replacing the stock binding rather than adding to it")
	check_eq(_binding_button(row).text, OS.get_keycode_string(KEY_G),
		"the row redraws to the new binding")
	check(not _reset_button(row).disabled,
		"and Reset is enabled now that there is an override to undo")

	await _drop(panel, backend)


## [b]Plan §4.4's named acceptance criterion: Space binds without complaint.[/b] Space rides
## [code]ui_accept[/code], so the row WARNS and commits rather than refusing — a player who wants
## Space on an in-game action is entitled to it, and is entitled to be told the menu also reacts.
## Asserted both ways: the binding landed AND the caption is the overlap one, not the refusal one.
func _test_space_binds_with_a_warning_caption() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	check(_event_is_bound_to(&"ui_accept", KEY_SPACE),
		"precondition: Space really is a ui_accept binding, which is what makes this the overlap case")

	await _activate(_binding_button(row))
	_push(_key(KEY_SPACE))
	await step_frame()
	_settle(row)

	check(_action_has_physical(ACTION_A, KEY_SPACE),
		"Space COMMITS — the overlap with menu navigation is a warning, never a refusal")
	var caption := _caption(row)
	check_eq(caption.text, MKRebindRow.CAPTION_UI_OVERLAP,
		"with the overlap caption shown, so the player is not surprised when Enter/Space also drives the menu")
	check(caption.visible, "and the caption is actually on screen")
	check(caption.text != MKRebindRow.CAPTION_RESERVED,
		"and it is NOT the reserved refusal — refusing Space is the behaviour this criterion forbids")

	await _drop(panel, backend)


## Joypad B is the one gesture that does two jobs: it is refused as reserved AND it ends the capture,
## because it is how a controller player expects to back out. There is no keyboard-Escape equivalent
## for them, which is why B — and only the NON-keyboard ui_cancel bindings — is on the reserved list.
##
## The reserved list is asserted through the panel's real derivation (boot-snapshot `ui_cancel`),
## not injected via extra_reserved_events: deriving it from the LIVE map instead would let a session
## that had already rebound something onto B take the menu-back button away.
func _test_joypad_b_is_refused_and_ends_the_capture() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	var reserved := panel._reserved_input_events()
	var has_pad_b := false
	for event in reserved:
		if event is InputEventJoypadButton \
				and int((event as InputEventJoypadButton).button_index) == JOY_BUTTON_B:
			has_pad_b = true
	check(has_pad_b,
		"the panel DERIVES joypad B as reserved from the boot-snapshot ui_cancel bindings — no host had to state it")
	check_eq(reserved.size(), _non_key_count(reserved),
		"and keyboard events are excluded from that list: Escape is unbindable by mechanism, not by blacklist")

	await _activate(_binding_button(row))
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_B
	pad.pressed = true
	var handled := _push(pad)
	await step_frame()

	check(handled, "the pad press is consumed like every other event the row inspects")
	check(not row.is_listening(),
		"and it ENDS the capture — one gesture doing both jobs, per the abort table")
	check(not _action_has_pad_button(ACTION_A, JOY_BUTTON_B),
		"the binding is unchanged: a reserved event never reaches the commit")
	check(_action_has_physical(ACTION_A, KEY_F), "the stock binding is still live")
	check_eq(_caption(row).text, MKRebindRow.CAPTION_RESERVED,
		"and the refusal explains itself — without the caption a pad player sees the prompt vanish for no stated reason")

	await _drop(panel, backend)


## [b]The priority rule, asserted where it actually matters (plan §4.4).[/b] A live capture reads
## input in `_input` and consumes it, so Escape aborts the capture and NOTHING ELSE — it must not
## also travel on to `MKRoot._unhandled_input` and pop the page the Controls rows are sitting on.
##
## Both rungs are exercised in one gesture sequence against a real [MKRoot] built from the demo
## config, because asserting only the abort passes against a row that consumes nothing.
func _test_escape_aborts_the_capture_without_popping_the_page() -> void:
	var config := ResourceLoader.load("res://demo/demo_config.tres") as MKConfig
	check(config != null, "demo config loads")
	if config == null:
		return
	var root := MKRoot.new()
	root.config = config.duplicate(true)
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()

	root.go_to_page(&"settings")
	root.push_page(&"sub")
	check_eq(root.get_back_depth(), 1, "precondition: a page is pushed, so Escape has something to pop")

	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")], root)
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		root.queue_free()
		await step_frame()
		return

	row.begin_listen()
	check(row.is_listening(), "precondition: a capture is live inside the shell")

	var handled := _push(_key(KEY_ESCAPE))
	await step_frame()
	check(handled, "Escape is consumed by the listening row")
	check(not row.is_listening(), "and aborts the capture")
	check(_action_has_physical(ACTION_A, KEY_F),
		"an abort NEVER writes — the stock binding is untouched")
	check(not _backend_has_override(backend, ACTION_A), "and no override was stored")
	check_eq(root.get_back_depth(), 1,
		"and the page stack did NOT pop — one Escape does one thing, which is the whole priority rule")
	check_eq(root.get_page_id(), &"sub", "the page under the row is exactly where it was")

	# The second Escape, with nothing listening, takes the next rung of the ladder.
	_push(_key(KEY_ESCAPE))
	await step_frame()
	check_eq(root.get_back_depth(), 0,
		"a SECOND Escape, with no capture live, pops the page — the row consumed the first one only")
	check_eq(root.get_page_id(), &"settings", "returning to the page it was pushed from")

	await _drop(panel, backend)
	root.queue_free()
	await step_frame()


## The mouse half of the abort table. While listening the row consumes mouse presses BEFORE GUI
## dispatch, so the Cancel button cannot be clicked normally — the abort is a manual hit-test against
## its rect. Both sides are asserted from the same rect, because a hit-test that always answered true
## would abort every click and one that always answered false would bind the Cancel button itself.
func _test_mouse_cancel_rect_aborts_and_elsewhere_records() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row))
	await step_frame()
	var cancel := _cancel_button(row)
	check(cancel.visible, "the Cancel button appears for the duration of a capture")
	var rect := cancel.get_global_rect()
	check(rect.get_area() > 0.0, "and has a real rect to hit-test against (got %s)" % rect)

	_push(_mouse(MOUSE_BUTTON_LEFT, rect.get_center()))
	await step_frame()
	check(not row.is_listening(), "a press INSIDE the Cancel rect aborts the capture")
	check(not _backend_has_override(backend, ACTION_A), "and writes nothing")

	# ...and a press anywhere else is a binding. Aimed at a point proven to be outside that same rect.
	await _activate(_binding_button(row))
	await step_frame()
	var elsewhere := cancel.get_global_rect().get_center() + Vector2(0.0, 400.0)
	check(not cancel.get_global_rect().has_point(elsewhere),
		"precondition: the second press really is outside the Cancel rect")
	_push(_mouse(MOUSE_BUTTON_RIGHT, elsewhere))
	await step_frame()
	_settle(row)

	var stored := backend.get_action_events(ACTION_A)
	check_eq(stored.size(), 1, "one binding was stored")
	if stored.size() == 1 and stored[0] is InputEventMouseButton:
		check_eq(int((stored[0] as InputEventMouseButton).button_index), MOUSE_BUTTON_RIGHT,
			"and it is the mouse BUTTON that was pressed")
	check(_action_has_mouse_button(ACTION_A, MOUSE_BUTTON_RIGHT),
		"applied to the live InputMap like any other capture")

	await _drop(panel, backend)


## [b]Replace[/b]: the matching event leaves the other action FIRST, then the capture commits — in
## that order, so the two actions are never both bound between the writes.
func _test_conflict_dialog_replace() -> void:
	var fixture := await _make_conflict_fixture()
	var dialog := fixture["dialog"] as MKConfirmDialog
	if dialog == null:
		await _drop_conflict(fixture)
		return
	var backend := fixture["backend"] as MKJsonSettingsBackend

	await _activate(dialog.get_confirm_button())
	await step_frame()

	check(_backend_has_physical(backend, ACTION_A, KEY_K), "Replace moved the key to the capturing action")
	check(not _backend_has_physical(backend, ACTION_B, KEY_K),
		"and took it off the other one — the store is the truth both rows read")
	check(_backend_has_physical(backend, ACTION_B, KEY_J),
		"the other action keeps its NON-colliding binding: only the key the user gave up is removed")
	check(_action_has_physical(ACTION_A, KEY_K), "applied live for the capturing action")
	check(_action_has_physical(ACTION_B, KEY_J), "and for the stripped one")
	check(not _action_has_physical(ACTION_B, KEY_K), "which no longer answers to the moved key")
	check_eq((fixture["layer"] as MKModalLayer).depth(), 0, "and the dialog closed itself")

	# The LOSER's row is on the same page, one line down, and it is the row whose binding just changed
	# out from under it. A store that moved the key while that row still displays it is the shape of
	# this bug users report as "it bound to both".
	var row_b := _row(fixture["panel"] as MKSettingsPanel, ID_B)
	check(row_b != null, "the other action's row is on the same page")
	if row_b != null:
		check(not _binding_button(row_b).text.contains(OS.get_keycode_string(KEY_K)),
			"and it REDRAWS without the key it just lost — nothing refreshes the loser today, so it keeps showing a binding the store says it no longer has")
		check(_binding_button(row_b).text.contains(OS.get_keycode_string(KEY_J)),
			"while still showing the binding it kept")

	await _drop_conflict(fixture)


## [b]Keep both[/b]: two actions on one key is a legitimate design (a map screen and a gameplay
## screen), so the addon commits and leaves the other action alone rather than overruling the game.
func _test_conflict_dialog_keep_both() -> void:
	var fixture := await _make_conflict_fixture()
	var dialog := fixture["dialog"] as MKConfirmDialog
	if dialog == null:
		await _drop_conflict(fixture)
		return
	var backend := fixture["backend"] as MKJsonSettingsBackend

	var alt := _find_button(dialog, "Keep both")
	check(alt != null, "the conflict dialog offers the third outcome")
	if alt == null:
		await _drop_conflict(fixture)
		return
	await _activate(alt)
	await step_frame()

	check(_backend_has_physical(backend, ACTION_A, KEY_K), "Keep both commits the new binding")
	check(_backend_has_physical(backend, ACTION_B, KEY_K), "and leaves the other action carrying it too")
	check(_action_has_physical(ACTION_A, KEY_K), "live for the capturing action")
	check(_action_has_physical(ACTION_B, KEY_K), "and still live for the other one")

	await _drop_conflict(fixture)


## [b]Cancel[/b]: nothing changes. Connected rather than left to the default, because the capture has
## already ended by the time the dialog opens — so "nothing changed" has to be an outcome rather than
## a missing branch.
func _test_conflict_dialog_cancel() -> void:
	var fixture := await _make_conflict_fixture()
	var dialog := fixture["dialog"] as MKConfirmDialog
	if dialog == null:
		await _drop_conflict(fixture)
		return
	var backend := fixture["backend"] as MKJsonSettingsBackend

	await _activate(dialog.get_cancel_button())
	await step_frame()

	check(not _backend_has_physical(backend, ACTION_A, KEY_K),
		"Cancel commits nothing to the capturing action")
	check(not _backend_has_override(backend, ACTION_A), "no override was stored for it at all")
	check(_backend_has_physical(backend, ACTION_B, KEY_K),
		"and the other action keeps the key it already had")
	check(_action_has_physical(ACTION_A, KEY_F), "the live map still runs the stock binding")
	check_eq((fixture["layer"] as MKModalLayer).depth(), 0, "and the dialog closed")

	await _drop_conflict(fixture)


## Per-row Reset, driven through the row's REAL button. A single-slot capture replaces a MULTI-event
## stock list, so the reset that undoes it has to restore all of it — from the boot snapshot, in both
## the store and the live [InputMap].
func _test_row_reset_restores_the_multi_event_stock_list() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row))
	_push(_key(KEY_G))
	await step_frame()
	_settle(row)
	check(_action_has_physical(ACTION_A, KEY_G), "precondition: rebound to a single key")
	check(not _action_has_physical(ACTION_A, KEY_T), "which dropped the second stock event")

	await _activate(_reset_button(row))
	await step_frame()

	check(_action_has_physical(ACTION_A, KEY_F), "Reset restored the first stock binding")
	check(_action_has_physical(ACTION_A, KEY_T),
		"AND the second one — the whole boot list comes back, not just one slot")
	check(not _action_has_physical(ACTION_A, KEY_G), "and dropped the override")
	check(not _backend_has_override(backend, ACTION_A), "the store no longer reports an override")
	check(_reset_button(row).disabled, "so the row's own Reset goes back to disabled")
	check_eq(_binding_button(row).text,
		"%s, %s" % [OS.get_keycode_string(KEY_F), OS.get_keycode_string(KEY_T)],
		"and the row redraws showing BOTH stock bindings")

	await _drop(panel, backend)


## The recovery net: one press puts every managed binding back, across rows, and redraws them all. A
## reset that fixed the store and left the rows showing the old text is the shape of this bug users
## report as "it didn't reset".
func _test_global_reset_restores_every_row() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [
		_keybind(ID_A, ACTION_A, "Action A"),
		_keybind(ID_B, ACTION_B, "Action B"),
	])
	var row_a := _row(panel, ID_A)
	var row_b := _row(panel, ID_B)
	if row_a == null or row_b == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row_a))
	_push(_key(KEY_G))
	await step_frame()
	_settle(row_a)
	await _activate(_binding_button(row_b))
	_push(_key(KEY_H))
	await step_frame()
	_settle(row_b)
	check(_action_has_physical(ACTION_A, KEY_G) and _action_has_physical(ACTION_B, KEY_H),
		"precondition: both rows are rebound")

	var reset_all := _find_button(panel, "Reset All Bindings")
	check(reset_all != null, "the page carries the global reset button")
	if reset_all == null:
		await _drop(panel, backend)
		return
	await _activate(reset_all)
	await step_frame()

	check(_action_has_physical(ACTION_A, KEY_F) and _action_has_physical(ACTION_A, KEY_T),
		"the first action is back to its stock list")
	check(_action_has_physical(ACTION_B, KEY_K), "and the second one too")
	check(not _action_has_physical(ACTION_A, KEY_G), "with both overrides gone from the engine")
	check(not _action_has_physical(ACTION_B, KEY_H), "for the second action as well")
	check(not _backend_has_override(backend, ACTION_A)
			and not _backend_has_override(backend, ACTION_B),
		"and gone from the store")
	check_eq(_binding_button(row_b).text, OS.get_keycode_string(KEY_K),
		"every row was redrawn — a reset that leaves the old text on screen reads as a failed reset")
	check(_reset_button(row_a).disabled and _reset_button(row_b).disabled,
		"and each row's own Reset is disabled again")

	await _drop(panel, backend)


## A rebind made in the UI survives a restart, and the SERIALISED SHAPE is pinned: plan §4.4 makes
## physical-keycode storage a decision (a QWERTY rebind lands on the same physical key on AZERTY), so
## changing it is a CHANGELOG Breaking entry rather than an implementation detail.
func _test_persistence_round_trip() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row))
	_push(_key(KEY_G))
	await step_frame()
	_settle(row)
	backend.save()
	await _drop(panel, backend)

	var raw := FileAccess.get_file_as_string(PATH)
	var parsed := JSON.new()
	check_eq(parsed.parse(raw), OK, "the saved store is valid JSON")
	var data: Variant = parsed.data
	check(data is Dictionary, "and a JSON object")
	if data is Dictionary:
		var input: Variant = (data as Dictionary).get("input", {})
		check(input is Dictionary, "carrying an 'input' section")
		if input is Dictionary:
			var rows: Variant = (input as Dictionary).get(String(ACTION_A), null)
			check(rows is Array and (rows as Array).size() == 1,
				"with exactly one event row for the rebound action")
			if rows is Array and (rows as Array).size() == 1 and (rows as Array)[0] is Dictionary:
				var event := (rows as Array)[0] as Dictionary
				check_eq(String(event.get("type", "")), "key", "typed as a key event")
				check_eq(int(event.get("physical_keycode", 0)), KEY_G,
					"and keyed by PHYSICAL keycode — the §4.4 format decision, breaking to change")

	# Back to stock, so anything surviving below must have come off disk.
	_seed_actions()
	check(not _action_has_physical(ACTION_A, KEY_G), "precondition: the live map is back to stock")

	var reloaded := MKJsonSettingsBackend.new()
	reloaded._mk_configure({"file_path": PATH})
	get_root().add_child(reloaded)
	reloaded.snapshot_input_defaults()
	reloaded.load()
	reloaded.apply_all()
	check(_action_has_physical(ACTION_A, KEY_G),
		"a FRESH backend on the same file applies the rebind — the round trip is what makes a rebind a setting")
	check(not _action_has_physical(ACTION_A, KEY_F), "replacing the stock binding rather than joining it")
	reloaded.queue_free()
	await step_frame()
	_seed_actions()


## The bare-scene criterion: a host that boots straight into gameplay never builds a settings panel,
## and the player's rebinds must still be live. test_input_persistence.gd owns the backend-level
## round trip; the DELTA asserted here is that no [MKRebindRow] and no [MKSettingsPanel] exists
## anywhere in the tree while it happens — the rebind UI is not a participant in application.
func _test_a_stored_rebind_applies_with_no_panel_in_the_tree() -> void:
	# Written as a file rather than through a row, because a row is precisely what this test forbids.
	var seeded := MKJsonSettingsBackend.new()
	seeded._mk_configure({"file_path": PATH})
	get_root().add_child(seeded)
	seeded.snapshot_input_defaults()
	var rebound := InputEventKey.new()
	rebound.physical_keycode = KEY_M
	seeded.set_action_events(ACTION_A, [rebound])
	seeded.save()
	seeded.queue_free()
	await step_frame()
	_seed_actions()

	check_eq(_count_in_tree(MKRebindRow), 0, "precondition: no rebind row exists in the tree")
	check_eq(_count_in_tree(MKSettingsPanel), 0, "and no settings panel either")

	var boot := MKJsonSettingsBackend.new()
	boot._mk_configure({"file_path": PATH})
	get_root().add_child(boot)
	boot.snapshot_input_defaults()
	boot.load()
	boot.apply_all()
	check(_action_has_physical(ACTION_A, KEY_M),
		"the stored rebind reaches the live InputMap with no menu ever built — the host that boots into gameplay honours it")
	boot.queue_free()
	await step_frame()
	_seed_actions()
	_clean()


## Stick axes: the DIRECTION is the binding, so the captured magnitude is normalised to ±1 — a
## binding whose meaning depended on how hard the user happened to push would fire differently every
## session. And a resting/drifting stick is consumed but IGNORED: below the deadzone the capture goes
## on, or the row would bind the drift of an untouched pad.
func _test_axis_capture() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row))
	var drift := InputEventJoypadMotion.new()
	drift.axis = JOY_AXIS_LEFT_Y
	drift.axis_value = 0.2
	var handled := _push(drift)
	await step_frame()
	check(handled, "a sub-deadzone motion is still CONSUMED — it belongs to the capture in progress")
	check(row.is_listening(), "but the capture continues: a drifting stick must not become a binding")
	check(not _backend_has_override(backend, ACTION_A), "and nothing was stored")

	var motion := InputEventJoypadMotion.new()
	motion.axis = JOY_AXIS_LEFT_Y
	motion.axis_value = -0.8
	_push(motion)
	await step_frame()
	_settle(row)

	var stored := backend.get_action_events(ACTION_A)
	check_eq(stored.size(), 1, "one axis binding stored")
	if stored.size() == 1 and stored[0] is InputEventJoypadMotion:
		var out := stored[0] as InputEventJoypadMotion
		check_eq(int(out.axis), JOY_AXIS_LEFT_Y, "on the axis that moved")
		check_eq(out.axis_value, -1.0,
			"with the value NORMALISED to the sign — 0.8 and 1.0 are the same binding, and storing the magnitude would persist how hard the user pushed")

	await _drop(panel, backend)


## Rows cannot see each other, so the one-listener-at-a-time rule is the PANEL's: starting a capture
## on one row ends every other. Two prompts on screen both claiming the whole keyboard is the state
## this prevents — the first row in tree order would take the press while the second went on waiting.
func _test_only_one_row_listens_at_a_time() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [
		_keybind(ID_A, ACTION_A, "Action A"),
		_keybind(ID_B, ACTION_B, "Action B"),
	])
	var row_a := _row(panel, ID_A)
	var row_b := _row(panel, ID_B)
	if row_a == null or row_b == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row_a))
	check(row_a.is_listening(), "row A is listening")

	# Started through the public seam rather than by clicking: while row A listens it consumes every
	# mouse press, so a click aimed at row B would be RECORDED by A — which is the behaviour the rule
	# exists to make impossible to reach by accident.
	row_b.begin_listen()
	await step_frame()

	check(row_b.is_listening(), "starting a capture on row B leaves B listening")
	check(not row_a.is_listening(), "and ENDS row A's capture")
	check(not row_a.is_processing_input(), "with A's input processing disarmed")
	check(not _backend_has_override(backend, ACTION_A), "A's binding is unchanged — an abort never writes")

	_push(_key(KEY_G))
	await step_frame()
	_settle(row_b)
	check(_backend_has_physical(backend, ACTION_B, KEY_G), "and the next press goes to B alone")
	check(not _backend_has_override(backend, ACTION_A), "never to A")

	await _drop(panel, backend)


## A listening row swallows the whole keyboard, so an unanswered capture must give up on its own. The
## player who walked away — or who started one by accident and cannot guess Escape gets out — is
## otherwise stuck in a menu that ignores every key.
func _test_capture_times_out() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	row.listen_timeout = 0.05
	await _activate(_binding_button(row))
	check(row.is_listening(), "precondition: a capture is live")

	var deadline := Time.get_ticks_msec() + 3000
	while row.is_listening() and Time.get_ticks_msec() < deadline:
		await step_frame()

	check(not row.is_listening(), "the capture gave up on its own once listen_timeout lapsed")
	check(not row.is_processing_input(), "releasing the keyboard it was holding")
	check(not _backend_has_override(backend, ACTION_A), "and a timeout writes nothing, like every other abort")
	check_eq(_binding_button(row).text, OS.get_keycode_string(KEY_F) + ", " + OS.get_keycode_string(KEY_T),
		"with the row's display restored to the binding it still has")

	await _drop(panel, backend)


## [method MKSettingsBackend.apply_action] is targeted on purpose: rebinding seven movement keys must
## not re-push the window mode, the resolution and every bus volume seven times. The commit half is
## asserted in the happy path; what this adds is the refusal — an action the project does not define
## is NAMED and the live map is left alone, rather than being erased into nothing.
func _test_apply_action_is_targeted() -> void:
	var backend := _make_backend()
	var before := InputMap.action_get_events(ACTION_A).size()

	_watch_warnings()
	backend.apply_action(&"mk_no_such_action")
	var warnings := _stop_watching()

	check(not InputMap.has_action(&"mk_no_such_action"), "precondition: the action really is undefined")
	check_eq(_count_containing(warnings, "mk_no_such_action"), 1,
		"an unknown action is named once — a rebind that silently applies to nothing is undebuggable")
	check_eq(InputMap.action_get_events(ACTION_A).size(), before,
		"and nothing else in the InputMap was touched")
	check(_action_has_physical(ACTION_A, KEY_F), "the neighbouring action still carries its binding")

	backend.queue_free()
	await step_frame()


## Godot stamps the modifier state of the MOMENT onto every key event, so a user holding Shift for an
## unrelated reason (or on a layout that needs it) would persist a Shift+G binding that then refuses
## to fire on a plain G.
func _test_modifiers_are_stripped() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_keybind(ID_A, ACTION_A, "Action A")])
	var row := _row(panel, ID_A)
	if row == null:
		await _drop(panel, backend)
		return

	await _activate(_binding_button(row))
	_push(_key(KEY_G, true))
	await step_frame()
	_settle(row)

	var stored := backend.get_action_events(ACTION_A)
	check_eq(stored.size(), 1, "the modified press still commits — modifiers are stripped, not refused")
	if stored.size() == 1 and stored[0] is InputEventKey:
		var key := stored[0] as InputEventKey
		check_eq(int(key.physical_keycode), KEY_G, "on the key that was pressed")
		check(not key.shift_pressed,
			"with Shift DROPPED — a stored Shift+G would refuse to fire on the plain G the user thinks they bound")
		check(not key.alt_pressed and not key.ctrl_pressed and not key.meta_pressed,
			"and the other modifier flags with it")

	await _drop(panel, backend)


# --- Conflict fixture ---------------------------------------------------------

## Builds a panel with two KEYBIND rows on a modal-layer host, gives action B the key that is about
## to be captured on row A, captures it, and returns everything the three outcome tests drive.
##
## The two assertions every outcome shares live here: a dialog appeared, and listening had ALREADY
## ended when it did. The second is not decoration — a modal that steals focus while the row still
## holds `_input` would consume the dialog's own keyboard, leaving its buttons reachable by mouse
## only, on a screen whose entire purpose is keyboard configuration.
func _make_conflict_fixture() -> Dictionary:
	var backend := _make_backend()
	# B carries the contested key AND one of its own, so Replace can be shown to remove only the
	# colliding event rather than clearing the action.
	var contested := InputEventKey.new()
	contested.physical_keycode = KEY_K
	var kept := InputEventKey.new()
	kept.physical_keycode = KEY_J
	backend.set_action_events(ACTION_B, [contested, kept])
	backend.apply_action(ACTION_B)

	var host := LayerHost.new()
	host.name = "LayerHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var layer := MKModalLayer.new()
	host.add_child(layer)
	host.layer = layer
	await step_frame()

	var panel := await _make_panel(backend, [
		_keybind(ID_A, ACTION_A, "Action A"),
		_keybind(ID_B, ACTION_B, "Action B"),
	], host)
	var row := _row(panel, ID_A)
	var dialog: MKConfirmDialog = null
	if row != null:
		await _activate(_binding_button(row))
		_push(_key(KEY_K))
		await step_frame()
		check(not row.is_listening(),
			"listening ends BEFORE the conflict dialog opens, or the dialog's own keyboard is eaten by this row")
		check_eq(layer.depth(), 1, "a conflict raised exactly one modal")
		dialog = layer.top() as MKConfirmDialog
		check(dialog != null, "and it is an MKConfirmDialog — no second near-identical dialog script")
		check(not _backend_has_override(backend, ACTION_A),
			"nothing is committed while the question is still open")

	return {"backend": backend, "panel": panel, "host": host, "layer": layer, "dialog": dialog}


func _drop_conflict(fixture: Dictionary) -> void:
	var panel := fixture["panel"] as MKSettingsPanel
	var backend := fixture["backend"] as MKJsonSettingsBackend
	var host := fixture["host"] as Control
	if panel != null:
		panel.queue_free()
	if backend != null:
		backend.queue_free()
	if host != null:
		host.queue_free()
	await step_frame()
	await step_frame()
	_seed_actions()


## A minimal shell: the ONE thing [MKSettingsPanel] needs from an ancestor to find a modal layer is
## this duck-typed method (see `_find_modal_layer`), so the conflict tests do not need a whole
## [MKRoot] and do not accidentally test one.
class LayerHost extends Control:
	var layer: MKModalLayer

	func get_modal_layer() -> MKModalLayer:
		return layer


# --- Fixtures -----------------------------------------------------------------

## Action A carries a TWO-event stock list on purpose: a single-slot capture replaces both, so it is
## what makes the multi-event Reset restore assertable.
func _seed_actions() -> void:
	_seed(ACTION_A, [KEY_F, KEY_T])
	_seed(ACTION_B, [KEY_K])


func _seed(action: StringName, physical_keycodes: Array) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action)
	for code in physical_keycodes:
		var event := InputEventKey.new()
		event.physical_keycode = code
		InputMap.action_add_event(action, event)


## [b]Installs the gamepad binding of [code]ui_cancel[/code] this project does not ship.[/b]
##
## Reported rather than worked around silently: MenuKit's demo project defines [code]ui_cancel[/code]
## as keyboard Escape ONLY, so [method MKSettingsPanel._reserved_input_events] derives an EMPTY list
## here and the pad-B guard — the one hazard that list exists for — is inert in the shipped
## configuration. A project with a controller carries the pad binding, which is the configuration the
## rule is written against, so it is installed for the duration of this suite.
##
## The derivation path itself is untouched and is what the test asserts: the binding goes into the
## live [InputMap] BEFORE any backend snapshot, so the panel still reads it out of the boot snapshot
## exactly as it would in a real project. The action is restored to the events found here.
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


func _teardown_actions() -> void:
	for action in [ACTION_A, ACTION_B]:
		if InputMap.has_action(action):
			InputMap.erase_action(action)


## Snapshots at construction, which is the order §4.2 fixes: the boot snapshot must predate any
## override, or Reset silently restores the user's own binding as the "default".
func _make_backend() -> MKJsonSettingsBackend:
	_clean()
	_seed_actions()
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": PATH})
	get_root().add_child(backend)
	backend.snapshot_input_defaults()
	return backend


func _keybind(id: StringName, action: StringName, label: String) -> MKSettingDef:
	var def := MKSettingDef.new()
	def.id = id
	def.type = MKSettingDef.RowType.KEYBIND
	def.label = label
	def.action_name = action
	return def


## Sized and given a frame, because half of this suite hit-tests real rects (the Cancel abort, every
## button press). An unsized panel lays its rows out at zero and every click lands nowhere.
func _make_panel(backend: MKSettingsBackend, rows: Array, parent: Node = null) -> MKSettingsPanel:
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
	if backend != null:
		panel.bind_backend(backend)
	(parent if parent != null else get_root()).add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(1920, 1080)
	await step_frame()
	await step_frame()
	return panel


## [b]The end-of-capture assertion, and the normalisation that has to follow it.[/b] Every commit
## route funnels through here: a capture that has produced a binding is over, which is what the
## capture prompt, the Cancel button, the one-listener rule and the panel's Reset All all assume.
##
## It also ABORTS a row that is somehow still listening, because a live capture consumes every event
## pushed after it — so one row left listening would silently swallow the next test's gesture and
## report as a different failure entirely. Asserting first and normalising second keeps the diagnosis
## at the row that actually misbehaved.
func _settle(row: MKRebindRow) -> void:
	check(not row.is_listening(),
		"a committed capture ENDS the capture — a row that keeps listening after binding a key still holds the whole keyboard, still shows the capture prompt, and takes the next press as a second binding")
	if row.is_listening():
		row.abort_listen()


func _drop(panel: Node, backend: Node) -> void:
	if panel != null and is_instance_valid(panel):
		panel.queue_free()
	if backend != null and is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()
	# Back to stock for the next test, so no assertion inherits a previous one's rebind.
	_seed_actions()


# --- Input drivers ------------------------------------------------------------

## A key event carrying BOTH codes, the way real hardware does on a QWERTY layout: the row matches
## Escape physically, while `ui_cancel` and the `ui_*` overlap scan match on keycode.
func _key(physical: int, shift := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = physical as Key
	event.keycode = physical as Key
	event.pressed = true
	event.shift_pressed = shift
	return event


func _mouse(button: int, at: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button as MouseButton
	event.pressed = true
	event.position = at
	event.global_position = at
	return event


## Pushes one event through the root viewport's real dispatch order and reports whether it was marked
## handled. Returning the flag rather than a bare true is what keeps the consumption assertions from
## being tautologies.
func _push(event: InputEvent) -> bool:
	var viewport := get_root()
	# in_local_coords = true: the root Window is 64x64 under the headless driver while the canvas is
	# the project's 1920-wide viewport, so the default (screen-space) path scales every mouse position
	# through the stretch transform and a press aimed at a Control's own get_global_rect() lands
	# somewhere else entirely. Pushing in canvas coordinates is what makes the Cancel-rect hit test
	# below an honest test of the row's arithmetic rather than of the stretch factor.
	viewport.push_input(event, true)
	return viewport.is_input_handled()


## Presses a button the way a keyboard/gamepad player does: focus it, then push a real
## [code]ui_accept[/code] key press AND its release through the viewport, so the engine's own GUI
## dispatch runs [BaseButton]'s activation. Emitting `pressed` directly would pass against a button
## nothing could reach.
##
## [b]Headless boundary.[/b] The mouse route to the same signal is NOT driven here: under the dummy
## display driver a pushed [InputEventMouseButton] never reaches GUI dispatch (verified — the button
## receives no `gui_input` at all, though the same event does reach [method Node._input], which is why
## the mouse ABORT test below is real). Clicking a row's button is therefore a human-pass check on a
## real display, and this suite says so rather than pretending a click happened.
func _activate(button: Button) -> void:
	button.grab_focus()
	await step_frame()
	var press := _key(KEY_ENTER)
	get_root().push_input(press, true)
	var release := _key(KEY_ENTER)
	release.pressed = false
	get_root().push_input(release, true)
	await step_frame()


# --- Row accessors ------------------------------------------------------------

func _row(panel: MKSettingsPanel, id: StringName) -> MKRebindRow:
	return panel._controls.get(id, null) as MKRebindRow


func _binding_button(row: MKRebindRow) -> Button:
	return row.get_node_or_null("Binding") as Button


func _reset_button(row: MKRebindRow) -> Button:
	return row.get_node_or_null("Reset") as Button


func _cancel_button(row: MKRebindRow) -> Button:
	return row.get_node_or_null("Cancel") as Button


func _caption(row: MKRebindRow) -> Label:
	return row.get_node_or_null("Caption") as Label


func _find_button(root: Node, text_or_name: String) -> Button:
	for node in _descendants(root):
		var button := node as Button
		if button != null and (button.text == text_or_name or button.name == text_or_name):
			return button
	return null


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	_collect(node, out)
	return out


func _collect(node: Node, out: Array[Node]) -> void:
	for child in node.get_children():
		out.append(child)
		_collect(child, out)


func _count_in_tree(type) -> int:
	var found := 0
	for node in _descendants(get_root()):
		if is_instance_of(node, type):
			found += 1
	return found


# --- InputMap / store queries -------------------------------------------------

func _action_has_physical(action: StringName, physical_keycode: int) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and int((event as InputEventKey).physical_keycode) == physical_keycode:
			return true
	return false


func _action_has_mouse_button(action: StringName, index: int) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventMouseButton \
				and int((event as InputEventMouseButton).button_index) == index:
			return true
	return false


func _action_has_pad_button(action: StringName, index: int) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton \
				and int((event as InputEventJoypadButton).button_index) == index:
			return true
	return false


## Matches by physical code with the keycode fallback the persisted format carries, so a stock
## binding authored either way is found.
func _event_is_bound_to(action: StringName, physical_keycode: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key == null:
			continue
		if int(key.physical_keycode) == physical_keycode or int(key.keycode) == physical_keycode:
			return true
	return false


func _backend_has_physical(backend: MKSettingsBackend, action: StringName,
		physical_keycode: int) -> bool:
	for event in backend.get_action_events(action):
		if event is InputEventKey and int((event as InputEventKey).physical_keycode) == physical_keycode:
			return true
	return false


func _backend_has_override(backend: MKSettingsBackend, action: StringName) -> bool:
	return backend.has_action_override(action)


func _non_key_count(events: Array[InputEvent]) -> int:
	var found := 0
	for event in events:
		if not (event is InputEventKey):
			found += 1
	return found


# --- Observation --------------------------------------------------------------

func _watch_warnings() -> void:
	_log = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_log.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _log


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found


# --- Housekeeping -------------------------------------------------------------

const SERVICE_NAME := "MKSettingsService"


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
