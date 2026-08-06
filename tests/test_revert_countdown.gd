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
	await _test_resolved_countdown_cannot_emit_again()
	await _test_invalid_duration_falls_back()
	await _test_ticks_while_the_tree_is_paused()
	await _test_layer_teardown_disposes_the_dialog()
	await _test_panel_timeout_restores_the_previous_value()
	await _test_panel_keep_retains_the_new_value()
	await _test_cancel_through_the_layer_pops_only_the_countdown()
	await _test_a_resolved_countdown_stops_swallowing_cancel()
	await _test_dismissal_leaves_a_modal_stacked_above_it_alone()
	await _test_a_page_change_reverts_an_unconfirmed_countdown()
	await _test_freeing_the_panel_reverts_an_unconfirmed_countdown()
	await _test_a_synced_control_raises_no_countdown()
	await _test_untouched_text_row_raises_no_countdown()
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
##
## And it reports the gesture CONSUMED. Emitting reverted resolves the dialog synchronously — the
## panel's handler removes it from the layer before handle_cancel has returned — so reporting "not
## consumed" made the layer pop a second time, taking whatever modal was underneath. The layer half
## of that is asserted in _test_cancel_through_the_layer_pops_only_the_countdown; this pins the
## contract at the dialog.
func _test_cancel_reverts() -> void:
	var countdown := _make_countdown()
	countdown.start(10.0)
	var consumed := countdown.handle_cancel()
	check(consumed,
		"handle_cancel reports the gesture CONSUMED — the dialog is already resolved and the layer must not pop anything")
	check_eq(_reverted, 1, "and the decision is revert")

	countdown.queue_free()
	await step_frame()


## The emit-once latch, driven through the public surfaces that can collide in one resolution: the
## timeout fires, and the player's Revert press lands on the same frame. Without the latch that is two
## [signal MKRevertCountdown.reverted] emissions, and the panel would revert a revert — restoring a
## value the user had already been put back to, over whatever they changed next.
func _test_resolved_countdown_cannot_emit_again() -> void:
	var countdown := _make_countdown()
	countdown.start(0.05)
	await _advance_until(func() -> bool: return not countdown.is_running(), 120)
	check_eq(_reverted, 1, "the timeout resolved it once")

	countdown.get_revert_button().pressed.emit()
	check_eq(_reverted, 1, "a Revert press in the same resolution adds nothing")
	# NOT consumed, and that is the contract: handle_cancel reports whether THIS call resolved the
	# dialog. A resolved dialog still on a stack has no owner left to remove it, so claiming the gesture
	# would swallow every Escape from then on — an unclosable scrim over nothing. Declining lets the
	# layer pop the stale entry and self-heal; the layer half is
	# _test_a_resolved_countdown_stops_swallowing_cancel.
	var consumed := countdown.handle_cancel()
	check(not consumed,
		"a cancel gesture on an ALREADY-resolved dialog is declined — it resolved nothing, and saying otherwise makes a stale entry swallow cancel forever")
	check_eq(_reverted, 1, "and emits nothing either")
	countdown.get_keep_button().pressed.emit()
	check_eq(_kept, 0, "and Keep cannot overturn a decision that already went out")

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


## [method MKModalLayer.clear_for_teardown] emits no modal_popped and the panel that owns this dialog
## is destroyed in the same teardown, so nobody is left to free it. The dialog disposes of itself
## through [code]_mk_layer_teardown[/code]; without that hook, every quit-while-open leaks one Control
## — and the harness's leaked-node gate is the second half of this assertion.
func _test_layer_teardown_disposes_the_dialog() -> void:
	var layer := MKModalLayer.new()
	layer.name = "TeardownLayer"
	get_root().add_child(layer)
	await step_frame()

	var countdown := _make_countdown_unparented()
	layer.push_modal(countdown)
	check_eq(layer.depth(), 1, "the countdown is stacked")

	layer.clear_for_teardown()
	check_eq(layer.depth(), 0, "teardown empties the stack")
	check_eq(_reverted, 0, "without resolving the dialog — teardown is not a decision")

	layer.queue_free()
	await step_frame()
	await step_frame()
	check(not is_instance_valid(countdown),
		"and the dialog freed ITSELF: unparented by the teardown and never popped, nothing else would")


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


## Escape on the countdown, driven through the REAL ladder: [code]MKRoot[/code] hands the gesture to
## [method MKModalLayer.handle_cancel], which hands it to the top modal.
##
## The dialog resolves synchronously and the panel removes it, so a dialog reporting "not consumed"
## had the layer pop a SECOND time — and with anything stacked beneath, that second pop destroyed a
## modal the player's Escape had nothing to do with. A host dialog is parked underneath here for
## exactly that reason: with an empty stack the bug is invisible, which is how it survived a round.
func _test_cancel_through_the_layer_pops_only_the_countdown() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	var host_modal := _make_host_modal()
	layer.push_modal(host_modal)
	check_eq(layer.depth(), 1, "a host modal is open beneath the settings row")

	button.select(1)
	button.item_selected.emit(1)
	check_eq(layer.depth(), 2, "the requires_confirm change stacks the countdown ON TOP of it")
	check(layer.top() is MKRevertCountdown, "which is the top of the stack")

	var handled := layer.handle_cancel()
	await step_frame()

	check(handled, "the layer reports the gesture handled")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"Escape reverted the setting")
	check_eq(layer.depth(), 1, "and removed exactly ONE modal")
	check_eq(layer.top(), host_modal,
		"the host's dialog is still open — a second pop here would have destroyed it")

	layer.pop_modal()
	host_modal.queue_free()
	await _drop_fixture(fixture)


## [b]The layer half of the declined cancel.[/b] A countdown that resolved while still stacked — its
## owner gone, so nothing left to call [method MKModalLayer.remove_modal] — used to consume every
## Escape forever, because [code]handle_cancel[/code] returned true unconditionally. That is the modal
## layer's own documented worst case: [code]is_empty()[/code] false forever, scrim up over nothing,
## every later cancel swallowed, and a host modal parked underneath unreachable.
##
## Driven at the layer, with something beneath, because that is where the swallowing is visible: the
## stale entry must be POPPED by the gesture it declines, and the next gesture must reach what was
## under it.
func _test_a_resolved_countdown_stops_swallowing_cancel() -> void:
	var layer := MKModalLayer.new()
	layer.name = "StaleLayer"
	get_root().add_child(layer)
	await step_frame()

	var host_modal := _make_host_modal()
	layer.push_modal(host_modal)
	var countdown := _make_countdown_unparented()
	layer.push_modal(countdown)
	check_eq(layer.depth(), 2, "a countdown is stacked over a host modal")

	# Resolved with NOBODY to remove it — the panel that owned it is gone. This is the corpse.
	countdown.get_revert_button().pressed.emit()
	check_eq(_reverted, 1, "the dialog resolved")
	check_eq(layer.depth(), 2, "and nothing took it off the stack, because its owner is gone")

	check(layer.handle_cancel(), "the first Escape is handled by the layer")
	check_eq(layer.depth(), 1,
		"and POPS the stale entry — the resolved dialog declines a gesture it cannot act on, so the layer self-heals instead of consuming it")
	check_eq(layer.top(), host_modal, "leaving the modal beneath it reachable")

	check(layer.handle_cancel(), "the next Escape is handled too")
	check_eq(layer.depth(), 0,
		"and reaches the host modal underneath — pre-fix, every Escape from here on vanished into the corpse")
	check_eq(_reverted, 1, "and none of it re-emitted a decision")

	countdown.queue_free()
	host_modal.queue_free()
	layer.queue_free()
	await step_frame()
	await step_frame()


## [b]D14's promise survives a nav tab.[/b] [code]MKRoot._show_page[/code] pops the whole modal stack
## on EVERY page change, so a live countdown was unparented: its [method Node._process] stopped, it
## never emitted, nothing freed it, and the un-confirmed display change stayed applied forever. One
## click on a nav tab voided the entire feature and leaked a Control doing it.
##
## Unconfirmed means NOT kept, so the departure resolves as a REVERT. The store is the assertion that
## matters; the leaked-node gate in the harness is the other half, and a subsequent visit proves
## nothing was left wedged.
func _test_a_page_change_reverts_an_unconfirmed_countdown() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	button.select(1)
	button.item_selected.emit(1)
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"the change is applied immediately, as D14 requires")
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "and the countdown is up")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	root.go_to_page(&"other")
	await step_frame()
	await step_frame()

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"navigating away REVERTS the unconfirmed change — the stack pop is not a confirmation")
	check_eq(button.selected, 0, "and the row that raised it goes back with the store")
	check_eq(layer.depth(), 0, "the modal stack is empty")
	check(not is_instance_valid(countdown),
		"and the dialog was FREED, not merely unparented — an orphan whose _process is dead leaks a Control and holds a decision nobody can make")

	button.select(1)
	button.item_selected.emit(1)
	check_eq(layer.depth(), 1,
		"and a later change still raises its countdown — nothing was left wedged in the layer or the panel")
	var again := layer.top() as MKRevertCountdown
	if again != null:
		again.get_keep_button().pressed.emit()
	await step_frame()
	await _drop_fixture(fixture)


## The other teardown order, and it really happens: the panel is destroyed while the countdown is
## STILL parented to the modal layer (a host tearing its options screen down, a rebuild). The panel is
## the only thing that knows what the previous value was, so it resolves what it raised before it lets
## go of the backend.
func _test_freeing_the_panel_reverts_an_unconfirmed_countdown() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up and still stacked")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	panel.queue_free()
	await step_frame()
	await step_frame()

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"the panel reverted what it had raised on its way out — the backend outlives it, which is why the STORE is the load-bearing half")
	check_eq(layer.depth(), 0, "and took the dialog off the stack")
	check(not is_instance_valid(countdown), "and freed it")

	await _drop_fixture(fixture)


## The countdown resolves on a TIMER, so anything pushed over it in those ten seconds is still on top
## when it lapses. Dismissal must therefore take THIS entry from wherever it sits
## ([method MKModalLayer.remove_modal]) rather than popping the top: popping would dismiss the modal
## above and leave the countdown wedged in the stack forever — is_empty() false, scrim up over
## nothing, every later cancel gesture swallowed.
func _test_dismissal_leaves_a_modal_stacked_above_it_alone() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	var host_modal := _make_host_modal()
	layer.push_modal(host_modal)
	check_eq(layer.depth(), 2, "and a host modal opens OVER it while it counts")

	countdown.start(0.1)
	await _advance_until(func() -> bool: return layer.depth() < 2, 120)
	await step_frame()

	check_eq(layer.depth(), 1, "the lapse removes exactly one entry")
	check_eq(layer.top(), host_modal,
		"and it is the COUNTDOWN that left — the modal above it is untouched")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"with the revert itself still performed")

	layer.pop_modal()
	host_modal.queue_free()
	await _drop_fixture(fixture)


## A control written from the STORE must not be mistaken for a user edit. Programmatic writes emit the
## same signals as input, so without the panel's _syncing guard an external write to a
## requires_confirm row raises a countdown for a change the user never made — and, worse, writes the
## value straight back.
##
## Driven on a SLIDER because assigning [member Range.value] genuinely emits value_changed; an
## OptionButton.select() does not, so the same test on the window-mode row would pass against a panel
## with no guard at all.
func _test_a_synced_control_raises_no_countdown() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var layer := root.get_modal_layer()

	var slider := _first_slider(panel)
	check(slider != null, "the fixture carries a requires_confirm SLIDER row")
	if slider == null:
		await _drop_fixture(fixture)
		return
	check_eq(layer.depth(), 0, "nothing is stacked before the write")

	backend.set_value(&"video/gamma_probe", 0.8)
	await step_frame()

	check_eq(slider.value, 0.8, "the store's write reached the widget")
	check_eq(layer.depth(), 0,
		"and raised NO countdown — the panel wrote that control, the user did not")
	check_eq(backend.get_value(&"video/gamma_probe", 0.0), 0.8,
		"and the sync echoed no write of its own")

	await _drop_fixture(fixture)


## A TEXT row commits on focus loss, which fires on every tab-through of an untouched field. On a
## requires_confirm row an unconditional write there raises a revert countdown over a field the user
## only passed through.
func _test_untouched_text_row_raises_no_countdown() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var layer := root.get_modal_layer()

	var edit := _first_line_edit(panel)
	check(edit != null, "the fixture carries a requires_confirm TEXT row")
	if edit == null:
		await _drop_fixture(fixture)
		return

	edit.grab_focus()
	await step_frame()
	edit.release_focus()
	edit.focus_exited.emit()
	await step_frame()

	check_eq(layer.depth(), 0,
		"tabbing through an untouched field commits nothing, so no countdown is raised")

	edit.text = "typed"
	edit.focus_exited.emit()
	await step_frame()
	check_eq(String(backend.get_value(&"gameplay/label_probe", "")), "typed",
		"while a field the user actually changed still commits on focus loss")
	check_eq(layer.depth(), 1, "and that one DOES raise the countdown its def asked for")

	# Resolved rather than popped: the panel owns the dismissal AND the free, so unwinding the stack
	# behind its back would unparent the dialog and leak it (the gate counts that as a failure).
	var raised := layer.top() as MKRevertCountdown
	if raised != null:
		raised.get_keep_button().pressed.emit()
	await step_frame()
	await _drop_fixture(fixture)


# --- Fixtures -----------------------------------------------------------------

## A stand-in for a dialog the HOST pushed: this layer never frees what it did not create, so a plain
## Control is exactly what a host modal looks like to it.
func _make_host_modal() -> Control:
	var modal := Control.new()
	modal.name = "HostModal"
	return modal


func _first_slider(node: Node) -> HSlider:
	for child in node.get_children():
		var slider := child as HSlider
		if slider != null:
			return slider
		var found := _first_slider(child)
		if found != null:
			return found
	return null


func _first_line_edit(node: Node) -> LineEdit:
	for child in node.get_children():
		var edit := child as LineEdit
		if edit != null:
			return edit
		var found := _first_line_edit(child)
		if found != null:
			return found
	return null


## The same dialog as [method _make_countdown], but left for the caller to parent — the modal layer
## adopts what it is pushed, and a dialog already parented to the root would only be reparented.
func _make_countdown_unparented() -> MKRevertCountdown:
	_kept = 0
	_reverted = 0
	var countdown := MKRevertCountdown.new()
	countdown.kept.connect(func() -> void: _kept += 1)
	countdown.reverted.connect(func() -> void: _reverted += 1)
	return countdown


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

	# Two more requires_confirm rows, of the types whose COMMIT gestures fire without user input: a
	# Range emits value_changed on a programmatic write, and a LineEdit emits focus_exited on every
	# tab-through. Both are ways a countdown gets raised over a change nobody made.
	var slider_def := MKSettingDef.new()
	slider_def.id = &"video/gamma_probe"
	slider_def.label = "Gamma Probe"
	slider_def.type = MKSettingDef.RowType.SLIDER
	slider_def.min_value = 0.0
	slider_def.max_value = 2.0
	slider_def.step = 0.05
	slider_def.default_value = 1.0
	slider_def.requires_confirm = true

	var text_def := MKSettingDef.new()
	text_def.id = &"gameplay/label_probe"
	text_def.label = "Label Probe"
	text_def.type = MKSettingDef.RowType.TEXT
	text_def.default_value = ""
	text_def.requires_confirm = true

	var page := MKSettingsPageDef.new()
	page.id = &"video"
	page.title = "Video"
	page.rows = [def, slider_def, text_def] as Array[MKSettingDef]

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
	# Untyped, and NOT cast. A typed assignment evaluates against a freed instance and raises "Trying
	# to assign invalid previously freed instance" — reachable because one test frees the panel itself
	# (that IS the test). Same reason MKModalLayer keeps its stack untyped.
	var panel = fixture["panel"]
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
	# A SECOND page, so a nav-tab move is stageable at all: _show_page pops the modal stack on every
	# page change, and with one page there is nowhere to go and the D14 hole is unreachable.
	var other := MKMenuPageDef.new()
	other.id = &"other"
	other.title = "Other"
	other.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(other)
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
