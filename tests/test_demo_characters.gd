extends MKTest
## The demo's rigged character: the archetype -> preview_scene -> rig chain, asserted on the SHIPPED
## files rather than on fixtures.
##
## [b]Why this suite exists at all.[/b] Every failure mode this asset introduces is SILENT. A
## re-export that renames the idle leaves the autoplay string pointing at nothing and the mannequin
## T-poses; a one-shot idle plays 2.5 seconds and freezes; a resave that drops the editable-instance
## overrides gives three archetypes one grey character; a pack swap to a centre-origin rig sinks the
## figure halfway into the dais. None of those crash, none warn, and a capture is one frame — so a
## still of a T-pose and a still of an idle are equally plausible pictures of "working".
##
## [b]Driven from the ARCHETYPE resources, never from hardcoded scene paths.[/b] The contract under
## test is "what the demo SHIPS previews correctly", so the suite enumerates
## [code]demo/demo_archetypes/[/code] and follows each [member MKArchetype.preview_scene] wherever it
## points. A future re-point (another asset, another folder) stays covered without touching this file;
## a hardcoded path would quietly stop testing the shipped thing the moment it moved.
##
## [b]Headless boundary.[/b] That the idle READS well — pace, seam, whether it looks alive behind a
## menu — is docs/DEVELOPMENT.md §6a row 26 on a real display. What is real headless is every premise that
## row depends on: the animation exists, it loops, the rig stands on the floor, the mount is where the
## rig's origin convention needs it, and the art carries its licence.

const ARCHETYPE_DIR := "res://demo/demo_archetypes"
const CONFIG_PATH := "res://demo/demo_config.tres"
const BACKDROP_PATH := "res://demo/backdrops/menu_backdrop_3d.tscn"
const LICENSE_PATH := "res://demo/characters/LICENSE.txt"

## Where the dais top is, and therefore where a FEET-ORIGIN rig must be mounted to stand on it.
const MOUNT_Y := 0.15

## Feet-origin tolerance. Generous on purpose: a rig authored a few millimetres off the floor is the
## same rig, and the failure this guards against is a centre-origin swap — half a body height out,
## nowhere near this margin.
const FEET_EPSILON := 0.05


func run_tests() -> void:
	_test_every_archetype_preview_autoplays_an_animation_that_exists()
	_test_the_previews_are_distinct_scenes_carrying_distinct_tints()
	_test_the_idle_loops()
	await _test_the_rig_stands_on_its_origin()
	_test_the_backdrop_mount_sits_on_the_dais()
	_test_the_art_ships_with_its_licence()


## [b]The anti-T-pose pin.[/b] [member AnimationPlayer.autoplay] is a plain [String]: a name that
## matches nothing is not an error, not a warning, and not visible in the scene tree — the player
## simply plays nothing and the mannequin stands in its bind pose. Quaternius ships 43 animations in
## the DEFAULT unnamed library (no [code]LibraryName/[/code] prefix), and a re-export that renames one
## or that lands them under a named library breaks the string without touching this project.
##
## Also asserted: the demo CONFIG ships exactly the archetypes this folder holds. Without it a
## fourth archetype could be authored, covered here, and never reach a player.
func _test_every_archetype_preview_autoplays_an_animation_that_exists() -> void:
	var archetypes := _shipped_archetypes()
	check(archetypes.size() >= 3,
		"the demo ships its archetypes (found %d in %s)" % [archetypes.size(), ARCHETYPE_DIR])

	for archetype in archetypes:
		var label: String = str(archetype.id)
		check(archetype.preview_scene != null, "%s carries a preview_scene" % label)
		if archetype.preview_scene == null:
			continue
		var inst := archetype.preview_scene.instantiate()
		var player := _find_animation_player(inst)
		check(player != null, "%s's preview contains an AnimationPlayer" % label)
		if player != null:
			check(not player.autoplay.is_empty(),
				"%s's AnimationPlayer names an autoplay animation — an empty one is a still mannequin"
					% label)
			check(player.has_animation(player.autoplay),
				"%s autoplays '%s', which EXISTS in its animation list — a renamed re-export T-poses in silence rather than failing (list holds %d: %s...)"
					% [label, player.autoplay, player.get_animation_list().size(),
						", ".join(Array(player.get_animation_list()).slice(0, 3))])
		inst.free()

	var config := ResourceLoader.load(CONFIG_PATH) as MKConfig
	check(config != null, "the demo config loads")
	if config != null:
		check_eq(_ids(config.archetypes), _ids(archetypes),
			"and it ships exactly the archetypes the folder holds — an authored-but-unwired archetype would be covered here and invisible to a player")


## [b]The tint pin, and it is about a RESAVE more than about colour.[/b] The per-archetype colour is
## an editable-instance [code]surface_material_override/0[/code] on a node INSIDE an instanced
## [code].glb[/code] — the most fragile thing in these scenes. Godot drops overrides whose node path
## no longer resolves (a re-import that renames [code]Mannequin[/code] or reshapes the Armature does
## exactly that) and it does so without a word: the result is three archetypes rendering one identical
## untinted mannequin, which reads as "the preview is not updating" and is debugged in the wrong place.
##
## Pairwise-different is the assertion rather than three literal colours: the demo may re-theme, and
## pinning the exact reds here would make a palette change a test edit for no gain. What must never
## happen is two archetypes looking the same.
func _test_the_previews_are_distinct_scenes_carrying_distinct_tints() -> void:
	var archetypes := _shipped_archetypes()
	var seen_paths: Array[String] = []
	var tints: Array[Color] = []
	var labels: Array[String] = []

	for archetype in archetypes:
		if archetype.preview_scene == null:
			continue
		var path: String = archetype.preview_scene.resource_path
		check(not seen_paths.has(path),
			"%s's preview scene is its OWN resource, not one already used (%s)" % [archetype.id, path])
		seen_paths.append(path)

		var inst := archetype.preview_scene.instantiate()
		var tinted := _first_overridden_mesh(inst)
		check(tinted != null,
			"%s's preview has a MeshInstance3D carrying a surface override — the editable-instance override survived the resave"
				% archetype.id)
		if tinted != null:
			var material := tinted.get_surface_override_material(0) as StandardMaterial3D
			check(material != null,
				"%s's override is a StandardMaterial3D whose albedo can be read" % archetype.id)
			if material != null:
				tints.append(material.albedo_color)
				labels.append(str(archetype.id))
		inst.free()

	check_eq(seen_paths.size(), archetypes.size(),
		"every shipped archetype resolved a preview scene")
	check(tints.size() >= 3, "three tints were read (got %d)" % tints.size())
	for i in tints.size():
		for j in range(i + 1, tints.size()):
			check(tints[i] != tints[j],
				"%s and %s are tinted DIFFERENTLY — identical previews read as a stuck widget, not as lost overrides (%s vs %s)"
					% [labels[i], labels[j], tints[i], tints[j]])


## [b]A one-shot idle is the failure no capture can catch.[/b] It plays for 2.5 seconds after the page
## opens and then holds its last frame forever, so every screenshot is of a posed character and the
## defect only exists for someone who watches the menu for three seconds — which nobody does on
## purpose. The loop flag lives in the [code].glb[/code]'s import, not in these scenes, so a re-import
## with different settings silently un-loops every archetype at once.
func _test_the_idle_loops() -> void:
	for archetype in _shipped_archetypes():
		if archetype.preview_scene == null:
			continue
		var inst := archetype.preview_scene.instantiate()
		var player := _find_animation_player(inst)
		if player != null and player.has_animation(player.autoplay):
			var anim := player.get_animation(player.autoplay)
			check(anim.loop_mode != Animation.LOOP_NONE,
				"%s's idle '%s' LOOPS (mode %d, %.2fs) — a one-shot freezes on its last frame and every capture of it looks correct"
					% [archetype.id, player.autoplay, anim.loop_mode, anim.length])
		else:
			# The premise failing must fail HERE too, not only in the autoplay test — a suite where
			# this loop silently skips every archetype would report the loop coverage it does not have.
			fail("%s has no player/autoplay to loop-check — premise failed, see the autoplay test"
				% archetype.id)
		inst.free()


## [b]The premise the mount move rests on.[/b] `menu_backdrop_3d.tscn`'s CharacterMount was moved from
## y = 0.7 (sized for a centre-origin 1.1 cube) to the dais top at y = 0.15 because THIS rig's origin
## is between its feet. Swap in a centre-origin pack later and the mount silently buries the character
## to the waist — a look bug, reported as "the dais is wrong", fixed in the wrong file.
##
## Measured after a frame in the tree: the AABB is read through global transforms, and a skinned mesh
## has no meaningful bounds until the skeleton has posed once.
func _test_the_rig_stands_on_its_origin() -> void:
	var archetype := _archetype(&"vanguard")
	check(archetype != null and archetype.preview_scene != null,
		"the vanguard archetype resolves a preview scene to measure")
	if archetype == null or archetype.preview_scene == null:
		return

	var inst := archetype.preview_scene.instantiate() as Node3D
	get_root().add_child(inst)
	await step_frame()
	var bounds := _merged_bounds(inst)

	check(bounds.size != Vector3.ZERO,
		"the rig has real VisualInstance3D bounds to measure (got %s)" % bounds)
	check(absf(bounds.position.y) <= FEET_EPSILON,
		"and it is FEET-ORIGIN: its lowest point sits on y = 0 within %s, which is what puts the mount at the dais top rather than inside it (min y %s)"
			% [FEET_EPSILON, bounds.position.y])
	check(bounds.size.y > 1.0,
		"measured on a whole figure rather than on one stray bone (height %s)" % bounds.size.y)

	inst.queue_free()
	await step_frame()
	await step_frame()


## The other half of the same premise: the mount actually moved. Read off the SHIPPED scene, because
## the pairing that matters is this number against the rig measured above — either alone is fine and
## the two together are what stands a character on the dais.
func _test_the_backdrop_mount_sits_on_the_dais() -> void:
	var scene := ResourceLoader.load(BACKDROP_PATH) as PackedScene
	check(scene != null, "the shipped backdrop scene loads")
	if scene == null:
		return
	var inst := scene.instantiate()
	var mount := inst.find_child("CharacterMount", true, false) as Node3D
	check(mount != null, "it carries the CharacterMount the addon mounts characters under")
	if mount != null:
		check(is_equal_approx(mount.position.y, MOUNT_Y),
			"parked at y = %s, the dais top — the height a feet-origin rig needs (got %s)"
				% [MOUNT_Y, mount.position.y])
	inst.free()


## [b]D19's enforcement, and the only part of a licence decision a machine can hold.[/b] The carve-out
## is "the demo may ship CC0 art, carrying the pack's own licence file beside the asset" — art that
## arrives without that file is the exact state the decision exists to forbid, and it is invisible in
## every other gate.
func _test_the_art_ships_with_its_licence() -> void:
	check(FileAccess.file_exists(LICENSE_PATH),
		"the licence file ships beside the .glb (%s)" % LICENSE_PATH)
	var text := FileAccess.get_file_as_string(LICENSE_PATH)
	check(text.contains("CC0"),
		"and it states CC0 — D19 permits CC0 art in the demo and nothing else (%d bytes read)"
			% text.length())


# --- Fixtures -----------------------------------------------------------------

## Every archetype the demo authors, read off disk rather than listed here: a fourth one added to the
## folder is covered the moment it exists.
func _shipped_archetypes() -> Array[MKArchetype]:
	var out: Array[MKArchetype] = []
	var dir := DirAccess.open(ARCHETYPE_DIR)
	if dir == null:
		fail("the archetype folder %s is readable" % ARCHETYPE_DIR)
		return out
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var archetype := ResourceLoader.load("%s/%s" % [ARCHETYPE_DIR, file]) as MKArchetype
		if archetype == null:
			fail("%s loads as an MKArchetype" % file)
			continue
		out.append(archetype)
	out.sort_custom(func(a: MKArchetype, b: MKArchetype) -> bool: return str(a.id) < str(b.id))
	return out


func _archetype(id: StringName) -> MKArchetype:
	for archetype in _shipped_archetypes():
		if archetype.id == id:
			return archetype
	return null


func _ids(archetypes: Array) -> Array[String]:
	var out: Array[String] = []
	for archetype in archetypes:
		if archetype != null:
			out.append(str(archetype.id))
	out.sort()
	return out


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


## The first mesh carrying a surface override, which is where the per-archetype tint lands. Searched
## for by the OVERRIDE rather than by node name, so a re-import that renames the mesh fails the
## "override survived" assertion honestly instead of failing to find a node it was told to look for.
func _first_overridden_mesh(node: Node) -> MeshInstance3D:
	var mesh := node as MeshInstance3D
	if mesh != null and mesh.get_surface_override_material_count() > 0 \
			and mesh.get_surface_override_material(0) != null:
		return mesh
	for child in node.get_children():
		var found := _first_overridden_mesh(child)
		if found != null:
			return found
	return null


func _merged_bounds(root: Node) -> AABB:
	var out := AABB()
	var got := false
	for visual in _visual_instances(root):
		var world: AABB = visual.global_transform * visual.get_aabb()
		if got:
			out = out.merge(world)
		else:
			out = world
			got = true
	return out


func _visual_instances(node: Node) -> Array[VisualInstance3D]:
	var out: Array[VisualInstance3D] = []
	var visual := node as VisualInstance3D
	if visual != null:
		out.append(visual)
	for child in node.get_children():
		out.append_array(_visual_instances(child))
	return out
