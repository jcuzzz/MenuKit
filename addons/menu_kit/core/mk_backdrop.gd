class_name MKBackdrop
extends Control
## The fullscreen backdrop layer: hosts one [MKBackdropDef] and applies the vendored blur shader.
##
## Two properties a host relies on:
## [br]- The blur shader is vendored inside the addon; nothing outside
##   [code]res://addons/menu_kit/[/code] is referenced.
## [br]- It renders correctly with [b]no texture assigned[/b] — a def with a null texture produces a
##   procedural vertical gradient rather than an empty rect and a warning.
##
## A def carrying a [member MKBackdropDef.scene] renders that 3D scene fullscreen instead, in a
## [SubViewport] with its own [World3D] — the whole screen is the viewport and the menu UI draws over
## it. [method set_character_scene] mounts a character (the selected roster entry, typically) under
## the scene's [member MKBackdropDef.character_mount] node, so the character lives IN the data-driven
## scene rather than in a separate preview slot over a flat background.
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

var _scene_container: SubViewportContainer = null
var _scene_viewport: SubViewport = null
var _scene_root: Node = null
## The character a host has asked for, kept even while no scene backdrop is live: selection can
## legitimately happen before (or between) scene defs, and the next [method apply_def] re-mounts it.
var _character_scene: PackedScene = null
var _character_instance: Node = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The backdrop is scenery: it must never eat a click meant for the menu above it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_rect()
	# Do NOT unconditionally stop processing: apply_def/apply_from_catalog work before the node
	# enters the tree and _apply_material already arms processing for a scrolling def. Only idle
	# when there is nothing to animate.
	if _def == null or absf(_def.scroll_speed) <= 0.0001:
		set_process(false)


## Displays [param def]. Null CLEARS the backdrop rather than being ignored, so a host can turn the
## layer off (it supplies its own 3D background) through the same call it uses to set one.
func apply_def(def: MKBackdropDef) -> void:
	_ensure_rect()
	_def = def
	if def == null:
		clear()
		return
	if def.scene != null:
		_apply_scene(def)
		visible = true
		return
	_teardown_scene()
	_rect.visible = true
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
	_teardown_scene()
	_rect.visible = true
	_rect.texture = null
	_rect.material = null
	_rect.modulate = Color(1, 1, 1, 1)
	set_process(false)


## Mounts [param scene] under the active scene backdrop's [member MKBackdropDef.character_mount]
## node — the one call a host (or [MKRoot]'s character-selection wiring) makes to put the selected
## character into the menu scene. Replaces any previous character; null clears the mount.
##
## The request is REMEMBERED across backdrop swaps: handed a character while no scene backdrop is
## live (a texture def, or before the catalog resolved), it mounts when one next applies rather than
## being silently dropped.
func set_character_scene(scene: PackedScene) -> void:
	_character_scene = scene
	_mount_character()


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
	# STRETCH_SCALE, not KEEP_ASPECT_COVERED: the generated gradient is a 4x256 ramp, so covering a
	# 16:9 viewport would scale it far past the screen and render as flat colour. A host supplying a
	# photographic texture and wanting cover behaviour sets stretch_mode itself.
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func _apply_scene(def: MKBackdropDef) -> void:
	# Fresh viewport per apply, torn down first: own_world_3d must be set while the viewport is
	# DETACHED and empty — flipping it on a live viewport errors ("Parameter 'scenario' is null").
	_teardown_scene()
	# The 2D rect goes dormant, not destroyed: a later texture/gradient def re-lights it in place.
	_rect.visible = false
	_rect.texture = null
	_rect.material = null
	set_process(false)

	_scene_container = SubViewportContainer.new()
	_scene_container.name = "MKBackdropScene"
	_scene_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	# stretch on: the container OWNS the SubViewport's size and tracks the screen. Never write the
	# viewport's size while this is set — the engine refuses it with a warning per attempt.
	_scene_container.stretch = true
	_scene_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_scene_viewport = SubViewport.new()
	_scene_viewport.name = "MKBackdropViewport"
	_scene_viewport.own_world_3d = true
	# Scenery, not UI: the menu above must receive every event, and the backdrop's viewport must
	# never route or locally handle any of them.
	_scene_viewport.gui_disable_input = true
	_scene_container.add_child(_scene_viewport)
	add_child(_scene_container)
	# The container was added after the shell already ordered its children (backdrop first). Within
	# THIS node it must sit wherever it lands — MKBackdrop itself is the shell's bottom layer, so
	# sibling order inside it is free; nothing else draws here while _rect is hidden.

	_scene_root = def.scene.instantiate()
	_scene_viewport.add_child(_scene_root)
	if _scene_viewport.get_camera_3d() == null:
		MKLog.warn("%s: scene '%s' contains no Camera3D — the backdrop will render nothing"
			% [MKLog.context(def, "scene"), def.scene.resource_path])
	_mount_character()


func _teardown_scene() -> void:
	_character_instance = null
	_scene_root = null
	_scene_viewport = null
	if _scene_container != null:
		# remove_child before queue_free, the shell-wide idiom: a queued container stays in the tree
		# until end of frame and would keep rendering (and answering size queries) under the new def.
		remove_child(_scene_container)
		_scene_container.queue_free()
		_scene_container = null


func _mount_character() -> void:
	if _scene_root == null or _def == null:
		return
	if _character_instance != null and is_instance_valid(_character_instance):
		var old_parent := _character_instance.get_parent()
		if old_parent != null:
			old_parent.remove_child(_character_instance)
		_character_instance.queue_free()
	_character_instance = null
	if _character_scene == null:
		return
	var mount := _scene_root.find_child(String(_def.character_mount), true, false)
	if mount == null:
		MKLog.warn("%s: scene has no node named '%s' to mount the character under"
			% [MKLog.context(_def, "character_mount"), _def.character_mount])
		return
	_character_instance = _character_scene.instantiate()
	mount.add_child(_character_instance)


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
