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
	# 4 since Phase 5 added the Characters page, 5 since Phase 7 added the Servers page; the hidden
	# pages (`sub`, `character_create`, `pause`) are what this assertion actually guards — they must
	# never surface as tabs.
	check_eq(config.get_visible_pages().size(), 5, "hidden sub-pages are not nav tabs")
	check_eq(config.get_visible_pages()[0].id, &"play", "visible pages sort by order")

	# Ties must resolve by authoring order. sort_custom is NOT stable, and this feeds both the tab
	# order and the boot page (visible_pages[0]) — so with equal `order` values a host could get tabs
	# that disagree with `pages` and a boot page that is not the first tab.
	var tied := MKConfig.new()
	var ids: Array[StringName] = [&"a", &"b", &"c", &"d"]
	for tie_id in ids:
		var page := MKMenuPageDef.new()
		page.id = tie_id
		page.order = 0
		tied.pages.append(page)
	var tied_ids: Array[StringName] = []
	for page in tied.get_visible_pages():
		tied_ids.append(page.id)
	check_eq(tied_ids, ids, "pages sharing an order keep their authored sequence")

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
	# The dummy DisplayServer never leaves MOUSE_MODE_VISIBLE, so the captured branch is unreachable
	# from a real cursor here — _modal_should_suspend takes the mode as a parameter precisely so this
	# case is testable rather than merely asserted in a comment.
	check(not root._modal_should_suspend(Input.MOUSE_MODE_VISIBLE),
		"with a free cursor and nothing suspended, a modal suspends nothing")
	check(root._modal_should_suspend(Input.MOUSE_MODE_CAPTURED),
		"a modal over captured gameplay DOES suspend, or the dialog is unclickable in an FPS")
	check(root._modal_should_suspend(Input.MOUSE_MODE_CONFINED),
		"any non-visible cursor counts, not just CAPTURED")
	# The rule must not be disabled by a host that owns its own cursor: manage_mouse_mode means
	# "MenuKit does not write the cursor", not "the world is not live".
	config.manage_mouse_mode = false
	check(root._modal_should_suspend(Input.MOUSE_MODE_CAPTURED),
		"manage_mouse_mode = false must NOT switch off the captured-gameplay rule")
	config.manage_mouse_mode = true
	root.open_pause_menu(&"play")
	check(root._modal_should_suspend(Input.MOUSE_MODE_VISIBLE),
		"with the world already suspended, a modal extends it regardless of cursor state")
	root.close_pause_menu()

	# --- a page change never strands a modal (plan §4.7a) ---
	# Run this with the pause menu OPEN so the modal actually carries a suspension. Asserting it on
	# the main menu made the depth check 0→0 whatever pop_all did — the §4.7a rule only has teeth
	# when there is a suspension to strand.
	root.open_pause_menu(&"play")
	check_eq(root.get_suspend_depth(), 1, "suspended before the page change")
	MKConfirmDialog.open(layer, "T", "B")
	await step_frame()
	check_eq(layer.depth(), 1, "modal open before a lateral page change")
	check_eq(root.get_suspend_depth(), 2, "the modal carries a suspension of its own")
	root.go_to_page(&"credits")
	await step_frame()
	check_eq(layer.depth(), 0, "a nav-tab page change pops the modal stack")
	check_eq(root.get_suspend_depth(), 1,
		"and releases the modal's suspension rather than stranding it forever")
	root.close_pause_menu()
	check_eq(root.get_suspend_depth(), 0, "closing unwinds the rest")

	# --- a bad page id must not strand a modal either ---
	MKConfirmDialog.open(layer, "T", "B")
	await step_frame()
	root.go_to_page(&"no_such_page")
	await step_frame()
	check_eq(layer.depth(), 0, "a refused page change still pops the modal stack")
	check_eq(root.get_page_id(), &"credits", "and leaves the current page untouched")

	# --- exit_menu is paired with the enter that happened, not a re-query of can_pause ---
	# A policy whose answer changes while a menu is open is the stated multiplayer story; re-asking
	# on the way out skipped exit_menu and left the world paused with no menu on screen.
	var enters_before := SpyPolicy.enters
	var exits_at_open := SpyPolicy.exits
	root.open_pause_menu(&"play")
	check_eq(SpyPolicy.enters - enters_before, 1, "opening entered the policy")
	SpyPolicy.pausable = false
	root.close_pause_menu()
	check_eq(SpyPolicy.exits - exits_at_open, 1,
		"exit_menu still fired even though can_pause() flipped false while the menu was open")
	SpyPolicy.pausable = true

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
	# Removed rather than freed, so the SAME root can be interrogated after _exit_tree has run.
	# Freeing it and asserting on a fresh instance was vacuous twice over: a new root's counter is
	# zero from its member initialiser, so deleting the entire body of _exit_tree left the suite
	# green — which is exactly how a teardown crash and a stuck cursor shipped past this assertion.
	root.open_pause_menu(&"play")
	MKConfirmDialog.open(root.get_modal_layer(), "T", "B")
	await step_frame()
	check_eq(root.get_suspend_depth(), 2, "suspended, with a modal stacked, before teardown")
	var exits_before := SpyPolicy.exits
	var teardowns_before := SpyPolicy.teardowns
	get_root().remove_child(root)

	check_eq(root.get_suspend_depth(), 0, "_exit_tree zeroed the suspend counter")
	check_eq(root.get_modal_layer().depth(), 0, "_exit_tree emptied the modal stack")
	check(not root.is_pause_menu_open(), "_exit_tree cleared the pause-menu flag")
	check_eq(SpyPolicy.teardowns - teardowns_before, 1,
		"the policy undid its own effects in its own _exit_tree")
	check_eq(SpyPolicy.exits - exits_before, 0,
		"MKRoot did NOT call exit_menu on teardown — the policy is already out of the tree by then, so the cross-node call crashes the shipped tree policy on every quit-while-paused")
	root.free()
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
	## Drives can_pause(), so a test can flip the answer mid-menu.
	static var pausable := true
	var _entered := false

	static func reset() -> void:
		enters = 0
		exits = 0
		teardowns = 0
		pausable = true

	func can_pause() -> bool:
		return pausable

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
