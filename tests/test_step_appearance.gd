extends MKTest
## The appearance step's preview mount (plan §4.5/§4.6).
##
## [b]The step still owns no payload key and is still always valid.[/b] Those two properties are what
## make it a safe placeholder for a host to replace, and mounting a preview inside it must not have
## bought them away — so they are asserted here alongside the mount rather than left to the host suite.
##
## [b]What is asserted about the preview is CONTENT, not pixels.[/b] Under `--headless` the dummy
## rasterizer draws nothing, so this suite checks that the chosen archetype's
## [member MKArchetype.preview_scene] reached the viewport as a live instance of the expected class,
## and that an archetype without one leaves the slot empty and silent. The look of it — framing,
## lighting, the idle spin — is the capture pass's job.
##
## The step is bound DIRECTLY rather than through an [MKCreationHost]: the host's own drop and
## ownership behaviour is test_creation_host.gd's subject, and the bind contract is the whole of the
## surface this step has.

const STEP_SCENE := "res://addons/menu_kit/creation/steps/mk_step_appearance.tscn"

var _log: Array[String] = []


func run_tests() -> void:
	await _test_the_chosen_archetypes_preview_is_mounted()
	await _test_an_archetype_with_no_preview_leaves_the_slot_empty_and_silent()
	await _test_an_unknown_or_non_string_archetype_clears_rather_than_keeping_the_last_one()
	await _test_the_step_still_owns_nothing_and_is_always_valid()


## The populated path: a payload naming an archetype that carries a preview_scene puts THAT scene's
## root under the viewport. Asserted on the instance's class as well as on non-null, because a mount
## that displayed some other archetype's model would satisfy a null check perfectly.
func _test_the_chosen_archetypes_preview_is_mounted() -> void:
	var step := await _bind([_archetype(&"box", _box_scene()), _archetype(&"sphere", _sphere_scene())],
		{"archetype": "sphere"})

	var preview := _preview(step)
	check(preview != null, "the step mounts an MKPreviewViewport")
	if preview == null:
		await _drop(step)
		return
	var content := preview.get_content()
	check(content != null, "with the chosen archetype's preview_scene instanced in it")
	if content != null:
		check(content is CSGSphere3D,
			"and it is the SPHERE the payload named, not the first archetype in the list (got %s)"
				% content.get_class())

	await _drop(step)


## The shipped placeholder state: every archetype the ADDON ships leaves preview_scene null, so an
## empty viewport behind the explanatory text is the ordinary out-of-the-box appearance step. It must
## therefore be silent — a warning here would fire on every default install, which is how a log stops
## being read.
func _test_an_archetype_with_no_preview_leaves_the_slot_empty_and_silent() -> void:
	_watch_log()
	var step := await _bind([_archetype(&"bare", null)], {"archetype": "bare"})
	var messages := _stop_watching()

	var preview := _preview(step)
	check(preview != null, "the viewport is mounted regardless")
	if preview != null:
		check_eq(preview.get_content(), null,
			"and holds nothing — an archetype with no authored preview is the shipped placeholder state, not a fault")
	check_eq(messages.size(), 0,
		"with NOTHING logged at any level: the addon's own archetypes are all preview-less, so a message here would fire on every default install (got %s)"
			% ["\n".join(messages)])
	check(step._mk_step_is_valid(), "and the step is still walkable past")

	await _drop(step)


## A payload key is OPAQUE host data, so "archetype" may hold an id nothing matches or a value that is
## not a string at all. Either way the slot is CLEARED rather than left showing the previous subject:
## a preview disagreeing with the payload is the one outcome it must never produce.
func _test_an_unknown_or_non_string_archetype_clears_rather_than_keeping_the_last_one() -> void:
	var archetypes := [_archetype(&"box", _box_scene())]
	var step := await _bind(archetypes, {"archetype": "box"})
	var preview := _preview(step)
	check(preview != null and preview.get_content() != null, "precondition: something is displayed")
	if preview == null:
		await _drop(step)
		return

	step._apply_preview({"archetype": "no_such_id"})
	await step_frame()
	check_eq(preview.get_content(), null, "an id no archetype answers to clears the slot")

	step._apply_preview({"archetype": "box"})
	await step_frame()
	check(preview.get_content() != null, "precondition: and it can be refilled")
	step._apply_preview({"archetype": {"nested": true}})
	await step_frame()
	check_eq(preview.get_content(), null,
		"a non-string value clears it too, type-gated rather than String()'d into a key that matches nothing")

	step._apply_preview({})
	await step_frame()
	check_eq(preview.get_content(), null, "and an absent key is the empty state, not an error")

	await _drop(step)


## The two properties that make this scene a safe placeholder for a host to replace. Mounting a widget
## inside it must not have bought either of them away: a placeholder that claimed a key would reserve
## it against the host's own replacement step, and one that could report invalid would gate Next on a
## screen with no input on it.
func _test_the_step_still_owns_nothing_and_is_always_valid() -> void:
	var step := await _bind([_archetype(&"box", _box_scene())], {"archetype": "box"})

	check_eq(step._mk_step_owned_keys(), [] as Array[String],
		"the step declares no owned payload key")
	var payload := {"untouched": 1}
	step._mk_step_commit(payload)
	check_eq(payload, {"untouched": 1}, "and its commit writes nothing at all")
	check(step._mk_step_is_valid(), "it is always valid, with a preview mounted")

	await _drop(step)


# --- Fixtures -----------------------------------------------------------------

func _bind(archetypes: Array, payload: Dictionary) -> MKStepAppearance:
	var packed := ResourceLoader.load(STEP_SCENE) as PackedScene
	check(packed != null, "the appearance step scene loads")
	var step := packed.instantiate() as MKStepAppearance
	get_root().add_child(step)
	var def := MKCreationStepDef.new()
	def.id = &"appearance"
	def.scene = packed
	var typed: Array[MKArchetype] = []
	for entry in archetypes:
		typed.append(entry)
	step._mk_step_bind(null, def, {
		"archetypes": typed,
		"profile_backend": null,
		"stat_schema": null,
		"payload": payload,
	})
	await step_frame()
	await step_frame()
	return step


func _archetype(id: StringName, preview: PackedScene) -> MKArchetype:
	var arch := MKArchetype.new()
	arch.id = id
	arch.display_name = String(id).capitalize()
	arch.preview_scene = preview
	return arch


func _preview(step: MKStepAppearance) -> MKPreviewViewport:
	return step.find_child("Preview", true, false) as MKPreviewViewport


## Two DIFFERENT primitive classes, so "the right one was mounted" is assertable at all. Packed in
## memory rather than loaded from demo/ — an addon test that reached into the demo would assert the
## demo's authoring instead of the step's behaviour.
func _box_scene() -> PackedScene:
	return _pack(CSGBox3D.new(), "Box")


func _sphere_scene() -> PackedScene:
	return _pack(CSGSphere3D.new(), "Sphere")


func _pack(node: Node3D, node_name: String) -> PackedScene:
	node.name = node_name
	var packed := PackedScene.new()
	packed.pack(node)
	node.free()
	return packed


func _drop(step: Node) -> void:
	if step != null and is_instance_valid(step):
		step.queue_free()
	await step_frame()
	await step_frame()


# --- Observation --------------------------------------------------------------

## Every level is collected, because the empty-preview case's rule is "nothing is said AT ALL" — a
## watcher limited to warnings would be satisfied by a debug line explaining art that was never
## promised.
func _watch_log() -> void:
	_log = []
	MKLog.observer = func(_level: MKLog.Level, message: String) -> void:
		_log.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _log
