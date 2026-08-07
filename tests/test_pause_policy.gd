extends MKTest
## The shipped pause policies against a real [MKRoot].
##
## The teardown case is the one that matters. Quit-to-menu frees the game scene and its MKRoot while
## the world is still paused, and [constant Node.NOTIFICATION_EXIT_TREE] propagates children first —
## so by the time MKRoot tears down, the policy is already detached and its [method Node.get_tree] is
## null. MKRoot must therefore NOT call [code]exit_menu[/code] on the way out: the contract is that
## the policy undoes its own work in its own [method Node._exit_tree], and this asserts the world
## really does end unpaused.

func run_tests() -> void:
	await _test_tree_policy()
	await _test_tree_policy_teardown_while_paused()
	await _test_no_pause_policy()
	await _test_can_pause_false_suppresses_enter_menu()
	await _test_host_paused_world_survives_a_menu_cycle()


## `can_pause() == false` must SUPPRESS enter_menu, not merely coexist with a policy that happens to
## do nothing in it. MKNoPausePolicy's enter_menu is empty, so this drives a policy with RECORDED
## side effects instead — a declining policy may still duck audio or notify a server from its own
## methods, and testing against the empty one cannot tell suppression from inertness.
func _test_can_pause_false_suppresses_enter_menu() -> void:
	DecliningSpy.reset()
	var root := _make_root(DecliningSpy)
	await step_frame()

	root.open_pause_menu(&"only")
	check(root.is_pause_menu_open(), "the menu opens under a declining policy — can_pause is never a veto")
	check_eq(DecliningSpy.enters, 0,
		"enter_menu is NOT called when can_pause() is false, even though the policy defines one")

	root.close_pause_menu()
	check_eq(DecliningSpy.exits, 0, "and exit_menu is not called either, keeping the pair symmetric")
	check_eq(root.get_suspend_depth(), 0, "while MKRoot's own counter still unwinds normally")

	root.free()
	await step_frame()


## A world the HOST paused must still be paused after a menu cycle. MKTreePausePolicy declines
## ownership of a pause it did not set, because clearing a flag it does not own would silently resume
## a cutscene or a loading screen — a failure the host cannot defend against.
func _test_host_paused_world_survives_a_menu_cycle() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	get_root().get_tree().paused = true

	root.open_pause_menu(&"only")
	check(get_root().get_tree().paused, "still paused with the menu open")
	root.close_pause_menu()
	check(get_root().get_tree().paused,
		"a host-paused world survives the cycle — MenuKit does not clear a pause it did not set")

	get_root().get_tree().paused = false
	root.free()
	await step_frame()


## Declines to pause AND records both calls, so the test can tell suppression from inertness.
class DecliningSpy extends MKPausePolicy:
	static var enters := 0
	static var exits := 0

	static func reset() -> void:
		enters = 0
		exits = 0

	func can_pause() -> bool:
		return false

	func enter_menu(_reason: StringName) -> void:
		enters += 1

	func exit_menu(_reason: StringName) -> void:
		exits += 1


func _test_tree_policy() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.get_pause_policy() is MKTreePausePolicy, "tree policy instantiated from its slot")
	check(not get_root().get_tree().paused, "the world starts running")

	root.open_pause_menu(&"only")
	check(get_root().get_tree().paused, "opening the pause menu pauses the world")

	MKConfirmDialog.open(root.get_modal_layer(), "T", "B")
	await step_frame()
	check_eq(root.get_suspend_depth(), 2, "a modal over pause extends the suspension")
	check(get_root().get_tree().paused, "and the world stays paused with the modal up")

	root.get_modal_layer().pop_modal()
	await step_frame()
	check(get_root().get_tree().paused,
		"dismissing the modal must NOT unpause under a still-open pause menu")

	root.close_pause_menu()
	check(not get_root().get_tree().paused, "closing the pause menu resumes the world")

	root.free()
	await step_frame()


## The teardown sequence: paused, then torn down.
func _test_tree_policy_teardown_while_paused() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	root.open_pause_menu(&"only")
	MKConfirmDialog.open(root.get_modal_layer(), "T", "B")
	await step_frame()
	check(get_root().get_tree().paused, "paused, with a modal open, before teardown")

	get_root().remove_child(root)
	check(not get_root().get_tree().paused,
		"quit-while-paused leaves the world UNPAUSED — otherwise the next game boots frozen, minutes from the cause")
	root.free()
	await step_frame()
	check(not get_root().get_tree().paused, "and it stays unpaused after the free")


## can_pause() false is never a veto on opening the menu — it means the menu opens and the world
## keeps running, which is the multiplayer case.
func _test_no_pause_policy() -> void:
	var root := _make_root(MKNoPausePolicy)
	await step_frame()
	check(root.get_pause_policy() is MKNoPausePolicy, "no-pause policy instantiated")
	check(not root.get_pause_policy().can_pause(), "and it declines to pause")

	var opened := root.open_pause_menu(&"only")
	check(opened, "the menu still OPENS under a no-pause policy")
	check(root.is_pause_menu_open(), "and reports itself open")
	check(not get_root().get_tree().paused, "while the world keeps running")
	check_eq(root.get_suspend_depth(), 1,
		"suspension counting is identical — only the policy's response differs")

	root.close_pause_menu()
	check(not get_root().get_tree().paused, "still running after close")
	check_eq(root.get_suspend_depth(), 0, "and the counter unwound")

	root.free()
	await step_frame()


func _make_root(policy_script: Script) -> MKRoot:
	var config := MKConfig.new()
	var slot := MKBackendSlot.new()
	slot.backend_script = policy_script
	config.pause_policy = slot
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
