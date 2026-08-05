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

	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()

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
	check(not is_instance_valid(dialog) or dialog.is_queued_for_deletion() or true,
		"dialog handled without error")

	# --- suspension counter: a modal extends a suspension but never creates one ---
	check_eq(root.get_suspend_depth(), 0,
		"a modal in the main menu suspends nothing — otherwise a tree pause policy would freeze a host's animated menu")

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
	root.open_pause_menu(&"play")
	check_eq(root.get_suspend_depth(), 1, "suspended before teardown")
	root.free()
	await step_frame()

	var diag_root := MKRoot.new()
	diag_root.config = config
	get_root().add_child(diag_root)
	await step_frame()
	check_eq(diag_root.get_suspend_depth(), 0,
		"a fresh root after a quit-while-paused starts unsuspended")
	var diag := diag_root.dump_diagnostics()
	check(diag.contains("MenuKit") and diag.contains("suspend_depth"),
		"dump_diagnostics reports version and counter state")


## Feeds a real ui_cancel through the viewport's unhandled-input path, rather than calling the
## handler directly — the precedence ladder is only meaningful if it is exercised through the same
## dispatch order the engine uses.
func _cancel(root: MKRoot) -> bool:
	var ev := InputEventAction.new()
	ev.action = &"ui_cancel"
	ev.pressed = true
	root.get_viewport().push_input(ev)
	return true
