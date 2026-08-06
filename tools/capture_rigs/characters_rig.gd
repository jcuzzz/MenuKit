extends RefCounted
## Capture rig: navigates the shell to the Characters page (Phase 5), optionally seeds the roster and
## optionally pushes on to the creation wizard, so the runtime-built select panel and creation host
## can be eyeballed — their failure modes (an unstyled card, a dead grid, a collapsed step footer) are
## visual by construction, same argument as the settings rig.
##
## MK_CAPTURE_SEED=<n>  creates n throwaway profiles through the demo's real profile backend before
##                      the shot (the capture run uses the wrapper's isolated user://, so nothing
##                      touches a real roster). Absent/0 = the empty-roster state, which is itself a
##                      Phase 5 deliverable worth a picture.
## MK_CAPTURE_CREATE=<step-id or index> non-empty pushes the character_create page after seeding, so
##                      the shot is the creation host; a numeric value advances Next that many times
##                      first (validity permitting), to reach later steps.

func wait_frames() -> int:
	return 40


func setup(node: Node, tree: SceneTree) -> void:
	var root := node as MKRoot
	if root == null:
		push_error("characters_rig expects an MKRoot as the captured scene")
		return

	var seed_raw := OS.get_environment("MK_CAPTURE_SEED")
	if not seed_raw.is_empty() and seed_raw.is_valid_int():
		var backend := root.get_profile_backend()
		if backend == null:
			push_error("characters_rig: MK_CAPTURE_SEED set but no profile backend resolved")
			return
		var names := ["Aldric", "Mira", "Tobin", "Sera", "Junen"]
		var kits := ["vanguard", "arcanist", "scout"]
		for i in mini(int(seed_raw), names.size()):
			backend.create_profile({"name": names[i], "archetype": kits[i % kits.size()]})

	root.go_to_page(&"characters")

	var create_raw := OS.get_environment("MK_CAPTURE_CREATE")
	if create_raw.is_empty():
		return
	root.push_page(&"character_create")
	if not create_raw.is_valid_int():
		return
	# Advancing steps needs the host's real Next button — found late, after the page built.
	tree.create_timer(0.2).timeout.connect(func() -> void:
		var advances := int(create_raw)
		var host := root.find_child("MKCreationHost", true, false)
		if host == null:
			# The create panel names its host child by class default; fall back to a class scan.
			for child in root.find_children("*", "MKCreationHost", true, false):
				host = child
				break
		if host == null:
			push_error("characters_rig: MK_CAPTURE_CREATE set but no MKCreationHost found")
			return
		var next_button := host.find_child("Next", true, false) as Button
		for i in advances:
			if next_button != null and not next_button.disabled:
				next_button.pressed.emit()
	)
