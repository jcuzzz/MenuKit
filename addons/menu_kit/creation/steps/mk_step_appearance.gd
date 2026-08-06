@tool
class_name MKStepAppearance
extends Control
## The appearance step: a deliberate PLACEHOLDER that writes nothing (plan §4.5).
##
## [b]Appearance is host-defined, and MenuKit will not guess at it.[/b] There is no universal set of
## appearance controls — one game needs a body slider and a palette, another a portrait grid, another a
## full 3D character with morph targets — and a shipped "appearance editor" would be wrong for all
## three while looking authoritative. So the step exists (the FLOW slot is the reusable part) and its
## content is the one thing a host is expected to replace.
##
## [b]How a host replaces it:[/b] point the step def's [member MKCreationStepDef.scene] at its own
## scene. Nothing else changes — the host's scene implements the same four-method contract documented on
## [MKCreationStepDef], declares whatever payload keys it writes, and slots into the same ordered array.
## This script is the smallest complete example of that contract: it declares no keys, is always valid,
## and commits nothing.
##
## A replacement scene is the natural place to host a preview viewport beside the controls (the addon
## ships one under the same phase). Referred to only here, in prose: nothing in this file names that
## class, so this step carries no dependency on it and a host that deletes the preview entirely still
## has a working flow.
##
## [b]Owns no payload keys[/b], which is a supported shape rather than a degenerate one — the host's
## ownership assertion is a statement about the keys a step CLAIMS, and claiming none can never
## collide. Being always valid means Next is never gated here, and pairing the def with
## [member MKCreationStepDef.skippable] (and [member MKCreationStepDef.required] false) makes it a
## no-cost stop the player can walk straight past.

signal step_state_changed()

const BODY := "Appearance options are defined by the game, not by MenuKit.

Point this step's scene at your own appearance UI. It only has to implement the step contract: bind, declare the payload keys it writes, report validity, and commit."

var _host: MKCreationHost
var _def: MKCreationStepDef
var _built := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return


## Nothing. See the class doc: a placeholder that claimed a key would reserve it against the host's own
## replacement step, which is the one thing a placeholder must not do.
func _mk_step_owned_keys() -> Array[String]:
	var none: Array[String] = []
	return none


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, _ctx: Dictionary) -> void:
	_host = host
	_def = def
	_build()


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

	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

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
