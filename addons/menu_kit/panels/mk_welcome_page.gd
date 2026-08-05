@tool
class_name MKWelcomePage
extends Control
## The one page the addon ships, so a cold drop has something to show.
##
## Ship gate 2 copies [code]addons/menu_kit/[/code] alone into an empty project, instances the shell
## and demands zero warnings. Without a shipped page the shell booted to an empty nav bar and warned
## that it had nothing to display — a first impression of "this is broken" for the exact test that is
## meant to prove it is not.
##
## It is intentionally minimal and carries no gameplay vocabulary. Phases 3 and 5 add the real pages
## (settings, character select); a host replaces this the moment it authors its own
## [MKMenuPageDef] array, and nothing else references it.

const _BODY := "MenuKit is installed and running.

This page is the addon's shipped default so a fresh install has something to show. Point MKConfig.pages at your own scenes to replace it — no addon edit required.

Backends are unassigned by default, so Play and Quit do nothing yet."


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the whole UI as unowned
	# children that get saved into whatever scene instanced it.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.custom_minimum_size = Vector2(520.0, 0.0)
	MKTheme.set_variation(frame, MKTheme.PANEL)
	margin.add_child(frame)

	var inner := MarginContainer.new()
	frame.add_child(inner)

	var column := VBoxContainer.new()
	inner.add_child(column)

	var heading := Label.new()
	heading.text = "Welcome"
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	var body := Label.new()
	body.text = _BODY
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MKTheme.set_variation(body, MKTheme.ROW_LABEL)
	column.add_child(body)

	var version := Label.new()
	version.text = MKVersion.version_string()
	MKTheme.set_variation(version, MKTheme.ROW_LABEL)
	column.add_child(version)
