@tool
class_name MKBrightnessController
extends CanvasLayer
## The working brightness implementation behind the Video page's brightness row (plan §4.3).
##
## Godot 4.7 has no global or OS gamma control, so "the backend applies brightness" is not a thing
## that can be written. Demoting the row to a plain host-consumed value (the way FOV is) was
## rejected for a reason worth restating: FOV needs host-owned state — a camera MenuKit does not
## have — whereas brightness has a complete engine-level implementation that needs to know nothing
## about the host's game. A dead slider in a Doom-like is a week-1 support question.
##
## [b]Who owns this node.[/b] [code]MKSettingsService[/code] — the autoload — not [MKRoot]. §4.2's
## whole premise is that a host may boot straight into gameplay without ever instancing a MenuKit
## scene; a controller owned by a per-scene root would not exist on that path, so the user would
## calibrate in the menu, start the game, and watch it snap back. [MKRoot] creates one only in the
## standalone no-service configuration, and that tier is honestly weaker: it dies with its per-scene
## root, so brightness gaps across scene transitions and reaches gameplay only if the game scene
## also hosts an [MKRoot]. The autoload is the supported configuration.
##
## [b]This node is not the floor.[/b] The row writes a plain value through the settings backend
## either way, so a host that sets [code]MKConfig.manage_brightness = false[/code] and consumes the
## value itself loses nothing. This adds a working default on top of that floor.
##
## [b]A CanvasLayer severs Control theme propagation[/b] (build handoff §4) — which is exactly why
## the modal layer is not one. It is harmless here: this layer hosts a single unstyled [ColorRect]
## with a [ShaderMaterial] and no themed control ever lives under it. Do not add one.

## Which mechanism applies the brightness value.
enum Mode {
	## Default. A full-rect [ColorRect] on a very high [CanvasLayer] re-encodes the finished frame
	## through [code]mk_gamma.gdshader[/code]. Renderer-independent, and it affects the UI too —
	## which matches the "adjust until the logo is barely visible" calibration convention every
	## shooter uses.
	OVERLAY,
	## Alternative: drives [member Environment.adjustment_enabled] and
	## [member Environment.adjustment_brightness]. Honest caveats, all inherent to the approach
	## rather than to this implementation:
	## [br]- It drives the [b]active[/b] [Environment]. MenuKit never owns one, so either the host
	##   names its [WorldEnvironment] through [member world_environment_path] or this walks the
	##   current viewport's [World3D] — and finds nothing in a 2D or menu-only scene.
	## [br]- It is a post-process that crushes rather than lifts true blacks at extremes, so the
	##   dark end of the slider behaves differently from [constant Mode.OVERLAY].
	## [br]- Adjustment support varies by renderer.
	## [br]- It does not affect the UI, so the calibration convention above does not apply.
	## The value is applied directly as [member Environment.adjustment_brightness] (a multiplier,
	## neutral at 1.0) rather than as a gamma exponent, so a given slider position does not look
	## identical in the two modes. Both are neutral at 1.0, which is the part that must match.
	ENVIRONMENT,
}

## The setting id this controller is driven from, and the single source of truth for its spelling.
## The Video page def's brightness row, [code]MKSettingsService[/code] and [code]MKRoot[/code]'s
## standalone tier all read it from here rather than each writing the string out.
const SETTING_ID := &"video/brightness"

## Sane range for the brightness value. Neutral is 1.0 in both modes. The bounds are not taste:
## below ~0.4 the image is unrecoverable and above ~2.5 it is fully blown out, and a slider that can
## render a game unplayable has no in-game route back to a readable menu.
const MIN_BRIGHTNESS := 0.4
const MAX_BRIGHTNESS := 2.5

## Value at which the overlay is switched off entirely (see [method set_brightness]). Not exactly
## 1.0: a float that arrives from a JSON round trip or a slider step is rarely bit-exact, and paying
## for a fullscreen texture read to compute pow(c, 1.0/1.0000001) is pure waste.
const NEUTRAL_EPSILON := 0.002

## Above every menu MenuKit draws, and above a host HUD on a default layer. Brightness calibration
## that does not include the UI is not calibration (see [constant Mode.OVERLAY]).
const OVERLAY_LAYER := 100

const _SHADER_PATH := "res://addons/menu_kit/shaders/mk_gamma.gdshader"
const _GAMMA_PARAM := &"gamma"

## Applied on the next [method set_brightness]; changing it at runtime is supported and tears the
## other mode's effect down first.
@export var mode: Mode = Mode.OVERLAY:
	set(value):
		if mode == value:
			return
		_release_current_mode()
		mode = value
		set_brightness(_brightness)

## [constant Mode.ENVIRONMENT] only. Points at a [WorldEnvironment] in the host's scene. Left empty,
## the controller walks the current viewport's [World3D] instead — which is fine for a 3D game and
## finds nothing in a menu-only scene.
@export var world_environment_path: NodePath

var _brightness := 1.0
var _overlay: ColorRect
var _material: ShaderMaterial
## True once this node enabled adjustment on an Environment, so teardown undoes only what it did —
## clearing a flag the host set itself would be a silent visual regression in the host's game.
var _adjustment_owned := false
var _adjusted_env: Environment
## One warning per node, not one per slider frame. A dragged slider emits dozens of writes a second
## and an unresolvable Environment would turn the log into a wall.
var _env_warned := false


func _init() -> void:
	layer = OVERLAY_LAYER
	# The pause menu runs under `get_tree().paused = true` and the brightness row is live-apply, so a
	# PAUSABLE controller would ignore the slider in exactly the screen where a player calibrates
	# (plan §4.2a). This node hangs off the settings-service autoload, outside the MKRoot subtree, so
	# it inherits nothing and must set this itself.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Applies [param value] as the brightness. 1.0 is neutral in both modes; out-of-range values are
## clamped rather than refused, because the caller is usually a stored setting from an older build
## or a host's own slider and dropping the write silently would be worse than clamping it.
##
## In [constant Mode.OVERLAY] a neutral value [b]hides the overlay entirely[/b] instead of drawing a
## no-op pass. Every player who never touches the slider is on that path, so leaving a fullscreen
## screen-texture read running for them would make the default configuration the expensive one.
func set_brightness(value: float) -> void:
	if not is_finite(value):
		MKLog.warn("MKBrightnessController.set_brightness: ignoring non-finite value '%s'" % value)
		return
	_brightness = clampf(value, MIN_BRIGHTNESS, MAX_BRIGHTNESS)
	# @tool guard: the value is remembered, nothing is applied. Building the overlay in the editor
	# would materialise an unowned child into whatever scene is open, and resolving an Environment
	# from an inspector edit (the `mode` setter runs there) would warn about a viewport that does not
	# exist yet.
	if Engine.is_editor_hint():
		return
	match mode:
		Mode.OVERLAY:
			_apply_overlay()
		Mode.ENVIRONMENT:
			_apply_environment()


## The clamped value currently applied. Read by diagnostics and by tests; the settings backend
## remains the store of record.
func get_brightness() -> float:
	return _brightness


## Whether the overlay quad is currently drawing. False at neutral by design — see
## [method set_brightness]. Always false in [constant Mode.ENVIRONMENT].
func is_overlay_active() -> bool:
	return _overlay != null and is_instance_valid(_overlay) and _overlay.visible


func _exit_tree() -> void:
	# Undo the Environment write while this node still has a tree reference, and only when this node
	# is the one that made it. NOTIFICATION_EXIT_TREE propagates children first (build handoff §4),
	# so anything that reached for a parent or a sibling here would already be too late; the
	# Environment is a Resource held directly, which is why this teardown is safe at all.
	_release_current_mode()


func _apply_overlay() -> void:
	var neutral := absf(_brightness - 1.0) <= NEUTRAL_EPSILON
	if neutral:
		if _overlay != null and is_instance_valid(_overlay):
			_overlay.visible = false
		return
	if not _ensure_overlay():
		return
	_material.set_shader_parameter(_GAMMA_PARAM, _brightness)
	_overlay.visible = true


## Builds the quad on first non-neutral use. Lazily, so a host that never moves the slider never
## pays for the node — and so constructing this controller headless touches no renderer state.
## Returns false when the vendored shader could not be loaded, which is a broken install rather than
## a misconfiguration: it warns and leaves brightness at the documented floor (the value still
## reaches the host through the backend) instead of taking the boot down.
func _ensure_overlay() -> bool:
	if _overlay != null and is_instance_valid(_overlay):
		return true
	var shader := ResourceLoader.load(_SHADER_PATH) as Shader
	if shader == null:
		MKLog.warn("%s: could not load the gamma shader — brightness stays a value the host consumes"
			% MKLog.context(_SHADER_PATH))
		return false
	_material = ShaderMaterial.new()
	_material.shader = shader

	_overlay = ColorRect.new()
	_overlay.name = "GammaOverlay"
	_overlay.material = _material
	# The shader replaces the pixel with a re-encoded copy of the screen, so the quad's own colour is
	# never read. White rather than transparent: a modulate of zero alpha would scale COLOR down in
	# any future variant of the shader that respected it.
	_overlay.color = Color.WHITE
	# IGNORE, not STOP: a fullscreen quad above every menu that ate mouse input would make the entire
	# UI unclickable the moment a player nudged the brightness slider off neutral — a bug that only
	# appears for users who changed the setting.
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The layer resizes with the window, so the quad follows without a resize handler.
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay.visible = false
	add_child(_overlay)
	return true


func _apply_environment() -> void:
	var env := _resolve_environment()
	if env == null:
		if not _env_warned:
			_env_warned = true
			MKLog.warn("MKBrightnessController: Mode.ENVIRONMENT found no Environment to drive — set world_environment_path, or use Mode.OVERLAY")
		return
	_env_warned = false
	if env != _adjusted_env:
		# Switched worlds. Release the previous one first, or a scene change leaves adjustment
		# enabled forever on an Environment nothing is driving any more.
		_release_environment()
		_adjusted_env = env
	if not env.adjustment_enabled:
		env.adjustment_enabled = true
		_adjustment_owned = true
	env.adjustment_brightness = _brightness


func _resolve_environment() -> Environment:
	if not world_environment_path.is_empty():
		var node := get_node_or_null(world_environment_path)
		var we := node as WorldEnvironment
		if we == null:
			if not _env_warned:
				_env_warned = true
				MKLog.warn("MKBrightnessController.world_environment_path: '%s' is not a WorldEnvironment"
					% world_environment_path)
			return null
		return we.environment
	var viewport := get_viewport()
	if viewport == null:
		return null
	var world := viewport.find_world_3d()
	if world == null:
		return null
	return world.environment


func _release_current_mode() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.visible = false
	_release_environment()


func _release_environment() -> void:
	if _adjusted_env != null and _adjustment_owned:
		# Only the flag this node set. adjustment_brightness is left where it is: restoring a
		# remembered value would fight a host that changed it meanwhile, and with the flag off it is
		# inert anyway.
		_adjusted_env.adjustment_enabled = false
	_adjusted_env = null
	_adjustment_owned = false
