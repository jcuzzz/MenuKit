extends MKTest
## [MKModalLayer]'s hostile-input paths (plan §1.3).
##
## Every case here was a real defect that shipped green, because the navigation suite exercises only
## the happy path. A mutation audit found five fixes with no test that failed without them; these are
## those cases. The rule this file exists to enforce: a fix is not done until something fails when it
## is reverted.

var _layer: MKModalLayer
var _host: Control


func run_tests() -> void:
	_host = Control.new()
	_host.size = Vector2(800, 600)
	get_root().add_child(_host)
	_layer = MKModalLayer.new()
	_host.add_child(_layer)
	await step_frame()

	await _test_freed_entry_pops_cleanly()
	await _test_handle_cancel_unwedges_freed_top()
	await _test_remove_modal_releases_focus_trap()
	await _test_clear_for_teardown_is_silent()


## A host that frees a dialog it pushed itself leaves a corpse in the stack. Popping it must not
## cast it: `as Control` evaluates against a freed instance and prints "Trying to cast a freed
## object" — a red engine error on a legitimate path, in a package whose ship gate is zero warnings.
func _test_freed_entry_pops_cleanly() -> void:
	var panel := _make_panel()
	_layer.push_modal(panel)
	await step_frame()
	check_eq(_layer.depth(), 1, "pushed a host-owned panel")
	panel.free()
	_layer.pop_modal()
	check_eq(_layer.depth(), 0, "a freed entry pops without error")
	check(_layer.is_empty(), "and the layer reports empty afterwards")


## handle_cancel used to return false and pop nothing when the top entry had been freed, so
## is_empty() reported false forever: the scrim stayed up over nothing and every later cancel was
## swallowed. MKRoot has a fallback; a host driving the public API directly does not.
func _test_handle_cancel_unwedges_freed_top() -> void:
	var panel := _make_panel()
	_layer.push_modal(panel)
	await step_frame()
	panel.free()
	var consumed := _layer.handle_cancel()
	check(consumed, "handle_cancel consumes the gesture even when the top entry was freed")
	check(_layer.is_empty(), "and clears the corpse rather than wedging the stack forever")


## remove_modal on a NON-top entry must release the focus trap, exactly as pop_modal does. Without
## it the control keeps its wrap-around neighbour ring, so a host that caches a dialog and later
## reuses it as page content has a region focus can enter and never leave.
func _test_remove_modal_releases_focus_trap() -> void:
	var lower := _make_panel()
	var upper := _make_panel()
	_layer.push_modal(lower)
	await step_frame()
	_layer.push_modal(upper)
	await step_frame()
	check_eq(_layer.depth(), 2, "two modals stacked")

	check(lower.has_meta(MKFocus.TRAP_META), "the lower modal is focus-trapped while stacked")
	var removed := _layer.remove_modal(lower)
	check(removed, "remove_modal finds a non-top entry")
	check_eq(_layer.depth(), 1, "and removes exactly one entry")
	check(not lower.has_meta(MKFocus.TRAP_META),
		"the removed modal's focus trap is released, or focus can enter it and never leave")

	var button := lower.get_child(0) as Button
	check(button != null, "panel carries its button")
	if button != null:
		check(button.focus_neighbor_bottom.is_empty(),
			"and its wrap-around neighbour ring is gone")

	_layer.pop_all()
	await step_frame()
	check(_layer.is_empty(), "stack drained")
	# Host-owned panels: the layer removes but never frees what it did not create, so the test owns
	# the cleanup. Leaving them queues leaked-ObjectDB noise at exit, which is the signal a real node
	# leak would otherwise announce itself with.
	lower.free()
	upper.free()


## Teardown must DISCARD the stack, not pop it. A real pop reaches MKRoot's 1→0 suspend edge and
## calls exit_menu on a policy already out of the tree — the crash the plan spent a revision
## correcting — and restores a gameplay cursor onto the main menu.
func _test_clear_for_teardown_is_silent() -> void:
	var popped: Array[String] = []
	var on_popped := func(_c: Control) -> void: popped.append("pop")
	_layer.modal_popped.connect(on_popped)

	var a := _make_panel()
	var b := _make_panel()
	_layer.push_modal(a)
	await step_frame()
	_layer.push_modal(b)
	await step_frame()
	check_eq(_layer.depth(), 2, "two modals before teardown")

	_layer.clear_for_teardown()
	check_eq(_layer.depth(), 0, "clear_for_teardown empties the stack")
	check_eq(popped.size(), 0,
		"and emits NO modal_popped — the signal is what drives the suspend edge into a detached policy")

	_layer.modal_popped.disconnect(on_popped)
	a.free()
	b.free()


func _make_panel() -> Control:
	var panel := Control.new()
	panel.size = Vector2(200, 120)
	var button := Button.new()
	button.text = "OK"
	button.focus_mode = Control.FOCUS_ALL
	panel.add_child(button)
	return panel
