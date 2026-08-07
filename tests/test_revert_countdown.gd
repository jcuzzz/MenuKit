extends MKTest
## The confirm-or-revert countdown, standalone and driven through a real panel.
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
	await _test_freeing_the_panel_reverts_an_unconfirmed_countdown(false)
	await _test_freeing_the_panel_reverts_an_unconfirmed_countdown(true)
	await _test_freeing_the_panel_pops_under_the_shell_layout(false)
	await _test_freeing_the_panel_pops_under_the_shell_layout(true)
	await _test_the_corpse_frame_is_inert_and_self_heals()
	await _test_a_synced_control_raises_no_countdown()
	await _test_untouched_text_row_raises_no_countdown()
	await _test_shell_teardown_emits_no_modal_pops()
	await _test_shell_hard_free_emits_no_modal_pops()
	await _test_a_doomed_shell_declines_the_reap()
	await _test_teardown_disconnects_the_backend_before_reverting()
	await _test_a_second_change_replaces_the_live_countdown()
	await _test_different_rows_keep_independent_countdowns()
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


## [b]The defining property.[/b] Display settings are changed from the pause menu; a countdown that
## froze with the world would leave the dialog open forever, and the change it was going to revert
## applied.
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
## owner gone, so nothing left to call [method MKModalLayer.remove_modal] — must DECLINE the cancel
## rather than consuming it. A stale entry that answers [code]handle_cancel[/code] true reaches the
## modal layer's documented worst case: [code]is_empty()[/code] false forever, scrim up over nothing,
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


## [b]The promise survives a nav tab.[/b] [code]MKRoot._show_page[/code] pops the whole modal stack on
## EVERY page change, so an unhandled pop unparents a live countdown: its [method Node._process] stops,
## it never emits, nothing frees it, and the un-confirmed display change stays applied forever. One
## click on a nav tab would void the entire feature and leak a Control doing it.
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
## STILL parented to the modal layer (a host tearing its options screen down, a rebuild) — but the
## SHELL survives. The panel is the only thing that knows what the previous value was, so it resolves
## what it raised on its way out, and here it does a REAL pop.
##
## [b]Leaving it stacked was not a residual, it was a live defect.[/b] The dialog is
## [constant Node.PROCESS_MODE_ALWAYS], so a stacked one keeps ticking with its owner gone: it
## repaints, it lapses into a dropped connection, it traps focus, and it holds the suspension its push
## raised — a shell that is still running, with the world suspended, over a dialog whose Keep button
## does nothing. Then its first declined cancel unparents it without freeing it: a leaked Control.
##
## The suspension is raised here for exactly that reason: "the shell is alive and the suspend depth
## came back down" is the assertion, and it is unreachable with nothing suspended. The Escape
## afterwards is the other half — it must reach the PAGE (the root's own quit-confirm) rather than
## being eaten by a corpse.
##
## The teardown case, where an emission really is a hazard, is
## _test_shell_teardown_emits_no_modal_pops, and the two are what the deferred reap has to tell apart.
##
## [param hard_free] runs the SAME assertions with [method Node.free] instead of
## [method Node.queue_free], because the two reach the reap by different routes: a queued panel exits
## the tree inside the delete queue, a freed one exits synchronously, and only the second is what
## [method SceneTree.change_scene_to_packed] and engine shutdown do. A design that keyed off
## [method Node.is_queued_for_deletion] passed one and did a real mid-teardown pop on the other.
func _test_freeing_the_panel_reverts_an_unconfirmed_countdown(hard_free: bool) -> void:
	var how := "free()" if hard_free else "queue_free()"
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	check(root.open_pause_menu(&"other"), "the shell is suspended, as it is when display settings are changed")
	var base_depth := root.get_suspend_depth()
	check(base_depth > 0, "so the suspend counter is genuinely raised")

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up and still stacked")
	if countdown == null:
		await _drop_fixture(fixture)
		return
	check_eq(root.get_suspend_depth(), base_depth + 1, "and the push raised the suspension one further")

	if hard_free:
		panel.free()
	else:
		panel.queue_free()
	await step_frame()
	await step_frame()

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"the panel reverted what it had raised on its way out via %s — the backend outlives it, which is why the STORE is the load-bearing half" % how)
	check_eq(layer.depth(), 0,
		"and the dialog left the stack after %s: the SHELL is alive, so the reap pops for real — that is not the teardown hazard, it is the unwind" % how)
	# is_instance_valid FIRST, and not merged into a has_modal() call: passing a freed instance to a
	# typed Control parameter is itself an engine error, which the gate fails on.
	check(not is_instance_valid(countdown),
		"and it was FREED, not merely unparented — an ownerless PROCESS_MODE_ALWAYS dialog is a leak that keeps ticking (%s)" % how)
	check_eq(root.get_suspend_depth(), base_depth,
		"the suspension the push raised came back down — leaving it stacked held the world suspended under a dead dialog (%s)" % how)

	# "Consumed by the page, not a corpse" reads through the pause-resume rung: with the pause menu
	# open and both stacks empty the root answers Escape by CLOSING the pause menu, not by raising the
	# quit-confirm. A swallowed gesture would leave the pause menu open and the stack empty, which is
	# what the two assertions below refuse.
	check(_cancel(root), "and the next Escape is consumed (%s)" % how)
	check(not root.is_pause_menu_open(),
		"by the ROOT's pause-resume rung — the gesture reached the page, not a corpse (%s)" % how)
	check_eq(layer.depth(), 0, "and no stray modal appeared — the ladder stopped at the pause rung")

	await _drop_fixture(fixture)


## The SAME route, on the layout the shipped shell actually builds: the panel sits several levels down
## inside the page host, so it and the modal layer are detached in a different order than in the flat
## fixture. The deferred reap must not depend on that ordering, and this is the assertion that says so
## rather than the reasoning. Both free mechanisms, for the reason given on the flat-layout test.
func _test_freeing_the_panel_pops_under_the_shell_layout(hard_free: bool) -> void:
	var how := "free()" if hard_free else "queue_free()"
	var fixture := await _make_panel_fixture(null, true)
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	check(panel.get_parent() != root, "the panel is nested inside the page host, not a direct child of the shell")

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up and still stacked")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	if hard_free:
		panel.free()
	else:
		panel.queue_free()
	await step_frame()
	await step_frame()

	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0, "the store is put back (%s)" % how)
	check_eq(layer.depth(), 0, "and the dialog is reaped here too — the nesting does not change the answer (%s)" % how)
	check(not is_instance_valid(countdown), "and freed, so neither layout leaks one (%s)" % how)

	await _drop_fixture(fixture)


## [b]The frame between the mark and the reap, which the deferral buys and mark_resolved pays for.[/b]
##
## The orphan path cannot dispose of a stacked dialog synchronously — that is the mid-teardown pop the
## whole redesign exists to avoid — so for one flush the dialog sits on a LIVE stack with its owner
## already gone. Everything it could do in that window has to be off, and this is the only test that
## says so — without it [method MKRevertCountdown.mark_resolved] could be emptied to `pass`.
##
## Three properties, in the order they would bite a player:
## [br]- it is not running, and a forced advance of MORE than the full countdown emits nothing — a
##   ticking corpse lapses into a dropped connection and reverts a revert;
## [br]- an Escape in that window is DECLINED by the dialog, so the layer pops the stale entry and the
##   stack self-heals rather than swallowing every cancel until the reap lands;
## [br]- the reap that arrives afterwards finds the dialog already gone and still disposes of it,
##   because it must tolerate exactly that.
##
## [method Node._process] is driven directly rather than by awaiting frames, because awaiting a frame
## IS the reap: the window under test would be over before the assertion ran.
func _test_the_corpse_frame_is_inert_and_self_heals() -> void:
	var fixture := await _make_panel_fixture()
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

	var resolutions := [0]
	countdown.reverted.connect(func() -> void: resolutions[0] += 1)
	countdown.kept.connect(func() -> void: resolutions[0] += 1)

	# free(), not queue_free(): the panel must be gone SYNCHRONOUSLY so the assertions below run inside
	# the window, before any frame has flushed the reap.
	panel.free()

	check_eq(layer.depth(), 1, "the dialog is still stacked the instant its owner died — the reap is deferred, by design")
	check(layer.top() == countdown, "and it is still the top, so it is what a cancel gesture would reach")

	# The process-flag half of mark_resolved, asserted directly: the manual _process() call below
	# ignores set_process(), so WITHOUT these two lines that half is unprovable in principle — a
	# mark_resolved reduced to the latch alone would pass.
	check(not countdown.is_running(), "mark_resolved stopped the countdown running the moment its owner died")
	check(not countdown.is_processing(), "and turned its _process off — the corpse does not tick between frames")

	countdown._process(MKSettingsPanel.REVERT_SECONDS * 2.0)
	check_eq(resolutions[0], 0,
		"an advance of twice the full duration emits NOTHING — mark_resolved stopped it and latched it, so the corpse cannot lapse into handlers whose panel is gone")

	check(_cancel(root), "an Escape in that window is consumed")
	check_eq(layer.depth(), 0,
		"by the LAYER: the dialog declined the gesture, so handle_cancel popped the stale entry and the stack self-healed instead of swallowing it")
	check_eq(resolutions[0], 0, "and the declined cancel still emitted neither signal")

	await step_frame()
	await step_frame()
	check(not is_instance_valid(countdown),
		"and the reap, arriving on a dialog already off the stack, still freed it — tolerating that is the other half of its contract")

	await _drop_fixture(fixture)


## [b]Teardown must be silent, including the part of it the settings panel runs.[/b]
##
## [constant Node.NOTIFICATION_EXIT_TREE] propagates children first, so on
## [code]MKRoot.queue_free()[/code] the panel's [method Node._exit_tree] runs BEFORE MKRoot's. Its
## orphan-revert path called [method MKModalLayer.remove_modal], which pops for real: that emitted
## [signal MKModalLayer.modal_popped] and [signal MKModalLayer.emptied] mid-teardown, drove MKRoot's
## suspend counter to its 1→0 edge, called [method MKPausePolicy.exit_menu] on a policy already out of
## the tree, and restored the GAMEPLAY mouse mode onto the menu — every failure
## [method MKModalLayer.clear_for_teardown] exists to prevent, routed around it by its own caller. And
## MKRoot's own repair ran afterwards, reading a suspend depth the pop had already zeroed.
##
## The suspension is real here (the pause menu is open) because that is the state that makes the
## emission harmful; with nothing suspended the pops are silent and the bug is invisible.
func _test_shell_teardown_emits_no_modal_pops() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	check(root.open_pause_menu(&"other"),
		"the shell is suspended — the pause menu is where a player changes display settings")
	check(root.get_suspend_depth() > 0, "so the suspend counter is genuinely raised")

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "and a requires_confirm change stacked its countdown")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	var pops := [0]
	var empties := [0]
	layer.modal_popped.connect(func(_c: Control) -> void: pops[0] += 1)
	layer.emptied.connect(func() -> void: empties[0] += 1)

	root.queue_free()
	await step_frame()
	await step_frame()

	check_eq(pops[0], 0,
		"tearing the whole shell down emits NO modal_popped — the panel's teardown revert never reaches the modal stack")
	check_eq(empties[0], 0, "and no emptied either, which is the edge a host acts on")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"while the unconfirmed change is still put back, which is what D14 owes the player")
	check(not is_instance_valid(countdown),
		"and the dialog was disposed of by the layer's teardown, so silence did not cost a leak")

	await _drop_fixture(fixture)


## [b]The same silence when the shell is hard-freed, which is the common host path and the one the
## previous design got wrong.[/b]
##
## [method Node.queue_free] is not how a shell usually dies. Starting the game calls
## [method SceneTree.change_scene_to_file], which memdeletes the current scene; so does engine
## shutdown, and so does any host that calls [method Node.free] directly. None of them set
## [method Node.is_queued_for_deletion], so a discriminator built on that flag answered "the shell is
## alive" while the shell was being destroyed around it, and did a real remove_modal mid-teardown —
## the exact defect the queue_free test above was supposed to be catching, resurrected on the more
## common path. Measured, not argued: that shape emitted one modal_popped and one emptied.
##
## The deferred reap has no flag to get wrong here: the layer is destroyed before the message queue
## next flushes, and Godot drops a deferred call to a freed object.
func _test_shell_hard_free_emits_no_modal_pops() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	check(root.open_pause_menu(&"other"), "the shell is suspended, as it is when display settings are changed")
	check(root.get_suspend_depth() > 0, "so the suspend counter is genuinely raised")

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "and a requires_confirm change stacked its countdown")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	var pops := [0]
	var empties := [0]
	layer.modal_popped.connect(func(_c: Control) -> void: pops[0] += 1)
	layer.emptied.connect(func() -> void: empties[0] += 1)

	root.free()
	await step_frame()
	await step_frame()

	check_eq(pops[0], 0,
		"a hard free of the shell emits NO modal_popped either — the reap cannot arrive, because the layer it was addressed to no longer exists")
	check_eq(empties[0], 0, "and no emptied, which is the edge a host acts on")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"while the unconfirmed change is still put back, which is what D14 owes the player")
	check(not is_instance_valid(countdown),
		"and the dialog went with the shell's own subtree, so silence did not cost a leak — the harness's leak gate is the other half of this")

	await _drop_fixture(fixture)


## [b]The one shape where the reap DOES arrive on a doomed shell, and declines.[/b]
##
## Dropping the deferred call covers a shell that dies in one cascade, but not a host that queues the
## shell and then tears a panel down under it in the same frame (a page swap on the way out, an
## options screen freed as the menu closes). There the panel's [method Node._exit_tree] runs a flush
## EARLIER than the shell's deletion, so the reap really is delivered — to a layer that is alive, still
## holding the countdown, and already queued. A real pop there is precisely the mid-teardown emission
## [method MKModalLayer.clear_for_teardown] exists to prevent, and it is what the reap's own teardown
## guard refuses. Measured: without that guard this shape emits a modal_popped and an emptied.
func _test_a_doomed_shell_declines_the_reap() -> void:
	var fixture := await _make_panel_fixture()
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	check(root.open_pause_menu(&"other"), "the shell is suspended — the state that makes a stray emission harmful")

	button.select(1)
	button.item_selected.emit(1)
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "the countdown is up and still stacked")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	var pops := [0]
	var empties := [0]
	layer.modal_popped.connect(func(_c: Control) -> void: pops[0] += 1)
	layer.emptied.connect(func() -> void: empties[0] += 1)

	# The shell is doomed but NOT yet detached, so the layer survives to receive the reap the panel's
	# death schedules — the whole point of this shape.
	root.queue_free()
	panel.free()
	check(layer.depth() == 1, "the layer is still alive and still holding the dialog when the reap is scheduled")
	await step_frame()
	await step_frame()

	check_eq(pops[0], 0,
		"the reap arrived on a live-but-queued layer and DECLINED — a pop here drives the suspend counter to its 1-0 edge inside a teardown, on a pause policy already leaving the tree")
	check_eq(empties[0], 0, "and no emptied either")
	check(not is_instance_valid(countdown),
		"and clear_for_teardown disposed of the dialog instead, so declining did not cost a leak")

	await _drop_fixture(fixture)


## [b]The backend is disconnected BEFORE the teardown revert, and the order is the assertion.[/b]
##
## The revert is a real [method MKSettingsBackend.set_value], so with the connection still live it came
## straight back through [code]_on_setting_changed[/code] and re-entered [code]_sync_control[/code] on
## a panel that is mid-[method Node._exit_tree] — writing widgets from inside the notification that is
## freeing them. Asserting "no error appeared" would pass against either order, so the probe backend
## records, at the moment of each write, whether the panel was still subscribed.
func _test_teardown_disconnects_the_backend_before_reverting() -> void:
	var probe := OrderProbeBackend.new()
	probe._mk_configure({"file_path": STORE_PATH})
	var fixture := await _make_panel_fixture(probe)
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	probe.watch(panel)

	button.select(1)
	button.item_selected.emit(1)
	check(probe.last_write_was_connected(),
		"an ordinary row write lands while the panel IS subscribed — that is the live path, and the probe can see it")

	panel.queue_free()
	await step_frame()
	await step_frame()

	check(not probe.last_write_was_connected(),
		"but the TEARDOWN revert lands with the panel already disconnected — resolving first sent it back through _on_setting_changed and into _sync_control on a dying panel")

	await _drop_fixture(fixture)


## [b]A second change to the SAME row replaces its countdown; it does not stack another.[/b]
##
## Two live dialogs over one setting meant two timers, and the older one carried the intermediate value
## as its [code]previous[/code]: a player who pressed Keep on the second dialog watched the first lapse
## a moment later and drag the setting back over the change they had just confirmed. And the chain is
## the other half — A→B→C reverts to A, because B was never confirmed either, so restoring B would
## restore a value the user never agreed to keep.
func _test_a_second_change_replaces_the_live_countdown() -> void:
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
	check_eq(slider.value, 1.0, "which starts on its default — the value a full revert must reach")

	slider.value = 1.5
	check_eq(layer.depth(), 1, "the first change raises one countdown")
	var countdown := layer.top() as MKRevertCountdown
	check(countdown != null, "which is the revert dialog")
	if countdown == null:
		await _drop_fixture(fixture)
		return

	# Let it tick, so a restarted timer is distinguishable from an untouched one.
	await step_frame()
	await step_frame()
	check(countdown.get_time_left() < MKSettingsPanel.REVERT_SECONDS, "and it is counting down")

	slider.value = 1.8
	check_eq(layer.depth(), 1,
		"a SECOND change to the same row stacks NOTHING — one dialog per setting, or two timers race over one value")
	check_eq(layer.top(), countdown, "it is the same dialog, still the top of the stack")
	check_eq(countdown.get_time_left(), MKSettingsPanel.REVERT_SECONDS,
		"with its timer RESTARTED — the user just acted, so they get the full window to react to what they can now see")
	check_eq(backend.get_value(&"video/gamma_probe", 0.0), 1.8,
		"and the newest change is applied immediately, as D14 requires")

	countdown.start(0.1)
	await _advance_until(func() -> bool: return layer.depth() == 0, 120)

	check_eq(backend.get_value(&"video/gamma_probe", 0.0), 1.0,
		"the lapse restores the value from before the FIRST unconfirmed change — chaining to the intermediate 1.5 would restore something the user never confirmed either")
	check(is_equal_approx(slider.value, 1.0), "and the control goes back with it")

	await _drop_fixture(fixture)


## Different ids stay independent: a window-mode countdown has nothing to say about a gamma change,
## and collapsing them onto one entry would let either revert overwrite the other's row.
func _test_different_rows_keep_independent_countdowns() -> void:
	var fixture := await _make_panel_fixture()
	var backend: MKJsonSettingsBackend = fixture["backend"]
	var root: MKRoot = fixture["root"]
	var panel: MKSettingsPanel = fixture["panel"]
	var button: OptionButton = fixture["option"]
	var layer := root.get_modal_layer()

	var slider := _first_slider(panel)
	check(slider != null, "the fixture carries the SLIDER row")
	if slider == null:
		await _drop_fixture(fixture)
		return

	slider.value = 1.5
	button.select(1)
	button.item_selected.emit(1)
	check_eq(layer.depth(), 2,
		"two DIFFERENT requires_confirm rows raise two countdowns — each def's revert is its own")

	# Resolve the window-mode one on top by keeping it; the gamma one underneath must be untouched.
	var top := layer.top() as MKRevertCountdown
	check(top != null, "the window-mode dialog is on top")
	if top != null:
		top.get_keep_button().pressed.emit()
	await step_frame()

	check_eq(layer.depth(), 1, "keeping one leaves the other stacked")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"the kept row keeps its new value")

	var remaining := layer.top() as MKRevertCountdown
	check(remaining != null, "and the gamma dialog is still live")
	if remaining != null:
		remaining.start(0.1)
		await _advance_until(func() -> bool: return layer.depth() == 0, 120)

	check_eq(backend.get_value(&"video/gamma_probe", 0.0), 1.0,
		"whose lapse reverts ITS row")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"and leaves the row that was confirmed alone — one entry for both ids would have dragged this back too")

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


## A real [MKJsonSettingsBackend] that records, for every write, whether the panel was still
## subscribed to [signal MKSettingsBackend.setting_changed] at the moment it landed.
##
## A subclass rather than a stub: the ordering under test is between the panel's own
## [method Node._exit_tree] steps, so everything except the recording must be the shipped backend's
## behaviour. It observes the CONNECTION rather than a side effect because the side effect — a sync
## re-entering a panel that is being freed — is invisible to an assertion and only sometimes an error.
class OrderProbeBackend extends MKJsonSettingsBackend:
	var _panel: Node
	## One entry per set_value, in order. The LAST is the teardown revert.
	var connected_at_write: Array[bool] = []

	func watch(panel: Node) -> void:
		_panel = panel

	func set_value(id: StringName, value: Variant) -> void:
		connected_at_write.append(_panel != null and is_instance_valid(_panel)
			and setting_changed.is_connected(Callable(_panel, "_on_setting_changed")))
		super(id, value)

	func last_write_was_connected() -> bool:
		return not connected_at_write.is_empty() \
			and connected_at_write[connected_at_write.size() - 1]


## A real MKRoot (for its modal layer), a real JSON backend, and a panel carrying one
## requires_confirm ENUM row — the shipped Video page's window-mode shape, minus the rest.
##
## [param backend_override] lets a test supply an observing subclass; null builds the plain one.
##
## [param nest_in_page_host] parents the panel inside the shell's page host instead of directly under
## [MKRoot] — the layout a host really gets when the panel is page content, and a DIFFERENT
## detach order relative to the modal layer. The orphan discriminator is asserted under both.
func _make_panel_fixture(backend_override: MKJsonSettingsBackend = null,
		nest_in_page_host := false) -> Dictionary:
	_clean()
	var backend := backend_override
	if backend == null:
		backend = MKJsonSettingsBackend.new()
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
	var host: Node = root
	if nest_in_page_host:
		var page_host := root.find_child("PageHost", true, false)
		check(page_host != null, "the shell built a page host to nest the panel in")
		if page_host != null:
			host = page_host.get_child(0) if page_host.get_child_count() > 0 else page_host
	host.add_child(panel)
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
	# The ROOT is untyped for the same reason as the panel now: one test frees the whole shell (that IS
	# the test), and a typed assignment evaluates against the freed instance and raises "Trying to
	# assign invalid previously freed instance" — an engine error the gate fails on.
	var root = fixture["root"]
	if is_instance_valid(root):
		root.queue_free()
	var backend = fixture["backend"]
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
	# page change, and with one page there is nowhere to go and the case is unreachable.
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


## Feeds a real ui_cancel through the viewport's unhandled-input path, so the precedence ladder is
## exercised through the engine's own dispatch order rather than by calling a handler directly.
## Returns whether the viewport marked the event handled, so a check against it can actually fail.
func _cancel(root: MKRoot) -> bool:
	var viewport := root.get_viewport()
	var ev := InputEventAction.new()
	ev.action = &"ui_cancel"
	ev.pressed = true
	viewport.push_input(ev)
	return viewport.is_input_handled()


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
