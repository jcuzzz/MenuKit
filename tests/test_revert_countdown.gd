extends MKTest
## The D14 confirm-or-revert countdown (plan §4.3), standalone and driven through a real panel.
##
## The property that makes this dialog work at all is that it ticks in [method Node._process] under
## [member SceneTree.paused]. Display settings are changed from the pause menu, where a [Timer] or a
## [SceneTreeTimer] under a tree pause policy never fires — the dialog would hang open forever with
## no failing write anywhere to reveal it, and the player whose screen just went black would have no
## recovery path. That case has its own test below and it is the one to keep.
##
## The panel half asserts the round trip a user performs: change a [code]requires_confirm[/code] row,
## get a modal, and either let it lapse (store, engine and CONTROL all go back) or keep it (the new
## value stands). Asserting only that a modal appeared would pass against a dialog wired to nothing.

const STORE_PATH := "user://test_revert_countdown.json"

var _kept := 0
var _reverted := 0


func run_tests() -> void:
	_clean()
	await _test_start_and_tick()
	await _test_timeout_reverts_exactly_once()
	await _test_keep_button()
	await _test_cancel_reverts()
	await _test_invalid_duration_falls_back()
	await _test_ticks_while_the_tree_is_paused()
	await _test_panel_timeout_restores_the_previous_value()
	await _test_panel_keep_retains_the_new_value()
	_clean()


func _test_start_and_tick() -> void:
	var countdown := _make_countdown()
	check(not countdown.is_running(), "a fresh countdown is not running until it is started")
	check_eq(countdown.get_time_left(), 0.0, "and reports no time left")

	countdown.start(5.0)
	check(countdown.is_running(), "start() runs it")
	check_eq(countdown.get_time_left(), 5.0, "with the duration it was given")

	await step_frame()
	await step_frame()
	check(countdown.get_time_left() < 5.0,
		"and it ticks down in _process — the accumulation is frame-driven, not a Timer")
	check(countdown.get_time_left() > 0.0, "without racing to zero")
	check_eq(_reverted, 0, "nothing has resolved yet")

	countdown.queue_free()
	await step_frame()


## Timeout is the safety net, and it must fire ONCE. A dialog that emitted twice would make the panel
## revert a revert — restoring a value the user had already been put back to, over a change they made
## afterwards.
func _test_timeout_reverts_exactly_once() -> void:
	var countdown := _make_countdown()
	countdown.start(0.1)
	await _advance_until(func() -> bool: return not countdown.is_running(), 120)

	check_eq(_reverted, 1, "the countdown reverted on timeout")
	check_eq(_kept, 0, "and did not also report kept")
	check(not countdown.is_running(), "it stopped running")
	check_eq(countdown.get_time_left(), 0.0, "and reports no time left")

	for i in 5:
		await step_frame()
	check_eq(_reverted, 1, "exactly once — further frames emit nothing")

	countdown.queue_free()
	await step_frame()


func _test_keep_button() -> void:
	var countdown := _make_countdown()
	countdown.start(10.0)
	var keep := countdown.get_keep_button()
	check(keep != null, "the dialog exposes its Keep button")
	keep.pressed.emit()

	check_eq(_kept, 1, "pressing Keep reports kept")
	check_eq(_reverted, 0, "and never reverted")
	check(not countdown.is_running(), "the countdown stops on the decision")

	for i in 5:
		await step_frame()
	check_eq(_kept, 1, "exactly once")
	check_eq(_reverted, 0, "and the lapsed timer cannot revert a kept change")

	countdown.queue_free()
	await step_frame()


## Escape means revert: the safe outcome is the one that needs no working input.
func _test_cancel_reverts() -> void:
	var countdown := _make_countdown()
	countdown.start(10.0)
	var consumed := countdown.handle_cancel()
	check(not consumed,
		"handle_cancel reports it did NOT consume the gesture, which is what makes the layer pop it")
	check_eq(_reverted, 1, "and the decision is revert")

	countdown.queue_free()
	await step_frame()


## A zero-second countdown would resolve on the first frame and read as "the dialog flickered and my
## setting was refused".
func _test_invalid_duration_falls_back() -> void:
	var countdown := _make_countdown()
	countdown.start(0.0)
	check_eq(countdown.get_time_left(), MKRevertCountdown.DEFAULT_DURATION,
		"a non-positive duration falls back to the default rather than resolving instantly")
	check(countdown.is_running(), "and the dialog is genuinely running")
	check_eq(_reverted, 0, "nothing resolved on the frame it started")

	countdown.start(NAN)
	check_eq(countdown.get_time_left(), MKRevertCountdown.DEFAULT_DURATION,
		"a non-finite duration does too — NAN would make the comparison never true and hang the dialog")

	countdown.queue_free()
	await step_frame()


## [b]The D14 property.[/b] Display settings are changed from the pause menu; a countdown that froze
## with the world would leave the dialog open forever, and the change it was going to revert applied.
func _test_ticks_while_the_tree_is_paused() -> void:
	var countdown := _make_countdown()
	check_eq(countdown.process_mode, Node.PROCESS_MODE_ALWAYS,
		"the dialog sets PROCESS_MODE_ALWAYS itself — it must tick wherever a host pushes it, not only inside the MKRoot subtree")

	countdown.start(10.0)
	get_root().get_tree().paused = true
	var before := countdown.get_time_left()
	for i in 4:
		await step_frame()
	var after := countdown.get_time_left()
	get_root().get_tree().paused = false

	check(after < before,
		"the countdown ticks with the tree PAUSED (%s -> %s) — the pause menu is where this dialog lives"
			% [before, after])
	check_eq(_reverted, 0, "and it is still counting, not resolved")

	countdown.queue_free()
	await step_frame()


# --- Panel integration --------------------------------------------------------

## Timeout through the real path: panel, modal layer, backend. The CONTROL is asserted alongside the
## store, because a revert that restores the value while the dropdown still shows the rejected one is
## the shape of this bug users report as "it didn't revert".
func _test_panel_timeout_restores_the_previous_value() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var panel: MKSettingsPanel = fixture["panel"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"the store starts on the previous value")

	button.select(1)
	button.item_selected.emit(1)
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"a requires_confirm change is applied IMMEDIATELY — asking first is what D14 rejects")

	var layer := root.get_modal_layer()
	check_eq(layer.depth(), 1, "and it pushed a modal")
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "which is the revert countdown")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	countdown.start(0.1)
	await _advance_until(func() -> bool: return layer.depth() == 0, 120)

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"letting the countdown lapse restores the PREVIOUS stored value")
	check_eq(button.selected, 0,
		"and the control is put back too — a dropdown still showing the rejected value reads as a failed revert")
	check_eq(layer.depth(), 0, "the dialog is removed from the modal stack")

	await _drop_fixture(fixture)


func _test_panel_keep_retains_the_new_value() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]

	button.select(1)
	button.item_selected.emit(1)
	var layer := root.get_modal_layer()
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	countdown.get_keep_button().pressed.emit()
	await step_frame()

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"Keep retains the new value")
	check_eq(button.selected, 1, "and the control stays on the user's choice")
	check_eq(layer.depth(), 0, "with the dialog dismissed")

	# The countdown was already at zero-risk once kept; several frames prove the dead timer cannot
	# reach back and revert a change the user confirmed.
	for i in 10:
		await step_frame()
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"and it stays kept — the resolved countdown cannot fire again")

	await _drop_fixture(fixture)


# --- Fixtures -----------------------------------------------------------------

func _make_countdown() -> MKRevertCountdown:
	_kept = 0
	_reverted = 0
	var countdown := MKRevertCountdown.new()
	countdown.kept.connect(func() -> void: _kept += 1)
	countdown.reverted.connect(func() -> void: _reverted += 1)
	get_root().add_child(countdown)
	return countdown


## A real MKRoot (for its modal layer), a real JSON backend, and a panel carrying one
## requires_confirm ENUM row — the shipped Video page's window-mode shape, minus the rest.
func _make_panel_fixture() -> Dictionary:
	_clean()
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": STORE_PATH})
	get_root().add_child(backend)
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 0)

	var root := _make_root()
	await step_frame()

	var def := MKSettingDef.new()
	def.id = MKSettingsPanel.ID_WINDOW_MODE
	def.label = "Window Mode"
	def.type = MKSettingDef.RowType.ENUM
	def.default_value = 0
	def.options = ["Windowed", "Fullscreen"] as Array[String]
	def.option_values = [0, 3]
	def.requires_confirm = true

	var page := MKSettingsPageDef.new()
	page.id = &"video"
	page.title = "Video"
	page.rows = [def] as Array[MKSettingDef]

	var panel := MKSettingsPanel.new()
	panel.pages = [page] as Array[MKSettingsPageDef]
	panel.bind_backend(backend)
	# Parented under MKRoot so the panel's ancestor walk finds a real modal layer, which is how a host
	# embedding it in a page gets one.
	root.add_child(panel)
	await step_frame()

	var option := _first_option(panel)
	return {"backend": backend, "panel": panel, "root": root, "option": option}


func _drop_fixture(fixture: Dictionary) -> void:
	var panel: MKSettingsPanel = fixture["panel"]
	if is_instance_valid(panel):
		panel.queue_free()
	var root: MKRoot = fixture["root"]
	if is_instance_valid(root):
		root.queue_free()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	if is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()


func _make_root() -> MKRoot:
	var config := MKConfig.new()
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	var page := MKMenuPageDef.new()
	page.id = &"only"
	page.title = "Only"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(page)
	config.initial_page = &"only"
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	return root


func _first_option(node: Node) -> OptionButton:
	for child in node.get_children():
		var button := child as OptionButton
		if button != null:
			return button
		var found := _first_option(child)
		if found != null:
			return found
	return null


## Advances frames until [param predicate] holds or [param limit] frames elapse. Bounded rather than
## looping forever: a broken countdown must fail the assertion after it, not hang the whole gate.
func _advance_until(predicate: Callable, limit: int) -> void:
	for i in limit:
		if predicate.call():
			return
		await step_frame()


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := STORE_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
