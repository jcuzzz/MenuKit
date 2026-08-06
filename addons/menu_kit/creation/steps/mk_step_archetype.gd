@tool
class_name MKStepArchetype
extends Control
## The archetype step: a grid of focusable cards, one selected, owning the payload key
## [code]archetype[/code] (plan §4.5, §3.1).
##
## [b]The grid is never an empty dead end[/b] (§3.1). The FIRST valid archetype is selected at bind, so
## the step arrives valid and the player is choosing between options rather than being blocked by one
## they have not made yet. With zero archetypes the step reports invalid and warns once — a card grid
## with nothing in it is a host configuration mistake, and silently letting the flow past it would write
## no archetype into the payload with nothing anywhere to explain the missing field.
##
## [b]Seeding defaults is the HOST's job.[/b] This step reports the chosen archetype through
## [method MKCreationHost.notify_archetype_chosen] and writes its own key on commit — nothing else. See
## that method for why the merge order and the F8 collision check cannot live out here.
##
## [b]Selection is shown with a ring, not a colour[/b]: a [Panel] child carrying
## [constant MKTheme.FOCUS_RING], the same idiom [method MKSettingsPanel._add_focus_ring] uses on a
## slider. Variation mechanics only — MenuKit ships zero [code]add_theme_*_override[/code] calls (ship
## gate 1), so a host swapping [MKPalette] restyles these rings with everything else.

signal step_state_changed()

const PAYLOAD_KEY := "archetype"

## Card grid width. Three reads as a grid and still leaves each card wide enough for a description at
## typical menu widths; a schema with one or two archetypes narrows to fit rather than rendering a row
## of empty cells.
const MAX_COLUMNS := 3

## Ring OUTSET — the ring is grown beyond the card it traces on all four sides, not inset within it —
## matching [constant MKSettingsPanel.FOCUS_RING_GROW]'s role: a layout rhythm, with the colour coming
## from the palette through the variation.
const RING_GROW := 3.0

var _host: MKCreationHost
var _def: MKCreationStepDef
## Only the archetypes that passed [method MKArchetype.is_valid], in authored order. The card index and
## this array are the same index; the caller's original array is not, because invalid entries are
## dropped from the grid.
var _archetypes: Array[MKArchetype] = []
var _rings: Array[Panel] = []
var _selected := -1
var _grid: GridContainer


func _ready() -> void:
	if Engine.is_editor_hint():
		return


func _mk_step_owned_keys() -> Array[String]:
	return [PAYLOAD_KEY]


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	_host = host
	_def = def
	_archetypes.clear()
	var raw: Variant = ctx.get("archetypes", null)
	if raw is Array:
		for entry in (raw as Array):
			var archetype := entry as MKArchetype
			if archetype == null:
				continue
			if not archetype.is_valid():
				# Named, because the symptom of a silent drop is a card that is simply absent from a grid the
				# author believes they filled.
				MKLog.warn("%s: archetype has no id or no display_name — it is not offered on step '%s'"
					% [MKLog.context(archetype), def.id if def != null else &"<unknown>"])
				continue
			_archetypes.append(archetype)
	_build()

	if _archetypes.is_empty():
		MKLog.warn("%s: step '%s' was given no usable archetypes — the step cannot be completed"
			% [MKLog.context(def, "scene"), def.id if def != null else &"<unknown>"])
		return

	# Restore a previous choice when the player came back through Back; otherwise §3.1's rule applies and
	# the first card is chosen for them.
	var restore := -1
	var payload_variant: Variant = ctx.get("payload", null)
	if payload_variant is Dictionary:
		var existing: Variant = (payload_variant as Dictionary).get(PAYLOAD_KEY, null)
		if existing != null:
			restore = _index_of_id(String(existing))
	_select(restore if restore >= 0 else 0)


func _mk_step_is_valid() -> bool:
	return _selected >= 0 and _selected < _archetypes.size()


func _mk_step_commit(payload: Dictionary) -> void:
	if not _mk_step_is_valid():
		return
	# String, not StringName: the payload crosses to JSON and back in the shipped backend, and a
	# StringName that survives one round trip as a String is a field whose type depends on whether it has
	# been saved yet.
	payload[PAYLOAD_KEY] = String(_archetypes[_selected].id)


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rings.clear()
	_selected = -1

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_grid = GridContainer.new()
	_grid.name = "Cards"
	_grid.columns = clampi(_archetypes.size(), 1, MAX_COLUMNS)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	for i in _archetypes.size():
		_grid.add_child(_build_card(i))


## One card: a focusable [Button] carrying the icon, the name and the description.
##
## A Button rather than a Panel with a click handler, because the card must be reachable by keyboard and
## gamepad (D12) — [MKFocus] collects focusable Controls, and a Panel is not one. Its children are
## [constant Control.MOUSE_FILTER_IGNORE] so the whole card stays one hit target instead of the label
## eating the press.
func _build_card(index: int) -> Control:
	var archetype := _archetypes[index]

	var card := Button.new()
	card.name = "Card_" + String(archetype.id)
	# The Button's own text is left EMPTY: the card lays its content out in a column, and a Button that
	# also carried text would render it underneath the column it is hosting.
	card.text = ""
	card.focus_mode = Control.FOCUS_ALL
	card.custom_minimum_size = Vector2(200.0, 140.0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = archetype.description
	MKTheme.set_variation(card, MKTheme.PANEL_BUTTON)
	card.pressed.connect(func() -> void: _select(index))

	# The card's content is inset by a MarginContainer rather than laid flush against the button's
	# border: the description autowraps, so without it the text ran edge to edge and the card read as a
	# block of type with a line around it. Theme-driven padding (MarginContainer's margin constants come
	# from the palette, MKThemeGenerator._style_panels), so it re-skins with everything else and no
	# number is spelled here.
	var padding := MarginContainer.new()
	padding.name = "Padding"
	padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(padding)

	var column := VBoxContainer.new()
	column.name = "Content"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	padding.add_child(column)

	if archetype.icon != null:
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = archetype.icon
		icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(0.0, 56.0)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(icon)

	var title := Label.new()
	title.name = "Title"
	title.text = archetype.display_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MKTheme.set_variation(title, MKTheme.HEADER)
	column.add_child(title)

	var body := Label.new()
	body.name = "Description"
	body.text = archetype.description
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MKTheme.set_variation(body, MKTheme.ROW_LABEL)
	column.add_child(body)

	# The selection ring. Hidden until this card is the chosen one; MOUSE_FILTER_IGNORE so it never eats
	# the press on the button beneath it.
	var ring := Panel.new()
	ring.name = "SelectionRing"
	MKTheme.set_variation(ring, MKTheme.FOCUS_RING)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.offset_left = -RING_GROW
	ring.offset_top = -RING_GROW
	ring.offset_right = RING_GROW
	ring.offset_bottom = RING_GROW
	ring.visible = false
	card.add_child(ring)
	_rings.append(ring)

	return card


## The one selection path — used by the auto-select at bind and by every press, so "chosen" always
## means the same three things: the ring moved, the host was told, and the host re-polled validity.
func _select(index: int) -> void:
	if index < 0 or index >= _archetypes.size():
		return
	_selected = index
	for i in _rings.size():
		var ring := _rings[i]
		if ring != null and is_instance_valid(ring):
			ring.visible = i == index
	if _host != null and is_instance_valid(_host):
		# Reporting, not seeding. The host clears the previous archetype's defaults and seeds the new
		# ones; this step's own key is written on commit like every other step's.
		_host.notify_archetype_chosen(_archetypes[index])
	step_state_changed.emit()


func _index_of_id(id: String) -> int:
	for i in _archetypes.size():
		if String(_archetypes[i].id) == id:
			return i
	return -1
