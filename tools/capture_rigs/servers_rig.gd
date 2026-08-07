extends RefCounted
## Capture rig: navigates the shell to the Servers page (Phase 7), optionally starting a connect, so
## the runtime-built browser can be eyeballed — an unstyled row, a collapsed footer or a status line
## that renders empty all pass every headless assertion, the same argument the settings and
## characters rigs make.
##
## MK_CAPTURE_CONNECT=<id|1>  presses Connect after the list has built, so the shot carries a
##                            connection outcome rather than the idle list. A value that names a
##                            server id selects that row first — `mk_stub_far` is the demo stub's
##                            always-failing entry (`MKStubNetworkBackend.FAILING_SERVER_ID`), which
##                            is how the FAILED caption gets a picture. Any other non-empty value
##                            connects to whatever row the page selected by default, which under the
##                            demo stub reaches CONNECTED.
##
## [b]Which state you get is a timing question, and the wait below settles it.[/b] The demo slot
## passes `connect_delay = 1.2` to the stub, and the press is scheduled 0.2s in (the page builds its
## rows on entering the tree, after this rig runs), so the outcome lands ~1.4s in. The shipped
## `wait_frames` is longer than that on purpose: the default shot is the RESOLVED caption. To
## photograph CONNECTING and its live Cancel button instead, cap the wait from the harness side
## (`capture_scene.gd` takes the LARGER of its `frames=` arg and this method, so it must be shortened
## HERE — measured against the arithmetic above, not guessed) or raise the demo slot's delay.

## Sized against the ~1.4s above with room to spare; an over-long wait costs only capture seconds.
func wait_frames() -> int:
	return 150


func setup(node: Node, tree: SceneTree) -> void:
	var root := node as MKRoot
	if root == null:
		push_error("servers_rig expects an MKRoot as the captured scene")
		return
	root.go_to_page(&"servers")

	var wanted := OS.get_environment("MK_CAPTURE_CONNECT")
	if wanted.is_empty():
		return
	# Found late, on a timer: MKRoot instantiates a page on first visit and the panel builds its rows
	# in _ready, so nothing named "Connect" exists in the frame this rig runs.
	tree.create_timer(0.2).timeout.connect(func() -> void:
		var panel := root.find_child("MKServerBrowser", true, false)
		if panel == null:
			for child in root.find_children("*", "MKServerBrowser", true, false):
				panel = child
				break
		if panel == null:
			push_error("servers_rig: MK_CAPTURE_CONNECT set but no MKServerBrowser found")
			return
		if wanted != "1":
			# Focusing the row selects it — the panel binds selection to focus_entered as well as to the
			# press, so this is the same gesture a keyboard user makes.
			var row := panel.find_child("Server_%s" % wanted, true, false) as Button
			if row == null:
				push_error("servers_rig: no server row 'Server_%s' — MK_CAPTURE_CONNECT names a server id" % wanted)
				return
			row.grab_focus()
		var connect_button := panel.find_child("Connect", true, false) as Button
		if connect_button == null or connect_button.disabled:
			push_error("servers_rig: Connect is unavailable — the shot is the idle list, not a connection")
			return
		connect_button.pressed.emit()
	)
