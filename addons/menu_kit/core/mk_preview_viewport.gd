@tool
class_name MKPreviewViewport
extends SubViewportContainer
## A self-contained 3D preview slot: a [SubViewport] with its own camera and neutral three-point
## lighting that displays any [PackedScene] a host hands it, with drag-to-spin, inertia, an idle
## turntable, and clamped zoom/pitch.
##
## [b]It assumes nothing about what it is shown.[/b] No rig, no skeleton, no scale convention, no
## genre. A [MeshInstance3D] cube frames and spins exactly as happily as an authored character, which
## is what makes the same node usable from the Appearance creation step, from character select, and
## from a host's weapon/armour viewer. Everything size-dependent is derived from the content's own
## bounds when it is shown ([method set_preview_scene]) and on demand ([method frame_content], the one
## call that refits the camera DISTANCE unconditionally), never from a number a host had to know.
##
## [b]There is no [code].tscn[/code] for this class, deliberately.[/b] The camera, the pivot and the
## three lights are built in code with stable names ([code]ContentPivot[/code],
## [code]PreviewCamera[/code], [code]KeyLight[/code], [code]FillLight[/code], [code]RimLight[/code]),
## so a host adds a preview by adding one node with one script — not by instancing a scene it would
## then be tempted to fork the moment it wanted a different clear colour. The stable names are also
## the handle tests index by; renaming one is a public-surface change.
##
## [b]The [SubViewport] owns its own [World3D] by default[/b] ([member use_own_world]). Shared worlds
## leak in BOTH directions: this node's key/fill/rim lights would light the running game, and the
## game's [WorldEnvironment] and sun would light the preview — so the same preview looks different in
## a menu over a night map than over a day map, and the game visibly brightens while a character
## sheet is open. A host that genuinely wants the shared world (previewing an item in situ under the
## level's own lighting) opts out; it is an opt-out precisely because the leak is invisible until
## somebody notices the game got brighter.
##
## [b]This node deliberately sets no [member Node.process_mode].[/b] It inherits, and under an
## [MKRoot] page host content is PAUSABLE — so a preview inside a paused page stops spinning, which
## is the required behaviour, not a bug. Setting [code]PROCESS_MODE_ALWAYS[/code] here would look
## like a fix ("the preview freezes when I open the pause menu!") and would silently break it. A host
## that wants an always-spinning preview sets the mode on ITS instance, where the decision is visible
## in that host's scene rather than baked into the addon.

## Emitted after the content instance has been swapped and re-framed — including on a swap to null,
## where it reports "the slot is now empty". Hosts drive dependent UI (a name label, a stat panel) off
## this rather than guessing at a frame boundary after calling [method set_preview_scene].
signal preview_changed()

## Stable child names. Public so callers can index children without re-spelling string literals that
## would drift out of sync with the builder.
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

## When true the [SubViewport] renders into its own [World3D]. See the class doc for why this is the
## default and what sharing actually costs.
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
## True once a piece of content with real bounds has had the camera distance FITTED to it. Subsequent
## swaps re-centre and re-derive near/far but keep the distance the user is at — see
## [method set_preview_scene]. Reset when the slot is cleared — in the CLEAR path of
## set_preview_scene itself, deliberately outside any tree check, so a detached clear resets it too —
## so refilling it fits again.
var _fitted_once := false
## Bumped by every [method set_preview_scene], and captured by each deferred framing pass so a pass
## queued for content that has since been replaced can recognise itself as stale — see
## [method _queue_reframe].
var _content_gen := 0
## True once [method _ready] has run. Node._ready runs ONCE per node lifetime, so it cannot be the
## re-framing hook for a node that leaves the tree and comes back (a pooled preview, a reparented
## panel) — that is [method _notification]'s job, and this flag is how it tells a RE-entry from the
## first one, where _ready's own pass is the one that frames. NOTIFICATION_ENTER_TREE arrives BEFORE
## _ready on the first entry, which is what makes the single flag sufficient.
var _readied := false


func _ready() -> void:
	# Build in the editor too, unlike the shipped pages' @tool guard: the point of this node is that a
	# host designing a character-select screen SEES the preview while laying it out. Every child below
	# is created with owner left null, so Godot excludes it from the saved scene as it does any runtime
	# child. _built guards the other hazard: a second _build within one instance's life would stack a
	# duplicate camera and a second set of lights (visibly doubling the exposure).
	# Caveat: _built is ordinary script state, so an editor script RELOAD re-runs _ready on a
	# re-created instance and the children ARE rebuilt on top of the previous set. What _built covers
	# is a second _ready/_build on the SAME instance.
	_build()
	# stretch alone is the whole resolution story: a SubViewportContainer with stretch enabled OWNS its
	# SubViewport's size and drives it to the container's pixel rect every layout pass — the engine
	# actively refuses a manual size write in that configuration (a WARNING per attempt). So there is
	# deliberately no resized hook and no size sync here.
	stretch = true
	visibility_changed.connect(_sync_render_mode)
	_sync_render_mode()
	# Entering the tree is the first moment the camera may be pointed at anything: _apply_transforms is
	# a no-op off-tree (look_at is refused there), so a node built and configured before it was added has
	# not had one applied yet.
	_apply_transforms()
	if get_content() != null:
		# The export was deserialised — or assigned by a host — before this node was in the tree, where
		# the framing pass cannot measure or point anything. The INSTANCE is already there (the setter
		# builds and parents it off-tree quite happily); only the framing was skipped, so only the framing
		# is redone. Re-applying the whole export would free and re-instantiate identical content and emit
		# a second preview_changed, which a host connected before add_child sees as two swaps.
		_queue_reframe(_content_gen, true)
	elif preview_scene != null:
		# A scene that produced no content (a non-Node3D root, reported at assignment) or a setter that
		# never ran: re-apply, which is also the path that reports it once, in the tree.
		set_preview_scene(preview_scene)
	_readied = true


## [b]Every tree entry after the first re-frames, not just the first one.[/b] [method Node._ready]
## runs ONCE per node lifetime, so it cannot cover a preview that LEAVES the tree and comes back — a
## pooled slot, a panel reparented into a different container. Off-tree the framing is skipped
## entirely (see [method _frame]), so a swap performed while detached leaves the pivot at the origin
## with the new content unshifted; without this hook the node comes back displaying content centred
## on nothing, at the previous subject's distance. The pass is generation-tagged like every other, so
## an entry followed by an immediate swap does not measure the outgoing content.
##
## The first entry is deliberately skipped: NOTIFICATION_ENTER_TREE arrives BEFORE [method _ready],
## and _ready runs the entry pass itself. Letting both fire is a double pass on the first entry.
func _notification(what: int) -> void:
	if what != NOTIFICATION_ENTER_TREE or not _readied:
		return
	if get_content() == null:
		return
	# Queued, not immediate: this notification arrives before the CONTENT's own tree entry (children
	# are notified after their parent), so an immediate measurement would read global transforms of a
	# subtree that is not registered yet. One deferred hop is enough. Silent about zero bounds: a
	# re-entry is not the moment to accuse content of having none.
	_queue_reframe(_content_gen, false)


## Displays [param scene], freeing whatever was there first. Null CLEARS the slot and is a legal,
## expected call — "no selection" is a real state in every host this serves, and making it an error
## would force each of them to invent an empty placeholder scene.
##
## The camera is re-CENTRED on the new content's bounds; yaw, pitch and zoom are NOT reset, so a user
## comparing two characters keeps the angle AND the zoom they chose while cycling through a list. The
## FIRST content this slot is given fits the distance to its bounds (there is no user choice to
## preserve yet); every swap after that keeps the current distance, clamped, and only re-centres the
## pivot and re-derives near/far. A host that genuinely wants a refit on a swap — content whose scale
## differs by an order of magnitude, not two characters in a list — calls [method frame_content]
## afterwards, which is that method's documented job.
##
## [b]The framing runs TWICE: immediately, and again deferred.[/b] CSG meshes (and anything else that
## builds its geometry on a deferred call, which is most procedural content) report a ZERO
## [method VisualInstance3D.get_aabb] on the frame they are added, so a single immediate pass
## measures nothing and takes the no-bounds fallback. The immediate pass is kept because content that
## IS built (an imported mesh) frames on the same frame it appears with no visible pop; the deferred
## pass catches everything else.
func set_preview_scene(scene: PackedScene) -> void:
	# Writing the backing property from inside its own setter does NOT re-enter it — GDScript
	# suppresses setter dispatch for self-assignment within the accessor, so no re-entry guard is
	# needed here.
	preview_scene = scene
	# Every swap is a new generation, so any deferred pass still queued for the OUTGOING content
	# recognises itself as stale and returns without measuring. See _queue_reframe.
	_content_gen += 1
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
	# The pivot is zeroed HERE, on the swap, and nowhere inside the framing. Framing accumulates (see
	# _frame) so that re-framing the SAME content is idempotent, and accumulation is only meaningful
	# against content that has already been shifted by it — a fresh instance has not, so its centring
	# must start from zero or the previous subject's centre is added to it.
	#
	# It is also OUTSIDE the tree check below on purpose: a swap performed off-tree frames nothing, so
	# this reset is the only thing that stops the previous subject's centre surviving into the re-entry
	# pass that does the centring (see _notification).
	_pivot.position = Vector3.ZERO
	if _content == null:
		# The cleared-slot STATE is written here, not in _frame's null branch: that branch sits behind
		# the is_inside_tree guard, so a clear performed while DETACHED would keep the previous subject's
		# _fitted_once and distance forever and the next content would re-enter at the old zoom instead
		# of a fresh fit. "Reset when the slot is cleared" is a statement about the SLOT, and the slot
		# does not care whether the node is in a tree.
		_fitted_once = false
		_distance = _clamp_zoom(_FALLBACK_DISTANCE)
	# Immediate pass: silent about zero bounds, because for deferred-built content zero IS the expected
	# reading on this frame and a debug line here would fire for every CSG preview ever shown.
	_frame(false)
	_queue_reframe(_content_gen, true)
	preview_changed.emit()


## Queues the second framing pass. Deferred rather than a timer or a frame counter: call_deferred runs
## at the end of the current frame, after the deferred mesh builds this exists to wait for, and before
## anything renders — so the re-frame is invisible rather than a one-frame jump.
##
## [b]Every call queues a pass; staleness is decided by GENERATION, not by de-duplication.[/b] A
## boolean "one queued at a time" flag looks like the same saving and is not, because Godot's
## deferred queue is FIFO and a swap's CSG build enqueues its own deferred work when the content is
## ADDED — i.e. AFTER a pass queued by an earlier swap in the same frame. With such a flag, two swaps
## in one frame run the pending pass BEFORE the second content's mesh exists, read zero bounds,
## consume the flag, and nothing re-queues — pivot at the origin and the fallback distance,
## permanently. Queuing per swap puts the live content's pass after its own build in the same FIFO
## order, and the generation check keeps the earlier, now-meaningless passes from measuring the new
## content before it is built.
func _queue_reframe(gen: int, report_no_bounds: bool, fit_distance := false) -> void:
	call_deferred("_deferred_reframe", gen, report_no_bounds, fit_distance)


func _deferred_reframe(gen: int, report_no_bounds: bool, fit_distance: bool) -> void:
	# Stale: the content this pass was queued for has already been replaced (or cleared). The swap that
	# replaced it queued its own pass, so returning here loses nothing.
	if gen != _content_gen:
		return
	# The node may also have been freed or removed from the tree between the queue and the call.
	# Off-tree the global transforms _merge_bounds reads are meaningless, so there is nothing to measure
	# and the next tree entry re-frames — which is a real hook (see _notification), not a hope: _ready
	# covers the FIRST entry and NOTIFICATION_ENTER_TREE every one after it. _frame itself tolerates
	# content that was freed or cleared.
	if not is_inside_tree() or not _built:
		return
	_frame(report_no_bounds, fit_distance)


## The live content instance, or null when the slot is empty. Always checked for validity, so a caller
## that cached it across a swap gets null rather than a freed object.
func get_content() -> Node3D:
	if _content == null or not is_instance_valid(_content):
		return null
	return _content


## Re-derives the camera distance from the content's merged bounds, ALWAYS — this is the one call that
## refits distance unconditionally, which is why a swap (see [method set_preview_scene]) does not use
## it that way. Called automatically on every swap for its centring half; exposed because content can
## change size AFTER it is instanced (an equipped weapon appears, a rig's meshes stream in) and only
## the host knows when that happened.
##
## The math: merge every [VisualInstance3D] descendant's global AABB into one box, take the pivot-space
## radius of that box (half its diagonal — orientation-independent, so spinning never clips), and place
## the camera at [code]radius / tan(fov/2)[/code], the exact distance at which a sphere of that radius
## fills the vertical frame, times [constant _FRAME_MARGIN] for breathing room. The pivot is lifted to
## the box centre so the subject spins about ITS middle rather than about the scene origin — content
## authored with its feet at y=0 otherwise orbits around its ankles.
##
## [b]It refits immediately and again, deferred — and the immediate half is SILENT.[/b] A host that
## calls this in the same frame as a swap (an ordinary "show this and refit it" pair) is asking about
## content whose mesh may not be built yet, so the immediate reading of zero is the expected state
## rather than news. The queued pass is the definitive answer and is the one that speaks.
func frame_content() -> void:
	_frame(false, true)
	_queue_reframe(_content_gen, true, true)


## The framing body. [param report_no_bounds] is false for the immediate half of a swap, where a zero
## reading is the EXPECTED state for deferred-built content rather than news. [param fit_distance]
## false keeps the current zoom and re-centres only.
##
## [b]Off-tree it does nothing at all.[/b] Every measurement here is a GLOBAL transform read and every
## write ends in [method _apply_transforms]'s look_at — both of which the engine refuses outside the
## tree, with an ERROR per attempt rather than a return value anything could branch on. A host that
## assigns [member preview_scene] on a node it has not added yet (the authored-export route, and what
## [method PackedScene.instantiate] does for a scene carrying the export) is doing something ordinary,
## so it must not print four engine errors; the node's tree ENTRY is where the framing this skipped
## actually happens — [method _ready] for the first entry, [method _notification]'s
## NOTIFICATION_ENTER_TREE for every one after it, so a swap performed while detached (a pooled or
## reparented preview) is framed on the way back in rather than never.
func _frame(report_no_bounds: bool, fit_distance := false) -> void:
	_build()
	if not is_inside_tree():
		return
	var content := get_content()
	if content == null:
		_pivot.position = Vector3.ZERO
		_distance = _clamp_zoom(_FALLBACK_DISTANCE)
		# An empty slot has no subject to have chosen a zoom for, so the next content fits from scratch.
		_fitted_once = false
		_apply_transforms()
		return
	var bounds := _merge_bounds(content)
	if bounds.size == Vector3.ZERO:
		if report_no_bounds:
			# Not a crash and not a warning: a scene with no visual instances yet is a legitimate state
			# (streamed meshes, a logic-only probe scene). Debug so --mk-verbose explains a preview that
			# looks empty, without spamming a host that does this on purpose. Reported only from the
			# DEFERRED pass, by which point a CSG or otherwise procedurally built mesh has been built and
			# a zero reading really does mean "there is nothing here".
			MKLog.debug("%s: preview content '%s' has no VisualInstance3D bounds; using fallback distance"
				% [name, content.name])
		if not _fitted_once:
			_distance = _clamp_zoom(_FALLBACK_DISTANCE)
		# The pivot is deliberately NOT reset here: it may already carry a centre from an earlier pass
		# over content that HAD bounds, and zeroing it would throw that centring away (with the content's
		# matching -centre shift left in place) the moment the bounds momentarily read empty.
		_apply_transforms()
		return
	# The pivot's children carry the content in pivot-local space; offsetting the pivot by -centre
	# would move the content, so instead the pivot node itself moves to the centre and the content is
	# shifted back under it by the same amount.
	#
	# [b]Both writes are RELATIVE, and that is what makes this idempotent.[/b] _merge_bounds reports in
	# pivot space, so a second call over unchanged content measures a centre of ~zero and both lines
	# no-op. An absolute `_pivot.position = centre` paired with the relative content shift would instead
	# measure zero and WRITE zero, throwing the first call's centring away — and re-framing is the
	# advertised gesture for content that grew, so it is called more than once by design.
	var centre := bounds.position + bounds.size * 0.5
	_pivot.position += centre
	content.position -= centre
	var radius := maxf(bounds.size.length() * 0.5, 0.001)
	if fit_distance or not _fitted_once:
		var half_fov := deg_to_rad(_camera.fov) * 0.5
		var fitted := radius / maxf(tan(half_fov), 0.001) * _FRAME_MARGIN
		_distance = _clamp_zoom(fitted)
	else:
		# A swap keeps the user's zoom, but the new subject's bounds may have moved the legal range's
		# meaning; clamping keeps it inside the exports either way.
		_distance = _clamp_zoom(_distance)
	_fitted_once = true
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


## Input arrives through _gui_input, NOT _input. This is an ordinary Control that only wants events
## landing on its own rect, and _gui_input delivers exactly those, respects mouse_filter, and lets a
## modal above it take priority for free. ([code]MKRebindRow[/code]'s _input usage is a documented
## exception for capturing a key press anywhere on screen — do not generalise from it.)
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
	_distance = _clamp_zoom(_distance + amount)
	_apply_transforms()


## The ONE place [member zoom_min] and [member zoom_max] become a range. Every distance write in this
## class goes through it — the wheel, the fit, the swap re-clamp and both fallback-distance parks.
##
## [b]It orders the pair rather than trusting it.[/b] The two are independent exports and nothing
## stops a host (or an editor drag) from leaving zoom_min above zoom_max. A plain
## [code]clampf(value, zoom_min, zoom_max)[/code] on an inverted pair collapses every input onto one
## of the two ends — clampf raises to its minimum FIRST, then lowers to its maximum, so an inverted
## pair answers zoom_min for inputs below zoom_min and zoom_max for everything at or above it
## (clampf(3, 5, 1) is 5; clampf(8, 5, 1) is 1). Ordering here makes an inverted pair merely a range
## spelled backwards, and makes every distance write agree by construction.
func _clamp_zoom(value: float) -> float:
	return clampf(value, minf(zoom_min, zoom_max), maxf(zoom_min, zoom_max))


## Yaw spins the PIVOT (the content turns in place); pitch and distance move the CAMERA in an orbit
## around it. Splitting them this way is what keeps the lighting fixed relative to the viewer while
## the subject rotates — spinning the camera instead would drag the key light around with it and the
## subject would appear evenly lit from every angle, which is the look this rig exists to avoid.
func _apply_transforms() -> void:
	if not _built:
		return
	# look_at is one of the calls the engine refuses outside the tree ("Node not inside tree. Use
	# look_at_from_position() instead."), and _build ends here — so an off-tree construction would print
	# it before the node has ever been shown. The transforms are re-applied on the next frame this node
	# runs in-tree, so skipping costs nothing. See _frame.
	if not is_inside_tree():
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
	# nulls their scenario mid-flight — the renderer errors ("Parameter \"scenario\" is null") because
	# the instances are torn between worlds while live. Detaching the viewport first unregisters
	# everything cleanly, the flip then happens on an offline viewport, and re-adding re-registers the
	# whole subtree with whichever world now applies. One frame of the preview texture is skipped.
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
