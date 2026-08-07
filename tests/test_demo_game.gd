extends MKTest
## The Phase 6 exit criteria that are only observable on the SHIPPED demo game scene
## (plan §5 row 6): the ESC flow, the MKNoPausePolicy multiplayer seam, the host's camera/movement
## gate, and the quit-while-paused teardown that decides whether the NEXT game boots frozen.
##
## [b]Why the shipped scene rather than a fixture.[/b] Round 3 of Phase 5 was a suite green on
## MeshInstance fixtures while every shipped CSG preview silently failed. The same divergence is
## available here in three places — the [MKRoot] child's exported process mode, its hidden-on-boot
## visibility, and the demo config's [code]pause[/code] page id — and all three are properties of the
## [code].tscn[/code]/[code].tres[/code], not of any script. So every test below instances
## [code]demo_game.tscn[/code] itself, and the only thing ever substituted is the pause-policy slot
## (on a DUPLICATE of the config, because [method Resource.load] hands out one shared instance and
## editing it would rewrite what the demo ships).
##
## [b]Gestures, not method calls.[/b] The menu is opened by pushing a real [code]ui_cancel[/code]
## through the viewport, which exercises the whole chain the exit criteria describe: the hidden shell
## declining the gesture, the host's own [method Node._unhandled_input] answering it, visibility
## before open (or focus lands nowhere), and [method MKRoot.open_pause_menu]. Movement is driven with
## [method Input.action_press], which is what the host actually polls.

const GAME_SCENE := "res://demo/demo_game.tscn"


func run_tests() -> void:
	await _test_the_shipped_scene_is_wired_for_pause()
	await _test_escape_pauses_the_world_and_escape_resumes_it()
	await _test_no_pause_policy_leaves_the_world_running()
	await _test_the_host_gates_camera_and_movement_while_the_menu_is_open()
	await _test_the_host_refuses_a_second_open()
	await _test_a_config_without_a_pause_page_unwinds_the_shell_visibility()
	await _test_quit_while_paused_then_a_new_game_is_not_frozen(false)
	await _test_quit_while_paused_then_a_new_game_is_not_frozen(true)


## The scene-file half of the contract. Every one of these is authored in [code]demo_game.tscn[/code]
## rather than in [code]demo_game.gd[/code], so nothing in any script fails when one is lost: an
## MKRoot left visible covers the world from frame one, one left at the default PAUSABLE page mode
## ships a Resume button that cannot be pressed under the very policy it is there for, and a backdrop
## left on hides the paused world the pause menu is supposed to sit over.
func _test_the_shipped_scene_is_wired_for_pause() -> void:
	var packed := load(GAME_SCENE) as PackedScene
	check(packed != null, "the shipped demo game scene loads")
	if packed == null:
		return
	var game := packed.instantiate()
	var menu := game.get_node_or_null("MKRoot") as MKRoot
	check(menu != null, "it parks an MKRoot inside the game scene — the §4.2a in-game configuration")
	if menu == null:
		game.free()
		return
	check(not menu.visible, "the shell boots HIDDEN, or the world is covered before the first draw")
	check_eq(menu.host_content_process_mode, Node.PROCESS_MODE_ALWAYS,
		"and its page content runs ALWAYS — a PAUSABLE pause page is input-dead under a tree pause")
	check(not menu.show_backdrop,
		"with the backdrop off: the paused world behind the panel is what says 'pause' rather than 'scene change'")

	var config := menu.config
	check(config != null, "the scene assigns a config rather than falling back to the project setting")
	if config != null:
		check(config.get_page(&"pause") != null,
			"the demo config authors a page under the id MKRoot.open_pause_menu defaults to")
		check(config.get_page(MKPauseMenu.SETTINGS_PAGE_ID) != null,
			"and one under the id the pause page's Settings button pushes")
		check(config.pause_policy != null and config.pause_policy.is_assigned(),
			"and assigns a pause policy, so the cold-drop demo pauses with zero wiring")
	game.free()


## The shipped gesture, end to end, with the spinner as the evidence. A paused flag is a claim about
## the tree; a box that stops turning is the world actually stopping, and it is the same object a
## human tester watches.
func _test_escape_pauses_the_world_and_escape_resumes_it() -> void:
	var game := await _mount_game()
	var menu := game.get_node("MKRoot") as MKRoot
	var spinner := game.get_node("Spinner") as Node3D

	check(await _spinner_advances(spinner), "the world is running before the gesture")
	check(not menu.is_visible_in_tree(), "with the shell hidden")

	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "ESC opened the pause menu — the hidden shell declined the gesture and the HOST answered it")
	check(menu.is_visible_in_tree(), "and the shell is shown")
	check_eq(menu.get_page_id(), &"pause", "on the shipped pause page")
	check(get_root().get_tree().paused, "MKTreePausePolicy paused the world")
	check_eq(menu.get_suspend_depth(), 1, "one suspension, from the pause")
	check(not await _spinner_advances(spinner),
		"and the spinner has STOPPED — the demo scene is PAUSABLE, which is what makes the pause observable at all")

	get_root().push_input(_cancel_event())
	await step_frame()
	check(not menu.is_pause_menu_open(),
		"a second ESC resumes: with both stacks empty the root's own pause rung answers it")
	check(not menu.is_visible_in_tree(), "the host hid the shell off pause_menu_toggled")
	check(not get_root().get_tree().paused, "the world is running again")
	check_eq(menu.get_suspend_depth(), 0, "and the counter unwound")
	check(await _spinner_advances(spinner), "with the spinner turning again")

	await _drop(game)


## The ~20-minute multiplayer-seam test the exit criteria ask for: ONE slot swapped, no fork, and the
## world keeps running with the menu open. The countdown assertion is the other half — a host that
## reached "the world does not pause" by making MenuKit's own subtree pausable would freeze the
## confirm-or-revert dialog, and the swap has to leave that alone.
func _test_no_pause_policy_leaves_the_world_running() -> void:
	var game := await _mount_game(MKNoPausePolicy)
	var menu := game.get_node("MKRoot") as MKRoot
	var spinner := game.get_node("Spinner") as Node3D
	check(menu.get_pause_policy() is MKNoPausePolicy, "the swapped slot really instantiated")

	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "the menu opens exactly as it does under the tree policy")
	check(not get_root().get_tree().paused, "and the world is NOT paused")
	check_eq(menu.get_suspend_depth(), 1, "while the suspension counting is identical")
	check(await _spinner_advances(spinner),
		"the demo world keeps running with the menu open — the multiplayer seam, one config slot")

	var countdown := MKRevertCountdown.new()
	# A one-element Array, not an int: a GDScript lambda captures locals BY VALUE, so an `int` counter
	# incremented inside the closure is a copy the assertion never sees.
	var reverted := [0]
	countdown.reverted.connect(func() -> void: reverted[0] += 1)
	menu.get_modal_layer().push_modal(countdown)
	countdown.start(0.15)
	var before := countdown.get_time_left()
	for i in 600:
		if not is_instance_valid(countdown) or not countdown.is_running():
			break
		await step_frame()
	check(is_instance_valid(countdown) and not countdown.is_running(),
		"and a D14 countdown pushed over that still-running world reaches its timeout")
	check(is_instance_valid(countdown) and countdown.get_time_left() < before, "having ticked, not jumped")
	check_eq(reverted[0], 1, "resolving as REVERTED — unconfirmed means not kept, no-pause policy or not")
	# The layer UNPARENTS what it pops; freeing it is the pusher's job (MKSettingsPanel does it in the
	# shipped path). This test pushed it, so this test disposes of it, or the harness leak gate fires.
	menu.get_modal_layer().pop_all()
	if is_instance_valid(countdown):
		countdown.queue_free()
	await step_frame()

	menu.close_pause_menu()
	await _drop(game)


## §4.2a's stated host footgun, on the host that documents it: under a no-pause policy the world keeps
## running while MenuKit frees the cursor, so relative motion and polled WASD both keep arriving. The
## gate is the HOST's job and this is where it is written.
##
## Run under the no-pause policy deliberately: under a tree pause the demo's own handlers never run,
## so the gate would be untestable there — green for a reason that has nothing to do with the gate.
func _test_the_host_gates_camera_and_movement_while_the_menu_is_open() -> void:
	var game := await _mount_game(MKNoPausePolicy)
	var menu := game.get_node("MKRoot") as MKRoot
	var player := game.get_node("Player") as Node3D

	# Positive control first: the same event, in the same place, DOES turn the player while the menu is
	# closed. Without it, "the camera did not move" is satisfied by a scene that never reads motion.
	var before_yaw := player.rotation.y
	get_root().push_input(_motion_event())
	await step_frame()
	check(player.rotation.y != before_yaw, "mouselook works with the menu closed")

	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "the menu is open, and the world is still running")
	var open_yaw := player.rotation.y
	get_root().push_input(_motion_event())
	await step_frame()
	check_eq(player.rotation.y, open_yaw,
		"mouse motion with the menu open does NOT turn the camera — the player is aiming at a button")

	Input.action_press(&"demo_move_forward")
	await physics_frame
	await physics_frame
	var body := player as CharacterBody3D
	check_eq(Vector2(body.velocity.x, body.velocity.z), Vector2.ZERO,
		"and polled WASD moves nothing while the menu is open — Input polling does not care that a Button has focus")

	menu.close_pause_menu()
	await physics_frame
	await physics_frame
	check(Vector2(body.velocity.x, body.velocity.z) != Vector2.ZERO,
		"while the SAME held key moves the player once the menu is closed")
	Input.action_release(&"demo_move_forward")

	await _drop(game)


## The host's own double-open guard. It is unreachable in the shipped configuration (a visible shell
## consumes the gesture first, and under a tree pause the host is not receiving input at all), so it
## is reached here the way a host reordering its children or hiding the shell would: with the menu
## open and the shell hidden, the gesture falls through to the host, which must decline it.
func _test_the_host_refuses_a_second_open() -> void:
	var game := await _mount_game(MKNoPausePolicy)
	var menu := game.get_node("MKRoot") as MKRoot

	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "open once")
	check_eq(menu.get_suspend_depth(), 1, "one suspension")

	menu.visible = false
	await step_frame()
	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "the menu is still open after a gesture that reached the host")
	check_eq(menu.get_suspend_depth(), 1,
		"and NO second suspension was raised — one close still unwinds the world completely")

	menu.close_pause_menu()
	check_eq(menu.get_suspend_depth(), 0, "which it does")
	await _drop(game)


## A config with no "pause" page: MKRoot refuses and unwinds its own suspension, and the host unwinds
## the one thing MKRoot cannot know about — the visibility it set a line earlier. Without that, a
## missing page leaves a fully opaque shell over the world with no way back.
func _test_a_config_without_a_pause_page_unwinds_the_shell_visibility() -> void:
	var game := await _mount_game(null, true)
	var menu := game.get_node("MKRoot") as MKRoot
	check(menu.config.get_page(&"pause") == null, "precondition: this config has no pause page")

	get_root().push_input(_cancel_event())
	await step_frame()
	check(not menu.is_pause_menu_open(), "the open is refused")
	check(not menu.is_visible_in_tree(),
		"and the HOST put its shell back — an opaque full-rect Control over the world would be unrecoverable")
	check_eq(menu.get_suspend_depth(), 0, "MKRoot unwound the suspension it had already raised")
	check(not get_root().get_tree().paused, "so the world was not left paused behind nothing")

	await _drop(game)


## Row 6's teardown clause, and the failure it names: quit-to-menu while paused, then start a new
## game, and the new game is frozen — minutes from the cause, with nothing on screen wrong.
## [code]test_pause_policy[/code] covers the counter unwind on a synthetic root; this runs it through
## the SHIPPED scene and then proves the claim the way a player would find it out, by booting a second
## game and watching the spinner.
##
## [param hard_free] runs the same sequence with [method Node.free], because that is what
## [method SceneTree.change_scene_to_file] — the shipped menu backend's quit-to-menu — actually does
## to the outgoing scene, while [method Node.queue_free] exits the tree inside the delete queue. A
## teardown keyed on [method Node.is_queued_for_deletion] tells the two apart; the world does not.
func _test_quit_while_paused_then_a_new_game_is_not_frozen(hard_free: bool) -> void:
	var how := "free()" if hard_free else "queue_free()"
	var game := await _mount_game()
	var menu := game.get_node("MKRoot") as MKRoot

	get_root().push_input(_cancel_event())
	await step_frame()
	check(menu.is_pause_menu_open(), "paused, with the menu open (%s)" % how)
	check(get_root().get_tree().paused, "and the world really is paused before the quit (%s)" % how)

	if hard_free:
		game.free()
	else:
		game.queue_free()
	await step_frame()
	await step_frame()
	check(not get_root().get_tree().paused,
		"quitting while paused leaves the world UNPAUSED via %s — the policy undoes its own work in its own _exit_tree" % how)

	var second := await _mount_game()
	var spinner := second.get_node("Spinner") as Node3D
	check(await _spinner_advances(spinner),
		"and the NEXT game is not frozen (%s) — the leak this guards is a tree flag no node-leak check can see" % how)
	var second_menu := second.get_node("MKRoot") as MKRoot
	check_eq(second_menu.get_suspend_depth(), 0, "the fresh shell starts at zero suspensions (%s)" % how)
	get_root().push_input(_cancel_event())
	await step_frame()
	check(second_menu.is_pause_menu_open(),
		"and it can still be paused — the recovered state is usable, not merely unpaused (%s)" % how)
	second_menu.close_pause_menu()

	await _drop(second)


# --- Fixtures -----------------------------------------------------------------

## Instances the SHIPPED scene and mounts it. [param policy_script], when given, replaces the pause
## policy slot on a DUPLICATE of the demo config — the config assigned in the scene is the same cached
## resource the demo ships, so editing it would leak into every later test and into the repo's own
## demo. [param drop_pause_page] removes the pause page from that duplicate for the refusal case; the
## page array is duplicated too, for the same reason.
func _mount_game(policy_script: Script = null, drop_pause_page := false) -> Node:
	var game := (load(GAME_SCENE) as PackedScene).instantiate()
	if policy_script != null or drop_pause_page:
		var menu := game.get_node("MKRoot") as MKRoot
		# Assigned BEFORE the node enters the tree: MKRoot resolves its config in _ready, and a swap
		# afterwards is explicitly not a supported gesture (it rebuilds nothing).
		var config := (menu.config as MKConfig).duplicate(false) as MKConfig
		if policy_script != null:
			var slot := MKBackendSlot.new()
			slot.backend_script = policy_script
			config.pause_policy = slot
		if drop_pause_page:
			var kept: Array[MKMenuPageDef] = []
			for page in config.pages:
				if page != null and page.id != &"pause":
					kept.append(page)
			config.pages = kept
		menu.config = config
	get_root().add_child(game)
	await step_frame()
	await step_frame()
	return game


func _drop(game: Node) -> void:
	if is_instance_valid(game):
		game.queue_free()
	await step_frame()
	await step_frame()


## Whether the demo's one continuously animating object moved across a few frames. The spinner is
## driven from [method Node._process] on a PAUSABLE node, so this answers "is the world running"
## with the same evidence a human tester uses.
func _spinner_advances(spinner: Node3D) -> bool:
	if spinner == null or not is_instance_valid(spinner):
		fail("the shipped scene has no Spinner to watch")
		return false
	var before := spinner.rotation.y
	for i in 4:
		await step_frame()
	return spinner.rotation.y != before


# --- Input drivers ------------------------------------------------------------

func _cancel_event() -> InputEventAction:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	return event


## A pushed mouse motion never reaches GUI dispatch under the headless driver, but it does reach
## [method Node._unhandled_input] — which is where the demo reads mouselook, so the gate is testable
## and a click is not.
func _motion_event() -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.relative = Vector2(40.0, 0.0)
	return event
