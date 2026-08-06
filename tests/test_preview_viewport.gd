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
	await _test_deferred_built_content_frames_on_the_second_pass()
	await _test_two_swaps_in_one_frame_frame_the_SECOND_content()
	await _test_frame_content_in_the_swap_frame_is_silent_and_frames_next_frame()
	await _test_content_assigned_off_tree_frames_when_it_enters_the_tree()
	await _test_a_swap_while_detached_frames_when_the_node_re_enters()
	await _test_a_reparent_before_the_deferred_pass_still_frames()
	await _test_framing_is_idempotent_and_tracks_content_that_grows()
	await _test_a_swap_keeps_the_zoom_the_user_chose()
	await _test_clearing_the_slot_gives_the_next_content_a_fresh_fit()
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


## [b]The case the three shipped demo previews are.[/b] CSG builds its mesh on a DEFERRED call, so
## [method VisualInstance3D.get_aabb] reads zero on the frame the node is added — measured here and in
## isolation: a bare CSGBox3D reports a zero AABB immediately and its real one on the next frame. A
## widget that framed only immediately therefore took the no-bounds fallback for every CSG preview
## (pivot at the origin, fallback distance, engine-default near/far) while ALSO logging that the
## content had no bounds, which it plainly did.
##
## So both halves are asserted: the second pass really measures, and the immediate zero — the expected
## reading for deferred-built content — says nothing in the log.
func _test_deferred_built_content_frames_on_the_second_pass() -> void:
	var preview := await _make_preview()
	# The REAL shipped demo scene, not a stand-in: the finding is that the addon fails on the content it
	# ships with, and a hand-built CSG node in this file could drift away from what demo_creation holds.
	var vanguard := load("res://demo/demo_creation/preview_vanguard.tscn") as PackedScene
	check(vanguard != null, "the shipped demo preview scene loads")
	if vanguard == null:
		await _drop(preview)
		return

	_watch_log()
	preview.set_preview_scene(vanguard)
	check_eq(preview._distance, 3.0,
		"precondition: the IMMEDIATE pass measures nothing, because the CSG mesh does not exist yet")
	await step_frame()
	var messages := _stop_watching()

	check(preview._distance != 3.0,
		"after the deferred pass the camera sits at a DERIVED distance, not the fallback (got %s)"
			% preview._distance)
	check(preview._distance >= preview.zoom_min and preview._distance <= preview.zoom_max,
		"clamped into the zoom range")
	check_eq(_count_containing(messages, "no VisualInstance3D bounds"), 0,
		"and the immediate zero is NOT reported — it is the expected reading for deferred-built content, so a line here fires for every CSG preview ever shown")
	var camera := _viewport(preview).get_node_or_null(MKPreviewViewport.CAMERA_NAME) as Camera3D
	check(camera != null and camera.near != 0.05,
		"the near plane is derived from the subject's radius rather than left at the engine default (got %s)"
			% (camera.near if camera != null else -1.0))
	check(camera != null and camera.far > preview.zoom_max,
		"and far clears the furthest the camera can be pushed")

	# Off-origin: the pivot has to reach the subject's real centre, or a demo preview authored anywhere
	# but the origin spins about a point beside itself. Measured after the deferred pass, because the
	# immediate one has no bounds to centre on.
	preview.set_preview_scene(_offset_csg_scene())
	await step_frame()
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 2.0, 0.0)),
		"content authored two units up is centred by the deferred pass (pivot at %s)"
			% _pivot(preview).position)
	check(preview.get_content().position.is_equal_approx(Vector3.ZERO),
		"with the content shifted back under the pivot by the same amount — its authored +2 cancels exactly, so the subject did not visibly move (got %s)"
			% preview.get_content().position)

	await _drop(preview)


## [b]Two swaps in ONE frame, which a host does by simply moving the selection twice (a keyboard
## repeat through a character list, a programmatic "select the default" landing on the same frame as a
## restored selection).[/b]
##
## The framing pass is deferred, and Godot's deferred queue is FIFO. A boolean "one pass queued at a
## time" de-dup therefore mis-ordered exactly this case: swap 1 queued the pass, swap 2's CSG build
## enqueued AFTER it, so the pass ran over content whose mesh did not exist yet, read zero bounds,
## consumed the flag — and nothing re-queued. Measured: pivot at the origin and the fallback distance,
## permanently, for the content the player is actually looking at.
##
## The generation counter is what fixes the ORDER rather than the count: every swap queues its own
## pass, so the live content's pass sits after its own build, and the earlier passes recognise
## themselves as stale and return without measuring.
func _test_two_swaps_in_one_frame_frame_the_SECOND_content() -> void:
	var preview := await _make_preview()

	_watch_log()
	preview.set_preview_scene(_offset_csg_scene())
	preview.set_preview_scene(_csg_scene_at(5.0))
	await step_frame()
	await step_frame()
	var messages := _stop_watching()

	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 5.0, 0.0)),
		"the SECOND content is the one that gets centred — the first swap's pass is stale and must not measure the second's unbuilt mesh (pivot at %s)"
			% _pivot(preview).position)
	check(preview.get_content() != null
			and preview.get_content().position.is_equal_approx(Vector3.ZERO),
		"with the live content shifted back under the pivot, as a single swap does")
	check(preview._distance != 3.0,
		"and the distance is DERIVED, not the no-bounds fallback the mis-ordered pass left behind (got %s)"
			% preview._distance)
	check_eq(_count_containing(messages, "no VisualInstance3D bounds"), 0,
		"and nothing claims the content had no bounds — the stale pass never speaks")

	# The other same-frame pair: swap, then clear before the queued pass runs. The pass must tolerate
	# content that no longer exists rather than measuring a freed node.
	_watch_log()
	preview.set_preview_scene(_offset_csg_scene())
	preview.set_preview_scene(null)
	await step_frame()
	await step_frame()
	var clear_messages := _stop_watching()

	check_eq(preview.get_content(), null, "a swap-then-clear in one frame leaves the slot empty")
	check_eq(_pivot(preview).get_child_count(), 0, "with nothing under the pivot")
	check_eq(_count_containing(clear_messages, "no VisualInstance3D bounds"), 0,
		"and says nothing — an empty slot is not a scene that failed to measure")

	await _drop(preview)


## [method MKPreviewViewport.frame_content] called in the SAME frame as a swap is an ordinary host
## pairing ("show this, and refit for it"). Its immediate pass therefore measures content whose mesh
## may not be built yet — zero, the expected reading — and reporting that printed "no VisualInstance3D
## bounds" for content that plainly had them one frame later. The immediate half is silent for the same
## reason the swap's is; the queued pass is the definitive answer and the one that speaks.
func _test_frame_content_in_the_swap_frame_is_silent_and_frames_next_frame() -> void:
	var preview := await _make_preview()

	_watch_log()
	preview.set_preview_scene(_offset_csg_scene())
	preview.frame_content()
	var messages := _stop_watching()
	check_eq(_count_containing(messages, "no VisualInstance3D bounds"), 0,
		"not one line in the swap frame — a CSG mesh that does not exist yet is not a preview with no bounds")

	await step_frame()
	await step_frame()
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 2.0, 0.0)),
		"and a frame later it IS framed (pivot at %s)" % _pivot(preview).position)
	check(preview._distance != 3.0,
		"at a derived distance — frame_content keeps its unconditional refit (got %s)" % preview._distance)

	await _drop(preview)


## The authored-export route: a host sets [member MKPreviewViewport.preview_scene] on a node it has not
## added yet — which is also what [method PackedScene.instantiate] does for a scene carrying the export.
## Framing off-tree reads global transforms and calls look_at, both of which the engine refuses with an
## ERROR per attempt (four lines for one assignment, measured). There is no return value to branch on,
## so the framing simply does not run there and [code]_ready[/code] runs it on entry instead.
##
## [b]The clean run IS half the assertion.[/b] check.ps1 fails any test whose output carries an
## ERROR: line, so re-introducing the off-tree pass fails this suite rather than being waved through.
## The other half is that skipping it costs nothing: the fit must match what an in-tree assignment
## produces, to the same number.
func _test_content_assigned_off_tree_frames_when_it_enters_the_tree() -> void:
	var content := _mesh_scene()

	var reference := await _make_preview()
	reference.set_preview_scene(content)
	await step_frame()
	var in_tree_distance: float = reference._distance
	check(in_tree_distance != 3.0, "precondition: an in-tree assignment fits the distance to the bounds")

	var preview := MKPreviewViewport.new()
	preview.name = "OffTree"
	preview.custom_minimum_size = Vector2(320, 320)
	preview.preview_scene = content
	check_eq(preview._distance, 3.0,
		"off-tree nothing is measured — there is no tree to read a global transform in")
	var off_tree_instance := preview.get_content()
	check(off_tree_instance != null,
		"the INSTANCE exists already, though: only the framing needed a tree")
	# Array counter, for the lambda capture-by-value reason recorded above. Connected here, which is
	# exactly where a host that built the node and set the export connects.
	var changes: Array[int] = [0]
	preview.preview_changed.connect(func() -> void: changes[0] += 1)
	get_root().add_child(preview)
	await step_frame()
	await step_frame()

	# Approx, not exact: the fit is derived through the pivot's inverse GLOBAL transform, which is a
	# float32 round-trip — the same math over a pivot that started at a different position differs in
	# the seventh digit and means the same framing.
	check(is_equal_approx(preview._distance, in_tree_distance),
		"and entering the tree produces the SAME fit as an in-tree assignment, so the skipped pass lost nothing (%s vs %s)"
			% [preview._distance, in_tree_distance])
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 1.0, 0.0)),
		"with the pivot on the subject's centre (got %s)" % _pivot(preview).position)
	check_eq(changes[0], 0,
		"and entering the tree emits NOTHING further: the content was already instanced by the off-tree assignment, so re-applying the export there would free it, build an identical one and report a second swap to a host that has seen one")
	check_eq(preview.get_content(), off_tree_instance,
		"the instance is the same object it always was — the entry pass frames it rather than replacing it")

	await _drop(preview)
	await _drop(reference)


## [b]The class doc invites pooling and reparenting ("a host adds a preview by adding one node"), and
## [code]_ready[/code] runs ONCE per node lifetime.[/b] So a preview that has already been shown, is
## detached, is given new content while detached, and is added back had NO framing hook at all: the
## off-tree swap skips the framing (measured: pivot at the origin, the new content still carrying its
## authored offset, the distance left from the previous subject) and nothing re-ran it on the way back
## in. It rendered wrong, silently. NOTIFICATION_ENTER_TREE is the hook; _ready still owns the first
## entry, which is why the deferred pass is not doubled there.
func _test_a_swap_while_detached_frames_when_the_node_re_enters() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 1.0, 0.0)),
		"precondition: the first content framed normally (pivot at %s)" % _pivot(preview).position)

	var root := get_root()
	root.remove_child(preview)
	await step_frame()
	preview.set_preview_scene(_offset_csg_scene())
	# Frames pass while it is still detached, so the pass the swap queued runs, finds itself off-tree and
	# returns without measuring — the pooled shape, and what leaves the re-entry as the only hook left.
	await step_frame()
	await step_frame()
	check(_pivot(preview).position.is_equal_approx(Vector3.ZERO),
		"the off-tree swap RESETS the pivot rather than leaving the previous subject's centre on it (got %s)"
			% _pivot(preview).position)
	root.add_child(preview)
	await step_frame()
	await step_frame()

	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 2.0, 0.0)),
		"re-entering the tree frames the NEW content — the pivot reaches its centre (got %s)"
			% _pivot(preview).position)
	check(preview.get_content() != null
			and preview.get_content().position.is_equal_approx(Vector3.ZERO),
		"with the content shifted back under it exactly once, as an in-tree swap does (got %s)"
			% (preview.get_content().position if preview.get_content() != null else Vector3.INF))
	check_eq(_pivot(preview).get_child_count(), 1,
		"and one child under the pivot — the detached swap freed the old instance as any swap does")
	check(preview._distance != 3.0,
		"at a real distance rather than the no-bounds fallback (got %s)" % preview._distance)

	await _drop(preview)


## [b]The other detached shape: the swap happens IN the tree, and the node is reparented before the
## deferred pass runs.[/b] The queued pass finds itself off-tree and returns without measuring — which
## is correct, and used to be the end of it. The re-entry hook is what picks the framing back up; a host
## moving a preview between containers on the same frame it changed the selection is an ordinary
## gesture, not a misuse.
func _test_a_reparent_before_the_deferred_pass_still_frames() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()

	var root := get_root()
	var holder := Control.new()
	holder.name = "Holder"
	root.add_child(holder)

	# Assign, then reparent in the SAME frame — before the pass queued by the assignment has run.
	preview.set_preview_scene(_csg_scene_at(4.0))
	root.remove_child(preview)
	# The queued pass runs here, off-tree, and returns without measuring — so the framing has to be
	# picked up by the entry rather than by the interrupted pass.
	await step_frame()
	await step_frame()
	holder.add_child(preview)
	await step_frame()
	await step_frame()

	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 4.0, 0.0)),
		"the reparented preview is framed on the way back in, rather than keeping the origin pivot the interrupted pass left (got %s)"
			% _pivot(preview).position)
	check(preview.get_content() != null
			and preview.get_content().position.is_equal_approx(Vector3.ZERO),
		"with a single content shift — the interrupted pass measured nothing, so nothing was applied twice")

	await _drop(preview)
	holder.queue_free()
	await step_frame()


## [method MKPreviewViewport.frame_content] is the advertised call for content that changed size after
## it was instanced, so it is called more than once BY DESIGN — and must therefore be idempotent. The
## pivot write is relative (`+= centre`) precisely because it is paired with a relative content shift:
## an absolute write measured a second centre of zero and wrote zero, throwing the first call's
## centring away while the content kept its -centre offset. The subject then hung a metre below the
## point it spins around.
func _test_framing_is_idempotent_and_tracks_content_that_grows() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()

	var pivot_after_first := _pivot(preview).position
	check(pivot_after_first.is_equal_approx(Vector3(0.0, 1.0, 0.0)),
		"precondition: the cube is authored a unit up, so the pivot lifted to its centre (got %s)"
			% pivot_after_first)

	preview.frame_content()
	check(_pivot(preview).position.is_equal_approx(pivot_after_first),
		"a SECOND framing over unchanged content measures a centre of ~zero and no-ops, rather than resetting the pivot to the origin (got %s)"
			% _pivot(preview).position)
	preview.frame_content()
	check(_pivot(preview).position.is_equal_approx(pivot_after_first),
		"and a third — idempotence, not an alternation between two states")

	# The advertised case: content that GROWS after it was instanced (a weapon is equipped, meshes
	# stream in). The merged centre moves, and the pivot has to move with it.
	var grown := MeshInstance3D.new()
	grown.name = "LateArrival"
	grown.mesh = BoxMesh.new()
	grown.position = Vector3(0.0, 5.0, 0.0)
	preview.get_content().add_child(grown)
	await step_frame()
	preview.frame_content()

	# Content-local: the original cube sits at y=1 and the new one at y=5, each a unit box, so the
	# merged box spans y=0.5..5.5 about a centre at y=3 — which is 2 above where the pivot already was.
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 3.0, 0.0)),
		"re-framing after growth tracks the NEW merged centre (got %s)" % _pivot(preview).position)
	check(preview._distance > 3.0,
		"and the distance refits to the larger subject — frame_content is the call that DOES refit (got %s)"
			% preview._distance)

	await _drop(preview)


## The comparison story the class doc tells: a user cycling a character list keeps the angle AND the
## zoom they chose. Yaw and pitch were already preserved across a swap; the distance was not — every
## swap refitted it, so a player who zoomed in to look at a helmet was pushed back out by the next
## card. The FIRST content still fits, because there is no user choice to preserve yet, and an explicit
## frame_content() still refits — that is what the previous test asserts.
func _test_a_swap_keeps_the_zoom_the_user_chose() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	var fitted := preview._distance
	check(fitted != 3.0, "precondition: the FIRST content fitted the distance to its own bounds")

	preview._pitch_deg = 30.0
	preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	var chosen := preview._distance
	check(chosen != fitted, "precondition: the user wheeled away from the fitted distance")

	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	check_eq(preview._distance, chosen,
		"a SWAP keeps the zoom the user chose — refitting it here is a comparison list that shoves the camera every time the player changes card")
	check_eq(preview._pitch_deg, 30.0, "along with the pitch, as it always did")
	check(_pivot(preview).position.is_equal_approx(Vector3(0.0, 1.0, 0.0)),
		"while the new content is still CENTRED, which is the half of framing a swap must always do (got %s)"
			% _pivot(preview).position)

	await _drop(preview)


## The documented exception to "a swap keeps the zoom the user chose": [code]_fitted_once[/code] is
## "reset when the slot is cleared, so refilling it fits again" — an empty slot has no subject the user
## can have chosen a zoom FOR. So a clear-then-set is the one swap that does refit, and a host cycling
## a list through a null (a deselect between two cards) is where a player notices. Pinned because the
## sentence was documented and nothing held it: making the clear preserve the distance would read as a
## kindness and would silently contradict the doc.
func _test_clearing_the_slot_gives_the_next_content_a_fresh_fit() -> void:
	var preview := await _make_preview()
	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	var fitted := preview._distance
	check(fitted != 3.0, "precondition: the first content fitted")

	preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	preview._gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	var chosen := preview._distance
	check(chosen != fitted, "precondition: the user wheeled away from it")

	preview.set_preview_scene(null)
	await step_frame()
	check_eq(preview._distance, 3.0,
		"clearing parks the camera at the fallback — there is no subject left to be at a distance from")

	preview.set_preview_scene(_mesh_scene())
	await step_frame()
	# Approx for the float32 round-trip reason recorded above; the assertion is refit-vs-preserved, and
	# the preserved value (the wheeled `chosen`) is nowhere near it.
	check(is_equal_approx(preview._distance, fitted),
		"and the next content REFITS rather than restoring the zoom chosen for a subject that is gone (got %s, chosen was %s)"
			% [preview._distance, chosen])

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


## A CSG subject authored AWAY from the origin: deferred-built bounds AND an offset to centre, which
## is the pair the deferred pass has to get right together.
func _offset_csg_scene() -> PackedScene:
	var root := CSGBox3D.new()
	root.name = "Offset"
	root.size = Vector3(1.0, 1.0, 1.0)
	root.position = Vector3(0.0, 2.0, 0.0)
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


## A second CSG subject at a DIFFERENT height, so "which of two same-frame swaps got framed" is
## answered by the pivot rather than inferred.
func _csg_scene_at(height: float) -> PackedScene:
	var root := CSGBox3D.new()
	root.name = "Second"
	root.size = Vector3(1.0, 1.0, 1.0)
	root.position = Vector3(0.0, height, 0.0)
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
