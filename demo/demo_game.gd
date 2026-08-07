extends Node3D
## The demo's grey-box first-person "game" (plan §5 row 6): the world an [MKRoot] pause menu is
## supposed to sit on top of, and the only place in this repo where the two §4.2a contracts —
## process mode and mouse capture — are observable rather than asserted.
##
## [b]Everything here is host code.[/b] The addon knows nothing about this scene; it is reached
## through [code]MKSceneMenuBackend[/code]'s [code]game_scene[/code] param, so the whole ESC flow
## below is what an integrator writes, and it is deliberately short: forward the gesture, show the
## shell, gate the camera. Anything longer than that would mean MenuKit had failed to own the
## atomicity §4.2a says it owns.
##
## [b]Why this scene runs PAUSABLE and the MKRoot child does not.[/b] This node drives the spinner,
## the mouselook and the walk, so leaving it at the inherited default is what makes
## [code]MKTreePausePolicy[/code] visible at all: with [member SceneTree.paused] true this script
## stops receiving [method Node._process], [method Node._physics_process] and
## [method Node._unhandled_input], while the [MKRoot] subtree keeps ticking on its own
## [constant Node.PROCESS_MODE_ALWAYS]. Under [code]MKNoPausePolicy[/code] nothing here stops, which
## is the ~20-minute multiplayer-seam test in the row-6 exit criteria — and the reason the camera
## gate below exists.

## Walk speed in m/s. Chosen for the capture, not for feel: fast enough to cross the 40m floor
## without waiting, slow enough that a mouse-captured tester can stop on a box.
const SPEED := 5.0

## Jump impulse in m/s. Paired with [constant GRAVITY]; ~1.1m of clearance.
const JUMP_VELOCITY := 4.6

## Local gravity rather than a ProjectSettings read: this scene is the ONLY 3D content in the
## repo, so the project's physics defaults are unexercised elsewhere and a silent dependency on
## them would be a worse trade than one named number.
const GRAVITY := 9.8

## Radians of yaw/pitch per pixel of relative mouse motion.
const MOUSE_SENSITIVITY := 0.0025

## Pitch clamp. Slightly inside ±90° so the camera never reaches the degenerate straight-up/down
## basis where yaw and roll coincide.
const PITCH_LIMIT := deg_to_rad(89.0)

## Degrees per second for the one continuously animating object. It is the row-6 evidence that
## pause actually froze the world: a screenshot cannot show that a static box is static, but a
## tester watching this box can tell paused from not-paused in one second, and so can the
## MKNoPausePolicy swap (the box keeps turning with the menu open).
const SPINNER_DEGREES_PER_SECOND := 45.0

@onready var _player: CharacterBody3D = $Player
@onready var _head: Camera3D = $Player/Head
@onready var _spinner: CSGBox3D = $Spinner
@onready var _menu: MKRoot = $MKRoot


func _ready() -> void:
	# Guarded because the dummy DisplayServer has no cursor to capture — the same
	# `get_name() != "headless"` idiom the rebind row and the JSON settings backend use for their
	# display-dependent calls. A headless run of this scene (a smoke instancing it) should not spend
	# a driver call on a mouse that does not exist.
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# The shell boots hidden: mk_root.tscn is a full-rect Control and would otherwise cover the world
	# with the backdrop and the nav bar from frame one. Set in the scene as well as here — this
	# assignment is what makes the state explicit to a reader of the script, the scene value is what
	# makes it true before the first draw.
	_menu.visible = false
	_menu.pause_menu_toggled.connect(_on_pause_menu_toggled)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _menu.is_pause_menu_open():
		var motion := event as InputEventMouseMotion
		# Yaw on the body, pitch on the head: rotating the body keeps the movement basis below in
		# sync with where the camera looks, which is why _physics_process can use _player.basis
		# directly and never touch the head's.
		_player.rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
		_head.rotation.x = clampf(_head.rotation.x - motion.relative.y * MOUSE_SENSITIVITY,
			-PITCH_LIMIT, PITCH_LIMIT)
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _menu.is_pause_menu_open():
		# Closing is MKRoot's job, not ours: with the menu open its _unhandled_input consumes
		# ui_cancel before this node can see it (the shell is the LAST child, and unhandled input
		# walks the tree in reverse order), and under a tree pause policy this node is not receiving
		# input at all. Both routes mean this branch is unreachable in the shipped configuration; it
		# exists so a host that reorders the children or swaps in MKNoPausePolicy does not get a
		# second open_pause_menu call, which MKRoot would refuse anyway (its _pause_menu_open guard).
		return
	# Visible BEFORE open. MKRoot._show_page defers _focus_page_content, and MKFocus.collect_focusables
	# skips every control failing is_visible_in_tree() — so opening the page while this shell is still
	# hidden focuses nothing and the pause menu is dead to a gamepad (D12). The pause_menu_toggled
	# handler below sets the same flag; it is the general contract (any other caller of
	# open_pause_menu gets the shell shown for free), not a duplicate of this line's job, which is
	# ordering.
	_menu.visible = true
	if not _menu.open_pause_menu():
		# A refused open touched NOTHING: MKRoot pre-checks the page def and its scene before it
		# suspends anything, so there is no suspension, no page change and no policy edge to undo —
		# which makes this line the only cleanup there is, and what it undoes is the visibility the
		# line above set. Without it, a config without a "pause" page leaves a fully opaque shell over
		# the world with no way back.
		_menu.visible = false
	get_viewport().set_input_as_handled()


## The host half of the §4.2a footgun. MenuKit frees the cursor whenever a surface is up, INCLUDING
## under MKNoPausePolicy where the world keeps running — so relative motion keeps arriving here and
## the camera would spin while the player aims at a menu button. Gating the camera on menu state is
## explicitly the host's job, and this is the host.
##
## Note what this handler does NOT do: it never writes [member Input.mouse_mode]. That is
## depth-counted inside MKRoot (a modal over the pause menu must not restore capture on dismiss),
## and a host that also wrote it would fight the counter. The demo sets the captured mode exactly
## once, in _ready.
func _on_pause_menu_toggled(open: bool) -> void:
	_menu.visible = open


func _process(delta: float) -> void:
	_spinner.rotate_y(deg_to_rad(SPINNER_DEGREES_PER_SECOND) * delta)


func _physics_process(delta: float) -> void:
	if not _player.is_on_floor():
		_player.velocity.y -= GRAVITY * delta
	# Movement is gated on the same state as the camera, and for the same reason: under a no-pause
	# policy this node keeps running with the menu open, and WASD is polled through
	# Input.is_action_pressed, which does not care that a Button has focus.
	var menu_open := _menu.is_pause_menu_open()
	if menu_open:
		_player.velocity.x = 0.0
		_player.velocity.z = 0.0
	else:
		if Input.is_action_just_pressed(&"demo_jump") and _player.is_on_floor():
			_player.velocity.y = JUMP_VELOCITY
		var input_dir := Input.get_vector(&"demo_move_left", &"demo_move_right",
			&"demo_move_forward", &"demo_move_back")
		# -Z is forward for a Godot Camera3D, and get_vector's Y grows toward "back", so the pair maps
		# straight onto (x, z) with no sign flip.
		var direction := (_player.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
		_player.velocity.x = direction.x * SPEED
		_player.velocity.z = direction.z * SPEED
	_player.move_and_slide()
