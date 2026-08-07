@tool
class_name MKBrightnessController
extends CanvasLayer
## The working brightness implementation behind the Video page's brightness row.
##
## Godot has no global or OS gamma control, so brightness cannot be "applied by a backend"; this
## node implements it at the engine level without knowing anything about the host's game.
##
## [b]Who owns this node.[/b] [code]MKSettingsService[/code] — the autoload — not [MKRoot]. A host
## may boot straight into gameplay without ever instancing a MenuKit scene, and a controller owned by
## a per-scene root would not exist on that path: the user would calibrate in the menu, start the
## game, and watch it snap back. [MKRoot] creates one only in the standalone no-service
## configuration, and that tier is weaker — it dies with its per-scene root, so brightness gaps
## across scene transitions and reaches gameplay only if the game scene also hosts an [MKRoot]. The
## autoload is the supported configuration.
##
## [b]This node is not the floor.[/b] The row writes a plain value through the settings backend
## either way, so a host that sets [code]MKConfig.manage_brightness = false[/code] and consumes the
## value itself loses nothing. This adds a working default on top of that floor.
##
## [b]A CanvasLayer severs Control theme propagation[/b] — harmless here, because this layer hosts a
## single unstyled [ColorRect] with a [ShaderMaterial]. Never add a themed control under it.

## Which mechanism applies the brightness value.
enum Mode {
	## Default. A full-rect [ColorRect] on a very high [CanvasLayer] re-encodes the finished frame
	## through [code]mk_gamma.gdshader[/code]. Renderer-independent, and it affects the UI too —
	## which matches the "adjust until the logo is barely visible" calibration convention every
	## shooter uses.
	OVERLAY,
	## Alternative: drives [member Environment.adjustment_enabled] and
	## [member Environment.adjustment_brightness]. Caveats, all inherent to the approach:
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

## Sane range for the brightness value. Neutral is 1.0 in both modes. Below ~0.4 the image is
## unrecoverable and above ~2.5 it is fully blown out — a slider that can render a game unplayable
## has no in-game route back to a readable menu.
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

## Which mechanism draws the adjustment. Changing it at runtime is supported and takes effect
## IMMEDIATELY, not on a later write: the setter releases the outgoing mode's effect and re-applies
## the brightness it already holds through the new one.
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
## True once this node has written an [Environment]'s adjustment. Teardown undoes only what it did,
## and only while this is set — writing over an Environment this node never touched would be a
## silent visual regression in the host's game.
var _adjustment_owned := false
var _adjusted_env: Environment
## The Environment's own adjustment state at the moment this node took it over, restored on teardown
## and on a mode switch. Captured as a PAIR: a host that already had adjustment enabled keeps its
## flag, and its brightness is put back too.
var _prior_adjustment_enabled := false
var _prior_adjustment_brightness := 1.0
## One warning per disappearance, not one per slider frame: the latch is cleared again the moment an
## Environment resolves, so a host whose Environment comes and goes with scene loads is told each
## time it goes — but a dragged slider over an unresolvable one, which emits dozens of writes a
## second, still warns once.
var _env_warned := false


func _init() -> void:
	layer = OVERLAY_LAYER
	# The pause menu runs with the tree paused and the brightness row is live-apply, so a PAUSABLE
	# controller would ignore the slider in exactly the screen where a player calibrates. This node
	# hangs off the settings-service autoload, outside the MKRoot subtree, so it inherits nothing.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Applies [param value] as the brightness. 1.0 is neutral in both modes.
##
## Out-of-range values are CLAMPED rather than refused: the caller is usually a stored setting from
## an older build or a host's own slider. A non-finite value IS refused, with a warning — NAN has no
## in-range value to clamp toward (clampf propagates it) and writing it into the shader's gamma
## leaves a black or blank screen that no later in-range write recovers from.
##
## In [constant Mode.OVERLAY] a neutral value [b]hides the overlay entirely[/b] instead of drawing a
## no-op pass, so the untouched-slider default costs no fullscreen screen-texture read.
func set_brightness(value: float) -> void:
	if not is_finite(value):
		MKLog.warn("MKBrightnessController.set_brightness: ignoring non-finite value '%s'" % value)
		return
	_brightness = clampf(value, MIN_BRIGHTNESS, MAX_BRIGHTNESS)
	# @tool guard: the value is remembered, nothing is applied. Building the overlay in the editor
	# would materialise an unowned child into whatever scene is open, and resolving an Environment
	# from an inspector edit (the `mode` setter runs there) would warn about a viewport that does
	# not exist yet.
	if Engine.is_editor_hint():
		return
	match mode:
		Mode.OVERLAY:
			_apply_overlay()
		Mode.ENVIRONMENT:
			_apply_environment()


## The clamped value currently applied. The settings backend remains the store of record.
func get_brightness() -> float:
	return _brightness


## Whether the overlay quad is currently drawing. False at neutral by design — see
## [method set_brightness]. Always false in [constant Mode.ENVIRONMENT].
func is_overlay_active() -> bool:
	return _overlay != null and is_instance_valid(_overlay) and _overlay.visible


func _exit_tree() -> void:
	# Undo the Environment write while this node still has a tree reference, and only when this node
	# made it. NOTIFICATION_EXIT_TREE propagates children first, so reaching for a parent or sibling
	# here would be too late; the Environment is a Resource held directly, so this is safe.
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


## Builds the quad on first non-neutral use — lazily, so a host that never moves the slider never
## pays for the node, and constructing this controller headless touches no renderer state.
## Returns false when the vendored shader could not be loaded: that is a broken install, so it warns
## and leaves brightness a value the host consumes rather than taking the boot down.
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
	# The quad's own colour is never read by the shader. White rather than transparent: a zero-alpha
	# modulate would scale COLOR down in any shader variant that respected it.
	_overlay.color = Color.WHITE
	# IGNORE, not STOP: a fullscreen quad above every menu that ate mouse input would make the whole
	# UI unclickable as soon as the brightness slider left neutral.
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
		# Switched worlds. Release the previous one first — restoring ITS state — or a scene change
		# leaves an Environment nothing is driving any more stuck on this node's adjustment.
		_release_environment()
		_adjusted_env = env
		# Capture before the first write, and only on takeover: re-capturing on every slider frame
		# would remember this node's own last value as the host's.
		_prior_adjustment_enabled = env.adjustment_enabled
		_prior_adjustment_brightness = env.adjustment_brightness
		_adjustment_owned = true
	if not env.adjustment_enabled:
		env.adjustment_enabled = true
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


## Puts the Environment back the way this node found it: BOTH halves of the state it took over.
##
## The brightness matters as much as the flag. Restoring only the flag would leave a host that ran
## with adjustment_enabled stuck at this node's last slider value after the menu closes. A host that
## had it OFF gets the flag cleared and the brightness restored, leaving the resource
## byte-identical to how it arrived.
func _release_environment() -> void:
	if _adjusted_env != null and _adjustment_owned:
		_adjusted_env.adjustment_brightness = _prior_adjustment_brightness
		if not _prior_adjustment_enabled:
			_adjusted_env.adjustment_enabled = false
	_adjusted_env = null
	_adjustment_owned = false
