extends Control
## A demo page. Deliberately dumb: its whole job is to prove the shell's contracts are reachable
## from ordinary host content that the addon knows nothing about.
##
## This script lives in [code]demo/[/code], not in the addon — which is the point. A page is an
## [code]MKMenuPageDef[/code] entry pointing at any [PackedScene], so adding one needs no addon edit
## and survives a version upgrade.

@export var title := "Page"
@export_multiline var body := ""

## Pushes a sub-page onto the back stack, so Escape has something to pop. Empty hides the button.
@export var push_page_id: StringName = &""

## Opens a confirm modal, exercising the modal stack, the scrim, and focus save/restore.
@export var show_modal_button := false

## Routed through the menu backend's [code]open_url[/code]. Empty hides the button.
@export var url := ""

var _root: MKRoot


func _ready() -> void:
	_root = _find_root()

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var column := VBoxContainer.new()
	# Left-aligned and width-capped: a VBox left to fill would stretch every button edge-to-edge,
	# which reads as a broken layout rather than a menu.
	column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	column.custom_minimum_size.x = 560.0
	margin.add_child(column)

	var heading := Label.new()
	heading.text = title
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	if not body.is_empty():
		var text := Label.new()
		text.text = body
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		MKTheme.set_variation(text, MKTheme.ROW_LABEL)
		column.add_child(text)

	if not push_page_id.is_empty():
		column.add_child(_button("Open sub-panel", func() -> void:
			if _root != null:
				_root.push_page(push_page_id)
		))

	if show_modal_button:
		column.add_child(_button("Open a modal", func() -> void:
			if _root == null:
				return
			MKConfirmDialog.open(_root.get_modal_layer(), "Modal",
				"Escape closes this before it touches the page underneath.", "OK", "Cancel")
		))

	if not url.is_empty():
		column.add_child(_button("Open link", func() -> void:
			if _root != null and _root.get_menu_backend() != null:
				_root.get_menu_backend().open_url(url)
			else:
				MKLog.warn("demo: no menu backend assigned, cannot open '%s'" % url)
		))

	# Keyboard-only traversal is a per-phase exit criterion, not Phase 8 work.
	MKFocus.chain_container(column)
	MKFocus.focus_first(column)


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	MKTheme.set_variation(b, MKTheme.PANEL_BUTTON)
	b.pressed.connect(action)
	return b


func _find_root() -> MKRoot:
	var node := get_parent()
	while node != null:
		if node is MKRoot:
			return node as MKRoot
		node = node.get_parent()
	return null
