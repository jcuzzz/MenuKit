extends MKTest
## InputMap override persistence and application (plan §4.2, §4.4).
##
## This half of the settings backend had no coverage at all: reducing `apply_all()` to `pass` AND
## corrupting the stored `physical_keycode` to 0 — simultaneously — left the suite green. Rebinds
## are the reason the settings service exists (§4.2 opens with "critically InputMap overrides"), and
## Phase 4's whole rebind UI is written against this surface.
##
## §4.4 makes the storage format a decision, not an implementation detail: keyboard events serialise
## by [code]physical_keycode[/code] so a rebind made on QWERTY lands on the same physical key for an
## AZERTY user. Changing that later is a CHANGELOG [b]Breaking[/b] entry, so it is pinned here.
##
## Headless-safe: `InputMap` is a real subsystem under `--headless` (unlike `DisplayServer`), so
## these assertions observe genuine engine state rather than silently no-op'ing.

const PATH := "user://test_input_persistence.json"
const ACTION := &"mk_test_action"


func run_tests() -> void:
	_clean()
	_seed_action()
	await _test_rebind_round_trip_and_apply()
	await _test_reset_to_default_uses_the_boot_snapshot()
	_teardown_action()
	_clean()


## A synthetic action so the test never depends on the host project's own InputMap.
func _seed_action() -> void:
	if InputMap.has_action(ACTION):
		InputMap.erase_action(ACTION)
	InputMap.add_action(ACTION)
	var stock := InputEventKey.new()
	stock.physical_keycode = KEY_F
	InputMap.action_add_event(ACTION, stock)


func _teardown_action() -> void:
	if InputMap.has_action(ACTION):
		InputMap.erase_action(ACTION)


func _test_rebind_round_trip_and_apply() -> void:
	var backend := _make_backend()
	backend.snapshot_input_defaults()

	var rebound := InputEventKey.new()
	rebound.physical_keycode = KEY_J
	rebound.shift_pressed = true
	backend.set_action_events(ACTION, [rebound])
	backend.save()
	backend.free()

	# Put the action back to stock, so anything surviving must have come off disk.
	_seed_action()
	check(not _action_has_physical(ACTION, KEY_J), "precondition: the action is back to stock")

	var reloaded := _make_backend()
	reloaded.snapshot_input_defaults()
	reloaded.load()
	reloaded.apply_all()

	check(_action_has_physical(ACTION, KEY_J),
		"apply_all pushed the stored rebind into the live InputMap")
	check(not _action_has_physical(ACTION, KEY_F),
		"and replaced the stock binding rather than adding to it")

	var stored := reloaded.get_action_events(ACTION)
	check(stored.size() > 0, "the backend reports the override it stored")
	if stored.size() > 0 and stored[0] is InputEventKey:
		var key := stored[0] as InputEventKey
		check_eq(key.physical_keycode, KEY_J,
			"stored by PHYSICAL keycode — a QWERTY rebind must land on the same physical key on AZERTY")
		check(key.shift_pressed, "modifiers survive the round trip")
	check(reloaded.has_action_override(ACTION), "the action reports as overridden")

	reloaded.free()


## Reset must restore the BOOT snapshot, which is why §4.2 orders snapshot before load. A snapshot
## taken after the override would capture the user's own binding, and Reset would silently do
## nothing while appearing to work.
func _test_reset_to_default_uses_the_boot_snapshot() -> void:
	_seed_action()
	var backend := _make_backend()
	backend.snapshot_input_defaults()
	backend.load()
	backend.apply_all()
	check(_action_has_physical(ACTION, KEY_J), "precondition: the override is applied")

	var defaults := backend.get_default_action_events(ACTION)
	check(defaults.size() > 0, "a boot snapshot exists for the action")
	if defaults.size() > 0 and defaults[0] is InputEventKey:
		check_eq((defaults[0] as InputEventKey).physical_keycode, KEY_F,
			"the snapshot holds the STOCK binding, not the user's override")

	backend.reset_action_to_default(ACTION)
	backend.apply_all()
	check(_action_has_physical(ACTION, KEY_F), "reset restored the stock binding")
	check(not _action_has_physical(ACTION, KEY_J), "and dropped the override")
	check(not backend.has_action_override(ACTION), "the action no longer reports as overridden")

	# The global reset — the Controls page's recovery button — takes the same restore path. It had no
	# coverage, so dropping the restore from it alone would have gone unnoticed.
	var rebound := InputEventKey.new()
	rebound.physical_keycode = KEY_K
	backend.set_action_events(ACTION, [rebound])
	backend.apply_all()
	check(_action_has_physical(ACTION, KEY_K), "precondition: rebound again for the global reset")

	backend.reset_all_actions_to_defaults()
	check(_action_has_physical(ACTION, KEY_F),
		"reset_all_actions_to_defaults restores stock bindings to the live InputMap too")
	check(not backend.has_action_override(ACTION), "and clears the override flags")

	backend.free()


func _make_backend() -> MKJsonSettingsBackend:
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": PATH})
	get_root().add_child(backend)
	return backend


func _action_has_physical(action: StringName, physical_keycode: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == physical_keycode:
			return true
	return false


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
