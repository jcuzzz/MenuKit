extends MKTest
## Page state machine, back stack, and the cancel precedence ladder (plan §4.4, §4.7a).
##
## The ladder is the part worth testing hard: stating the rule only for the rebind/page pair once
## left the modal case broken, so that Escape popped the page underneath a still-open modal and
## desynced the depth-counted mouse-mode restore. Each rung is asserted separately here.
##
## Headless-safe by construction: everything asserted is page ids, stack depth, and counter state.
## No assertion here depends on an engine-visible effect, because those silently no-op under
## --headless and would count as covered while proving nothing.

const CONFIG_PATH := "res://demo/demo_config.tres"


func run_tests() -> void:
	var config := ResourceLoader.load(CONFIG_PATH) as MKConfig
	check(config != null, "demo config loads")
	if config == null:
		return

	check_eq(config.validate(), PackedStringArray(), "demo config validates clean")
	check_eq(config.get_visible_pages().size(), 3, "hidden sub-page is not a nav tab")
	check_eq(config.get_visible_pages()[0].id, &"play", "visible pages sort by order")

	# Duplicate before mutating: the shipped config is a cached resource, and wiring a spy policy into
	# the original would leak into every later test in the sweep.
	config = config.duplicate(true)
	SpyPolicy.reset()
	var slot := MKBackendSlot.new()
	slot.backend_script = SpyPolicy
	config.pause_policy = slot
	check_eq(config.validate(), PackedStringArray(),
		"a slot carrying an MKPausePolicy subclass validates")

	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()
	check(root.get_pause_policy() != null, "MKRoot instantiated the pause policy from its slot")

	# --- boot ---
	check_eq(root.get_page_id(), &"play", "boots to initial_page")
	check_eq(root.get_back_depth(), 0, "back stack starts empty")
	check_eq(root.process_mode, Node.PROCESS_MODE_ALWAYS,
		"MKRoot runs ALWAYS or the revert countdown hangs under pause")

	# --- lateral vs. push ---
	root.go_to_page(&"settings")
	check_eq(root.get_page_id(), &"settings", "tab selection changes page")
	check_eq(root.get_back_depth(), 0, "a lateral move clears the back stack")

	root.push_page(&"sub")
	check_eq(root.get_page_id(), &"sub", "push enters the sub-panel")
	check_eq(root.get_back_depth(), 1, "push remembers where to return")

	# --- cancel rung 3: page back stack ---
	check(_cancel(root), "cancel pops the page when nothing is open over it")
	await step_frame()
	check_eq(root.get_page_id(), &"settings", "cancel returned to the pushed-from page")
	check_eq(root.get_back_depth(), 0, "back stack unwound")

	# --- cancel rung 2: modal wins over the page ---
	var layer := root.get_modal_layer()
	check(layer != null, "modal layer exists")
	var dialog := MKConfirmDialog.open(layer, "T", "B")
	await step_frame()
	check_eq(layer.depth(), 1, "modal pushed")
	check(_cancel(root), "cancel is consumed while a modal is open")
	await step_frame()
	check_eq(layer.depth(), 0, "cancel popped the modal")
	check_eq(root.get_page_id(), &"settings",
		"cancel did NOT also pop the page underneath the modal")
	check(not is_instance_valid(dialog) or dialog.is_queued_for_deletion(),
		"a dialog opened by MKConfirmDialog.open frees itself when popped")

	# --- suspension counter: a modal extends a suspension but never creates one ---
	# Asserted while the modal is OPEN. Measuring after the pop passed for the wrong reason and was
	# the only guard on this rule, which turned out not to be implemented at all.
	MKConfirmDialog.open(layer, "T", "B")
	await step_frame()
	check_eq(layer.depth(), 1, "modal open for the main-menu suspension check")
	check_eq(root.get_suspend_depth(), 0,
		"a modal in the main menu suspends nothing — otherwise a tree pause policy would freeze a host's animated menu and leave the page under the dialog input-dead")
	layer.pop_modal()
	await step_frame()
	check_eq(root.get_suspend_depth(), 0, "and popping it does not underflow the counter")

	# --- a modal over captured gameplay DOES suspend (the FPS case) ---
	# Depth is 0 here, same as the main menu, but the cursor is captured — so a dialog raised over
	# live gameplay that never went through open_pause_menu must still free it, or it is literally
	# unclickable in a Doom-like. Keying this rule on depth alone got that backwards.
	# Headless note: the dummy DisplayServer does not honour a real mouse mode, so this asserts the
	# decision function rather than Input.mouse_mode itself. The cursor half is gate 4b (Phase 6).
	check(not root._modal_should_suspend(),
		"with a free cursor and nothing suspended, a modal suspends nothing")
	root.open_pause_menu(&"play")
	check(root._modal_should_suspend(), "with the world already suspended, a modal extends it")
	root.close_pause_menu()

	# --- a page change never strands a modal (plan §4.7a) ---
	MKConfirmDialog.open(layer, "T", "B")
	await step_frame()
	check_eq(layer.depth(), 1, "modal open before a lateral page change")
	root.go_to_page(&"credits")
	await step_frame()
	check_eq(layer.depth(), 0, "a nav-tab page change pops the modal stack")
	check_eq(root.get_suspend_depth(), 0, "and leaves no orphaned suspension behind")

	root.open_pause_menu(&"play")
	check_eq(root.get_suspend_depth(), 1, "pause menu suspends")
	MKConfirmDialog.open(root.get_modal_layer(), "T", "B")
	await step_frame()
	check_eq(root.get_suspend_depth(), 2, "a modal over pause extends the suspension")
	root.get_modal_layer().pop_modal()
	await step_frame()
	check_eq(root.get_suspend_depth(), 1,
		"dismissing the modal must NOT restore capture under a still-open pause menu")
	root.close_pause_menu()
	check_eq(root.get_suspend_depth(), 0, "closing the pause menu unwinds fully")

	# --- teardown zeroes the counter (plan §4.2a) ---
	# Asserted on the SAME root, before it is freed, and on a policy spy that records its own
	# teardown. The previous version freed the root and then checked a brand-new instance's counter —
	# which is zero from its member initialiser regardless, so deleting the whole body of _exit_tree
	# left it green. It was the only guard on the unwind rule.
	root.open_pause_menu(&"play")
	check_eq(root.get_suspend_depth(), 1, "suspended before teardown")
	var exits_before := SpyPolicy.exits
	var teardowns_before := SpyPolicy.teardowns
	root.free()
	check_eq(SpyPolicy.teardowns - teardowns_before, 1,
		"the policy undid its own effects in its own _exit_tree")
	check_eq(SpyPolicy.exits - exits_before, 0,
		"MKRoot did NOT call exit_menu on teardown — the policy is already out of the tree by then, so the cross-node call would crash the shipped default on every quit-while-paused")
	await step_frame()

	var diag_root := MKRoot.new()
	diag_root.config = config
	get_root().add_child(diag_root)
	await step_frame()
	var diag := diag_root.dump_diagnostics()
	check(diag.contains("MenuKit") and diag.contains("suspend_depth"),
		"dump_diagnostics reports version and counter state")


## A pause policy that records what it was asked to do, so the teardown contract can be asserted
## rather than assumed. Counters are static because the instance is destroyed by the very teardown
## under test.
class SpyPolicy extends MKPausePolicy:
	static var enters := 0
	static var exits := 0
	static var teardowns := 0
	var _entered := false

	static func reset() -> void:
		enters = 0
		exits = 0
		teardowns = 0

	func enter_menu(_reason: StringName) -> void:
		enters += 1
		_entered = true

	func exit_menu(_reason: StringName) -> void:
		exits += 1
		_entered = false

	func _exit_tree() -> void:
		# The defined teardown path: undo only what this policy did, while its own tree reference is
		# still valid.
		if _entered:
			teardowns += 1
			_entered = false


## Feeds a real ui_cancel through the viewport's unhandled-input path, rather than calling the
## handler directly — the precedence ladder is only meaningful if it is exercised through the same
## dispatch order the engine uses.
##
## Returns whether the viewport actually marked the event handled. Returning a bare [code]true[/code]
## made every [code]check(_cancel(root), …)[/code] a tautology that could not fail, which is worse
## than no assertion because the suite counts it as coverage.
func _cancel(root: MKRoot) -> bool:
	var viewport := root.get_viewport()
	var ev := InputEventAction.new()
	ev.action = &"ui_cancel"
	ev.pressed = true
	# push_input resets the handled flag at dispatch start, so no manual clearing is needed here —
	# and calling set_input_as_handled() first would SET it, not clear it.
	viewport.push_input(ev)
	return viewport.is_input_handled()
