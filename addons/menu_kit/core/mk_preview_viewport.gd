@tool
class_name MKPreviewViewport
extends SubViewportContainer
## A self-contained 3D preview slot: a [SubViewport] with its own camera and neutral three-point
## lighting that displays any [PackedScene] a host hands it, with drag-to-spin, inertia, an idle
## turntable, and clamped zoom/pitch (plan §4.6, D13).
##
## [b]It assumes nothing about what it is shown.[/b] No rig, no skeleton, no scale convention, no
## genre. A [MeshInstance3D] cube frames and spins exactly as happily as an authored character, which
## is what makes the same node usable from the Appearance creation step, from character select, and
## from a host's weapon/armour viewer. Everything size-dependent is derived from the content's own
## bounds at swap time ([method frame_content]), never from a number a host had to know.
##
## [b]There is no [code].tscn[/code] for this class, deliberately.[/b] The camera, the pivot and the
## three lights are built in code with stable names ([code]ContentPivot[/code],
## [code]PreviewCamera[/code], [code]KeyLight[/code], [code]FillLight[/code], [code]RimLight[/code]),
## so a host adds a preview by adding one node with one script — not by instancing a scene it would
## then be tempted to fork the moment it wanted a different clear colour. The stable names are also
## the handle tests index by; renaming one is a public-surface change.
##
## [b]The [SubViewport] owns its own [World3D] by default[/b] ([member use_own_world], F10). Shared
## worlds leak in BOTH directions: this node's key/fill/rim lights would light the running game, and
## the game's [WorldEnvironment] and sun would light the preview — so the same preview looks different
## in a menu over a night map than over a day map, and the game visibly brightens while a character
## sheet is open. A host that genuinely wants the shared world (previewing an item in situ under the
## level's own lighting) opts out; it is an opt-out precisely because the leak is invisible until
## somebody notices the game got brighter.
##
## [b]This node deliberately sets no [member Node.process_mode].[/b] It inherits, and under an
## [MKRoot] page the §4.2a rule forces host content PAUSABLE — so a preview sitting inside a paused
## page stops spinning, which is exactly what the Phase 6 exit criteria require ("a host preview scene
## does not animate during pause"). Setting [code]PROCESS_MODE_ALWAYS[/code] here would look like a
## bug fix ("the preview freezes when I open the pause menu!") and would silently break that gate.
## If a host wants an always-spinning preview it sets the mode on ITS instance, where the decision is
## visible in that host's scene rather than baked into the addon.

## Emitted after the content instance has been swapped and re-framed — including on a swap to null,
## where it reports "the slot is now empty". Hosts drive dependent UI (a name label, a stat panel) off
## this rather than guessing at a frame boundary after calling [method set_preview_scene].
signal preview_changed()

## Stable child names. Public so a test can index them without re-spelling string literals that would
## then drift out of sync with the builder.
const PIVOT_NAME := "ContentPivot"
const CAMERA_NAME := "PreviewCamera"
const KEY_LIGHT_NAME := "KeyLight"
const FILL_LIGHT_NAME := "FillLight"
const RIM_LIGHT_NAME := "RimLight"

## Distance used when the content has no [VisualInstance3D] at all (a pure logic scene, or a rig whose
## meshes spawn later). Sized for a roughly human-scale subject so an empty-bounds scene that later
## grows meshes is at least pointed somewhere sensible instead of clipped inside the camera.
const _FALLBACK_DISTANCE := 3.0

## Fraction added to the fitted distance so the subject does not touch the viewport edges.
const _FRAME_MARGIN := 1.25

## Below this angular speed (rad/s) the released spin is treated as stopped and the idle turntable is
## allowed to take over. Small enough that the handover is invisible, large enough that exponential
## decay actually reaches it in finite time.
const _INERTIA_EPSILON := 0.02

## The [PackedScene] currently displayed. Assigning swaps the live content, so a host can drive the
## preview straight from a selection signal without a separate "apply" call. Null is legal and clears
## the slot.
@export var preview_scene: PackedScene: set = set_preview_scene

## When true the [SubViewport] renders into its own [World3D]. See the class doc (F10) for why this
## is the default and what sharing actually costs.
@export var use_own_world := true:
	set = _set_use_own_world

## Slow idle turntable. Suppressed while the user is dragging, and until any released inertia has
## decayed — see [method _process].
@export var auto_rotate := true

## Idle turntable speed in radians/second. 0.3 is a little under one revolution per 20 seconds:
## readable as motion, slow enough that a user reading a stat panel beside the preview is not chased
## by it.
@export var auto_rotate_speed := 0.3

## Closest the camera may be pulled to the pivot.
@export var zoom_min := 1.0

## Furthest the camera may be pushed from the pivot.
@export var zoom_max := 6.0

## Distance change per wheel notch.
@export var zoom_step := 0.5

## Lowest camera pitch. Negative looks UP at the subject from below; the default stops well short of
## straight-under, where most content shows its unfinished side.
@export var pitch_min_deg := -20.0

## Highest camera pitch, looking down at the subject.
@export var pitch_max_deg := 45.0

## Radians of rotation per pixel of drag, on both axes.
@export var drag_sensitivity := 0.01

## Exponential decay rate of released spin, in 1/s. Higher stops sooner. Exponential rather than
## linear so a hard flick and a gentle nudge both feel like the same material.
@export var inertia_damping := 4.0

var _viewport: SubViewport = null
var _pivot: Node3D = null
var _camera: Camera3D = null
var _content: Node3D = null
var _dragging := false
var _yaw := 0.0
var _pitch_deg := 15.0
var _distance := _FALLBACK_DISTANCE
var _spin_velocity := 0.0
var _built := false


func _ready() -> void:
	# Build in the editor too, unlike the shipped pages' @tool guard: the entire point of this node is
	# that a host designing a character-select screen SEES the preview while laying it out. The guard
	# those pages need is against unowned children being serialised into the instancing scene, and it
	# does not apply here — every child below is created with owner left null, so Godot excludes it
	# from the saved scene exactly as it excludes any runtime child. _built guards the other hazard:
	# in the editor _ready can run again after a script reload, and a second build would stack a
	# duplicate camera and a second set of lights (visibly doubling the exposure).
	_build()
	# stretch alone is the whole resolution story: a SubViewportContainer with stretch enabled OWNS its
	# SubViewport's size and drives it to the container's pixel rect every layout pass — the engine
	# actively refuses a manual size write in that configuration (a WARNING per attempt, measured by
	# the Phase 5 test leg). So there is deliberately no resized hook and no size sync here; writing
	# one back would be inert noise pretending to be load-bearing.
	stretch = true
	visibility_changed.connect(_sync_render_mode)
	_sync_render_mode()
	if preview_scene != null:
		# The export may have been deserialised before the children existed. Apply it now.
		set_preview_scene(preview_scene)


## Displays [param scene], freeing whatever was there first. Null CLEARS the slot and is a legal,
## expected call — "no selection" is a real state in every host this serves, and making it an error
## would force each of them to invent an empty placeholder scene.
##
## The camera is re-framed from the new content's bounds; the current yaw/pitch/zoom are NOT reset, so
## a user comparing two characters keeps the angle they chose while cycling through a list.
func set_preview_scene(scene: PackedScene) -> void:
	# Writing the backing property from inside its own setter does NOT re-enter it — GDScript's
	# setter/getter dispatch is suppressed for self-assignment within the accessor. So the guard flag
	# this method used to carry was inert, and the "emits exactly once, not twice through its own
	# setter" assertion in test_preview_viewport.gd is what holds the line if that ever changes.
	preview_scene = scene
	_build()
	if _content != null and is_instance_valid(_content):
		# Detach before free so a same-frame get_content() cannot hand back a queued-for-deletion node.
		_pivot.remove_child(_content)
		_content.queue_free()
	_content = null
	if scene != null:
		var inst := scene.instantiate()
		var node_3d := inst as Node3D
		if node_3d == null:
			# A non-Node3D cannot be parented under the pivot and would never be visible. Name the
			# scene and the type rather than silently showing nothing.
			MKLog.warn("%s: preview_scene %s instantiates a %s, not a Node3D — nothing to preview"
				% [name, MKLog.context(scene), inst.get_class()])
			inst.queue_free()
		else:
			_content = node_3d
			_pivot.add_child(_content)
	frame_content()
	preview_changed.emit()


## The live content instance, or null when the slot is empty. Always checked for validity, so a caller
## that cached it across a swap gets null rather than a freed object.
func get_content() -> Node3D:
	if _content == null or not is_instance_valid(_content):
		return null
	return _content


## Re-derives the camera distance from the content's merged bounds. Called automatically on every
## swap; exposed because content can change size AFTER it is instanced (an equipped weapon appears, a
## rig's meshes stream in) and only the host knows when that happened.
##
## The math: merge every [VisualInstance3D] descendant's global AABB into one box, take the pivot-space
## radius of that box (half its diagonal — orientation-independent, so spinning never clips), and place
## the camera at [code]radius / tan(fov/2)[/code], the exact distance at which a sphere of that radius
## fills the vertical frame, times [constant _FRAME_MARGIN] for breathing room. The pivot is lifted to
## the box centre so the subject spins about ITS middle rather than about the scene origin — content
## authored with its feet at y=0 otherwise orbits around its ankles.
func frame_content() -> void:
	_build()
	var content := get_content()
	if content == null:
		_pivot.position = Vector3.ZERO
		_distance = clampf(_FALLBACK_DISTANCE, zoom_min, zoom_max)
		_apply_transforms()
		return
	var bounds := _merge_bounds(content)
	if bounds.size == Vector3.ZERO:
		# Not a crash and not a warning: a scene with no visual instances yet is a legitimate state
		# (streamed meshes, a logic-only probe scene). Debug so --mk-verbose explains a preview that
		# looks empty, without spamming a host that does this on purpose.
		MKLog.debug("%s: preview content '%s' has no VisualInstance3D bounds; using fallback distance"
			% [name, content.name])
		_pivot.position = Vector3.ZERO
		_distance = clampf(_FALLBACK_DISTANCE, zoom_min, zoom_max)
		_apply_transforms()
		return
	# The pivot's children carry the content in pivot-local space; offsetting the pivot by -centre
	# would move the content, so instead the pivot node itself sits at the centre and the content is
	# shifted back under it by the same amount.
	var centre := bounds.position + bounds.size * 0.5
	_pivot.position = centre
	content.position -= centre
	var radius := maxf(bounds.size.length() * 0.5, 0.001)
	var half_fov := deg_to_rad(_camera.fov) * 0.5
	var fitted := radius / maxf(tan(half_fov), 0.001) * _FRAME_MARGIN
	_distance = clampf(fitted, zoom_min, zoom_max)
	# Near/far are derived rather than left at defaults: a 3cm gemstone previewed at 0.1 units would
	# sit inside a 0.05 default near plane on some fov/zoom_min combinations and vanish.
	_camera.near = maxf(radius * 0.01, 0.01)
	_camera.far = maxf(zoom_max + radius * 4.0, 100.0)
	_apply_transforms()


func _process(delta: float) -> void:
	if not _built:
		return
	var spinning := absf(_spin_velocity) > _INERTIA_EPSILON
	if _dragging:
		# A held drag owns the rotation outright; neither inertia nor the turntable competes with it.
		return
	if spinning:
		_yaw += _spin_velocity * delta
		# Exponential decay: v *= e^(-k*dt). Frame-rate independent, unlike a per-frame multiply.
		_spin_velocity *= exp(-inertia_damping * delta)
		if absf(_spin_velocity) <= _INERTIA_EPSILON:
			_spin_velocity = 0.0
		_apply_transforms()
		return
	if auto_rotate:
		_yaw += auto_rotate_speed * delta
		_apply_transforms()


## Input arrives through _gui_input, NOT _input. This is an ordinary Control that only ever wants
## events landing on its own rect, and _gui_input already delivers exactly those, respects
## mouse_filter, and lets a modal above it take priority for free. (The rebind row's _input usage is a
## documented exception for capturing a key press anywhere on screen — do not generalise from it.)
##
## Every event this node acts on is consumed with accept_event(): a preview inside a scrolling
## character sheet must not let a zoom gesture ALSO scroll the page under it, and a spin drag must not
## also drag-select the list behind. Events it does not act on are left alone, so a right-click still
## reaches a host context menu.
func _gui_input(event: InputEvent) -> void:
	if not _built:
		return
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
			if button.pressed:
				# Grabbing kills the residual spin: the model must stop under the finger, not keep
				# drifting while held.
				_spin_velocity = 0.0
			accept_event()
			return
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(-zoom_step)
			accept_event()
			return
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(zoom_step)
			accept_event()
			return
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		_yaw += motion.relative.x * drag_sensitivity
		_pitch_deg = clampf(_pitch_deg + rad_to_deg(motion.relative.y * drag_sensitivity),
			minf(pitch_min_deg, pitch_max_deg), maxf(pitch_min_deg, pitch_max_deg))
		# The last motion's velocity IS the throw. Converting px/s to rad/s here keeps the released
		# spin at the speed the hand was moving, which is what makes the flick feel physical.
		_spin_velocity = motion.velocity.x * drag_sensitivity
		_apply_transforms()
		accept_event()


func _zoom_by(amount: float) -> void:
	_distance = clampf(_distance + amount, minf(zoom_min, zoom_max), maxf(zoom_min, zoom_max))
	_apply_transforms()


## Yaw spins the PIVOT (the content turns in place); pitch and distance move the CAMERA in an orbit
## around it. Splitting them this way is what keeps the lighting fixed relative to the viewer while
## the subject rotates — spinning the camera instead would drag the key light around with it and the
## subject would appear evenly lit from every angle, which is the look this rig exists to avoid.
func _apply_transforms() -> void:
	if not _built:
		return
	_pivot.rotation = Vector3(0.0, _yaw, 0.0)
	var pitch := deg_to_rad(_pitch_deg)
	var offset := Vector3(0.0, sin(pitch), cos(pitch)) * _distance
	_camera.position = _pivot.position + offset
	_camera.look_at(_pivot.position, Vector3.UP)


## A SubViewport with UPDATE_ALWAYS renders every frame whether or not anyone can see it — a full 3D
## pass paid by a character sheet nobody has open. Gating on visibility costs one signal and makes a
## hidden preview genuinely free; UPDATE_ONCE is not usable here because the content animates.
func _sync_render_mode() -> void:
	if _viewport == null:
		return
	_viewport.render_target_update_mode = (SubViewport.UPDATE_ALWAYS if is_visible_in_tree()
		else SubViewport.UPDATE_DISABLED)


func _set_use_own_world(value: bool) -> void:
	use_own_world = value
	if _viewport == null:
		return
	# Flipping own_world_3d on a SubViewport whose 3D instances are already registered with a World3D
	# nulls their scenario mid-flight — the renderer errors ("Parameter \"scenario\" is null", measured
	# by the Phase 5 test leg) because the instances are torn between worlds while live. Detaching the
	# viewport first unregisters everything cleanly, the flip then happens on an offline viewport, and
	# re-adding re-registers the whole subtree with whichever world now applies. One frame of the
	# preview texture is skipped; nothing else observes the bounce.
	var parent := _viewport.get_parent()
	if parent != null and _viewport.is_inside_tree():
		parent.remove_child(_viewport)
		_viewport.own_world_3d = value
		parent.add_child(_viewport)
	else:
		_viewport.own_world_3d = value


## Merges the global AABBs of every [VisualInstance3D] under [param root], INCLUDING root itself, into
## one box expressed in the pivot's space. Returns a zero-size AABB when there are none.
func _merge_bounds(root: Node3D) -> AABB:
	var merged := AABB()
	var has_any := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		var vis := node as VisualInstance3D
		if vis == null:
			continue
		# get_aabb() is local to the instance; transform it into pivot space so meshes offset by
		# nested nodes are measured where they actually are.
		var local := _pivot.global_transform.affine_inverse() * vis.global_transform
		var box := local * vis.get_aabb()
		if has_any:
			merged = merged.merge(box)
		else:
			merged = box
			has_any = true
	return merged if has_any else AABB()


func _build() -> void:
	if _built:
		return
	_built = true

	_viewport = SubViewport.new()
	_viewport.name = "PreviewSubViewport"
	_viewport.own_world_3d = use_own_world
	# Transparent, so the preview composites over whatever the host put behind it (an MKBackdrop, a
	# panel) instead of punching an opaque rectangle through the menu.
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_pivot = Node3D.new()
	_pivot.name = PIVOT_NAME
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_camera.name = CAMERA_NAME
	_camera.fov = 45.0
	_camera.current = true
	_viewport.add_child(_camera)

	# Neutral three-point rig: pure white at every lamp, no colour grading, no environment tint. A
	# preview's job is to show the host's material as authored — a warm key would make every piece of
	# armour look like it had a gold tint the artist never put there. Hosts that want mood attach
	# their own WorldEnvironment to the content scene.
	_add_light(KEY_LIGHT_NAME, Vector3(-35.0, -40.0, 0.0), 1.6)
	_add_light(FILL_LIGHT_NAME, Vector3(-15.0, 55.0, 0.0), 0.6)
	_add_light(RIM_LIGHT_NAME, Vector3(-10.0, 170.0, 0.0), 1.0)

	_apply_transforms()


func _add_light(light_name: String, rotation_deg: Vector3, energy: float) -> void:
	var light := DirectionalLight3D.new()
	light.name = light_name
	light.rotation_degrees = rotation_deg
	light.light_energy = energy
	light.light_color = Color(1, 1, 1, 1)
	# Shadows off across the rig: at preview scale they cost a full shadow pass to produce acne on a
	# subject that has no ground plane to receive them anyway.
	light.shadow_enabled = false
	_viewport.add_child(light)
