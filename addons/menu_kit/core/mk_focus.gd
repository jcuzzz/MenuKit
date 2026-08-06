@tool
class_name MKFocus
extends RefCounted
## Focus wiring helpers for the cases Godot's automatic container neighbours do not cover
## (plan §4.7).
##
## Godot derives focus neighbours from geometry inside a container, which is enough for a
## hand-authored [VBoxContainer] and not enough for MenuKit: panels are built at runtime from
## [code].tres[/code] schemas (D5/D6), so there is no author to hand-wire neighbours; wrap-around
## does not exist at all; jumping from a rows column to a footer button crosses containers; and
## modal focus trapping (plan §1.3) has no engine equivalent. Every helper therefore takes a
## container and does the wiring, so a panel that rebuilt its rows calls one function afterwards.
##
## All helpers are static and tolerate freed/removed nodes — a runtime panel rebuild frees the
## controls a previous chain referenced, and a helper that crashed on that would make schema-driven
## panels unusable.

## Meta key marking a subtree as focus-trapped, so [method release] knows what to undo and a
## double-trap is a no-op rather than a corrupted chain.
const TRAP_META := &"mk_focus_trapped"


## Returns every focusable descendant of [param root] in tree (i.e. visual) order.
## "Focusable" means [constant Control.FOCUS_ALL] or [constant Control.FOCUS_CLICK], visible in
## the tree, and — for a [BaseButton] — not [member BaseButton.disabled]. A hidden or
## disabled-by-hiding row must never appear in a chain, otherwise keyboard traversal stops on an
## invisible control and looks like a hang.
static func collect_focusables(root: Node) -> Array[Control]:
	return _collect(root, true)


## The collector every caller shares — [method collect_focusables] with the filter on,
## [method release] and [method trap]'s last-resort fallback with it off. [param skip_disabled] false
## keeps disabled buttons in the list, which is what those two latter callers need: they are
## answering "which controls did trap TOUCH" and "what is inside this subtree at all", not "where
## should focus go" — and a control can be disabled AFTER it was wired, so the enabled-only view no
## longer describes the set whose neighbours exist.
static func _collect(root: Node, skip_disabled: bool) -> Array[Control]:
	var out: Array[Control] = []
	if root == null or not is_instance_valid(root):
		return out
	_collect_recursive(root, out, skip_disabled)
	return out


static func _collect_recursive(node: Node, out: Array[Control], skip_disabled: bool) -> void:
	for child in node.get_children():
		if child is Control:
			var c := child as Control
			if not c.is_visible_in_tree():
				continue
			# A DISABLED button is skipped. Godot lets a disabled control HOLD focus perfectly happily —
			# so nothing errors, the ring just sits on a control that swallows every activation — and
			# MKFocus exists to answer "where should focus go", for which "a button that does nothing" is
			# never the answer. The empty Characters page is the case that named it: its Play button is
			# disabled with no selection and sits first in tree order, so the shell's deferred
			# focus_first landed there and a gamepad-only player pressed A into silence while the one
			# live action (New Character) sat two controls away.
			var button := c as BaseButton
			if skip_disabled and button != null and button.disabled:
				continue
			if c.focus_mode != Control.FOCUS_NONE:
				out.append(c)
		_collect_recursive(child, out, skip_disabled)


## Grabs focus on the first focusable descendant and returns it (null when there is none).
## Used on every panel/modal open: a menu that opens with nothing focused is dead to a gamepad,
## which is the D12 promise, so "open" and "focus something" must be one call and never two.
static func focus_first(root: Node) -> Control:
	var controls := collect_focusables(root)
	if controls.is_empty():
		MKLog.debug("MKFocus.focus_first: no focusable control under %s"
			% [root.name if root != null and is_instance_valid(root) else "<null>"])
		return null
	controls[0].grab_focus()
	return controls[0]


## Wires [param controls] into a linear focus chain, vertically by default.
## [param wrap] closes the ring so pressing down on the last row lands on the first — Godot leaves
## the ends dangling, and a dangling end is where gamepad focus silently escapes into whatever
## control happens to be geometrically beyond the panel.
## Also sets [member Control.focus_next]/[member Control.focus_previous] so Tab agrees with the
## arrow keys instead of following an unrelated tree order.
static func link_chain(controls: Array[Control], vertical := true, wrap := true) -> void:
	var live: Array[Control] = []
	for c in controls:
		if c != null and is_instance_valid(c):
			live.append(c)
	var count := live.size()
	if count == 0:
		return
	for i in count:
		var cur := live[i]
		var has_prev := i > 0 or wrap
		var has_next := i < count - 1 or wrap
		var prev_path := cur.get_path_to(live[(i - 1 + count) % count]) if has_prev else NodePath()
		var next_path := cur.get_path_to(live[(i + 1) % count]) if has_next else NodePath()
		if vertical:
			cur.focus_neighbor_top = prev_path
			cur.focus_neighbor_bottom = next_path
		else:
			cur.focus_neighbor_left = prev_path
			cur.focus_neighbor_right = next_path
		cur.focus_previous = prev_path
		cur.focus_next = next_path


## Convenience over [method link_chain]: collects [param container]'s focusables and chains them.
## This is the call a schema-driven panel makes at the end of every rebuild.
static func chain_container(container: Node, vertical := true, wrap := true) -> Array[Control]:
	var controls := collect_focusables(container)
	link_chain(controls, vertical, wrap)
	return controls


## Links the edge of [param from_container] to the edge of [param to_container] so focus can cross
## between two independently chained groups (a rows list and its footer buttons, a nav bar and the
## page body). One-directional by default is a trap for the user, so the reverse edge is wired too.
## Leaves each group's internal chain untouched — call after both groups are chained.
static func link_containers(from_container: Node, to_container: Node, vertical := true) -> void:
	var from_list := collect_focusables(from_container)
	var to_list := collect_focusables(to_container)
	if from_list.is_empty() or to_list.is_empty():
		return
	var exit := from_list[from_list.size() - 1]
	var entry := to_list[0]
	if vertical:
		exit.focus_neighbor_bottom = exit.get_path_to(entry)
		entry.focus_neighbor_top = entry.get_path_to(exit)
	else:
		exit.focus_neighbor_right = exit.get_path_to(entry)
		entry.focus_neighbor_left = entry.get_path_to(exit)


## Traps focus inside [param root]: chains its focusables with wrap-around on BOTH axes and focuses
## the first one. Godot has no focus trap, and a modal whose Cancel button lets a right-press land
## on the page underneath is not modal (plan §1.3). Wrapping both axes matters because a modal's
## buttons are usually a horizontal row inside a vertical body — a single-axis ring leaves the
## other axis pointing at the page.
## Returns the control that received focus, or null when the subtree has none.
static func trap(root: Node) -> Control:
	if root == null or not is_instance_valid(root):
		return null
	if root.has_meta(TRAP_META):
		# Already trapped: return the focus that is inside it and change nothing. A second trap is not a
		# harmless repeat — it re-collects (over a set that may have changed shape since) and re-grabs,
		# so a modal that re-traps on a resize or a rebuild would yank the ring back to its first control
		# under the player's hands. The no-op is what makes trap safe to call defensively, which is how a
		# modal layer with more than one path to "this is now on top" ends up calling it.
		var owner := _focus_owner(root)
		if owner != null and is_within(owner, root):
			return owner
		# Trapped, but focus escaped anyway (the holder was freed or disabled out of the tree). Falling
		# through re-wires and re-grabs, which is the repair this state actually needs.
	var controls := collect_focusables(root)
	if controls.is_empty():
		# Last resort: a modal whose every button is disabled (a confirm dialog awaiting an async
		# result, a page-embedded modal built before its data arrived) has no ENABLED control to land
		# on, and returning null here leaves focus wherever it was — on the page UNDERNEATH, which is
		# the one thing §1.3 says a modal must never permit. So the ring is wired over the disabled set
		# instead. The trade is deliberate and worth naming: focus then sits on a control that cannot be
		# activated, but every key and every stick direction stays INSIDE the modal, which is the
		# property that actually makes it modal. An enabled control is still preferred whenever one
		# exists — this branch only runs when none does.
		controls = _collect(root, false)
		if controls.is_empty():
			MKLog.debug("MKFocus.trap: nothing focusable under %s" % root.name)
			return null
		MKLog.debug("MKFocus.trap: every focusable under %s is disabled — trapping on the disabled set so input cannot reach the page beneath" % root.name)
	link_chain(controls, true, true)
	# Horizontal ring over the same set, so left/right cannot exit either.
	for i in controls.size():
		var cur := controls[i]
		cur.focus_neighbor_left = cur.get_path_to(controls[(i - 1 + controls.size()) % controls.size()])
		cur.focus_neighbor_right = cur.get_path_to(controls[(i + 1) % controls.size()])
	root.set_meta(TRAP_META, true)
	controls[0].grab_focus()
	return controls[0]


## Clears every focus neighbour a [method trap] wired under [param root].
## Called on modal pop: the popped control may be reused (a cached confirm dialog), and stale
## NodePaths into a subtree that has since changed shape are a silent traversal bug.
##
## Collected WITHOUT the disabled filter, unlike [method collect_focusables]: release must undo
## exactly what trap wired, and a control trap wired while it was enabled and that has since been
## disabled (a modal's Confirm greying out while it is open) would otherwise keep its whole neighbour
## ring — the stale NodePaths this method exists to clear.
static func release(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	if not root.has_meta(TRAP_META):
		return
	root.remove_meta(TRAP_META)
	for c in _collect(root, false):
		c.focus_neighbor_top = NodePath()
		c.focus_neighbor_bottom = NodePath()
		c.focus_neighbor_left = NodePath()
		c.focus_neighbor_right = NodePath()
		c.focus_next = NodePath()
		c.focus_previous = NodePath()


## The control currently holding GUI focus in [param root]'s viewport, or null when there is none (or
## when root is not in a tree to have one). Static, so it cannot reach for a node's own get_viewport
## without checking that there is one.
static func _focus_owner(root: Node) -> Control:
	if root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return null
	var viewport := root.get_viewport()
	if viewport == null:
		return null
	return viewport.gui_get_focus_owner()


## True when [param node] is [param root] or a descendant of it.
## The modal layer's escape check needs this every time focus changes, and it must not assume the
## focus owner is still alive — a control can be freed in the same frame it loses focus.
static func is_within(node: Node, root: Node) -> bool:
	if node == null or root == null:
		return false
	if not is_instance_valid(node) or not is_instance_valid(root):
		return false
	return node == root or root.is_ancestor_of(node)
