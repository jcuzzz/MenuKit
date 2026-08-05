class_name MKNavBar
extends Control
## The menu's tab strip. Builds itself at runtime from an [code]Array[MKMenuPageDef][/code].
##
## The source nav bar declared its tabs as a [code]const[/code] array, so a host adding a Credits or
## Mods page had to fork the file — breaking the pin-a-tag upgrade path (plan §4.7a, finding F5).
## [b]No hardcoded tab list ships here.[/b] Tabs come from [method set_pages], sorted by
## [member MKMenuPageDef.order], skipping [code]visible == false[/code] entries.
##
## Styling is a [member Control.theme_type_variation] swap between [constant MKTheme.NAV_TAB] and
## [constant MKTheme.NAV_TAB_ACTIVE], never an [code]add_theme_*_override[/code]: an override beats
## the Theme and would make the palette swap (ship gate 3) a lie.
##
## Presentation-only. Pressing a tab emits [signal page_selected]; the bar does not change its own
## active state — [code]MKRoot[/code] owns the page state machine and calls [method set_active]
## back. That one-way flow is what keeps the bar honest when navigation is driven from host code
## (a Continue button, a deep link) instead of from a click.
##
## Keyboard/gamepad traversable from the first build: tabs are focusable and laid out in an
## [HBoxContainer], so Godot's automatic focus neighbors give left/right traversal, and
## [method focus_active] hands focus to the current tab when the bar is entered.

## Emitted when the user activates a tab. Carries [member MKMenuPageDef.id]; the bar's own active
## state is NOT updated by this — see the class docs.
signal page_selected(id: StringName)

## Default bar height. Exported rather than a const so a host can match its own layout without
## touching the addon.
@export var bar_height: float = 58.0

var _buttons: Dictionary = {}          # StringName id -> Button
var _pages: Array[MKMenuPageDef] = []  # the built (visible, sorted) subset
var _active: StringName = &""
var _row: HBoxContainer = null
var _built := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = bar_height
	custom_minimum_size.y = bar_height
	# PASS, not STOP: the bar is a strip over the backdrop and must not swallow clicks in its gaps.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_ensure_skeleton()


## Rebuilds the whole tab strip from [param pages]. Rebuilding wholesale (rather than diffing) is
## deliberate: page arrays are small, change rarely, and a diff is a second source of truth for
## ordering that could disagree with [method set_pages]'s own sort.
##
## Entries are sorted ascending by [member MKMenuPageDef.order] with array order preserved on ties,
## so a host can slot a page between two shipped ones without renumbering them. Hidden and id-less
## entries are skipped; an id-less one warns by index because it has no name to report.
## An empty array is a legitimate state (a host driving navigation entirely from its own UI) and
## produces one debug line, not a warning per frame.
func set_pages(pages: Array[MKMenuPageDef]) -> void:
	_ensure_skeleton()
	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()
	_buttons.clear()
	_pages.clear()

	var ordered: Array[MKMenuPageDef] = []
	for i in pages.size():
		var def := pages[i]
		if def == null:
			MKLog.warn("MKNavBar: pages[%d] is null — skipped" % i)
			continue
		if not def.is_valid():
			MKLog.warn("%s: page has an empty id (pages[%d]) — skipped"
				% [MKLog.context(def, "id"), i])
			continue
		if not def.visible:
			continue
		if _buttons.has(def.id) or _has_id(ordered, def.id):
			MKLog.warn("%s: duplicate page id '%s' — only the first is shown"
				% [MKLog.context(def, "id"), def.id])
			continue
		ordered.append(def)
	# Stable sort: Array.sort_custom is not guaranteed stable, so ties are broken by original index.
	var indexed: Array = []
	for i in ordered.size():
		indexed.append([ordered[i].order, i, ordered[i]])
	indexed.sort_custom(func(a, b) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])

	for entry in indexed:
		var def: MKMenuPageDef = entry[2]
		_pages.append(def)
		_row.add_child(_make_tab(def))

	_built = true
	if _pages.is_empty():
		MKLog.debug("MKNavBar: no visible pages — the bar renders empty")
	# The active id may no longer exist after a rebuild; re-apply so styling matches reality.
	set_active(_active)


## Reflects the active page. Called by [code]MKRoot[/code], never by the bar itself. An unknown or
## empty id is valid and clears the highlight (a landing/showcase state with no tab selected), so it
## is silent — warning here would fire on every legitimate root state.
func set_active(id: StringName) -> void:
	_active = id
	for key in _buttons:
		var btn: Button = _buttons[key]
		MKTheme.set_variation_if(btn, key == id, MKTheme.NAV_TAB_ACTIVE, MKTheme.NAV_TAB)
		btn.button_pressed = key == id


## The currently reflected page id, or [code]&""[/code].
func get_active() -> StringName:
	return _active


## Ids of the tabs actually built, in display order. The proof surface for tests and the list a host
## can iterate to drive its own navigation UI off the same data the bar used.
func get_page_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for def in _pages:
		ids.append(def.id)
	return ids


## Number of built tabs. Cheap enough to expose so callers need not build an id array to ask.
func get_tab_count() -> int:
	return _pages.size()


## The Button for [param id], or null. Exposed for focus wiring and host-side decoration; callers
## must still style through [MKTheme] variations, never overrides.
func get_tab_button(id: StringName) -> Button:
	return _buttons.get(id, null) as Button


## Moves keyboard/gamepad focus to the active tab (or the first tab if none is active). Returns
## false when there is nothing to focus, so a caller can fall through to the page content instead of
## leaving focus nowhere — the failure mode that makes a menu unusable on a controller.
func focus_active() -> bool:
	var btn := get_tab_button(_active)
	if btn == null and not _pages.is_empty():
		btn = get_tab_button(_pages[0].id)
	if btn == null or not btn.is_inside_tree():
		# grab_focus() errors outside the tree; report the miss instead so a caller mid-build can
		# retry after the bar is mounted rather than eating an engine error.
		return false
	btn.grab_focus()
	return true


func _make_tab(def: MKMenuPageDef) -> Button:
	var btn := Button.new()
	btn.name = "MKNavTab_%s" % def.id
	btn.text = def.title if not def.title.is_empty() else String(def.id)
	if def.icon != null:
		btn.icon = def.icon
	btn.toggle_mode = true          # so the Theme's pressed state can carry the active look too
	btn.focus_mode = Control.FOCUS_ALL
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	MKTheme.set_variation(btn, MKTheme.NAV_TAB)
	var id := def.id
	# Emit intent only. Re-styling happens when MKRoot calls set_active back, so a host that vetoes
	# the navigation never leaves the bar showing a page that was not entered.
	btn.pressed.connect(func() -> void: page_selected.emit(id))
	_buttons[id] = btn
	return btn


func _ensure_skeleton() -> void:
	if _row != null:
		return
	var bg := PanelContainer.new()
	bg.name = "MKNavBarPanel"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_PASS
	MKTheme.set_variation(bg, MKTheme.PANEL)
	add_child(bg)

	var center := CenterContainer.new()
	center.name = "MKNavBarCenter"
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	bg.add_child(center)

	_row = HBoxContainer.new()
	_row.name = "MKNavBarTabs"
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(_row)


func _has_id(defs: Array[MKMenuPageDef], id: StringName) -> bool:
	for def in defs:
		if def.id == id:
			return true
	return false
