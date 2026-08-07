@tool
class_name MKStepAppearance
extends Control
## The appearance step: a deliberate PLACEHOLDER that writes nothing.
##
## [b]Appearance is host-defined, and MenuKit will not guess at it.[/b] There is no universal set of
## appearance controls — a body slider and a palette, a portrait grid, a 3D character with morph
## targets — so a shipped "appearance editor" would be wrong for all of them while looking
## authoritative. The step exists because the FLOW slot is the reusable part; its content is the one
## thing a host is expected to replace.
##
## [b]How a host replaces it:[/b] point the step def's [member MKCreationStepDef.scene] at its own
## scene. Nothing else changes — the host's scene implements the same four-method contract documented on
## [MKCreationStepDef], declares whatever payload keys it writes, and slots into the same ordered array.
## This script is the smallest complete example of that contract: it declares no keys, is always valid,
## and commits nothing.
##
## [b]It does host the shipped [MKPreviewViewport], on the left.[/b] The viewport is the reusable half
## of "appearance", and showing the chosen archetype's [member MKArchetype.preview_scene] in it is the
## one appearance behaviour genre-neutral enough for MenuKit to ship. It reads that field and nothing
## else — no morph targets, no palette, no body sliders.
##
## [b]An archetype with no preview_scene leaves the viewport EMPTY, and that is the shipped placeholder
## state[/b] — not a failure and not a warning. The slot renders its backdrop, the text column beside it
## says what a host is expected to replace, and the flow is completable either way. Every archetype the
## ADDON ships is preview-less, since it ships no art at all.
##
## [b]Owns no payload keys[/b], which is a supported shape rather than a degenerate one — the host's
## ownership assertion is a statement about the keys a step CLAIMS, and claiming none can never
## collide. Being always valid means Next is never gated here, and pairing the def with
## [member MKCreationStepDef.skippable] (and [member MKCreationStepDef.required] false) makes it a
## no-cost stop the player can walk straight past.

signal step_state_changed()

## The payload key this step READS (it owns nothing and writes nothing). Spelled from
## [constant MKStepArchetype.PAYLOAD_KEY] rather than as a literal, because the two must not be able
## to drift apart: a rename on one side would leave this step silently previewing nothing.
const PAYLOAD_ARCHETYPE_KEY := MKStepArchetype.PAYLOAD_KEY

## Width floor for the preview column, so the model does not render into a sliver beside the text at
## typical menu widths. A layout rhythm, not a palette value.
const PREVIEW_MIN_SIZE := Vector2(360.0, 360.0)

const BODY := "Appearance options are defined by the game, not by MenuKit.

Point this step's scene at your own appearance UI. It only has to implement the step contract: bind, declare the payload keys it writes, report validity, and commit."

var _host: MKCreationHost
var _def: MKCreationStepDef
var _built := false
var _preview: MKPreviewViewport
## The archetypes the host handed over at bind, kept so the preview can be re-resolved when the step
## is SHOWN. Every step is bound once, eagerly, at [method MKCreationHost.configure] — before the
## player has chosen anything — so the bind-time payload copy carries no archetype in the shipped
## flow, where this step sits after the archetype step. Re-reading the host's live payload on
## visibility is what makes the preview show the choice the player actually made; the bind-time read
## is what makes it correct for a host that jumps straight here with a payload already assembled.
var _archetypes: Array[MKArchetype] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return


## Nothing. See the class doc: a placeholder that claimed a key would reserve it against the host's own
## replacement step, which is the one thing a placeholder must not do.
func _mk_step_owned_keys() -> Array[String]:
	var none: Array[String] = []
	return none


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	_host = host
	_def = def
	_archetypes.clear()
	var raw: Variant = ctx.get("archetypes", null)
	if raw is Array:
		for entry in (raw as Array):
			var archetype := entry as MKArchetype
			if archetype != null:
				_archetypes.append(archetype)
	_build()
	var payload_variant: Variant = ctx.get("payload", null)
	_apply_preview(payload_variant if payload_variant is Dictionary else {})


## Re-resolves the preview from the host's LIVE payload each time this step becomes visible. See
## [member _archetypes] for why the bind-time read is not enough on its own. Reading through the
## host's public [method MKCreationHost.get_payload] rather than reaching into its state keeps this
## step exactly as coupled to the host as every other step is.
func _on_visibility_changed() -> void:
	if not visible or _host == null or not is_instance_valid(_host):
		return
	_apply_preview(_host.get_payload())


## Points the viewport at the chosen archetype's scene, or CLEARS it. Clearing on an unknown or absent
## archetype is deliberate: leaving the previous choice's model on screen while the payload says
## something else is the one outcome a preview must never produce.
func _apply_preview(payload: Dictionary) -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	# typeof-gated: "archetype" is a key of an OPAQUE payload, so a host can have put anything under
	# it, and String(a Dictionary) would produce a lookup key that matches nothing while looking like
	# a miss rather than a type error.
	var raw: Variant = payload.get(PAYLOAD_ARCHETYPE_KEY, null)
	if typeof(raw) != TYPE_STRING and typeof(raw) != TYPE_STRING_NAME:
		_preview.set_preview_scene(null)
		return
	var id := String(raw)
	for archetype in _archetypes:
		if String(archetype.id) == id:
			# Null is a legal assignment and IS the placeholder state — an archetype with no authored
			# preview leaves the slot empty rather than warning about art that was never promised.
			_preview.set_preview_scene(archetype.preview_scene)
			return
	_preview.set_preview_scene(null)


## Always. There is no input here to be incomplete.
func _mk_step_is_valid() -> bool:
	return true


func _mk_step_commit(_payload: Dictionary) -> void:
	pass


func _build() -> void:
	if _built:
		return
	_built = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Preview left, explanatory column right. An HBox because the two halves are peers and a host
	# replacing this scene should be able to read the arrangement at a glance.
	var row := HBoxContainer.new()
	row.name = "Row"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(row)

	_preview = MKPreviewViewport.new()
	_preview.name = "Preview"
	_preview.custom_minimum_size = PREVIEW_MIN_SIZE
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# auto_rotate is left at its default true: a still model reads as a broken viewport.
	row.add_child(_preview)
	# Connected once the preview node exists, since the handler writes to it. The bind's own
	# _apply_preview fills the slot the first time; this signal covers the LATER shows, after the player
	# has chosen an archetype.
	visibility_changed.connect(_on_visibility_changed)

	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(centre)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.custom_minimum_size = Vector2(420.0, 0.0)
	MKTheme.set_variation(frame, MKTheme.PANEL)
	centre.add_child(frame)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	margin.add_child(column)

	var heading := Label.new()
	heading.name = "Heading"
	heading.text = "Appearance is host-defined"
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	var body := Label.new()
	body.name = "Body"
	body.text = BODY
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MKTheme.set_variation(body, MKTheme.ROW_LABEL)
	column.add_child(body)
