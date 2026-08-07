@tool
class_name MKSettingsPanel
extends Control
## The data-driven settings panel: builds every tab and every row at runtime from
## [code]Array[MKSettingsPageDef][/code] (plan §4.3, D5) and applies each change instantly through
## [MKSettingsBackend] (D14).
##
## [b]Nothing here is authored per row.[/b] There is no settings [code].tscn[/code] with hand-placed
## controls, because the moment a host needs one extra row it would have to fork one — the same
## hardcoded-list trap [MKMenuPageDef] exists to avoid for navigation. Adding "Mouse Sensitivity" is
## authoring one [MKSettingDef] sub-resource.
##
## [b]Styling is type variations only.[/b] MenuKit ships ZERO [code]add_theme_*_override[/code] calls
## (plan §1.2, ship gate 1): an override beats the [Theme], so a package using one could never be
## re-skinned by swapping an [MKPalette]. Plain controls ([CheckBox], [HSlider], [OptionButton],
## [LineEdit]) rely on the generated Theme's BASE type styling, which [MKThemeGenerator] provides for
## exactly this reason; if one of them ever looks unstyled the fix is in the generator, never here.
##
## [b]A null backend is not an error.[/b] The panel renders its rows disabled with one warning rather
## than refusing to build. A panel that vanishes when a backend is unassigned is indistinguishable
## from a crashed page, and the host's actual mistake — an unassigned settings slot — goes unnamed.

## Emitted after the tabs and rows are (re)built, so tests and hosts can act on a real tree instead of
## guessing at a frame boundary.
signal built()

## Default confirm-or-revert window for [member MKSettingDef.requires_confirm] rows (D14).
const REVERT_SECONDS := 10.0

## The autoload that owns the one settings backend when a host registered it (plan §4.2). Aliased
## from [constant MKConfig.SETTINGS_SERVICE_PATH], never re-spelled: see that constant for what a
## rename silently costs when the three sites that resolve this node disagree.
const SETTINGS_SERVICE_PATH := MKConfig.SETTINGS_SERVICE_PATH

## Ids this panel gives behaviour beyond the generic row types. All three are reserved by the shipped
## [MKJsonSettingsBackend]'s application logic too, so the special-casing follows the backend's own
## reserved-id convention rather than inventing a second one.
const ID_WINDOW_MODE := &"video/window_mode"
const ID_RESOLUTION := &"video/resolution"
const ID_BRIGHTNESS := &"video/brightness"

## Width reserved for row labels, so every control on a page lines up in one column. A pixel value
## rather than a palette step because it is a layout rhythm, not a visual constant a re-skinner would
## reach for (plan §1.2's rule for what earns a palette field).
const LABEL_COLUMN_WIDTH := 260.0

## How far the slider focus ring is grown beyond the slider's own rect (see
## [method _add_focus_ring]). A layout rhythm like [constant LABEL_COLUMN_WIDTH]; the ring's COLOUR
## and thickness come from the palette, through the [constant MKTheme.FOCUS_RING] variation.
const FOCUS_RING_GROW := 4.0

## The pages to build, in tab order. Assigned in the scene, or by a host at runtime followed by
## [method rebuild].
@export var pages: Array[MKSettingsPageDef] = []

## Extra events a [constant MKSettingDef.RowType.KEYBIND] row must REFUSE to bind, appended to the
## ones [method _reserved_input_events] derives. Exported so a host can widen the list — a game whose
## menu is also opened by Start, or by a second gamepad face button, has a hazard MenuKit cannot know
## about — without forking the panel.
##
## See [method _reserved_input_events] for why the derived part of the list is so short, and why
## keyboard Escape is deliberately NOT on it.
@export var extra_reserved_events: Array[InputEvent] = []

var _backend: MKSettingsBackend
var _tabs: TabContainer
var _built := false
## True while the panel is writing a control's value FROM the store. Control signals fire on
## programmatic writes exactly as they do on user input, so without this a sync would immediately
## write the value back — harmless for equal values, but it re-applies engine settings and, on a
## [member MKSettingDef.requires_confirm] row, would raise a second countdown for a change the user
## never made.
var _syncing := false

## [b]A testing seam, not a host feature.[/b] When valid, this [Callable] answers
## [code]() -> int[/code] with a [enum DisplayServer.WindowMode] IN PLACE OF
## [method DisplayServer.window_get_mode], and installing one also makes [method _is_windowed] take
## its real-display branch under the headless driver.
##
## It exists because the decision [method _is_windowed] documents — the WINDOW beats the store, the
## store is consulted only when there is no window — is unobservable in this suite otherwise: headless
## has no window to diverge from the store, so both orderings behave identically and the rule could be
## inverted without a single assertion going red. The probe stages the divergence the rule is about.
##
## Production behaviour is untouched: with no probe installed, a real display still queries
## [DisplayServer] and headless still falls back to the stored mode. Same convention as
## [member MKSettingsService.override_backend_slot].
##
## The return is VALIDATED as an int rather than coerced — see [method _is_windowed] for what a
## coerced String would silently do to this row's enablement.
var window_mode_probe := Callable()

## Row roots keyed by setting id, for [method _sync_control] after a revert.
var _controls: Dictionary = {}
## The def behind each built row, keyed by id.
var _defs: Dictionary = {}
## The page each registered id was FIRST claimed by, so a duplicate id can name both resources.
var _pages_of_id: Dictionary = {}
## The page currently being built, for the same message. Null outside [method _build_page].
var _building_page: MKSettingsPageDef
## Unresolved [member MKSettingDef.requires_confirm] countdowns this panel raised, as
## [code]{countdown, def, previous, layer}[/code]. See [method _resolve_orphaned_countdown] for why
## the panel holds them rather than trusting the dialog to outlive its own owner.
var _live_countdowns: Array = []
## Rows carrying [member MKSettingDef.visible_condition_id], as
## [code]{node: Control, condition: StringName}[/code].
var _conditional_rows: Array = []
## The resolution row's [OptionButton], if one was built. Its enabled state tracks the window mode.
var _resolution_button: OptionButton
## Every built [MKRebindRow], across all pages, in build order. Held separately from [member
## _controls] because the global "Reset All Bindings" button must refresh EVERY rebind row — including
## one whose id lost the [method _register_control] race to a duplicate and is therefore absent from
## [member _controls] while still being on screen and still showing a binding.
var _rebind_rows: Array[MKRebindRow] = []
## The ONE device tracker for this panel, created on demand by [method _ensure_input_glyphs] and
## handed to every rebind row. See that method for why it is one and not one per row.
var _input_glyphs: MKInputGlyphs


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the whole UI as unowned
	# children that get saved into whatever scene instanced it.
	if Engine.is_editor_hint():
		return
	if _backend == null:
		_backend = _resolve_backend()
	_connect_backend()
	# Re-showing this page is one of the three edges the resolution row's enabled state is
	# re-evaluated on (see _is_windowed): a window mode changed out of band while the player was in
	# gameplay is only noticed when the settings page comes back up.
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)
	rebuild()


## The explicit wiring seam. A host or a panel container calls this before the panel enters the tree
## (or after, which rebuilds) rather than relying on the ancestor walk in [method _resolve_backend].
##
## Passing null is legal and means "render disabled": see the class doc for why that beats refusing.
func bind_backend(backend: MKSettingsBackend) -> void:
	if backend == _backend:
		return
	_disconnect_backend()
	_backend = backend
	_connect_backend()
	if is_inside_tree() and not Engine.is_editor_hint():
		rebuild()


func get_backend() -> MKSettingsBackend:
	return _backend


## True once [method rebuild] has produced a tab strip. Tests assert against this rather than sleeping
## a frame, and a host embedding the panel can gate its own wiring on it.
func is_built() -> bool:
	return _built


## Duck-typed backend discovery, in the order a host's configurations actually occur.
##
## 1. The [code]MKSettingsService[/code] autoload, which is the supported configuration (plan §4.2) —
##    checked FIRST so a panel inside an [MKRoot] that adopted the service still resolves the same
##    single instance either way.
## 2. Any ancestor exposing [code]get_settings_backend()[/code] — in practice [MKRoot], which owns the
##    backend in the no-autoload configuration.
##
## Duck-typed rather than typed against [MKRoot]: a host embedding this panel in its own options
## screen has no [MKRoot] above it and should not need one, and the method name is the whole contract.
func _resolve_backend() -> MKSettingsBackend:
	var service := get_node_or_null(SETTINGS_SERVICE_PATH)
	if service != null and service.has_method("get_settings_backend"):
		var live: MKSettingsBackend = service.call("get_settings_backend")
		if live != null:
			return live
	var node := get_parent()
	while node != null:
		if node.has_method("get_settings_backend"):
			var found: MKSettingsBackend = node.call("get_settings_backend")
			if found != null:
				return found
		node = node.get_parent()
	return null


func _connect_backend() -> void:
	if _backend == null:
		return
	if not _backend.setting_changed.is_connected(_on_setting_changed):
		_backend.setting_changed.connect(_on_setting_changed)


func _disconnect_backend() -> void:
	if _backend == null or not is_instance_valid(_backend):
		return
	if _backend.setting_changed.is_connected(_on_setting_changed):
		_backend.setting_changed.disconnect(_on_setting_changed)


## An unresolved countdown does not survive its owner. See [method _resolve_orphaned_countdown]: the
## panel is the only thing that knows how to put the value back, so it resolves anything still live
## on its way out.
##
## [b]The backend is disconnected FIRST, and the order is load-bearing.[/b] The teardown revert is a
## real [method MKSettingsBackend.set_value], so with the connection still live it came straight back
## through [method _on_setting_changed] and re-entered [method _sync_control] and
## [method _update_conditional_rows] on a panel that is mid-[method Node._exit_tree] — writing widgets
## that are being freed, from inside the notification that is freeing them. Resolving first was the
## original order and the [code]is_inside_tree()[/code] guard in
## [method _resolve_orphaned_countdown] did not cover it, because that guard is on the panel's OWN
## sync call and not on the one arriving back through the signal.
##
## Nothing in the revert needs the connection: [method _revert_value] calls the backend directly, and
## since the orphan path no longer touches the modal layer there is no second consumer either.
func _exit_tree() -> void:
	_disconnect_backend()
	_resolve_live_countdowns()


# --- Build --------------------------------------------------------------------

## Tears down and rebuilds every tab and row. Idempotent; safe to call after mutating [member pages].
func rebuild() -> void:
	_clear()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if _backend == null:
		# ONE warning for the whole panel, not one per row: a page of twenty rows would otherwise bury
		# every other diagnostic in the log for a single unassigned slot.
		MKLog.warn("%s: no MKSettingsBackend resolved — rows render disabled and nothing is persisted"
			% _context("bind_backend"))

	_tabs = TabContainer.new()
	_tabs.name = "Pages"
	_tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_tabs)

	for i in pages.size():
		var page := pages[i]
		if page == null:
			MKLog.warn("%s: page entry %d is null — skipping it" % [_context("pages"), i])
			continue
		if not page.is_valid():
			MKLog.warn("%s: page entry %d has an empty id — skipping it"
				% [MKLog.context(page, "id"), i])
			continue
		_build_page(page)

	_place_input_glyphs_last()
	_update_conditional_rows()
	_update_resolution_enabled()
	_built = true
	built.emit()


## Enforces the dispatch order [MKInputGlyphs]'s class doc states as a contract: the tracker is this
## panel's LAST child, so [method Node._input]'s reverse-order walk reaches it before any row.
##
## Without this the order INVERTS across a rebuild and nobody notices. A first build creates the
## tracker mid-build, after the tab strip, so it lands last by accident; [method _clear] then frees
## the tab strip but deliberately keeps the tracker, and the next [method rebuild] re-adds "Pages"
## BELOW it — putting the rows first and the tracker behind a listening row's
## [method Viewport.set_input_as_handled].
func _place_input_glyphs_last() -> void:
	if _input_glyphs == null or not is_instance_valid(_input_glyphs):
		return
	if _input_glyphs.get_parent() != self:
		return
	move_child(_input_glyphs, get_child_count() - 1)


func _clear() -> void:
	_controls.clear()
	_defs.clear()
	_pages_of_id.clear()
	_conditional_rows.clear()
	_rebind_rows.clear()
	_resolution_button = null
	if _tabs != null and is_instance_valid(_tabs):
		# remove_child before queue_free: a queued node stays in the tree until end of frame, so a
		# rebuild would briefly have two tab strips both answering focus queries.
		remove_child(_tabs)
		_tabs.queue_free()
	_tabs = null
	_built = false


func _build_page(page: MKSettingsPageDef) -> void:
	var scroll := ScrollContainer.new()
	# TabContainer takes its tab titles from child node names, so the name IS the label. Falling back
	# to the id keeps a title-less page reachable instead of showing a blank tab.
	scroll.name = page.title if not page.title.is_empty() else String(page.id)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	if page.icon != null:
		_tabs.set_tab_icon(_tabs.get_tab_count() - 1, page.icon)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Rows"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(column)

	# Remembered for the duration of this page's rows so _register_control can name the page a
	# duplicate id arrived on. Cleared at the end, so a registration from anywhere else cannot blame a
	# page that had finished building.
	_building_page = page
	var rebinds_before := _rebind_rows.size()
	for i in page.rows.size():
		var def := page.rows[i]
		if def == null:
			MKLog.warn("%s: row %d is null — skipping it" % [MKLog.context(page, "rows"), i])
			continue
		if not def.is_valid():
			MKLog.warn("%s: row %d on page '%s' has no id (or, for a HEADER, no label) — skipping it"
				% [MKLog.context(def), i, page.id])
			continue
		var row := _build_row(def)
		if row == null:
			continue
		column.add_child(row)
		if def.visible_condition_id != &"":
			_conditional_rows.append({"node": row, "condition": def.visible_condition_id})
	# The recovery net, on any page that actually has bindings to recover. Appended below the rows
	# rather than pinned to the panel, because a project can carry rebind rows on more than one page
	# and a button floating outside the tab strip belongs to none of them.
	if _rebind_rows.size() > rebinds_before:
		column.add_child(_build_reset_all_bindings_button())
	_building_page = null


## Records a built control under its id, or refuses and warns when that id is already taken.
##
## [b]First registration wins, and the collision is named.[/b] [member _controls] and [member _defs]
## are keyed by id alone, so two rows sharing one — the ordinary way a page is duplicated and edited —
## used to overwrite each other silently: the LAST row registered received every external sync, every
## revert and every visible_condition lookup, while the first sat on screen answering to nothing. Both
## rows are still built (dropping one would hide the mistake rather than report it); only the tracking
## is refused, and the warning names both pages and the id so the duplicate is findable without
## diffing two resources by eye.
func _register_control(def: MKSettingDef, control: Control) -> void:
	var existing: MKSettingDef = _defs.get(def.id, null)
	if existing != null and existing != def:
		var first: MKSettingsPageDef = _pages_of_id.get(def.id, null)
		MKLog.warn("%s: duplicate setting id '%s' — already registered by page '%s' (%s), seen again on page '%s' (%s). The FIRST row keeps the id; the later one is displayed but receives no syncs or reverts"
			% [MKLog.context(def, "id"), def.id,
				first.id if first != null else "<unknown>", MKLog.context(first),
				_building_page.id if _building_page != null else "<unknown>",
				MKLog.context(_building_page)])
		return
	_controls[def.id] = control
	_defs[def.id] = def
	_pages_of_id[def.id] = _building_page


## Builds one row, or returns null when the def cannot produce one (a KEYBIND naming no action, a
## CUSTOM scene that does not honour the bind contract). Callers skip a null; the warning is issued
## here so it names the offending resource once, where the reason is known.
func _build_row(def: MKSettingDef) -> Control:
	match def.type:
		MKSettingDef.RowType.HEADER:
			return _build_header(def)
		MKSettingDef.RowType.TOGGLE:
			return _wrap(def, _build_toggle(def))
		MKSettingDef.RowType.SLIDER:
			return _build_slider_row(def)
		MKSettingDef.RowType.ENUM:
			return _wrap(def, _build_enum(def))
		MKSettingDef.RowType.TEXT:
			return _wrap(def, _build_text(def))
		MKSettingDef.RowType.KEYBIND:
			return _build_keybind(def)
		MKSettingDef.RowType.CUSTOM:
			return _build_custom(def)
	MKLog.warn("%s: unknown row type %d — skipping row '%s'"
		% [MKLog.context(def, "type"), def.type, def.id])
	return null


func _build_header(def: MKSettingDef) -> Control:
	var label := Label.new()
	label.text = def.label
	MKTheme.set_variation(label, MKTheme.HEADER)
	return label


## The standard row shell: label column on the left, control on the right, so every page reads as one
## aligned table regardless of which control types an author mixed.
func _wrap(def: MKSettingDef, control: Control) -> Control:
	if control == null:
		return null
	var row := HBoxContainer.new()
	row.name = "Row_" + String(def.id).replace("/", "_")

	var label := Label.new()
	label.text = def.label if not def.label.is_empty() else String(def.id)
	label.custom_minimum_size = Vector2(LABEL_COLUMN_WIDTH, 0.0)
	# [b]FILL, not EXPAND_FILL — this is the mechanism behind the slider/enum column drift.[/b] With
	# EXPAND the label was not a COLUMN at all: an HBox splits the row's LEFTOVER width between its
	# expanding children, so the label's final width — and therefore the x its control starts at —
	# was a function of the minimum widths of everything ELSE on that line. Those differ per row type:
	# a SLIDER row appends a 72px readout this wrap never sees, and an OptionButton's minimum width is
	# its widest option's text while an HSlider's is a groove. So no two row types resolved the same
	# label width, and the "one aligned table" this shell exists to produce was aligned only within a
	# type. Without EXPAND the label is LABEL_COLUMN_WIDTH on every row, unconditionally.
	# (The DIRECTION of the old drift is a measurement, not an argument — the round-2 NIT recorded
	# slider controls sitting left of enum ones; the widths above say why any difference at all was
	# possible.)
	label.size_flags_horizontal = Control.SIZE_FILL
	MKTheme.set_variation(label, MKTheme.ROW_LABEL)
	row.add_child(label)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

	if not def.tooltip.is_empty():
		# Set on the row, not only the control: the label is the larger hit area and a tooltip that
		# only appears over a 20px checkbox is one most users never find.
		row.tooltip_text = def.tooltip
		control.tooltip_text = def.tooltip
	_register_control(def, control)
	return row


func _build_toggle(def: MKSettingDef) -> Control:
	var check := CheckBox.new()
	check.text = ""
	check.button_pressed = _display_value(def)
	check.disabled = _backend == null
	check.toggled.connect(func(pressed: bool) -> void:
		if _syncing:
			return
		_write(def, pressed)
	)
	return check


## SLIDER rows return their own shell rather than routing through [method _wrap], because the slider
## carries a live value readout and, for brightness, a calibration swatch beneath it.
func _build_slider_row(def: MKSettingDef) -> Control:
	var slider := HSlider.new()
	slider.min_value = def.min_value
	slider.max_value = def.max_value
	slider.step = def.step
	slider.value = _display_value(def)
	slider.editable = _backend != null
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var readout := Label.new()
	readout.text = _format_number(slider.value)
	readout.custom_minimum_size = Vector2(72.0, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	MKTheme.set_variation(readout, MKTheme.ROW_LABEL)

	slider.value_changed.connect(func(value: float) -> void:
		# The readout updates even while syncing — it is a display of the slider, not a write.
		readout.text = _format_number(value)
		if _syncing:
			return
		_write(def, value)
	)

	_add_focus_ring(slider)

	var row := _wrap(def, slider)
	if row == null:
		return null
	# Appended after the control so the readout sits on the far right of the same line.
	row.add_child(readout)

	if def.id != ID_BRIGHTNESS:
		return row
	return _with_brightness_swatch(def, row, slider)


## Gives [param slider] a visible focus indicator, because [HSlider] has no focus StyleBox of its
## own: the engine's Slider theme defines the groove, the grabber and its highlight and nothing that
## changes when focus arrives. A keyboard or gamepad player traversing a settings page therefore had
## no way to tell which slider the arrow keys were about to move — the D12 promise with the one
## control type that cannot honour it.
##
## The ring is a [Panel] child of the slider carrying [constant MKTheme.FOCUS_RING], the variation
## the generated Theme has always defined and nothing consumed. Variation mechanics only: no
## [code]add_theme_*_override[/code] (ship gate 1), so a host swapping [MKPalette] restyles this ring
## with everything else.
##
## Parented to the slider (not the row) so the ring tracks the CONTROL's rect rather than the whole
## labelled line, and grown by [constant FOCUS_RING_GROW] so it traces the groove instead of sitting
## on it. [constant Control.MOUSE_FILTER_IGNORE] so it never eats a drag on the slider beneath it.
func _add_focus_ring(slider: HSlider) -> void:
	var ring := Panel.new()
	ring.name = "FocusRing"
	MKTheme.set_variation(ring, MKTheme.FOCUS_RING)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.offset_left = -FOCUS_RING_GROW
	ring.offset_top = -FOCUS_RING_GROW
	ring.offset_right = FOCUS_RING_GROW
	ring.offset_bottom = FOCUS_RING_GROW
	ring.visible = false
	slider.add_child(ring)
	slider.focus_entered.connect(func() -> void: ring.visible = true)
	slider.focus_exited.connect(func() -> void: ring.visible = false)


## Brightness gets a reference gradient beneath the slider (plan §4.3): a brightness control with no
## calibration target is unusable by construction — "drag until the dark end is barely visible" is the
## only instruction that works across monitors, and it needs something to look at.
##
## The gradient is built in code from a [GradientTexture2D]; no external asset, so the isolation rule
## (§3) is untouched.
##
## Shown while the user is adjusting: [signal Slider.drag_started]/[signal Slider.drag_ended] cover
## the mouse, and focus covers keyboard and gamepad, which emit no drag signals at all — without the
## focus half the swatch would be permanently invisible to a controller player, in a package whose
## D12 promise is full gamepad navigation.
func _with_brightness_swatch(def: MKSettingDef, row: Control, slider: HSlider) -> Control:
	var column := VBoxContainer.new()
	column.name = "Row_" + String(def.id).replace("/", "_") + "_Calibrated"
	column.add_child(row)

	var gradient := Gradient.new()
	gradient.set_color(0, Color.BLACK)
	gradient.set_color(1, Color.WHITE)
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 512
	texture.height = 1
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(1.0, 0.0)

	var swatch := TextureRect.new()
	swatch.name = "CalibrationSwatch"
	swatch.texture = texture
	swatch.stretch_mode = TextureRect.STRETCH_SCALE
	swatch.custom_minimum_size = Vector2(0.0, 28.0)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	swatch.visible = false
	column.add_child(swatch)

	var hint := Label.new()
	hint.name = "CalibrationHint"
	hint.text = "Adjust until the dark end of the strip is only just visible."
	hint.visible = false
	MKTheme.set_variation(hint, MKTheme.ROW_LABEL)
	column.add_child(hint)

	var show := func(visible_now: bool) -> void:
		swatch.visible = visible_now
		hint.visible = visible_now
	slider.drag_started.connect(func() -> void: show.call(true))
	slider.drag_ended.connect(func(_changed: bool) -> void: show.call(false))
	slider.focus_entered.connect(func() -> void: show.call(true))
	slider.focus_exited.connect(func() -> void: show.call(false))
	return column


func _build_enum(def: MKSettingDef) -> Control:
	var button := OptionButton.new()
	button.disabled = _backend == null

	var labels: Array[String] = []
	var values: Array = []
	if def.id == ID_RESOLUTION:
		_collect_resolution_choices(def, labels, values)
	else:
		_collect_choices(def, labels, values)

	if labels.is_empty():
		MKLog.warn("%s: enum row '%s' has no options — it would render as an empty dropdown"
			% [MKLog.context(def, "options"), def.id])

	for i in labels.size():
		button.add_item(labels[i], i)
	var current: Variant = _current(def)
	var selected := _index_of_value(values, current)
	if selected >= 0:
		button.select(selected)
	elif not labels.is_empty():
		# The stored value is not on the list — a curated list that changed, or a hand-edited file.
		# Selecting nothing renders a blank dropdown that looks broken, so select the first entry and
		# say why; the store is NOT rewritten, because silently replacing a user's value is worse.
		button.select(0)
		MKLog.debug("stored value %s for '%s' is not among its options — showing the first entry"
			% [current, def.id])

	button.item_selected.connect(func(index: int) -> void:
		if _syncing:
			return
		if index < 0 or index >= values.size():
			return
		_write(def, values[index])
	)
	if def.id == ID_RESOLUTION:
		_resolution_button = button
	return button


func _collect_choices(def: MKSettingDef, labels: Array[String], values: Array) -> void:
	for i in def.options.size():
		labels.append(def.options[i])
		# option_values is positional and may be shorter than (or absent from) options, in which case
		# the display string IS the value — which is what a plain string choice wants and saves an
		# author authoring the same list twice.
		values.append(def.option_values[i] if i < def.option_values.size() else def.options[i])
	# Surplus values have no label, so they cannot be rendered as entries and are dropped. Said out
	# loud, and NAMING the def: a value list longer than its label list is an editing slip (a row
	# deleted from one array only), and the symptom without this line is a choice that is simply absent
	# from the dropdown with nothing anywhere to explain it. Debug rather than a warning — it is not a
	# broken page, and the resolution row's own collector treats the same shape as normal by design.
	if def.option_values.size() > def.options.size():
		MKLog.debug("%s: enum row '%s' authored %d option_values but only %d options — the %d surplus value(s) have no label and are not offered"
			% [MKLog.context(def, "option_values"), def.id, def.option_values.size(),
				def.options.size(), def.option_values.size() - def.options.size()])


## The resolution row's options are a curated [Vector2i] list on the def, filtered to what fits the
## current screen, with the native size always present (plan §4.3, finding F4).
##
## Godot 4 exposes no "list the supported modes" API — only [method DisplayServer.screen_get_size] —
## so enumeration is authored data plus this filter, not a query. Under the headless driver every
## screen query is meaningless, so the curated list passes through unfiltered rather than being
## filtered against a phantom 0x0 screen, which would empty the dropdown in the test suite.
## [b]Authored labels are USED, positionally.[/b] [member MKSettingDef.options] is optional on this row
## — the size is the whole meaning, and formatting it is a better default than making every host spell
## "1920 x 1080" twice — but a host that DID author labels ("1920 x 1080 (Native)", a localised
## string) had them silently discarded and the formatted string shown instead. So the candidate list
## is [member MKSettingDef.option_values] in full, and each one takes its authored label when the
## arrays line up at that index and the formatted fallback otherwise. Nothing is dropped for being
## unlabelled and nothing warns about it: on THIS row a longer values array is the normal shape, not
## the drift [method _collect_choices] reports. Surplus LABELS are the other direction and ARE
## reported, because a label past the end of the values array is attached to no size and is simply
## lost — the same editing slip, and silence about it was an asymmetry rather than a policy.
func _collect_resolution_choices(def: MKSettingDef, labels: Array[String], values: Array) -> void:
	var candidates: Array = def.option_values.duplicate()
	# Keyed by the value rather than carried by index: the filtering below drops candidates and appends
	# the native size, so positions do not survive to the emit loop.
	var authored: Dictionary = {}
	for i in candidates.size():
		if i < def.options.size() and not def.options[i].is_empty():
			# Keyed by value, so a repeated size collapses onto one key and the LAST label wins. Behaviour
			# kept — one entry per distinct size is what the dropdown wants either way — but said out loud
			# and NAMING the def, because the symptom otherwise is an authored label that simply never
			# appears with nothing anywhere to explain it.
			if authored.has(candidates[i]) and authored[candidates[i]] != def.options[i]:
				MKLog.debug("%s: resolution row '%s' authors %s twice with different labels ('%s' then '%s') — one entry is offered and the LAST label wins"
					% [MKLog.context(def, "option_values"), def.id, candidates[i],
						authored[candidates[i]], def.options[i]])
			authored[candidates[i]] = def.options[i]
	# The MIRROR of the surplus-values line _collect_choices prints, at the same level and for the same
	# reason. On this row a longer VALUES array is the normal shape, so nothing is said about it — but a
	# longer LABELS array is the same editing slip in the other direction, and its trailing labels are
	# attached to no candidate and vanish. Reporting only one direction is how that stayed invisible.
	if def.options.size() > candidates.size():
		MKLog.debug("%s: resolution row '%s' authored %d labels but only %d option_values — the %d trailing label(s) belong to no size and are not shown"
			% [MKLog.context(def, "options"), def.id, def.options.size(), candidates.size(),
				def.options.size() - candidates.size()])

	var screen := Vector2i.ZERO
	if not _is_headless():
		screen = DisplayServer.screen_get_size()

	var accepted: Array = []
	for candidate in candidates:
		if not (candidate is Vector2i):
			MKLog.warn("%s: resolution option %s is not a Vector2i — ignoring it"
				% [MKLog.context(def, "option_values"), candidate])
			continue
		var size := candidate as Vector2i
		if screen.x > 0 and screen.y > 0 and (size.x > screen.x or size.y > screen.y):
			continue
		accepted.append(size)
	# The native size is ALWAYS offered, even when the curated list omits it: a user on a resolution
	# nobody thought to author would otherwise have no way back to their own display's size.
	if screen.x > 0 and screen.y > 0 and not accepted.has(screen):
		accepted.append(screen)

	for size in accepted:
		labels.append(authored.get(size, "%d x %d" % [size.x, size.y]))
		values.append(size)


func _build_text(def: MKSettingDef) -> Control:
	var edit := LineEdit.new()
	edit.text = _display_value(def)
	edit.editable = _backend != null
	# Committed on Enter AND on focus loss. Writing per keystroke would fire a store write and an
	# engine apply on every character; committing only on Enter loses the edit of anyone who tabs away,
	# which is most people.
	#
	# Both routes go through _commit_text, which drops a commit that would write the value already in
	# the store: focus_exited fires on every tab-through of an untouched field, and on a
	# requires_confirm TEXT row an unconditional write there raises a revert countdown over a change
	# the user never made.
	edit.text_submitted.connect(func(_text: String) -> void: _commit_text(def, edit))
	edit.focus_exited.connect(func() -> void: _commit_text(def, edit))
	return edit


## Writes a TEXT row's field, unless nothing changed. Compared against the STORE rather than against
## a remembered last-commit, so a [method _sync_control] that rewrote the field from outside (a
## revert, a host write) leaves the row agreeing with the store instead of poised to re-commit.
func _commit_text(def: MKSettingDef, edit: LineEdit) -> void:
	if _syncing:
		return
	var as_text: String = _display_value(def)
	if edit.text == as_text:
		return
	_write(def, edit.text)


## [constant MKSettingDef.RowType.CUSTOM]: instantiate the host's scene and hand it the backend.
##
## The contract (plan §4.3, finding M7) is one method on the scene root:
## [code]_mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void[/code]. It is called
## immediately after instantiation — before the row is parented — so the scene can size itself from
## the value it reads.
##
## A root without the method is skipped with a named warning and freed. Adding it anyway would put an
## unbound control on screen that silently discards every change, which is the worst available outcome
## and the exact failure M7 was raised about.
func _build_custom(def: MKSettingDef) -> Control:
	if def.custom_scene == null:
		MKLog.warn("%s: CUSTOM row '%s' has no custom_scene — skipping it"
			% [MKLog.context(def, "custom_scene"), def.id])
		return null
	var inst := def.custom_scene.instantiate()
	if not inst.has_method("_mk_bind"):
		MKLog.warn("%s: CUSTOM row '%s' root does not implement _mk_bind(backend, def) — skipping it. See mk_example_custom_row.gd"
			% [MKLog.context(def, "custom_scene"), def.id])
		inst.free()
		return null
	# The Control check precedes the bind: _mk_bind is where a row reads the store, wires signals and
	# may register itself with the host, and running all of that on an instance this method is about
	# to free leaves those side effects behind with nothing on screen to show for them.
	var control := inst as Control
	if control == null:
		MKLog.warn("%s: CUSTOM row '%s' root is a %s, not a Control — skipping it"
			% [MKLog.context(def, "custom_scene"), def.id, inst.get_class()])
		inst.free()
		return null
	inst.call("_mk_bind", _backend, def)
	_register_control(def, control)
	return control


# --- Keybinds -----------------------------------------------------------------

## [constant MKSettingDef.RowType.KEYBIND]: one [MKRebindRow], which is its own labelled shell.
##
## It does NOT route through [method _wrap]. The row owns a label plus one button per binding and
## swaps that button into a "press a key" state during capture, so the shell has to be the row's — a
## panel-owned label column beside a control that is itself a labelled row would render the name
## twice.
##
## [b]An empty [member MKSettingDef.action_name] is an authoring error, not a degraded row.[/b] There
## is no binding to show, no key to capture into and nothing to reset; the row would be a button that
## does nothing, which is worse than an absent row plus a warning that names the resource.
##
## Registered through [method _register_control] like a [constant MKSettingDef.RowType.CUSTOM] row:
## registration is what gives it duplicate-id refusal and [member MKSettingDef.visible_condition_id]
## participation. It does NOT sign the row up for value syncs — see [method _sync_control], which
## excludes this type outright.
func _build_keybind(def: MKSettingDef) -> Control:
	if def.action_name == &"":
		MKLog.warn("%s: KEYBIND row '%s' names no action — skipping it. A rebind row with no action has no binding to show, capture or reset"
			% [MKLog.context(def, "action_name"), def.id])
		return null
	if def.requires_confirm:
		# D14's confirm-or-revert machinery is built entirely on the scalar value store (capture the
		# previous value, write, apply, put it back on timeout). A binding lives in the INPUT store
		# instead, which that path cannot read or restore, so honouring the flag here would raise a
		# countdown that reverts nothing. Ignored and said out loud rather than silently obeyed-and-broken.
		MKLog.debug("%s: KEYBIND row '%s' sets requires_confirm — ignored. Confirm-or-revert operates on the value store, and a binding is not in it; the row's own abort (Escape) and Reset are its undo"
			% [MKLog.context(def, "requires_confirm"), def.id])

	var row := MKRebindRow.new()
	row.name = "Row_" + String(def.id).replace("/", "_")
	# No tooltip write here: setup() below assigns it unconditionally (empty clears), and a second,
	# conditional write above it was the same stale-tooltip shape the round-1 n3 fix removed.
	# Registered BEFORE setup, so a duplicate id is reported against the row that is about to go on
	# screen rather than after it has already wired itself to the backend.
	_register_control(def, row)
	# A null backend is passed through rather than skipping the row, which is the policy every other
	# row type here follows (see rebuild(): ONE warning per panel, then rows render disabled). A page
	# that loses half its rows to an unassigned backend slot looks like a missing resource; a page of
	# visibly disabled rows looks like what it is.
	row.setup(def, _backend, _find_modal_layer(), Callable(self, "_managed_rebind_actions"),
		_reserved_input_events(), _ensure_input_glyphs())
	# One capture at a time, enforced HERE because rows cannot see each other. Without this, two rows
	# both listening would both consume the same press in _input — in tree order, so the first row
	# records it and the second keeps listening for a key the user believes was just taken — and both
	# prompts would be on screen claiming the whole keyboard.
	row.capture_state_changed.connect(func(listening: bool) -> void:
		if listening:
			_end_other_captures(row)
	)
	# The Replace outcome of a conflict rewrites an action some OTHER row displays; the emitting row
	# cannot reach it, so the panel redraws them all. Every rebind row, not the one whose action
	# matches: the set is small, refresh_display() is a read-and-repaint, and matching by action here
	# would quietly miss two defs naming one action.
	row.binding_changed.connect(func(_action: StringName) -> void:
		_refresh_rebind_rows()
	)
	_rebind_rows.append(row)
	return row


## The panel's single [MKInputGlyphs], created the first time a KEYBIND row asks for one and reused
## for the panel's whole life.
##
## [b]One per PANEL, not one per row.[/b] The tracker exists to answer "keyboard or pad" from
## [method Node._input], and that answer is identical for every row on the page — seven trackers
## would be seven dispatches per event producing seven copies of one boolean. Created lazily so a
## panel with no keybind rows (the addon's own four shipped pages have none) mounts no input handler
## at all.
##
## [b]It survives [method _clear].[/b] Rebuilds free and rebuild every row, and a tracker rebuilt with
## them would reset to its keyboard default — silently relabelling a pad player's prompts every time
## the panel refreshed. The rows are handed the surviving instance instead.
##
## Never marks input handled ([MKInputGlyphs] documents that as a contract), so mounting it cannot
## take a press away from a listening [MKRebindRow] below it. Where it sits among this panel's
## children is not left to the order it happened to be created in — see
## [method _place_input_glyphs_last], which is where this panel discharges the tracker's
## dispatch-order guarantee.
func _ensure_input_glyphs() -> MKInputGlyphs:
	if _input_glyphs != null and is_instance_valid(_input_glyphs):
		return _input_glyphs
	_input_glyphs = MKInputGlyphs.new()
	_input_glyphs.name = "InputGlyphs"
	add_child(_input_glyphs)
	return _input_glyphs


## Redraws every rebind row from the store. A row mid-capture keeps its prompt — refresh_display()
## itself protects the listening button text.
func _refresh_rebind_rows() -> void:
	for row in _rebind_rows:
		if row != null and is_instance_valid(row):
			row.refresh_display()


## Ends every live capture except [param keep]'s. The signal connection above makes this run the
## moment any row starts listening, which is what makes "at most one row is ever listening" a panel
## invariant rather than a hope.
func _end_other_captures(keep: MKRebindRow) -> void:
	for row in _rebind_rows:
		if row == keep or row == null or not is_instance_valid(row):
			continue
		if row.is_listening():
			row.abort_listen()


## Every action this panel rebinds, across ALL pages, deduped — handed to each row as a [Callable] so
## it is answered at CAPTURE time rather than at build time.
##
## That timing is the point: it is the conflict-detection set, and a row capturing a key needs to know
## whether that key is already bound to another action MenuKit manages so it can say so (or clear the
## loser) instead of silently leaving two actions on one key. Answering from [member _defs] means the
## set covers rows built after this one, which a snapshot taken during the first page's build could
## not.
##
## Only MANAGED actions are listed. Actions the project defines but no row rebinds are deliberately
## absent: MenuKit cannot offer to fix a conflict with a binding it has no row for, and reporting one
## the user cannot act on is noise.
func _managed_rebind_actions() -> Array[StringName]:
	var actions: Array[StringName] = []
	for id in _defs.keys():
		var def: MKSettingDef = _defs[id]
		if def == null or def.type != MKSettingDef.RowType.KEYBIND:
			continue
		if def.action_name == &"" or actions.has(def.action_name):
			continue
		actions.append(def.action_name)
	return actions


## Events a rebind row must refuse to capture (plan §4.4).
##
## [b]The list is short on purpose, and keyboard Escape is deliberately NOT on it.[/b] Escape is
## unbindable by MECHANISM: it is the row's abort gesture, so a press of it ends the capture and never
## reaches the commit — putting it on this list as well would be dead code that reads as the reason
## Escape cannot be bound, and the next reader would "fix" the mechanism trusting the list.
##
## What the list IS for is the hazard the mechanism does not cover: the non-keyboard bindings of
## [code]ui_cancel[/code] — in practice the gamepad B button. That one closes menus everywhere in the
## shell, so a player who binds it to Jump can no longer back out of the settings page they bound it
## on, with a controller as their only input device. There is no keyboard-Escape equivalent of that
## trap for them to escape through.
##
## [b]Derived from the BOOT DEFAULT [code]ui_cancel[/code] bindings, not the live ones.[/b] The live
## [InputMap] is exactly what these rows edit: once a session had rebound something onto B, reading
## live would report the NEW binding as the reserved one and let the menu-back button itself be taken.
## The boot snapshot is the fixed statement of what the menu is driven by.
##
## A store-only backend answers [method MKSettingsBackend.get_default_action_events] with the base
## class's empty list, so the derived part is simply absent there — which costs the joypad-B guard
## and nothing else; [member extra_reserved_events] is still honoured, so a host on such a backend
## can state the hazard itself.
func _reserved_input_events() -> Array[InputEvent]:
	var reserved: Array[InputEvent] = []
	if _backend != null:
		for event in _backend.get_default_action_events(&"ui_cancel"):
			# Keyboard events are excluded, not because Escape is allowed, but because the row's abort
			# already makes it unreachable — see the doc above.
			if event != null and not (event is InputEventKey):
				reserved.append(event)
	for extra in extra_reserved_events:
		if extra != null:
			reserved.append(extra)
	return reserved


## The recovery net (plan §4.4): one button that puts every managed binding back to its boot default.
##
## [b]Focusable and PANEL_BUTTON-styled, deliberately.[/b] The user most likely to need this is one
## who has just bound something over the key they were navigating with, so the button has to be
## reachable by mouse AND by gamepad — a mouse-only recovery path is no recovery path for a controller
## player, which is the case that produces the state this button exists to undo.
##
## [b]No confirmation dialog, and that is a choice rather than an omission.[/b] A destructive global
## action normally earns one; this one does not, because a confirm dialog is one more thing the user
## must drive with input they may have just broken, and its cost — re-pressing seven keys they chose
## on purpose — is fully recoverable by hand. If this ever grows a confirm, it must be reachable by
## every input device the reset itself is.
func _build_reset_all_bindings_button() -> Button:
	var button := Button.new()
	button.name = "ResetAllBindings"
	button.text = "Reset All Bindings"
	button.focus_mode = Control.FOCUS_ALL
	button.size_flags_horizontal = Control.SIZE_SHRINK_END
	button.disabled = _backend == null
	button.tooltip_text = "Restores every key binding on this page to the game's defaults."
	MKTheme.set_variation(button, MKTheme.PANEL_BUTTON)
	button.pressed.connect(_reset_all_bindings)
	return button


## Drops every override, re-applies each managed action, then redraws every row.
##
## All three steps are needed and in this order. [method MKSettingsBackend.reset_all_actions_to_defaults]
## is a STORE operation; the shipped backend also restores the live [InputMap] for the actions that
## HAD an override, but the panel cannot assume that of a host backend, so each managed action is
## pushed explicitly through [method MKSettingsBackend.apply_action] — which is idempotent and, on an
## action with no override, applies the boot snapshot, which is precisely what a reset wants. The
## refresh comes last, so every row reads a store and an engine that already agree.
##
## On a store-only backend [method MKSettingsBackend.reset_all_actions_to_defaults] is the base
## class's no-op, so the recovery path degrades there the same way the rows themselves do: visibly
## inert, never wrong.
##
## [b]One press can log the "no boot snapshot" warning TWICE for the same action, and that is
## accepted.[/b] The two sites are the backend's own restore inside
## [method MKSettingsBackend.reset_all_actions_to_defaults] and the explicit
## [method MKSettingsBackend.apply_action] below; both warn when an action carries an override but no
## snapshot. That state is only reachable when the §4.2 host contract has ALREADY been breached
## (snapshot_input_defaults() never ran, or ran after the override existed), so the duplicate appears
## exclusively in a run that is being diagnosed by that very warning — where two lines are noise, not
## a wrong answer. Deduping would mean the panel asking the backend whether a snapshot exists before
## deciding to apply, which couples this method to snapshot internals the abstract
## [MKSettingsBackend] deliberately does not expose, to tidy the log of an already-broken boot.
func _reset_all_bindings() -> void:
	if _backend == null:
		return
	_backend.reset_all_actions_to_defaults()
	for action in _managed_rebind_actions():
		_backend.apply_action(action)
	for row in _rebind_rows:
		if row != null and is_instance_valid(row):
			row.refresh_display()


# --- Values -------------------------------------------------------------------

func _current(def: MKSettingDef) -> Variant:
	if _backend == null:
		return def.default_value
	return _backend.get_value(def.id, def.default_value)


## The store's value for [param def], coerced to what that row's control can be assigned.
##
## [b]ONE helper for the build path and [method _sync_control], and that is the whole point.[/b]
## [code]bool(null)[/code] and [code]float(null)[/code] are SCRIPT ERRORS, not coercions. The build
## path carried the guards; the sync path did not, so once every external write was routed into
## [method _sync_control] a host calling [code]set_value(id, null)[/code] — a reset-to-unset, a load
## of a file with a null in it — took the panel down on a TOGGLE or SLIDER row the build path had
## already been taught to survive. Two copies of a coercion rule is how they diverge, so there is one.
##
## The fallbacks are the build path's, unchanged: TOGGLE false, SLIDER the def's own minimum (which
## [Range] would clamp to anyway), TEXT the empty string. ENUM has no coercion of its own and gets the
## stored value untouched — [method _index_of_value] is type-gated and handles null by simply not
## matching. [constant MKSettingDef.RowType.CUSTOM] never arrives here: nothing in this panel reads or
## writes a custom row's display (see [method _sync_control]), so there is no widget to coerce for.
## [constant MKSettingDef.RowType.KEYBIND] never arrives either, and by the same two routes: it is
## excluded from [method _sync_control], and the build path does not call this — a rebind row reads
## the input store, not the value store. Nor can it reach [method _write] or the D14 countdown, which
## are entered only from the signal handlers of the widgets THIS panel builds, and it is not one of
## them.
func _display_value(def: MKSettingDef) -> Variant:
	var current: Variant = _current(def)
	match def.type:
		MKSettingDef.RowType.TOGGLE:
			return bool(current) if current != null else false
		MKSettingDef.RowType.SLIDER:
			return float(current) if current != null else def.min_value
		MKSettingDef.RowType.TEXT:
			return String(current) if current != null else ""
	return current


## The one write path. Store, then apply — in that order, because the store is the truth and the
## engine call is its consequence; applying first would leave the two disagreeing if the write were
## ever rejected.
##
## [method MKSettingsBackend.apply_one] is targeted rather than [method MKSettingsBackend.apply_all]:
## a slider drag emits per pixel, and re-pushing every window, bus and InputMap value at the engine on
## each of those is both slow and a source of visible window flicker.
func _write(def: MKSettingDef, value: Variant) -> void:
	if _backend == null:
		return
	if not def.requires_confirm:
		_backend.set_value(def.id, value)
		_backend.apply_one(def.id)
		return
	# Capture BEFORE the write: after set_value the previous value is gone, and the countdown's entire
	# job is to put it back.
	var previous: Variant = _backend.get_value(def.id, def.default_value)
	_backend.set_value(def.id, value)
	_backend.apply_one(def.id)
	_start_revert_countdown(def, previous)


## D14: apply, then ask. A display change that leaves the user unable to see the screen also leaves
## them unable to click Undo, so the revert runs on a timer rather than on a button.
##
## The countdown is pushed as a modal through the [MKModalLayer] the shell already owns, so it dims
## the page, traps focus, and takes cancel ahead of the page back stack like every other modal. It
## runs under [member SceneTree.paused] because the whole [MKRoot] subtree is
## [constant Node.PROCESS_MODE_ALWAYS] (plan §4.2a) — without that it would freeze open forever when
## opened from the pause menu, with no failing write to reveal it.
##
## With no modal layer reachable (a host embedding this panel bare) the change simply stays applied
## and one warning names the gap. Reverting silently instead would undo a change the user asked for
## and never saw questioned.
## [b]One live countdown per setting id, and it keeps the FIRST unconfirmed value.[/b] A second
## change to the same row while its countdown is up used to push a SECOND dialog carrying the
## intermediate value as its [code]previous[/code]: two scrimmed dialogs over one row, and — because
## the first one is still ticking underneath — a player who pressed Keep on the second still had the
## first lapse a moment later and drag the setting back to the value it had shown, over the change
## they had just confirmed.
##
## Replacement rather than a second dialog: the existing countdown's timer is RESTARTED (the user just
## acted, so they get the full window again to react to what they can now see) and its
## [code]previous[/code] is deliberately left alone. A→B→C reverting to A is the correct chain — B was
## never confirmed either, so restoring it would restore a value the user never agreed to keep.
##
## Different ids stay independent: each def's revert is its own, and a window-mode countdown has
## nothing to say about a resolution change.
func _start_revert_countdown(def: MKSettingDef, previous: Variant) -> void:
	for entry in _live_countdowns:
		var live_def: MKSettingDef = entry["def"]
		if live_def == null or live_def.id != def.id:
			continue
		var live_countdown: Variant = entry["countdown"]
		if live_countdown == null or not is_instance_valid(live_countdown):
			# A dialog that was freed without resolving. Drop the stale bookkeeping and fall through to
			# raise a fresh one rather than restarting a corpse, which would leave the change unguarded.
			_live_countdowns.erase(entry)
			break
		live_countdown.call("start", REVERT_SECONDS)
		return

	var layer := _find_modal_layer()
	if layer == null:
		MKLog.warn("%s: '%s' requires confirmation but no MKModalLayer is reachable — the change stays applied without a countdown"
			% [MKLog.context(def, "requires_confirm"), def.id])
		return
	var countdown := MKRevertCountdown.new()
	countdown.name = "RevertCountdown"
	var entry := {"countdown": countdown, "def": def, "previous": previous, "layer": layer}
	_live_countdowns.append(entry)
	countdown.kept.connect(func() -> void:
		_live_countdowns.erase(entry)
		_dismiss_countdown(layer, countdown)
	)
	countdown.reverted.connect(func() -> void:
		_live_countdowns.erase(entry)
		# Read from the ENTRY rather than from the captured `previous` local. Stated honestly: this is a
		# STYLE choice with no behavioural difference today. entry["previous"] is written once, at
		# construction, and never mutated anywhere, so the entry read and the closure capture are the
		# same value on every path — there is no test that can tell them apart, and none is pretended.
		# What it buys is one place to look: the entry is where the orphan/teardown route already reads
		# the target value from, so if a future path ever DOES rewrite an entry's previous (a revision of
		# the same-def replacement rule above is the obvious candidate), both routes follow it instead of
		# this one silently keeping the value the lambda closed over.
		_revert_value(def, entry["previous"])
		# Put the CONTROL back too. The store and the engine are restored above, but a dropdown still
		# reading the rejected value is the shape of this bug that users report as "it didn't revert".
		_sync_control(def)
		_dismiss_countdown(layer, countdown)
	)
	# The dialog leaving the tree without having resolved is the D14 hole this closes: see
	# _resolve_orphaned_countdown. Connected AFTER the decision signals so a normal resolution has
	# already cleared the entry by the time the unparenting reaches here.
	countdown.tree_exited.connect(func() -> void: _resolve_orphaned_countdown(entry))
	layer.push_modal(countdown)
	countdown.start(REVERT_SECONDS)


## Puts a [member MKSettingDef.requires_confirm] value back through the store and the engine. Split
## out of the [signal MKRevertCountdown.reverted] handler because it is also the whole of what a
## teardown revert can do — by then the widgets are dying, but the STORE is the part that outlives the
## panel and the part D14 actually promises.
func _revert_value(def: MKSettingDef, previous: Variant) -> void:
	if _backend == null or not is_instance_valid(_backend):
		return
	_backend.set_value(def.id, previous)
	_backend.apply_one(def.id)


## [b]An unresolved countdown resolves as REVERTED when it or its panel goes away.[/b]
##
## D14's promise is that a display change nobody confirmed does not stick. But the dialog is only a
## dialog: [code]MKRoot._show_page[/code] calls [method MKModalLayer.pop_all] on EVERY page change, so
## clicking a nav tab while the countdown was up unparented it — its [method Node._process] stopped,
## nothing ever emitted, the panel was freed a moment later, and the un-confirmed change stayed applied
## forever. One click voided the entire promise, and leaked a Control doing it.
##
## Unconfirmed means NOT kept, so both departures resolve the same way: the value goes back. Reached
## from two directions because the two orders both really happen —
## [br]- the dialog leaves the tree first ([method MKModalLayer.pop_all], a host popping it), via its
##   own [signal Node.tree_exited];
## [br]- the panel dies first with the dialog still stacked, via [method _exit_tree].
## Whichever arrives first erases the entry, so the other is a no-op.
##
## [b]This path never touches the modal stack SYNCHRONOUSLY, and that is the whole of its second
## contract.[/b] It used to call [method MKModalLayer.remove_modal] inline, which is a real pop: on
## [code]MKRoot.queue_free()[/code] the panel's [method Node._exit_tree] runs BEFORE the root's
## (exit propagates children first), so that pop emitted [signal MKModalLayer.modal_popped] and
## [signal MKModalLayer.emptied] DURING teardown — driving MKRoot's suspend counter to its 1→0 edge,
## calling [method MKPausePolicy.exit_menu] on a policy already out of the tree, and restoring the
## GAMEPLAY cursor onto the menu that is about to be shown. Every one of those is the failure
## [method MKModalLayer.clear_for_teardown] exists to prevent, routed around it by its own caller.
##
## So disposal is decided by ownership instead:
## [br]- [b]Off the stack[/b] — the [method MKModalLayer.pop_all] on a page change already let go of
##   it — nobody else will ever free it, so this frees it, here and now.
## [br]- [b]Still stacked[/b] — disposal belongs to the LAYER, and this path only asks for it: the
##   dialog is marked resolved (it stops ticking, emits nothing more, and declines any later cancel)
##   and [method MKModalLayer.reap_modal] is scheduled with [method Object.call_deferred]. Freeing it
##   here would leave a corpse wedged in the layer's stack; popping it here would emit, and this code
##   runs on teardown paths where an emission is the hazard described above.
##
## [b]The deferral is what tells the two "still stacked" situations apart, and it does so without a
## discriminator on this side.[/b] Read [method MKModalLayer.reap_modal] for the mechanism; the
## outcomes are:
## [br]- [b]The shell is going away[/b] — [code]MKRoot.queue_free()[/code],
##   [method Node.free], a [SceneTree] scene change, engine shutdown. The layer is destroyed before
##   the deferred call can flush, Godot drops calls to freed objects, and the dialog goes with the
##   layer's own subtree. Nothing is emitted, which is the whole requirement. Where the layer DOES
##   survive to the flush while doomed (a host that detaches the shell before queueing it),
##   [method MKModalLayer.reap_modal]'s own teardown guard declines and
##   [method MKModalLayer.clear_for_teardown] disposes of the dialog through
##   [code]_mk_layer_teardown[/code].
## [br]- [b]The shell is ALIVE and only the panel died[/b] (a host tearing down its options screen, a
##   page rebuild). The reap arrives on a live layer and pops for real. That is not a hazard here, it
##   is the requirement: the emissions unwind MKRoot's suspend depth and its mouse mode, which the
##   push had raised. Leaving the dialog stacked instead left a live
##   [constant Node.PROCESS_MODE_ALWAYS] countdown repainting and about to emit
##   [signal MKRevertCountdown.reverted] into a dropped connection, trapping focus, holding that
##   suspension, swallowing the Escape AND the Keep click of a user looking at it — and after its
##   cancel was finally declined it was unparented rather than freed: one leaked Control per event.
##
## The cost of the deferral is one frame of a marked, inert corpse on the stack, and it is paid for
## rather than merely tolerated: [method MKRevertCountdown.mark_resolved] has already stopped its
## [method Node._process] and latched its signals, so it cannot tick, lapse or emit in that window,
## and an Escape landing there is DECLINED — which routes the gesture to
## [method MKModalLayer.handle_cancel]'s own pop, clearing the entry and self-healing the stack. The
## reap then finds it already gone and does nothing. That window is asserted in the suite rather than
## argued.
##
## Both layouts — the shipped shell and a panel parented straight under an [MKRoot] — are asserted,
## because sibling exit order decides which of the layer and the panel is detached first and the
## answer must not move with it.
##
## The control sync is skipped once the panel is out of the tree: the widgets are being freed, and the
## store — restored above — is the half that outlives the panel and the half D14 actually promises.
## The guard is REAL, not defensive tidiness: [method _exit_tree] reaches here after
## [method _disconnect_backend], so this is the only remaining sync call on a dying panel.
func _resolve_orphaned_countdown(entry: Dictionary) -> void:
	if not _live_countdowns.has(entry):
		return
	_live_countdowns.erase(entry)
	var def: MKSettingDef = entry["def"]
	_revert_value(def, entry["previous"])
	if is_inside_tree():
		_sync_control(def)
	var layer: MKModalLayer = entry["layer"]
	# Untyped, and NOT cast: `as MKRevertCountdown` on a freed instance is itself an engine error, and
	# a host freeing the dialog it was shown is a normal way to get here.
	var countdown: Variant = entry["countdown"]
	if countdown == null or not is_instance_valid(countdown):
		return
	if layer != null and is_instance_valid(layer) and layer.has_modal(countdown):
		# Typed now that validity is established, so mark_resolved is a real call the compiler checks.
		var dialog: MKRevertCountdown = countdown
		dialog.mark_resolved()
		# Deferred, never inline: see the doc above and MKModalLayer.reap_modal. The layer decides
		# whether this becomes a real pop or nothing at all, by whether it is still alive to receive it.
		layer.call_deferred(&"reap_modal", dialog)
		return
	countdown.queue_free()


func _resolve_live_countdowns() -> void:
	# Iterated over a copy: _resolve_orphaned_countdown erases the entry it resolves, and a queue_free
	# in there can reach tree_exited (hence this same function's callee) for another.
	for entry in _live_countdowns.duplicate():
		_resolve_orphaned_countdown(entry)


func _dismiss_countdown(layer: MKModalLayer, countdown: Control) -> void:
	if countdown == null or not is_instance_valid(countdown):
		return
	if layer != null and is_instance_valid(layer):
		# remove_modal, not pop_modal, and the case is reachable: the countdown resolves on a timer, so
		# anything pushed over it in those ten seconds (a host dialog, a confirm from another row) is
		# still on top when it lapses. pop_modal would then dismiss THAT and leave this entry wedged in
		# the stack — is_empty() false forever, scrim up over nothing, every later cancel swallowed.
		# remove_modal takes this entry wherever it sits, and routes through pop_modal when it is the
		# top so focus restoration still happens.
		#
		# Its false — "not on this stack" — is tolerated rather than reported: the layer may already
		# have let go of this dialog (a pop_all on a page change, a host popping it) and the free below
		# is still owed either way.
		#
		# This is the only remove_modal this file calls DIRECTLY, and deliberately so: a Keep, a Revert
		# or a cancel is a real resolution with the shell alive, so a real pop — scrim, focus
		# restoration, MKRoot's suspend edge — is exactly right here, synchronously. The orphan route
		# (_resolve_orphaned_countdown) may be running mid-teardown and must not pop synchronously at
		# all, so it does not come through here: it hands the dialog to MKModalLayer.reap_modal
		# deferred, and that reaches remove_modal only if the layer is still alive next flush.
		layer.remove_modal(countdown)
	countdown.queue_free()


## The modal layer the shell owns, found by walking ancestors for [code]get_modal_layer()[/code].
## Duck-typed for the same reason as the backend walk: a host embedding this panel in its own screen
## may supply its own layer host and should not have to be an [MKRoot].
func _find_modal_layer() -> MKModalLayer:
	var node := get_parent()
	while node != null:
		if node.has_method("get_modal_layer"):
			var layer: MKModalLayer = node.call("get_modal_layer")
			if layer != null and is_instance_valid(layer):
				return layer
		node = node.get_parent()
	return null


## Writes the store's current value back into a built control without echoing it as a user edit.
##
## [b]It is a DISPLAY sync, and it never writes back.[/b] Two places the widget can legitimately end
## up disagreeing with the store, both deliberate:
## [br]- A SLIDER snaps the assigned value to its [member Range.step] and clamps it to the row's
##   range. An off-step external write therefore leaves the widget showing the SNAPPED value while
##   the store keeps the host's exact one. MenuKit does not reconcile that by writing the snapped
##   value back: fighting the host's store from a display sync is the worse failure — it would
##   silently rewrite a value the host set on purpose, from a code path the host never called. The
##   divergence is logged instead.
## [br]- An ENUM whose stored value matches no option keeps its current selection. Selecting the
##   first entry (which the BUILD path does, because a blank dropdown reads as broken) would be a
##   live control claiming the store holds something it does not; the build path can afford it
##   because nothing was on screen yet, and a sync cannot. Logged, for the same reason.
##
## Values are coerced through [method _display_value], so an external write of null lands as the same
## fallback the build path uses rather than as a script error.
##
## [b][constant MKSettingDef.RowType.CUSTOM] rows are excluded outright, before any dispatch.[/b]
## [method _build_custom] registers the host scene's ROOT in [member _controls] (that is how a custom
## row gets a revert and a visible_condition lookup at all), and a custom root is legally any Control —
## including a [LineEdit], a [CheckBox] or an [HSlider]. The dispatch below is by widget CLASS, so such
## a root fell into a branch written for a row this panel had built: it received an assignment of the
## RAW store value, uncoerced (a CUSTOM row has no [method _display_value] arm and cannot have one —
## the panel does not know what the scene reads), and [code]LineEdit.text = 7[/code] is a script error,
## not a coercion. Even where the type happened to line up, the panel was overwriting a display it
## does not own, from a value the row may not even be showing.
##
## So the rule the class doc on [method _on_setting_changed] states is enforced here rather than
## assumed: a CUSTOM row owns its backend relationship end to end. It subscribes to
## [signal MKSettingsBackend.setting_changed] in its own [code]_mk_bind[/code] if it wants liveness —
## which is exactly what the shipped [MKExampleCustomRow] does.
func _sync_control(def: MKSettingDef) -> void:
	if def.type == MKSettingDef.RowType.CUSTOM:
		return
	# KEYBIND rows are excluded for the same structural reason, arrived at from the other side: a
	# rebind row's state does not live in the value store at all. It lives in the INPUT store
	# (get_action_events / set_action_events), keyed by action rather than by setting id, so
	# _display_value has nothing to return for it — the value store holds no entry for its id and never
	# will, and the def's own default_value is a bool/float field that means nothing to a binding.
	# Worse, the dispatch below is by widget CLASS and _register_control stores the row's ROOT: an
	# MKRebindRow is an HBoxContainer today, but nothing stops a future one from being (or containing,
	# as its root) a Button, at which point it would fall into a branch written for a control this
	# panel built and be assigned a value from a store that does not describe it. The row redraws
	# itself through refresh_display() instead, which reads the store that actually holds its state.
	if def.type == MKSettingDef.RowType.KEYBIND:
		return
	var control: Variant = _controls.get(def.id, null)
	if control == null or not is_instance_valid(control):
		return
	var value: Variant = _display_value(def)
	_syncing = true
	if control is CheckBox:
		(control as CheckBox).button_pressed = value
	elif control is HSlider:
		var slider := control as HSlider
		var wanted := float(value)
		slider.value = wanted
		if not is_equal_approx(slider.value, wanted):
			MKLog.debug("'%s' synced to %s but the slider snapped it to %s — the STORE keeps the exact value; the widget shows what its step and range allow"
				% [def.id, wanted, slider.value])
	elif control is OptionButton:
		var button := control as OptionButton
		var labels: Array[String] = []
		var values: Array = []
		if def.id == ID_RESOLUTION:
			_collect_resolution_choices(def, labels, values)
		else:
			_collect_choices(def, labels, values)
		var index := _index_of_value(values, value)
		if index >= 0:
			button.select(index)
		else:
			MKLog.debug("stored value %s for '%s' is not among its options — the row KEEPS its current selection rather than misrepresenting the store as one of them"
				% [value, def.id])
	elif control is LineEdit:
		(control as LineEdit).text = value
	_syncing = false


## The index of [param value] among an enum row's [code]option_values[/code], or -1.
##
## [b]Type-gated, and that is not defensive tidiness.[/b] GDScript's [code]==[/code] does not return
## false across unrelated types — [code]Vector2i == String[/code] raises "Invalid operands", a SCRIPT
## ERROR mid-build. The resolution row's values are [Vector2i] and its stored value can be anything a
## hand-edited JSON file holds, so a bare comparison loop takes the whole page down for a store the
## backend itself was careful to tolerate.
##
## The numeric branch is the one cross-type comparison that means something: JSON has a single number
## type, so an int authored as an [code]option_value[/code] can arrive back as a float (and the
## reverse). Same-type values compare directly and everything else is simply not a match.
func _index_of_value(values: Array, value: Variant) -> int:
	var value_is_number := typeof(value) in [TYPE_INT, TYPE_FLOAT]
	for i in values.size():
		var candidate: Variant = values[i]
		if typeof(candidate) == typeof(value):
			if candidate == value:
				return i
			continue
		if value_is_number and typeof(candidate) in [TYPE_INT, TYPE_FLOAT] \
				and float(candidate) == float(value):
			return i
	return -1


# --- Reactions ----------------------------------------------------------------

## Every write to the store — this panel's own rows, a host writing directly, a load — lands here.
##
## The changed row's CONTROL is re-synced, because the store is the truth and a widget that disagrees
## with it is the bug users report as "the setting didn't take": a host brightening the image through
## the backend used to leave the brightness slider sitting where the player left it.
##
## [b]This covers the row types this panel BUILDS — not [constant MKSettingDef.RowType.CUSTOM].[/b]
## A custom row is a host scene the panel knows nothing about beyond
## [code]_mk_bind(backend, def)[/code]; there is no widget here to write, so it owns its backend
## relationship end to end. A custom row that wants liveness subscribes to
## [signal MKSettingsBackend.setting_changed] itself and updates its own display — which is exactly
## what the shipped [MKExampleCustomRow] does, so the pattern is demonstrated by the example rather
## than only described here.
##
## Guarded by [member _syncing] so a sync cannot re-enter itself. A row's own write also arrives here
## and re-syncs the control it came from: that is a write of the value the control already holds, and
## the backend's own dedup means the resulting control signal (if any) writes nothing back.
func _on_setting_changed(id: StringName, _value: Variant) -> void:
	_update_conditional_rows()
	if not _syncing:
		var def: MKSettingDef = _defs.get(id, null)
		if def != null:
			_sync_control(def)
	if id == ID_WINDOW_MODE:
		# Deferred: this signal fires from set_value, which runs BEFORE apply_one pushes the mode at the
		# DisplayServer. Querying the window now would read the mode we are leaving, so the row's
		# enabled state would lag one change behind — a bug that looks like the row is simply broken.
		_update_resolution_enabled.call_deferred()


## Rows carrying a [member MKSettingDef.visible_condition_id] follow their controlling value live,
## rather than only at build time — a "Show advanced" toggle that needs a page reopen to take effect
## reads as a bug.
##
## [b]The fallback is the CONTROLLING row's own default_value, never a hardcoded false.[/b] An
## untouched setting is absent from the store (seeding a control writes nothing), so on a fresh
## install every condition resolves to its default — and a hardcoded false made a default-TRUE
## controller disagree with its own dependent row. The shipped Gameplay page is exactly that shape:
## Subtitles defaults on, so a first-run player saw the box CHECKED with the Subtitle Size row
## missing, and the only gesture that revealed it was toggling Subtitles off and back on.
##
## Null-safe by construction: an unknown condition id (a typo, or a controller built on a page this
## panel does not carry) and a def that authored no default both fall back to false, which is the
## only safe reading of "nothing here says this row should be visible".
func _update_conditional_rows() -> void:
	for entry in _conditional_rows:
		var node: Variant = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		var condition: StringName = entry["condition"]
		var shown := false
		if _backend != null:
			var raw: Variant = _backend.get_value(condition, _condition_default(condition))
			shown = raw != null and bool(raw)
		(node as Control).visible = shown


## The value a [member MKSettingDef.visible_condition_id] resolves to while its controlling setting is
## unset: that row's [member MKSettingDef.default_value]. Null when the id names no row this panel
## built, or when the row authored no default.
func _condition_default(condition: StringName) -> Variant:
	var def: MKSettingDef = _defs.get(condition, null)
	return def.default_value if def != null else null


## The resolution row is DISABLED outside windowed mode (plan §4.3): [method
## DisplayServer.window_set_size] is a no-op in fullscreen and borderless, so an enabled row there
## would appear to work and change nothing — the worst of the three possible behaviours.
##
## The tooltip says why. A disabled control with no explanation is a support ticket.
func _update_resolution_enabled() -> void:
	if _resolution_button == null or not is_instance_valid(_resolution_button):
		return
	var windowed := _is_windowed()
	_resolution_button.disabled = _backend == null or not windowed
	var def: MKSettingDef = _defs.get(ID_RESOLUTION, null)
	var base := def.tooltip if def != null else ""
	if windowed:
		_resolution_button.tooltip_text = base
	else:
		var note := "Available in Windowed mode only — the window size is fixed by the display in fullscreen and borderless."
		_resolution_button.tooltip_text = note if base.is_empty() else base + "\n" + note


## [b]The WINDOW is the source of truth, not the store.[/b]
##
## The store only knows about mode changes that went through this panel. Alt+Enter, a host calling
## [method DisplayServer.window_set_mode] itself, and a window manager forcing a mode all move the
## real window without writing anything — and against a stored "windowed" the resolution row would
## then render ENABLED while [method DisplayServer.window_set_size] silently did nothing. That is the
## worst of the three possible behaviours and the exact one this row exists to avoid, so a divergence
## must be decided in favour of the window.
##
## The stored value is consulted [b]only under the headless driver[/b], where there is no window for
## the query to be about: [method DisplayServer.window_get_mode] answers for a dummy, so trusting it
## would disable the row for the whole test suite and make every assertion about enablement a
## statement about the stub. Absent a stored mode, headless reports windowed.
##
## [b]The remaining gap, stated rather than papered over.[/b] Nothing polls. Enablement is
## re-evaluated at build, on a [code]video/window_mode[/code] [signal
## MKSettingsBackend.setting_changed] (deferred — see [method _on_setting_changed]), and on this
## panel's own [signal CanvasItem.visibility_changed]. A mode change that happens while the settings
## page is open and untouched is therefore NOT noticed until one of those edges comes round; the
## re-show edge is there because leaving the page for gameplay and coming back is when that
## divergence actually bites.
## [b]The probe.[/b] [member window_mode_probe], when a test installs one, both ANSWERS the window
## query and puts this method on its real-display branch — see that member for why the rule below is
## otherwise unobservable. Nothing installs one in production.
func _is_windowed() -> bool:
	if window_mode_probe.is_valid():
		# VALIDATED, not coerced. int() on a String parses it ("fullscreen" -> 0, which IS
		# WINDOW_MODE_WINDOWED) and on a Dictionary or an Object is a script error, so a probe wired to
		# the wrong signature would either invert this row's enablement silently or take the page down.
		# A bad probe falls through to the real query below and says so, naming the seam — the seam is a
		# testing hook, and a testing hook that lies about the window is worse than no hook.
		var probed: Variant = window_mode_probe.call()
		if typeof(probed) == TYPE_INT:
			return int(probed) == DisplayServer.WINDOW_MODE_WINDOWED
		MKLog.warn("%s: window_mode_probe returned %s (%s), not an int — ignoring it and querying the window as usual"
			% [_context("window_mode_probe"), probed, type_string(typeof(probed))])
	if not _is_headless():
		return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED
	if _backend != null:
		var stored: Variant = _backend.get_value(ID_WINDOW_MODE, null)
		if stored != null and typeof(stored) in [TYPE_INT, TYPE_FLOAT]:
			return int(stored) == DisplayServer.WINDOW_MODE_WINDOWED
	return true


## Re-checks the resolution row whenever this panel is shown again. See [method _is_windowed] for why
## this edge exists and what it does not cover.
func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_update_resolution_enabled()


## Asked here rather than delegated to [method MKJsonSettingsBackend.is_headless_display], because the
## panel must answer it with NO backend at all (the disabled-rows path) and must not assume which
## backend script a host assigned.
func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## This panel is a Node, not a Resource, so [method MKLog.context] has no resource path to name. The
## script path is the identifying thing a reader needs (same convention as the JSON backends).
func _context(field := "") -> String:
	var script := get_script() as Script
	if script != null and not script.resource_path.is_empty():
		return MKLog.context(script.resource_path, field)
	return MKLog.context("MKSettingsPanel", field)


func _format_number(value: float) -> String:
	# Integral values read as "90", not "90.00" — a FOV slider showing two decimal places looks like a
	# debug readout. Fractional ones keep two, which is enough for a 0.5..2.0 brightness range.
	if is_equal_approx(value, roundf(value)):
		return "%d" % int(roundf(value))
	return "%.2f" % value
