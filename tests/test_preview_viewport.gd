extends MKTest
## The 3D preview slot: content swapping, framing, world isolation, zoom clamps and render gating
## (plan §4.6, D13/F10).
##
## [b]What this suite can and cannot see.[/b] Under `--headless` the dummy rasterizer draws nothing,
## so nothing here asserts an image. What IS real headless — and is what the class's contracts are
## actually written about — is the node graph the widget builds, the [SubViewport] flags it sets, the
## camera distance it derives from content bounds, and the instances it frees. The look of the
## three-point rig is a human pass on a real display; the arithmetic that points the camera at the
## subject is asserted here.
##
## [b]Input is driven by calling [code]_gui_input[/code] directly, and that is legitimate here.[/b]
## GUI dispatch is dead under the dummy display driver (verified in test_rebind: a pushed
## InputEventMouseButton never reaches a Control's gui_input), so a pushed wheel event would assert
## nothing. The rebind suite pushes at the viewport instead because ITS contract is about PRIORITY —
## the row consuming an event before anything else sees it — and calling the handler would bypass the
## very thing under test. This widget makes no priority claim: [method _gui_input] is documented as an
## ordinary Control handler that acts only on events already routed to its own rect, so invoking it is
## the same call the engine would make.

## Instances built per test, freed at the end of each.
var _log: Array[String] = []


func run_tests() -> void:
	# No expect_engine_error here, deliberately: the runtime own_world_3d flip used to print the
	# renderer's 'Parameter "scenario" is null' ERROR (live instances torn between worlds), and this
	# suite shipped a declaration for it. The setter now detaches the viewport around the flip, so a
	# clean run IS the assertion — reintroducing the error must FAIL this suite, not be waved through.
	await _test_a_swap_frees_the_old_content()
	await _test_the_subviewport_owns_its_own_world_by_default()
	await _test_clearing_the_slot_is_legal()
	await _test_framing_falls_back_when_the_content_has_no_bounds()
	await _test_a_non_node3d_scene_warns_and_parents_nothing()
	await _test_zoom_clamps_at_both_bounds_and_survives_an_inverted_pair()
	await _test_preview_changed_fires_once_per_swap()
	await _test_render_mode_follows_visibility()


## The leak this rule exists to prevent is invisible: a preview that parented each new character
## beside the last would still LOOK right — the newest content is drawn over the old — while every
## previous one keeps its meshes, its skeleton and its process time. So both halves are asserted: the
## old instance is gone, and the pivot holds exactly one child.
func _test_a_swap_frees_the_old_content() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	var first := preview.get_content()
	check(first != null, "the first scene is displayed")
	check_eq(_pivot(preview).get_child_count(), 1, "as the pivot's only child")

	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	await step_frame()

	check(not is_instance_valid(first), "a swap FREES the previous instance rather than hiding it")
	check(preview.get_content() != null, "and the new one is live")
	check(preview.get_content() != first, "specifically a different instance")
	check_eq(_pivot(preview).get_child_count(), 1,
		"with exactly one child under the pivot — a preview that stacked them would look correct and leak every character ever shown")

	await _drop(preview)


## F10: shared worlds leak in BOTH directions — this rig's key/fill/rim lights would light the running
## game, and the game's sun and environment would light the preview, so the same character looks
## different in a menu over a night map. Opt-OUT precisely because the leak is invisible until somebody
## notices the game got brighter.
func _test_the_subviewport_owns_its_own_world_by_default() -> void:
	var preview := await _make_preview()
	check(preview.use_own_world, "the exported default is own-world")
	check(_viewport(preview).own_world_3d,
		"and it reached the SubViewport — the export alone would be a decorative flag")

	preview.use_own_world = false
	check(not _viewport(preview).own_world_3d,
		"a RUNTIME flip retargets the live viewport, so a host opting in to the shared world does not have to rebuild the node")
	preview.use_own_world = true
	check(_viewport(preview).own_world_3d, "and back")

	# The rig itself, by the stable names the class doc makes public: renaming one is a public-surface
	# change, and a host (or this suite) indexing them must fail loudly if that happens silently.
	check(_viewport(preview).get_node_or_null(MKPreviewViewport.CAMERA_NAME) != null, "the camera is built")
	for light_name in [MKPreviewViewport.KEY_LIGHT_NAME, MKPreviewViewport.FILL_LIGHT_NAME,
			MKPreviewViewport.RIM_LIGHT_NAME]:
		var light := _viewport(preview).get_node_or_null(light_name) as DirectionalLight3D
		check(light != null, "the %s exists under its documented name" % light_name)
		if light != null:
			check_eq(light.light_color, Color(1, 1, 1, 1),
				"lit pure white — a warm key would make every piece of armour look like it had a gold tint the artist never put there")

	await _drop(preview)


## "No selection" is a real state in every host this serves, so clearing is an expected call rather
## than an error — making it one would force each host to invent an empty placeholder scene.
func _test_clearing_the_slot_is_legal() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check(preview.get_content() != null, "precondition: something is displayed")

	# Counted through an Array, not an int local: GDScript lambdas capture by VALUE, so a captured
	# integer counter stays at its initial value however often the signal fires — which reads as a
	# signal that never fired at all.
	var changes: Array[int] = [0]
	preview.preview_changed.connect(func() -> void: changes[0] += 1)
	preview.set_preview_scene(null)
	await step_frame()
	await step_frame()

	check_eq(preview.get_content(), null, "a null assignment clears the slot")
	check_eq(_pivot(preview).get_child_count(), 0, "with nothing left under the pivot")
	check_eq(changes[0], 1,
		"and it still EMITS preview_changed — 'the slot is now empty' is exactly the news a dependent name label needs")
	check_eq(preview.preview_scene, null, "the exported property reflects the clear")

	await _drop(preview)


## A scene with no [VisualInstance3D] yet is a legitimate state (streamed meshes, a logic-only probe),
## so it is neither a crash nor a warning: the camera takes the fallback distance and says so at debug
## level, where `--mk-verbose` explains a preview that looks empty without spamming a host doing it on
## purpose.
func _test_framing_falls_back_when_the_content_has_no_bounds() -> void:
	var preview := await _make_preview()

	_watch_log()
	preview.set_preview_scene(_bare_node3d_scene())
	await step_frame()
	var messages := _stop_watching()

	check(preview.get_content() != null, "the boundless scene IS instanced and parented")
	check_eq(preview._distance, 3.0,
		"and the camera sits at the fallback distance rather than inside a zero-sized subject")
	check_eq(_count_containing(messages, "no VisualInstance3D bounds"), 1,
		"with one line explaining it")
	check_eq(_warn_count("no VisualInstance3D bounds"), 0,
		"at DEBUG, not WARN — a rig whose meshes spawn later is not a misconfiguration")

	# And the contrast: real bounds produce a DERIVED distance, so the fallback is not simply what the
	# widget always does.
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check(preview._distance != 3.0,
		"content WITH bounds is framed from those bounds — otherwise the assertion above is satisfied by a widget that never frames anything")
	check(preview._distance >= preview.zoom_min and preview._distance <= preview.zoom_max,
		"and the fitted distance is clamped into the zoom range (got %s)" % preview._distance)
	check(_pivot(preview).position != Vector3.ZERO,
		"the pivot is lifted to the content's centre, so the subject spins about its middle rather than its ankles")

	await _drop(preview)


## A non-[Node3D] root cannot be parented under the pivot and would never be visible. Naming the scene
## and the type is the whole behaviour: silently showing nothing is the state a host cannot debug.
func _test_a_non_node3d_scene_warns_and_parents_nothing() -> void:
	var preview := await _make_preview()

	_watch_log()
	preview.set_preview_scene(_control_scene())
	await step_frame()
	await step_frame()
	var warnings := _warnings_only()
	_stop_watching()

	check_eq(_count_containing(warnings, "not a Node3D"), 1,
		"one warning naming the problem")
	check_eq(preview.get_content(), null, "nothing is reported as content")
	check_eq(_pivot(preview).get_child_count(), 0,
		"and nothing was parented — the instance is freed rather than left orphaned under the viewport")

	await _drop(preview)


## Zoom is bounded on both sides, and the bounds are read as a RANGE rather than as "min then max": a
## host that authored them the wrong way round gets a working widget instead of a distance that can
## never satisfy both clamps.
func _test_zoom_clamps_at_both_bounds_and_survives_an_inverted_pair() -> void:
	var preview := await _make_preview()
	preview.zoom_min = 1.0
	preview.zoom_max = 6.0
	preview.zoom_step = 0.5
	preview.set_preview_scene(null)
	await step_frame()

	for _i in 40:
		preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	check_eq(preview._distance, 6.0, "pushing out stops at zoom_max")
	for _i in 40:
		preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_UP))
	check_eq(preview._distance, 1.0, "and pulling in stops at zoom_min")

	# One notch, to prove the wheel moves the camera at all — a clamp that pinned the distance to a
	# constant would satisfy both assertions above.
	preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	check_eq(preview._distance, 1.5, "a single notch moves by exactly zoom_step")

	preview.zoom_min = 6.0
	preview.zoom_max = 1.0
	for _i in 40:
		preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_UP))
	check_eq(preview._distance, 1.0,
		"with an INVERTED pair the lower number is still the floor — the clamp reads the exports as a range")
	for _i in 40:
		preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	check_eq(preview._distance, 6.0, "and the higher one the ceiling")

	await _drop(preview)


## Hosts drive dependent UI off this signal rather than guessing at a frame boundary, so it must fire
## once per swap — no more (a doubled emission re-runs a host's stat panel rebuild) and no less.
func _test_preview_changed_fires_once_per_swap() -> void:
	var preview := await _make_preview()
	# Array counter, for the lambda capture-by-value reason recorded above.
	var changes: Array[int] = [0]
	preview.preview_changed.connect(func() -> void: changes[0] += 1)

	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check_eq(changes[0], 1, "one emission for the first swap")
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check_eq(changes[0], 2, "one for the second")
	preview.set_preview_scene(null)
	await step_frame()
	check_eq(changes[0], 3, "and one for the clear")

	# Assigned through the exported PROPERTY rather than the method: the setter is the documented route
	# a host drives from a selection signal, and it must not re-enter and double-emit.
	preview.preview_scene = _mesh_scene()
	await step_frame()
	check_eq(changes[0], 4, "the property assignment emits exactly once, not twice through its own setter")

	await _drop(preview)


## A SubViewport left at UPDATE_ALWAYS renders a full 3D pass every frame whether or not anyone can see
## it — paid by a character sheet nobody has open. UPDATE_ONCE is not usable because the content
## animates, so visibility gating is the whole saving.
func _test_render_mode_follows_visibility() -> void:
	var preview := await _make_preview()
	check_eq(_viewport(preview).render_target_update_mode, SubViewport.UPDATE_ALWAYS,
		"a visible preview renders every frame")

	preview.visible = false
	await step_frame()
	check_eq(_viewport(preview).render_target_update_mode, SubViewport.UPDATE_DISABLED,
		"a hidden one renders nothing at all")

	preview.visible = true
	await step_frame()
	check_eq(_viewport(preview).render_target_update_mode, SubViewport.UPDATE_ALWAYS,
		"and showing it again resumes — a gate that never re-opened would be a blank preview")

	await _drop(preview)


# --- Fixtures -----------------------------------------------------------------

func _make_preview() -> MKPreviewViewport:
	var preview := MKPreviewViewport.new()
	preview.name = "Preview"
	preview.custom_minimum_size = Vector2(320, 320)
	get_root().add_child(preview)
	await step_frame()
	return preview


func _drop(preview: Node) -> void:
	if preview != null and is_instance_valid(preview):
		preview.queue_free()
	await step_frame()
	await step_frame()


func _viewport(preview: MKPreviewViewport) -> SubViewport:
	return preview.get_node_or_null("PreviewSubViewport") as SubViewport


func _pivot(preview: MKPreviewViewport) -> Node3D:
	return _viewport(preview).get_node_or_null(MKPreviewViewport.PIVOT_NAME) as Node3D


## A one-cube subject: real [VisualInstance3D] bounds, so the framing math has something to fit.
## Packed in memory (the child's owner set, or pack() would drop it) rather than shipped as a .tscn,
## so the content each assertion is about is visible in the test that reads it.
func _mesh_scene() -> PackedScene:
	var root := Node3D.new()
	root.name = "Subject"
	var mesh := MeshInstance3D.new()
	mesh.name = "Body"
	mesh.mesh = BoxMesh.new()
	mesh.position = Vector3(0.0, 1.0, 0.0)
	root.add_child(mesh)
	mesh.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _bare_node3d_scene() -> PackedScene:
	var root := Node3D.new()
	root.name = "Logic"
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _control_scene() -> PackedScene:
	var root := Control.new()
	root.name = "NotSpatial"
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _wheel(button_index: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index as MouseButton
	event.pressed = true
	return event


# --- Observation --------------------------------------------------------------

## Levels are kept with the message: two of this widget's rules are about the LEVEL a thing is reported
## at ("a boundless scene is debug, not a warning"), and a suite that only counted messages could not
## tell those apart.
func _watch_log() -> void:
	_log = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		_log.append("%d|%s" % [level, message])


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _messages()


func _messages() -> Array[String]:
	var out: Array[String] = []
	for entry in _log:
		out.append(entry.substr(entry.find("|") + 1))
	return out


func _warnings_only() -> Array[String]:
	var out: Array[String] = []
	for entry in _log:
		if entry.begins_with("%d|" % MKLog.Level.WARN):
			out.append(entry.substr(entry.find("|") + 1))
	return out


func _warn_count(needle: String) -> int:
	return _count_containing(_warnings_only(), needle)


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found
