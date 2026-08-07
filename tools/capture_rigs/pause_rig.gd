extends RefCounted
## Capture rig: opens the pause menu over the demo's grey-box world, so the one composition no other
## rig can produce — a MenuKit surface drawn on top of a live 3D scene — can be eyeballed.
##
## Its failure modes are visual by construction and pass every headless assertion: a shell that
## covers the world completely (nothing proves a pause menu is a pause menu if the game is not behind
## it), a page whose panel is transparent against a bright floor, a nav bar colliding with the pause
## buttons.
##
## Shoot it with:
##   ./tools/capture_scene.ps1 -Scene res://demo/demo_game.tscn -Rig res://tools/capture_rigs/pause_rig.gd
##
## [b]The captured scene is a Node3D, not an MKRoot.[/b] Unlike every other rig here, the shell is a
## CHILD of the host scene, so this one searches for it — a `node as MKRoot` cast would be null and a
## rig that assumed otherwise would push_error on a perfectly correct scene.
##
## The rig does not touch [member Input.mouse_mode]. demo_game.gd captures the cursor in its _ready,
## and MKRoot frees it on the 0→1 suspend edge inside open_pause_menu — so by the time the shot is
## taken the cursor is already visible, through the shipped path rather than a rig override.

## The pause page is instantiated inside open_pause_menu and MKRoot defers its focus pass by a frame,
## so a short wait photographs an unfocused (and, on the first frame, unlaid-out) panel. Frames, not
## seconds — size any change to this for the fastest common refresh rate, never the typical one.
func wait_frames() -> int:
	return 40


func setup(node: Node, _tree: SceneTree) -> void:
	var root := _find_root(node)
	if root == null:
		push_error("pause_rig: no MKRoot found under '%s' — expected the demo game scene" % node.name)
		return
	# Visible BEFORE open, for the reason demo_game.gd states at its own call site: MKRoot's deferred
	# focus pass runs MKFocus, which skips controls failing is_visible_in_tree(), so opening while
	# hidden photographs a page with no focus ring on anything.
	root.visible = true
	if not root.open_pause_menu():
		# A refused open suspended nothing, so the visibility set above is the only thing to undo —
		# without this the shot is an opaque empty shell over the world, which reads as a layout bug
		# rather than a missing page def.
		root.visible = false
		push_error("pause_rig: open_pause_menu() refused — the config defines no 'pause' page")


## Depth-first scan rather than a fixed node path: the shell's position in the host scene is the
## host's business (demo_game.tscn makes it the last child for draw and input order, which is a
## sibling-order fact, not a name).
func _find_root(node: Node) -> MKRoot:
	if node is MKRoot:
		return node as MKRoot
	for child in node.get_children():
		var found := _find_root(child)
		if found != null:
			return found
	return null
