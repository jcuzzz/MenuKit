@tool
class_name MKModalLayer
extends Control
## The modal stack: push/pop, a mouse-blocking scrim, and focus save/restore (plan §1.3).
##
## This is greenfield, not a port. The source project's [code]ModalLayer[/code] is a fullscreen
## click-blocker whose real job is group bookkeeping for click-to-move; it has no stack, no dim and
## no focus management, and the source main menu does not use it at all. Nothing about it was
## reusable, so the contract here is written from the requirement instead.
##
## [b]Why Control and NOT CanvasLayer — do not "fix" this back.[/b] This node was a [CanvasLayer]
## once, for draw order: a [CanvasLayer] gets its own layer index, so it renders above the page no
## matter where [code]MKRoot[/code] sits in a host's tree. That reasoning is real but it is
## outweighed, and the cost is not subtle:
## [br]- A [Theme] propagates down the [b]Control[/b] tree only. A [CanvasLayer] is not a [Control],
##   so it SEVERS propagation. [code]MKRoot[/code] assigns the palette-generated Theme to itself, so
##   every dialog parented under a CanvasLayer fell back to the engine default theme: grey buttons,
##   no panel background, and a [constant MKTheme.DANGER_BUTTON] delete button that was not red.
##   That breaks D4 re-skinning and ship gate 3, which is the entire promise of the package.
## [br]- A [Control] under a bare [CanvasLayer] has no parent rect driving its layout, so full-rect
##   anchors resolve against nothing and a centred dialog lands in the top-left at its minimum size.
##
## Draw order is preserved the Control way instead, cheaply and without giving up theming:
## [br]- [code]MKRoot._build_shell()[/code] adds this node LAST, and sibling draw order is tree
##   order, so it is already above the page host. That ordering is load-bearing and commented there.
## [br]- [member CanvasItem.z_index] (see [member modal_z_index]) lifts it above siblings even if a
##   host or a later refactor inserts something after it.
## [br][member CanvasItem.top_level] is deliberately NOT used: it detaches this node from the parent
## rect, which would reintroduce exactly the layout half of the bug described above.
##
## The layout work happens on an internal fullscreen [Control] host, built in code so the scene and
## the script can never drift apart.
##
## [b]Why this node does not read input.[/b] Cancel is a stack discipline (plan §4.4/§4.7a): the
## precedence ladder is rebind capture → modal stack top → page back stack → root quit-confirm.
## [code]MKRoot[/code] owns [code]_unhandled_input[/code] and calls [method handle_cancel]; if this
## node also read [code]ui_cancel[/code] it would consume the gesture out of turn and the ladder
## would be decided by node order instead of by policy.
##
## [b]Process mode.[/b] The whole [code]MKRoot[/code] subtree runs [constant Node.PROCESS_MODE_ALWAYS]
## (plan §4.2a) so the pause menu works under [code]get_tree().paused[/code]. This node deliberately
## leaves [member Node.process_mode] at [constant Node.PROCESS_MODE_INHERIT] — inherit it, do not
## fight it.

## Emitted after [param control] is parented and focused. Consumers use it for audio/analytics.
signal modal_pushed(control: Control)

## Emitted after [param control] leaves the stack, before focus restoration completes is not
## guaranteed — treat the control as still valid but no longer owned by this layer.
signal modal_popped(control: Control)

## Emitted once the stack reaches zero, after the final [signal modal_popped]. This is the edge a
## host cares about ("the world is interactive again"); polling [method depth] every frame is not.
signal emptied()

## Scrim tint. A plain [ColorRect] colour, not a theme override — MenuKit ships zero
## [code]add_theme_*_override[/code] calls (ship gate 1), and a dim is presentation of this node's
## own child rather than a restyle of someone else's control.
@export var scrim_color := Color(0.0, 0.0, 0.0, 0.6):
	set(value):
		scrim_color = value
		if _scrim != null and is_instance_valid(_scrim):
			_scrim.color = value

## Optional scrim material, so a host can supply a blur shader without MenuKit shipping one.
## A built-in blur would need a BackBufferCopy and a shader file per renderer; the dim is the
## portable default and the hook keeps the fancier version a host decision.
@export var scrim_material: Material:
	set(value):
		scrim_material = value
		if _scrim != null and is_instance_valid(_scrim):
			_scrim.material = value

## Draw order among siblings. High by default so a modal sits above anything a host or a later
## refactor parents alongside it. This is a [member CanvasItem.z_index], not a [CanvasLayer] index:
## see the class doc for why this node must stay a [Control].
@export var modal_z_index := 128:
	set(value):
		modal_z_index = clampi(value, RenderingServer.CANVAS_ITEM_Z_MIN,
			RenderingServer.CANVAS_ITEM_Z_MAX)
		z_index = modal_z_index

var _host: Control
var _scrim: ColorRect
var _stack: Array[Control] = []
## Parallel to [member _stack]: the focus owner at the moment of each push. Stored as an
## [ObjectID]-safe reference and ALWAYS re-checked with [method @GlobalScope.is_instance_valid]
## before use — the remembered control is routinely freed while the modal is open (a settings row
## whose panel rebuilt, a roster entry the modal just deleted). Plan §1.3 names this explicitly.
## Deliberately untyped: a typed [code]Array[Control][/code] REFUSES to hand back an element whose
## object has been freed ("Trying to assign invalid previously freed instance"), which is precisely
## the case this array exists to survive.
var _focus_memory: Array = []
var _restoring_focus := false


func _ready() -> void:
	# Offsets as well as anchors: set_anchors_preset alone leaves the rect at its old size, which is
	# how a "full rect" modal layer ends up 280px wide in the top-left corner.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = modal_z_index
	_build_host()
	_sync_scrim()
	if not Engine.is_editor_hint():
		get_viewport().gui_focus_changed.connect(_on_gui_focus_changed)


func _build_host() -> void:
	if _host != null and is_instance_valid(_host):
		return
	_host = Control.new()
	_host.name = "ModalHost"
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_host)
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# STOP, not PASS: the scrim's entire job is that no click reaches anything beneath the top modal.
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.color = scrim_color
	_scrim.material = scrim_material
	_scrim.visible = false
	_host.add_child(_scrim)


## Pushes [param control] onto the stack, parenting it above the scrim, remembering the current
## focus owner and trapping focus inside it.
## Re-pushing an already-stacked control is refused rather than corrupting the stack — a
## double-click on an Open button is a normal way to hit that.
func push_modal(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		MKLog.warn("MKModalLayer.push_modal: null or freed control ignored")
		return
	if _stack.has(control):
		MKLog.warn("MKModalLayer.push_modal: '%s' is already on the stack" % control.name)
		return
	_build_host()
	_focus_memory.append(get_viewport().gui_get_focus_owner() if not Engine.is_editor_hint() else null)
	_stack.append(control)
	if control.get_parent() == null:
		_host.add_child(control)
	elif control.get_parent() != _host:
		control.reparent(_host)
	control.visible = true
	_sync_scrim()
	MKFocus.trap(control)
	MKLog.debug("MKModalLayer: pushed '%s' (depth %d)" % [control.name, _stack.size()])
	modal_pushed.emit(control)


## Pops the top modal, releases its focus trap and restores the focus owner recorded at its push.
## Restoration is guarded by [method @GlobalScope.is_instance_valid]: when the remembered control
## was freed while the modal was open, focus falls back to the new top modal (if any) and otherwise
## is simply left alone — never a crash, which is a Phase 1 exit criterion.
## The popped control is removed from this layer but NOT freed; ownership returns to whoever pushed
## it, so a cached dialog can be reused.
func pop_modal() -> void:
	if _stack.is_empty():
		return
	# Untyped, and NOT cast. `as Control` evaluates against a freed instance and prints
	# "Trying to cast a freed object" — reachable whenever a host frees a dialog it pushed itself.
	# _focus_memory is untyped for exactly this reason; _stack carries the identical risk.
	var control = _stack.pop_back()
	var remembered = _focus_memory.pop_back()
	if control != null and is_instance_valid(control):
		MKFocus.release(control)
		if control.get_parent() == _host:
			_host.remove_child(control)
	_sync_scrim()
	MKLog.debug("MKModalLayer: popped '%s' (depth %d)"
		% [control.name if control != null and is_instance_valid(control) else "<freed>", _stack.size()])
	modal_popped.emit(control)
	_restore_focus(remembered)
	if _stack.is_empty():
		emptied.emit()


## Removes [param control] from anywhere in the stack, not just the top.
##
## Exists so a modal that closes itself while something is stacked above it has a route that keeps
## the layer's bookkeeping intact. Reaching around the layer — reparenting and freeing directly —
## leaves the entry in [member _stack], so [method is_empty] reports false forever, the scrim stays
## up over nothing, and [code]MKRoot[/code] swallows every cancel gesture from then on. A permanently
## dead menu with no diagnostic.
##
## Returns whether the control was found. Popping the top routes through [method pop_modal] so focus
## restoration still happens.
func remove_modal(control: Control) -> bool:
	var index := _stack.find(control)
	if index == -1:
		return false
	if index == _stack.size() - 1:
		pop_modal()
		return true
	_stack.remove_at(index)
	_focus_memory.remove_at(index)
	if control != null and is_instance_valid(control):
		# Release the focus trap, exactly as pop_modal does. Without it the control keeps its
		# wrap-around neighbour ring and its trapped marker, so a host that caches a dialog and later
		# reuses it as ordinary page content has a region focus can enter and never leave.
		MKFocus.release(control)
		if control.get_parent() == _host:
			_host.remove_child(control)
	_sync_scrim()
	modal_popped.emit(control)
	return true


## Whether [param control] is currently on this stack. A read-only query, so an owner can decide
## whether it still has to dispose of a modal without mutating the stack to find out — which
## [method remove_modal] would, and which is exactly what a teardown path must not do.
##
## [MKSettingsPanel._resolve_orphaned_countdown] is the caller this exists for: a dialog the layer has
## already let go of (a [method pop_all] on a page change) is freed by the panel there and then, while
## one that is still stacked is handed to [method reap_modal] deferred — because disposing of it
## synchronously is a stack mutation, and that path may be running inside a teardown.
func has_modal(control: Control) -> bool:
	return _stack.has(control)


## Disposes of a modal whose owner died while it was still stacked: removes it from the stack and
## frees it — [b]unless this layer is itself being torn down[/b], in which case it does nothing.
##
## [b]Always call this deferred[/b] ([code]layer.call_deferred(&"reap_modal", dialog)[/code]).
## The deferral is not tidiness, it is the whole mechanism, and it is what makes the two teardown
## shapes decide themselves instead of being told apart by a flag:
## [br]- [b]The shell is destroyed with the dialog still stacked[/b] — [method Node.free], a
##   [method SceneTree.change_scene_to_packed] memdelete of the current scene, engine shutdown, or a
##   [method Node.queue_free] whose delete cascade reaches this layer. This layer is gone before the
##   [code]MessageQueue[/code] next flushes, and Godot drops a deferred call whose target object has
##   been freed. So nothing runs, nothing is emitted, and the dialog is freed with this layer's own
##   subtree. That is measured behaviour, not an assumption: a call deferred onto a node that is
##   memdeleted before the next flush never arrives.
## [br]- [b]Only the owner died and this layer outlives it[/b] — the deferred call arrives on a live
##   layer, the guard below is false, and the modal is popped for real. A real pop is the REQUIREMENT
##   here, not a hazard: the emissions unwind the host's suspend depth and mouse mode, which the push
##   had raised.
##
## The guard is still load-bearing on top of the drop, because the drop is not universal: a host that
## DETACHES the shell and then queues it ([code]remove_child(root)[/code] then
## [code]root.queue_free()[/code]) runs the owner's [method Node._exit_tree] a flush earlier than the
## deletion, so the deferred call really does arrive — on a layer that is alive but doomed. Emitting
## there is the exact mid-teardown pop [method clear_for_teardown] exists to prevent. Hence the walk:
## whether this layer, or anything above it, is queued for deletion. It is a walk rather than a check
## on this node because the queued flag is set on whichever ancestor the host called
## [method Node.queue_free] on and is not propagated down.
##
## Tolerant by design: the dialog may already have been popped, or freed, in the frame between the
## schedule and the flush (a cancel gesture in that window is declined by the resolved dialog, so the
## layer pops it and self-heals). Both are no-ops here rather than errors.
func reap_modal(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	if _is_tearing_down():
		# clear_for_teardown owns disposal from here; a pop now would emit mid-teardown.
		return
	# false — "not on this stack" — is fine: something already let go of it, and the free is still owed.
	remove_modal(control)
	control.queue_free()


## Whether this layer, or any ancestor, is queued for deletion.
func _is_tearing_down() -> bool:
	var node: Node = self
	while node != null:
		if node.is_queued_for_deletion():
			return true
		node = node.get_parent()
	return false


## Empties the stack during teardown [b]without emitting [signal modal_popped][/b].
##
## Teardown must not route through the normal pop path. [constant Node.NOTIFICATION_EXIT_TREE]
## propagates children first, so when [code]MKRoot._exit_tree[/code] runs, both this layer and the
## pause policy are already detached. A real pop there would drive MKRoot's suspend counter to its
## 1→0 edge and call [code]MKPausePolicy.exit_menu[/code] on a policy whose
## [method Node.get_tree] is null — crashing the shipped tree policy on exactly the
## quit-while-paused sequence the plan spent a revision correcting. It would also restore the
## [i]saved[/i] cursor, which was captured from gameplay, leaving the main menu with an invisible
## captured cursor.
##
## So teardown discards rather than unwinds: MKRoot zeroes its own counters, and each policy undoes
## its own effects in its own [method Node._exit_tree] while its tree reference is still valid.
func clear_for_teardown() -> void:
	# DRAINED FROM A SNAPSHOT, and the stack is emptied BEFORE the loop body runs — not iterated in
	# place. remove_child() fires NOTIFICATION_EXIT_TREE synchronously, so any handler an entry (or one
	# of its descendants) has on tree_exited can re-enter remove_modal and shrink _stack underneath the
	# cursor: an entry removed at or below the current index slides the rest down one, and the entry
	# that lands on the vacated index is SKIPPED — never untrapped, never unparented, never told the
	# layer went away, and then destroyed by the root's own free. Emptying first also makes any such
	# re-entrant remove_modal a no-op that finds nothing and emits nothing, which is what teardown
	# requires of it.
	var draining := _stack.duplicate()
	_stack.clear()
	_focus_memory.clear()
	# Unparent and untrap each entry, exactly as a pop would — just without the signal. This layer
	# never frees what it did not create (a host may cache a dialog and reuse it), so leaving entries
	# parented here would hand them to the root's own free and destroy them with it.
	for control in draining:
		if control == null or not is_instance_valid(control):
			continue
		MKFocus.release(control)
		if control.get_parent() == _host:
			_host.remove_child(control)
		# Teardown emits no modal_popped, so anything that frees itself on that signal would leak
		# now that it is also unparented. A modal may implement `_mk_layer_teardown()` to dispose of
		# itself; the layer still never decides ownership, it just tells the entry the layer is going
		# away. Host-owned modals implement nothing and are simply handed back.
		if control.has_method("_mk_layer_teardown"):
			control.call("_mk_layer_teardown")
	_sync_scrim()


## Pops every modal, newest first, emitting the same signals as individual pops.
## Page changes must never leave a modal orphaned above the new page (plan §4.7a), and a host
## closing the menu wholesale needs one call it can trust.
func pop_all() -> void:
	while not _stack.is_empty():
		pop_modal()


## Number of modals currently stacked. Cheap enough for an assertion, not intended for per-frame use.
func depth() -> int:
	return _stack.size()


## True when nothing is stacked — the condition [code]MKRoot[/code] checks before letting cancel
## fall through to the page back stack.
func is_empty() -> bool:
	return _stack.is_empty()


## The modal that currently owns input, or null. Freed entries are reported as null rather than
## returned, so callers cannot receive a dangling reference.
func top() -> Control:
	if _stack.is_empty():
		return null
	var c := _stack[_stack.size() - 1]
	return c if is_instance_valid(c) else null


## Dispatches a cancel gesture to the top modal. [code]MKRoot[/code] calls this from its own
## [code]_unhandled_input[/code] as rung two of the precedence ladder.
##
## [b]Declining happens at the modal, not here.[/b] A modal may define
## [code]handle_cancel() -> bool[/code] and return [code]true[/code] to keep the gesture and stay open
## (a rebind row that is listening, a wizard step that goes back one step instead of closing);
## anything else is closed by popping, which is what every simple dialog wants without writing code
## for it.
##
## The [code]false[/code] this returns means only "there was no live modal to hand it to" — i.e. the
## top entry had been freed. It does [b]not[/b] pass the gesture down to the page back stack: while
## the stack is non-empty the gesture belongs to the stack, and letting it fall through would pop a
## page out from under an open modal, which is the desync this ladder exists to prevent.
func handle_cancel() -> bool:
	var control := top()
	if control == null:
		# Non-empty stack with a freed top: the entry is a corpse. Clear it here rather than reporting
		# "nothing to hand it to" and leaving it wedged — otherwise is_empty() reports false forever,
		# the scrim stays up over nothing, and every later cancel gesture is swallowed. MKRoot has a
		# fallback for this, but a host driving the layer through its public API does not.
		if not _stack.is_empty():
			pop_modal()
			return true
		return false
	if control.has_method("handle_cancel"):
		var consumed: bool = control.call("handle_cancel")
		if consumed:
			return true
	pop_modal()
	return true


func _restore_focus(remembered) -> void:
	_restoring_focus = true
	var target := top()
	if target != null:
		MKFocus.focus_first(target)
	# is_instance_valid MUST come before `is Control` — the `is` operator itself errors on a
	# previously freed instance, so the order of these two checks is load-bearing.
	elif is_instance_valid(remembered) and remembered is Control and remembered.is_inside_tree() \
			and remembered.is_visible_in_tree() and remembered.focus_mode != Control.FOCUS_NONE:
		(remembered as Control).grab_focus()
	else:
		# The remembered control was freed or hidden while the modal was open. Focus is RELEASED
		# rather than left where it was: the popped modal's own button would otherwise keep it,
		# and an off-tree control holding focus is an invisible keyboard dead end.
		MKLog.debug("MKModalLayer: focus memory unusable on pop — releasing focus")
		# Guarded: during teardown this layer is already out of the tree and get_viewport() is null.
		# Unguarded, every quit-to-menu with a dialog open printed a script error.
		var viewport := get_viewport()
		if viewport != null:
			viewport.gui_release_focus()
	_restoring_focus = false


## Keeps the scrim's visibility, its position in the child order, and this node's own
## [member Control.mouse_filter] in step with the stack — one function, so the three can never drift.
##
## [b]The filter MUST be state-driven.[/b] Now that this node is a full-rect [Control] covering the
## whole shell, a permanent [constant Control.MOUSE_FILTER_STOP] would swallow every click on the
## page underneath and the menu would look dead — the obvious regression this conversion invites. So
## it STOPs only while something is stacked and IGNOREs otherwise. The scrim already STOPs on its
## own (and is hidden, hence non-interactive, when the stack is empty); this is the belt to its
## braces, and it is what makes the no-modal case explicit rather than incidental.
func _sync_scrim() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if not _stack.is_empty() \
		else Control.MOUSE_FILTER_IGNORE
	if _scrim == null or not is_instance_valid(_scrim):
		return
	_scrim.visible = not _stack.is_empty()
	# The scrim must sit directly beneath the TOP modal so lower modals are dimmed too — that is
	# what makes a stack read as a stack instead of as one flat pile of panels.
	var index := maxi(_host.get_child_count() - 2, 0)
	_host.move_child(_scrim, index)


func _on_gui_focus_changed(control: Control) -> void:
	# The focus trap's second half. MKFocus.trap rings the modal's own neighbours, but a mouse click
	# or a host-side grab_focus() can still land outside; when it does, focus is pulled straight back.
	if _restoring_focus or _stack.is_empty():
		return
	var modal := top()
	if modal == null:
		return
	if MKFocus.is_within(control, modal):
		return
	_restoring_focus = true
	MKFocus.focus_first(modal)
	_restoring_focus = false
