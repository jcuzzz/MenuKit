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
	await _test_clear_for_teardown_returns_ownership()
	await _test_pop_on_detached_layer_is_quiet()
	await _test_teardown_survives_a_re_entrant_removal()


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


## Teardown must hand host-owned modals back, not keep them parented. Clearing the stack while
## leaving entries under ModalHost meant the root's own free destroyed them — so an integrator who
## caches a confirm dialog across scene changes would find it dead after the first teardown, which
## contradicts the layer's documented "removed but NOT freed" ownership rule.
func _test_clear_for_teardown_returns_ownership() -> void:
	var panel := _make_panel()
	_layer.push_modal(panel)
	await step_frame()
	check_eq(panel.get_parent() != null, true, "panel is parented while stacked")

	_layer.clear_for_teardown()
	check(is_instance_valid(panel), "a host-owned modal survives teardown")
	check_eq(panel.get_parent(), null, "and is unparented, so the layer's free cannot take it with it")
	check(not panel.has_meta(MKFocus.TRAP_META), "and its focus trap is released")
	panel.free()


## A host calling pop_all() from its own teardown pops a layer that is already out of the tree, where
## get_viewport() is null. Unguarded, the focus-release path printed a script error — which every
## assertion in the suite passed straight through, because assertions cannot see engine output.
## The engine-noise gate in check.ps1 is what turns that into a failure.
func _test_pop_on_detached_layer_is_quiet() -> void:
	var host := Control.new()
	get_root().add_child(host)
	var layer := MKModalLayer.new()
	host.add_child(layer)
	await step_frame()

	var panel := _make_panel()
	layer.push_modal(panel)
	await step_frame()
	check_eq(layer.depth(), 1, "modal stacked on the detachable layer")

	# Detach, then pop — the shape of a host tearing down while a dialog is open.
	get_root().remove_child(host)
	check(layer.get_viewport() == null, "the detached layer really has no viewport")
	layer.pop_all()
	check(layer.is_empty(), "pop_all on a detached layer drains the stack without erroring")

	panel.free()
	host.free()


## [b]Teardown must survive an entry that reaches back into the layer while it is being drained.[/b]
##
## [method MKModalLayer.clear_for_teardown] unparents each entry, and [method Node.remove_child] fires
## [constant Node.NOTIFICATION_EXIT_TREE] SYNCHRONOUSLY — so a modal with a [signal Node.tree_exited]
## handler runs inside the drain loop. Iterated in place, a handler that removes an entry at or below
## the cursor shrinks [code]_stack[/code] underneath it: the entry that slides into the vacated index
## is skipped entirely — never untrapped, never unparented, never told the layer is going away, and
## then destroyed by the root's own free along with the layer.
##
## The shape is not invented for the test. Removing itself from the layer on [signal Node.tree_exited]
## is precisely what [MKSettingsPanel]'s revert countdown did until this round, and any host modal that
## keeps the layer's bookkeeping straight from its own teardown does the same thing.
func _test_teardown_survives_a_re_entrant_removal() -> void:
	var layer := MKModalLayer.new()
	layer.name = "ReentrantLayer"
	get_root().add_child(layer)
	await step_frame()

	var popped: Array[String] = []
	layer.modal_popped.connect(func(_c: Control) -> void: popped.append("pop"))

	var first := _make_panel()
	var second := _make_panel()
	layer.push_modal(first)
	await step_frame()
	layer.push_modal(second)
	await step_frame()
	check_eq(layer.depth(), 2, "two modals stacked")

	# `first` is the entry the drain reaches FIRST, and it removes ITSELF — so an in-place loop advances
	# its cursor past `second`, the entry that just slid down into index 0.
	first.tree_exited.connect(func() -> void:
		if is_instance_valid(layer):
			layer.remove_modal(first)
	)

	layer.clear_for_teardown()

	check_eq(layer.depth(), 0, "teardown still empties the stack")
	check_eq(second.get_parent(), null,
		"and the entry a re-entrant removal shifted past is STILL unparented — skipped, it would be freed with the layer, contradicting the layer's own 'removed but never freed' ownership rule")
	check(not second.has_meta(MKFocus.TRAP_META),
		"and its focus trap released, so a host reusing it as page content has no region focus cannot leave")
	check(not first.has_meta(MKFocus.TRAP_META), "the self-removing entry is released too")
	check_eq(popped.size(), 0,
		"and NOTHING was emitted: the stack is emptied before the drain runs, so a re-entrant remove_modal finds nothing and reports false rather than popping during teardown")

	first.free()
	second.free()
	layer.queue_free()
	await step_frame()
	await step_frame()


func _make_panel() -> Control:
	var panel := Control.new()
	panel.size = Vector2(200, 120)
	var button := Button.new()
	button.text = "OK"
	button.focus_mode = Control.FOCUS_ALL
	panel.add_child(button)
	return panel
