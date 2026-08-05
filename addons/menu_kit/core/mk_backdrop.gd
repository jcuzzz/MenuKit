class_name MKBackdrop
extends Control
## The fullscreen backdrop layer: hosts one [MKBackdropDef] and applies the vendored blur shader.
##
## Two deliberate departures from the source implementation (plan §1.1, §3.1):
## [br]- The shader is vendored inside the addon, so nothing outside
##   [code]res://addons/menu_kit/[/code] is referenced and ship gate 1 passes.
## [br]- It renders correctly with [b]no texture assigned[/b]. The cold-drop gate copies the addon
##   into an empty project and demands zero warnings, and the shipped catalog carries a generated
##   backdrop rather than an image — so a def with a null texture produces a procedural vertical
##   gradient here instead of an empty rect and a complaint.
##
## Presentation-only: it never selects a backdrop, it displays the one it is handed.

const _BLUR_SHADER: Shader = preload("res://addons/menu_kit/shaders/mk_backdrop_blur.gdshader")

## Height in pixels of the procedurally generated gradient. Two-stop vertical ramps need no
## resolution; the TextureRect stretches it across the viewport.
const _GRADIENT_HEIGHT := 256

var _rect: TextureRect = null
var _blur_material: ShaderMaterial = null
var _def: MKBackdropDef = null
var _scroll_offset := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The backdrop is scenery: it must never eat a click meant for the menu above it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_rect()
	# Do NOT unconditionally stop processing here. apply_def/apply_from_catalog work before the node
	# enters the tree (they call _ensure_rect themselves), and _apply_material already arms processing
	# for a scrolling def — so a blanket set_process(false) silently cancelled scrolling configured
	# pre-tree, and nothing re-armed it. Only idle when there is genuinely nothing to animate.
	if _def == null or absf(_def.scroll_speed) <= 0.0001:
		set_process(false)


## Displays [param def]. Null CLEARS the backdrop rather than being ignored, so a host can turn the
## layer off (it supplies its own 3D background) through the same call it uses to set one — the
## source version's silent no-op on null left no way to do that.
func apply_def(def: MKBackdropDef) -> void:
	_ensure_rect()
	_def = def
	if def == null:
		clear()
		return
	_rect.texture = def.texture if def.texture != null else _make_gradient(def)
	_rect.modulate = def.tint
	_rect.texture_repeat = (CanvasItem.TEXTURE_REPEAT_ENABLED if absf(def.scroll_speed) > 0.0001
		else CanvasItem.TEXTURE_REPEAT_DISABLED)
	_scroll_offset = 0.0
	_apply_material(def)
	visible = true


## Resolves an id through [param catalog] and displays it; an empty [param id] takes the catalog
## default. This is the one-line call a host makes, and it keeps the resolution rules (and their
## named warnings) inside [MKBackdropCatalog] instead of duplicating them per call site.
func apply_from_catalog(catalog: MKBackdropCatalog, id: StringName = &"") -> void:
	if catalog == null:
		MKLog.warn("%s: apply_from_catalog called with a null catalog" % name)
		clear()
		return
	var def := catalog.get_backdrop(id) if id != &"" else catalog.get_default()
	if def == null:
		# The catalog has already warned with its own path/field; do not double-report.
		clear()
		return
	apply_def(def)


## Drops the texture, material, and per-frame scroll work. Used on teardown and whenever a null def
## arrives, so an unconfigured backdrop costs nothing rather than idling with a live shader.
func clear() -> void:
	_ensure_rect()
	_def = null
	_rect.texture = null
	_rect.material = null
	_rect.modulate = Color(1, 1, 1, 1)
	set_process(false)


## The def currently displayed, or null. Lets a settings page show the active selection without
## keeping a parallel copy of the id that could drift out of sync with what is on screen.
func get_active_def() -> MKBackdropDef:
	return _def


func _process(delta: float) -> void:
	if _def == null or _blur_material == null:
		return
	_scroll_offset = fposmod(_scroll_offset + _def.scroll_speed * delta, 1.0)
	_blur_material.set_shader_parameter("scroll_offset", _scroll_offset)


func _apply_material(def: MKBackdropDef) -> void:
	var wants_blur := def.blur_amount > 0.001
	var wants_scroll := absf(def.scroll_speed) > 0.0001
	if not wants_blur and not wants_scroll:
		# Passthrough: a sharp, static backdrop should not pay for a shader at all.
		_rect.material = null
		set_process(false)
		return
	if _blur_material == null:
		_blur_material = ShaderMaterial.new()
		_blur_material.shader = _BLUR_SHADER
	_blur_material.set_shader_parameter("blur_amount", def.blur_amount)
	_blur_material.set_shader_parameter("scroll_offset", 0.0)
	_rect.material = _blur_material
	set_process(wants_scroll)


func _ensure_rect() -> void:
	if _rect != null:
		return
	_rect = TextureRect.new()
	_rect.name = "MKBackdropRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# STRETCH_SCALE, not KEEP_ASPECT_COVERED. The generated gradient is a 4x256 ramp; covering a 16:9
	# viewport from a 1:64 source scales it to tens of thousands of pixels tall, so under 1% of the
	# ramp lands on screen and the shipped backdrop rendered as flat colour — sampling four rows of
	# the cold drop returned an identical value at every one. Scaling to the rect shows the whole
	# ramp; a host supplying a real photographic texture and wanting cover behaviour can set
	# stretch_mode itself.
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func _make_gradient(def: MKBackdropDef) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, def.gradient_top)
	gradient.set_color(1, def.gradient_bottom)
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 4
	tex.height = _GRADIENT_HEIGHT
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	return tex
