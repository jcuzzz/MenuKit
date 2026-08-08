extends MKTest
## The 3D scene backdrop: a def carrying a PackedScene renders fullscreen in a SubViewport with its
## own World3D, and set_character_scene stands a character in it under the def's mount node.
##
## [b]Headless boundary.[/b] Structure, ownership, warn paths and the swap/stash semantics are real
## headless; whether the scene LOOKS right (camera framing, lighting, the character on the dais) is
## the capture rig + a human pass, exactly like every other backdrop look question.

const PROFILES_PATH := "user://test_backdrop_scene_profiles.json"
const CONFIG_PATH := "res://demo/demo_config.tres"
const DEMO_SCENE_PATH := "res://demo/backdrops/menu_backdrop_3d.tscn"
const DEMO_CATALOG_PATH := "res://demo/backdrops/demo_backdrop_catalog.tres"


func run_tests() -> void:
	await _test_a_texture_def_still_renders_through_the_rect()
	await _test_a_scene_def_builds_an_own_world_viewport()
	await _test_a_character_mounts_replaces_and_clears()
	await _test_a_character_handed_early_mounts_when_the_scene_arrives()
	await _test_a_scene_without_a_camera_warns_naming_the_def()
	await _test_a_scene_without_the_mount_warns_when_a_character_needs_it()
	await _test_swapping_back_to_a_gradient_def_restores_the_rect()
	_test_the_shipped_demo_scene_carries_what_the_addon_needs()
	await _test_selecting_a_character_stands_its_archetype_in_the_backdrop()


## The pre-existing 2D path is byte-identical in behaviour: no scene on the def, no viewport in the
## tree, the TextureRect visible and textured.
func _test_a_texture_def_still_renders_through_the_rect() -> void:
	var backdrop := _make_backdrop()
	backdrop.apply_def(_gradient_def())
	check(_rect(backdrop).visible, "the rect is visible for a gradient def")
	check(_rect(backdrop).texture != null, "the gradient def produced a texture")
	check_eq(backdrop.find_child("MKBackdropScene", true, false), null,
		"no scene viewport exists for a 2D def")
	backdrop.queue_free()
	await step_frame()


func _test_a_scene_def_builds_an_own_world_viewport() -> void:
	var backdrop := _make_backdrop()
	backdrop.apply_def(_scene_def(_make_scene()))
	var container := backdrop.find_child("MKBackdropScene", true, false) as SubViewportContainer
	check(container != null, "a scene def builds the SubViewportContainer")
	check(container.stretch, "the container stretches — the viewport tracks the screen")
	check_eq(container.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the scene backdrop never eats a click meant for the menu")
	var viewport := backdrop.find_child("MKBackdropViewport", true, false) as SubViewport
	check(viewport != null, "the SubViewport exists")
	check(viewport.own_world_3d, "the scene renders in its own World3D — no light leaks either way")
	check(viewport.get_camera_3d() != null, "the authored camera became the viewport's active camera")
	check(not _rect(backdrop).visible, "the 2D rect is dormant while a scene renders")
	backdrop.queue_free()
	await step_frame()


func _test_a_character_mounts_replaces_and_clears() -> void:
	var backdrop := _make_backdrop()
	backdrop.apply_def(_scene_def(_make_scene()))
	var mount := backdrop.find_child("CharacterMount", true, false)
	check(mount != null, "the fixture's mount is reachable")

	backdrop.set_character_scene(_make_character("CharA"))
	check_eq(mount.get_child_count(), 1, "the character mounted under the mount node")
	check_eq(mount.get_child(0).name, StringName("CharA"), "and it is the scene that was handed over")

	backdrop.set_character_scene(_make_character("CharB"))
	await step_frame()
	check_eq(mount.get_child_count(), 1, "a second character REPLACES the first, never joins it")
	check_eq(mount.get_child(0).name, StringName("CharB"), "the replacement is the newer scene")

	backdrop.set_character_scene(null)
	await step_frame()
	check_eq(mount.get_child_count(), 0, "null clears the mount")
	backdrop.queue_free()
	await step_frame()


## Selection can precede the catalog resolving (or land while a texture def is up) — the request is
## remembered, not dropped, and mounts when a scene backdrop next applies.
func _test_a_character_handed_early_mounts_when_the_scene_arrives() -> void:
	var backdrop := _make_backdrop()
	backdrop.set_character_scene(_make_character("Early"))
	backdrop.apply_def(_scene_def(_make_scene()))
	var mount := backdrop.find_child("CharacterMount", true, false)
	check_eq(mount.get_child_count(), 1, "the early character mounted when the scene applied")
	backdrop.queue_free()
	await step_frame()


func _test_a_scene_without_a_camera_warns_naming_the_def() -> void:
	var root := Node3D.new()
	root.name = "NoCamera"
	var scene := _pack(root)
	var backdrop := _make_backdrop()
	var seen := _observe()
	backdrop.apply_def(_scene_def(scene))
	_unobserve()
	check(_any_contains(seen, "no Camera3D"), "a cameraless scene is warned about")
	backdrop.queue_free()
	await step_frame()


func _test_a_scene_without_the_mount_warns_when_a_character_needs_it() -> void:
	var root := Node3D.new()
	root.name = "NoMount"
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.owner = root
	var backdrop := _make_backdrop()
	backdrop.apply_def(_scene_def(_pack(root)))
	var seen := _observe()
	backdrop.set_character_scene(_make_character("Nowhere"))
	_unobserve()
	check(_any_contains(seen, "CharacterMount"), "the missing mount is warned about by name")
	backdrop.queue_free()
	await step_frame()


func _test_swapping_back_to_a_gradient_def_restores_the_rect() -> void:
	var backdrop := _make_backdrop()
	backdrop.apply_def(_scene_def(_make_scene()))
	backdrop.apply_def(_gradient_def())
	await step_frame()
	check_eq(backdrop.find_child("MKBackdropScene", true, false), null,
		"the viewport is torn down when a 2D def takes over")
	check(_rect(backdrop).visible and _rect(backdrop).texture != null,
		"the rect re-lights with the gradient")
	backdrop.queue_free()
	await step_frame()


## The fixture-vs-shipped-asset rule: the demo's authored scene and catalog must actually carry what
## the addon's warn paths would otherwise flag at first boot.
func _test_the_shipped_demo_scene_carries_what_the_addon_needs() -> void:
	var scene := ResourceLoader.load(DEMO_SCENE_PATH) as PackedScene
	check(scene != null, "the demo backdrop scene loads")
	var inst := scene.instantiate()
	check(_find_type(inst, "Camera3D") != null, "the shipped scene carries a Camera3D")
	check(inst.find_child("CharacterMount", true, false) != null,
		"the shipped scene carries the CharacterMount")
	inst.free()
	var catalog := ResourceLoader.load(DEMO_CATALOG_PATH) as MKBackdropCatalog
	check(catalog != null, "the demo catalog loads")
	var def := catalog.get_backdrop(&"menu_3d")
	check(def != null and def.scene != null, "the catalog's menu_3d entry is a scene def")
	check_eq(catalog.get_default(), def, "and it is the catalog default the demo config selects")


## End to end through a REAL shell on the demo config: selecting a roster card stands that entry's
## archetype preview in the backdrop scene, and selecting one with an unknown archetype clears it.
func _test_selecting_a_character_stands_its_archetype_in_the_backdrop() -> void:
	_clean()
	var backend := MKJsonProfileBackend.new()
	backend._mk_configure({"file_path": PROFILES_PATH})
	get_root().add_child(backend)
	check(not backend.create_profile({"name": "Alice", "archetype": "scout"}).is_empty(),
		"seeded Alice")
	check(not backend.create_profile({"name": "Bob", "archetype": "no_such_archetype"}).is_empty(),
		"seeded Bob")
	get_root().remove_child(backend)
	backend.free()

	var config := (ResourceLoader.load(CONFIG_PATH) as MKConfig).duplicate(true)
	var profile_slot := MKBackendSlot.new()
	profile_slot.backend_script = MKJsonProfileBackend
	profile_slot.params = {"file_path": PROFILES_PATH}
	config.profile_backend = profile_slot
	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()
	root.go_to_page(&"characters")
	await step_frame()
	await step_frame()

	var mount := root.find_child("CharacterMount", true, false)
	check(mount != null, "the shell built the demo's scene backdrop")
	# The panel default-selects the first card (Alice, a scout) on page entry.
	check_eq(mount.get_child_count(), 1, "the selected entry's archetype preview is standing in the scene")

	var panel := _find_type(root, "MKCharacterSelect")
	# One-element Array, not an int: a lambda captures locals BY VALUE (§4 trap) and a plain counter
	# would read zero forever regardless of emissions.
	var emissions := [0]
	panel.connect("selection_changed", func(_entry: Dictionary) -> void: emissions[0] += 1)
	panel._select(panel.get_selected_profile())
	check_eq(emissions[0], 0, "re-selecting the same id is quiet — focus travel must not churn the mount")

	panel._select({"id": "bogus", "name": "Bob", "archetype": "no_such_archetype"})
	await step_frame()
	check_eq(mount.get_child_count(), 0,
		"an archetype the config does not know CLEARS the mount rather than showing the wrong character")

	root.queue_free()
	await step_frame()
	_clean()


func _make_backdrop() -> MKBackdrop:
	var backdrop := MKBackdrop.new()
	get_root().add_child(backdrop)
	return backdrop


func _rect(backdrop: MKBackdrop) -> TextureRect:
	return backdrop.find_child("MKBackdropRect", false, false) as TextureRect


func _gradient_def() -> MKBackdropDef:
	var def := MKBackdropDef.new()
	def.id = &"test_gradient"
	return def


func _scene_def(scene: PackedScene) -> MKBackdropDef:
	var def := MKBackdropDef.new()
	def.id = &"test_scene"
	def.scene = scene
	return def


## A minimal valid backdrop scene: a camera and the default-named mount.
func _make_scene() -> PackedScene:
	var root := Node3D.new()
	root.name = "SceneRoot"
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.5, 3)
	root.add_child(camera)
	camera.owner = root
	var mount := Marker3D.new()
	mount.name = "CharacterMount"
	root.add_child(mount)
	mount.owner = root
	return _pack(root)


func _make_character(char_name: String) -> PackedScene:
	var root := Node3D.new()
	root.name = char_name
	return _pack(root)


func _pack(root: Node) -> PackedScene:
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene


func _find_type(root: Node, type_name: String) -> Node:
	if root.is_class(type_name) or (root.get_script() != null \
			and (root.get_script() as Script).get_global_name() == StringName(type_name)):
		return root
	for child in root.get_children():
		var found := _find_type(child, type_name)
		if found != null:
			return found
	return null


var _seen: Array[String] = []


func _observe() -> Array[String]:
	_seen = []
	MKLog.observer = func(_level: MKLog.Level, message: String) -> void:
		_seen.append(message)
	return _seen


func _unobserve() -> void:
	MKLog.observer = Callable()


func _any_contains(messages: Array[String], needle: String) -> bool:
	for message in messages:
		if message.contains(needle):
			return true
	return false


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := PROFILES_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
