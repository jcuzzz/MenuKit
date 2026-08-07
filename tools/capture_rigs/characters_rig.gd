extends RefCounted
## Capture rig: navigates the shell to the Characters page, optionally seeds the roster and
## optionally pushes on to the creation wizard, so the runtime-built select panel and creation host
## can be eyeballed — their failure modes (an unstyled card, a dead grid, a collapsed step footer)
## are visual by construction.
##
## MK_CAPTURE_SEED=<n>  creates n throwaway profiles through the demo's real profile backend before
##                      the shot, CAPPED AT 5 — the rig carries five authored names and seeds
##                      mini(n, 5), so a larger number is the same picture as 5. The isolation that
##                      makes this safe lives in the WRAPPER (tools/capture_scene.ps1 redirects
##                      APPDATA into .agent_tmp for the child engine); this script writes through
##                      the ordinary backend and knows nothing about where user:// resolves.
##                      Absent/0 = the empty-roster state.
## MK_CAPTURE_CREATE=<n> non-empty pushes the character_create page after seeding, so the shot is the
##                      creation host; a NUMERIC value additionally advances Next that many times, to
##                      reach later steps. Any non-numeric value is accepted and ignored beyond the
##                      push — there is no step-id form, deliberately: reaching a step by id would mean
##                      committing every step before it with values the rig would have to invent.
##
## [b]Advancing needs a valid step 1.[/b] The first step is the name field and its Next stays
## disabled until the name validates, so the rig types a name FIRST — and emits text_changed itself,
## because assigning LineEdit.text emits nothing and the step would never re-poll its validity.
## Presses are then spaced on timers rather than run in a loop: each step builds its widgets on being
## shown, and the host re-gates Next off the newly visible step, so a same-frame second press reads
## the previous step's button state.

## Long enough for the whole advance chain to finish before the shot: the timers below run 0.2s to
## find the host plus 0.15s per press, so a three-step advance needs ~0.65s. Frames, not seconds —
## this count only means "~0.65s" at an assumed refresh rate, so it must be sized for the FASTEST
## common display (a 60 Hz-sized wait under-waits on a 144/165 Hz panel and photographs an earlier
## step). An over-long wait costs only capture seconds.
func wait_frames() -> int:
	return 120


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
		_fill_name(host)
		_advance(host, tree, advances)
	)


## Types a valid name into the name step's LineEdit, so the first Next can enable at all.
## Searched by CLASS rather than by node name: the shipped step names it "NameEdit", but a host that
## replaced step 1 with its own scene still has to satisfy the same validity gate, and a rig that
## hard-coded the name would silently do nothing there.
func _fill_name(host: Node) -> void:
	for node in host.find_children("*", "LineEdit", true, false):
		var edit := node as LineEdit
		if edit == null:
			continue
		edit.text = "Capture"
		# Assignment alone emits NOTHING. The step listens on text_changed to re-validate and to tell
		# the host to re-poll, so without this the field reads "Capture" on screen and Next stays grey.
		edit.text_changed.emit(edit.text)
		return


## One Next press per timer tick. Recursive rather than a loop for the reason the class doc gives:
## the newly shown step has to build and the host has to re-gate Next before the next press is
## meaningful.
func _advance(host: Node, tree: SceneTree, remaining: int) -> void:
	if remaining <= 0:
		return
	var next_button := host.find_child("Next", true, false) as Button
	if next_button == null or next_button.disabled:
		push_error("characters_rig: Next is unavailable with %d advance(s) left — the shot is an earlier step than requested" % remaining)
		return
	next_button.pressed.emit()
	tree.create_timer(0.15).timeout.connect(func() -> void:
		_advance(host, tree, remaining - 1)
	)
