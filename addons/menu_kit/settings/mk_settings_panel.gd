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

## The autoload that owns the one settings backend when a host registered it (plan §4.2).
const SETTINGS_SERVICE_PATH := "/root/MKSettingsService"

## Ids this panel gives behaviour beyond the generic row types. Both are reserved by the shipped
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
## BEFORE it lets go of the backend it would need to do so.
func _exit_tree() -> void:
	_resolve_live_countdowns()
	_disconnect_backend()


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

	_update_conditional_rows()
	_update_resolution_enabled()
	_built = true
	built.emit()


func _clear() -> void:
	_controls.clear()
	_defs.clear()
	_pages_of_id.clear()
	_conditional_rows.clear()
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


## Builds one row, or returns null when the def cannot produce one (KEYBIND this phase, a CUSTOM
## scene that does not honour the bind contract). Callers skip a null; the warning is issued here so
## it names the offending resource once, where the reason is known.
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
			# Phase 4 (plan §4.4). Named rather than silently dropped: a row that simply is not there
			# reads as a missing resource, and the addon ships no KEYBIND rows precisely so this never
			# fires in the cold drop (plan §3.1).
			MKLog.warn("%s: KEYBIND rows arrive in Phase 4 — skipping row '%s'"
				% [MKLog.context(def, "type"), def.id])
			return null
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
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


## The resolution row's options are a curated [Vector2i] list on the def, filtered to what fits the
## current screen, with the native size always present (plan §4.3, finding F4).
##
## Godot 4 exposes no "list the supported modes" API — only [method DisplayServer.screen_get_size] —
## so enumeration is authored data plus this filter, not a query. Under the headless driver every
## screen query is meaningless, so the curated list passes through unfiltered rather than being
## filtered against a phantom 0x0 screen, which would empty the dropdown in the test suite.
func _collect_resolution_choices(def: MKSettingDef, labels: Array[String], values: Array) -> void:
	var candidates: Array = []
	for i in def.options.size():
		if i < def.option_values.size():
			candidates.append(def.option_values[i])
	if candidates.is_empty():
		candidates = def.option_values.duplicate()

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
		labels.append("%d x %d" % [size.x, size.y])
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
## [Range] would clamp to anyway), TEXT the empty string. Types with no coercion of their own (ENUM,
## and anything a CUSTOM row reads) get the stored value untouched — [method _index_of_value] is
## type-gated and handles null by simply not matching.
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
func _start_revert_countdown(def: MKSettingDef, previous: Variant) -> void:
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
		_revert_value(def, previous)
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
## Re-entrancy is why the removal is written defensively. This runs INSIDE
## [method MKModalLayer.pop_modal] on the pop_all route — the entry has already left the stack, so
## [method MKModalLayer.remove_modal] finds nothing and reports false, which is exactly the tolerance
## required rather than an error. The control sync is skipped once the panel is out of the tree: the
## widgets are being freed and the store, restored above, is the load-bearing half.
func _resolve_orphaned_countdown(entry: Dictionary) -> void:
	if not _live_countdowns.has(entry):
		return
	_live_countdowns.erase(entry)
	var def: MKSettingDef = entry["def"]
	_revert_value(def, entry["previous"])
	if is_inside_tree():
		_sync_control(def)
	var layer: MKModalLayer = entry["layer"]
	var countdown: Variant = entry["countdown"]
	if countdown == null or not is_instance_valid(countdown):
		return
	if layer != null and is_instance_valid(layer):
		layer.remove_modal(countdown)
	countdown.queue_free()


func _resolve_live_countdowns() -> void:
	# Iterated over a copy: _resolve_orphaned_countdown erases from _live_countdowns, and the
	# remove_modal inside it can re-enter through tree_exited and erase another.
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
		# is still owed either way. See _resolve_orphaned_countdown, which reaches here re-entrantly
		# from inside pop_modal.
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
func _sync_control(def: MKSettingDef) -> void:
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
		return int(window_mode_probe.call()) == DisplayServer.WINDOW_MODE_WINDOWED
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
