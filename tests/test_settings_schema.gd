extends MKTest
## The data-driven settings panel against a real backend (plan §4.3, D5).
##
## Every row type is built from an [MKSettingDef] at runtime, so the thing that breaks is never a
## scene — it is the build/read/write triangle between a def, a control and the store. This suite
## drives the built controls the way a user does (press the CheckBox, move the HSlider, pick an
## OptionButton entry, submit the LineEdit) and asserts what landed in an [MKJsonSettingsBackend],
## because a test that only asserts "a CheckBox exists" passes against a panel that reads nothing and
## writes nothing.
##
## [b]Headless boundary[/b] (plan §4.8). The resolution row's screen filtering and the enable/disable
## it derives from a real window are engine-visible effects the headless driver cannot show honestly;
## what IS assertable here is the VALUE logic those effects are derived from — the stored window mode
## driving enablement, the curated list passing through, a non-Vector2i entry being dropped. Each such
## boundary is marked where it is reached.

const STORE_PATH := "user://test_settings_schema.json"

## Rows the shipped default pages are expected to build a control for. Recomputed from the loaded
## resources rather than hardcoded, so authoring a new row does not silently shrink the coverage.
const DEFAULT_PAGES := [
	"res://addons/menu_kit/settings/defaults/video_page.tres",
	"res://addons/menu_kit/settings/defaults/audio_page.tres",
	"res://addons/menu_kit/settings/defaults/controls_page.tres",
	"res://addons/menu_kit/settings/defaults/gameplay_page.tres",
]

## Messages MKLog emitted while [method _watch_warnings] was armed.
var _warnings: Array[String] = []


func run_tests() -> void:
	# The project registers the real MKSettingsService autoload, and MKSettingsPanel resolves a backend
	# from it FIRST. Left in place, the no-backend case would silently resolve the autoload's live
	# backend and test the opposite of what it claims.
	var parked := _park_autoload()
	_clean()

	await _test_row_types_build_and_write()
	await _test_enum_option_values()
	await _test_defaults_seed_empty_store()
	await _test_keybind_row_is_skipped()
	await _test_custom_rows()
	await _test_invalid_defs_are_skipped()
	await _test_visible_condition_is_live()
	await _test_visible_condition_defaults_to_the_controlling_row()
	await _test_shipped_gameplay_page_shows_its_dependent_row()
	await _test_shipped_default_pages_build_silently()
	await _test_no_backend_renders_disabled()
	await _test_resolution_row()
	await _test_resolution_enabled_rechecks_on_reshow()
	await _test_external_write_syncs_the_control()
	await _test_row_interaction_applies_one()
	await _test_enum_matches_a_numeric_value_across_types()
	await _test_slider_rows_carry_a_focus_ring()
	await _test_null_default_rows_build()
	await _test_custom_row_root_must_be_a_control()
	await _test_external_null_write_does_not_break_a_built_row()
	await _test_enum_sync_keeps_an_unmatched_selection()
	await _test_slider_sync_snaps_the_widget_and_leaves_the_store()
	await _test_duplicate_row_ids_are_named()
	await _test_the_window_beats_the_store()

	_clean()
	_restore_autoload(parked)


# --- Row types ----------------------------------------------------------------

## Each buildable type reads the STORED value at build time and writes back through
## [method MKSettingsBackend.set_value] on interaction.
func _test_row_types_build_and_write() -> void:
	var backend := _make_backend()
	backend.set_value(&"probe/toggle", true)
	backend.set_value(&"probe/slider", 0.25)
	backend.set_value(&"probe/enum", 1)
	backend.set_value(&"probe/text", "stored")

	var page := _page("probe", "Probe", [
		_def(&"", MKSettingDef.RowType.HEADER, "Section"),
		_def(&"probe/toggle", MKSettingDef.RowType.TOGGLE, "Toggle"),
		_slider_def(&"probe/slider", 0.0, 1.0, 0.01),
		_enum_def(&"probe/enum", ["Easy", "Hard"], [0, 1]),
		_def(&"probe/text", MKSettingDef.RowType.TEXT, "Text"),
	])
	var panel := await _make_panel(backend, [page])

	# HEADER is label-only: it produces a Label directly on the rows column, with no control and no
	# entry in the value map — a header that built a row shell would take a value slot it never uses.
	var header := _find_label(panel, "Section")
	check(header != null, "HEADER builds a Label carrying its own text")
	if header != null:
		check(header.get_parent() is VBoxContainer,
			"HEADER sits directly on the rows column — it is not wrapped in a labelled row shell")
	check(not panel._controls.has(&""),
		"HEADER registers no control: it holds no value and reads no backend id")

	var toggle := _first(panel, CheckBox) as CheckBox
	check(toggle != null, "TOGGLE builds a CheckBox")
	var slider := _first(panel, HSlider) as HSlider
	check(slider != null, "SLIDER builds an HSlider")
	var option := _first(panel, OptionButton) as OptionButton
	check(option != null, "ENUM builds an OptionButton")
	var edit := _first(panel, LineEdit) as LineEdit
	check(edit != null, "TEXT builds a LineEdit")
	if toggle == null or slider == null or option == null or edit == null:
		panel.queue_free()
		backend.queue_free()
		return

	check_eq(toggle.button_pressed, true, "TOGGLE seeds from the STORED value, not from default_value")
	check_eq(slider.value, 0.25, "SLIDER seeds from the stored value")
	check_eq(option.get_selected_id(), 1, "ENUM selects the entry whose option_value is stored")
	check_eq(edit.text, "stored", "TEXT seeds from the stored value")
	check_eq(slider.min_value, 0.0, "SLIDER takes its range from the def")
	check_eq(slider.max_value, 1.0, "SLIDER max comes from the def")
	check_eq(slider.step, 0.01, "SLIDER step comes from the def")

	toggle.button_pressed = false
	check_eq(backend.get_value(&"probe/toggle", true), false,
		"pressing the CheckBox writes through set_value")

	slider.value = 0.75
	check_eq(backend.get_value(&"probe/slider", 0.0), 0.75,
		"moving the HSlider writes the new value through the backend")

	option.select(0)
	option.item_selected.emit(0)
	check_eq(backend.get_value(&"probe/enum", -1), 0,
		"picking an OptionButton entry writes that entry's value")

	edit.text = "typed"
	edit.text_submitted.emit("typed")
	check_eq(backend.get_value(&"probe/text", ""), "typed",
		"submitting the LineEdit writes the text through the backend")

	# The readout beside a slider is a display of the control, so it must follow a programmatic sync as
	# well as a drag — a revert that leaves "0.75" beside a slider sitting at 0.25 reads as a failed
	# revert.
	backend.set_value(&"probe/slider", 0.4)
	panel._sync_control(page.rows[2])
	check_eq(slider.value, 0.4, "a store-side change synced back into the control does not echo a write")
	check_eq(backend.get_value(&"probe/slider", 0.0), 0.4,
		"and the sync itself writes nothing — _syncing suppresses the echo")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## option_values is positional and OPTIONAL: absent, the display string IS the value. Both halves are
## asserted, because a panel that always wrote the index would satisfy the first case's `0`.
func _test_enum_option_values() -> void:
	var backend := _make_backend()
	var page := _page("enums", "Enums", [
		_enum_def(&"enum/mapped", ["Low", "High"], [10, 99]),
		_enum_def(&"enum/plain", ["alpha", "beta"], []),
	])
	var panel := await _make_panel(backend, [page])

	var buttons := _all(panel, OptionButton)
	check_eq(buttons.size(), 2, "both ENUM rows built")
	if buttons.size() < 2:
		panel.queue_free()
		backend.queue_free()
		return

	var mapped := buttons[0] as OptionButton
	mapped.select(1)
	mapped.item_selected.emit(1)
	check_eq(backend.get_value(&"enum/mapped", null), 99,
		"with option_values present, the row writes option_values[i] — not the index, not the label")

	var plain := buttons[1] as OptionButton
	plain.select(1)
	plain.item_selected.emit(1)
	check_eq(backend.get_value(&"enum/plain", null), "beta",
		"with option_values absent, the row writes the option STRING")
	check_eq(plain.get_item_text(0), "alpha", "and the labels are the options as authored")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## An empty store is the first-run path, and it is the only place default_value is consulted.
func _test_defaults_seed_empty_store() -> void:
	var backend := _make_backend()
	var toggle_def := _def(&"fresh/toggle", MKSettingDef.RowType.TOGGLE, "Fresh")
	toggle_def.default_value = true
	var slider_def := _slider_def(&"fresh/slider", 0.0, 10.0, 1.0)
	slider_def.default_value = 7.0
	var text_def := _def(&"fresh/text", MKSettingDef.RowType.TEXT, "Name")
	text_def.default_value = "anon"
	var enum_def := _enum_def(&"fresh/enum", ["A", "B"], [1, 2])
	enum_def.default_value = 2

	var panel := await _make_panel(backend, [_page("fresh", "Fresh",
		[toggle_def, slider_def, text_def, enum_def])])

	check_eq((_first(panel, CheckBox) as CheckBox).button_pressed, true,
		"an unset TOGGLE seeds from default_value")
	check_eq((_first(panel, HSlider) as HSlider).value, 7.0,
		"an unset SLIDER seeds from default_value")
	check_eq((_first(panel, LineEdit) as LineEdit).text, "anon",
		"an unset TEXT seeds from default_value")
	check_eq((_first(panel, OptionButton) as OptionButton).get_selected_id(), 1,
		"an unset ENUM selects the entry matching default_value")
	check(not backend.get_file_path().is_empty(), "the store is the test's own file, not a host's")
	check_eq(backend.get_value(&"fresh/toggle", null), null,
		"seeding a control from default_value writes NOTHING to the store — an untouched setting stays absent")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## KEYBIND is Phase 4. The row is skipped with a named warning rather than rendered dead, and the
## addon ships no KEYBIND row precisely so this never fires in the cold drop (plan §3.1).
func _test_keybind_row_is_skipped() -> void:
	var backend := _make_backend()
	var keybind := _def(&"input/jump", MKSettingDef.RowType.KEYBIND, "Jump")
	keybind.action_name = &"ui_accept"

	_watch_warnings()
	var panel := await _make_panel(backend, [_page("keys", "Keys", [
		keybind,
		_def(&"input/invert", MKSettingDef.RowType.TOGGLE, "Invert"),
	])])
	var warnings := _stop_watching()

	check(panel.is_built(), "the page still builds around a KEYBIND row")
	check(not panel._controls.has(&"input/jump"), "the KEYBIND row produced no control")
	check(panel._controls.has(&"input/invert"), "while the rows around it built normally")
	check_eq(_count_containing(warnings, "input/jump"), 1,
		"the skip is named once, so a missing row is not diagnosed by reading source")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## The CUSTOM contract is one method. A root that has it is bound to the backend AND the def; a root
## that does not is skipped rather than shown as a control that silently discards every change.
func _test_custom_rows() -> void:
	var backend := _make_backend()
	backend.set_value(&"custom/value", 5.0)

	var good := _def(&"custom/value", MKSettingDef.RowType.CUSTOM, "Example")
	good.custom_scene = load("res://addons/menu_kit/settings/mk_example_custom_row.tscn")
	good.min_value = 0.0
	good.max_value = 10.0
	good.step = 1.0

	var bad := _def(&"custom/unbound", MKSettingDef.RowType.CUSTOM, "Unbound")
	bad.custom_scene = _scene_without_bind()

	var missing := _def(&"custom/missing", MKSettingDef.RowType.CUSTOM, "No scene")

	_watch_warnings()
	var panel := await _make_panel(backend, [_page("custom", "Custom", [good, bad, missing])])
	var warnings := _stop_watching()

	var row := _first(panel, MKExampleCustomRow)
	check(row != null, "the shipped CUSTOM example builds")
	var spin := _first(panel, SpinBox) as SpinBox
	check(spin != null, "and produced its control")
	if spin != null:
		# _mk_bind received the DEF: the spin's range comes from it. And it received the BACKEND: the
		# value came from the store, not from default_value.
		check_eq(spin.max_value, 10.0, "_mk_bind was handed the def — the range is the def's")
		check_eq(spin.value, 5.0, "_mk_bind was handed the backend — the value is the STORED one")
		spin.value = 8.0
		check_eq(backend.get_value(&"custom/value", 0.0), 8.0,
			"and the custom row writes back through that same backend")

		# The panel re-syncs the rows IT built and cannot write a widget it has never seen, so a CUSTOM
		# row owns liveness itself. The shipped example subscribes to setting_changed, because an example
		# is the thing people copy: without it, a host writing this id — a revert, a load, a reset button
		# — moves the store while the control keeps showing the old number.
		backend.set_value(&"custom/value", 3.0)
		await step_frame()
		check_eq(spin.value, 3.0,
			"an EXTERNAL write moves the custom row's display too — the example subscribes to setting_changed rather than assuming the panel will sync it")
		check_eq(backend.get_value(&"custom/value", 0.0), 3.0,
			"and that sync echoed no write of its own back into the store")

	check(not panel._controls.has(&"custom/unbound"),
		"a CUSTOM root without _mk_bind is SKIPPED, never shown unbound")
	check_eq(_count_containing(warnings, "custom/unbound"), 1, "and the skip names the row")
	check(not panel._controls.has(&"custom/missing"), "a CUSTOM row with no scene is skipped too")
	check_eq(_count_containing(warnings, "custom/missing"), 1, "and is named as well")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Null and id-less entries are authoring accidents, and every one of them must cost a named warning
## and a skipped row rather than a crash mid-build that takes the rest of the page with it.
func _test_invalid_defs_are_skipped() -> void:
	var backend := _make_backend()
	var nameless := _def(&"", MKSettingDef.RowType.TOGGLE, "No id")
	var headerless := _def(&"", MKSettingDef.RowType.HEADER, "")

	var broken := _page("broken", "Broken", [nameless, headerless,
		_def(&"ok/value", MKSettingDef.RowType.TOGGLE, "Fine")])
	var no_id_page := _page("", "Untitled", [_def(&"never/built", MKSettingDef.RowType.TOGGLE, "X")])
	var pages: Array[MKSettingsPageDef] = [broken, null, no_id_page]

	_watch_warnings()
	var panel := await _make_panel(backend, pages)
	var warnings := _stop_watching()

	check(panel.is_built(), "the panel builds through null pages and malformed rows without crashing")
	check_eq(panel._tabs.get_tab_count(), 1, "only the one VALID page became a tab")
	check(panel._controls.has(&"ok/value"), "and the valid row on it still built")
	check(not panel._controls.has(&"never/built"),
		"no row of the id-less page was built — the whole page was skipped")
	check_eq(_all(panel, CheckBox).size(), 1,
		"exactly one control exists: the id-less TOGGLE produced none")
	check(_find_label(panel, "") == null, "and the label-less HEADER produced none")
	check(warnings.size() >= 3,
		"each skip is named — a silently missing row is indistinguishable from a missing resource")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## visible_condition_id follows its controlling value LIVE, off setting_changed. A row that needs the
## page reopened to appear reads as a bug, so the panel subscribes rather than evaluating once.
func _test_visible_condition_is_live() -> void:
	var backend := _make_backend()
	var conditional := _slider_def(&"cond/size", 0.0, 4.0, 1.0)
	conditional.visible_condition_id = &"cond/advanced"

	var panel := await _make_panel(backend, [_page("cond", "Cond", [
		_def(&"cond/advanced", MKSettingDef.RowType.TOGGLE, "Advanced"),
		conditional,
	])])

	var slider := _first(panel, HSlider) as HSlider
	check(slider != null, "the conditional row was built")
	if slider == null:
		panel.queue_free()
		backend.queue_free()
		return
	var row := _row_root(panel, slider)
	check(not row.visible, "with the condition false, the row is hidden at build time")

	backend.set_value(&"cond/advanced", true)
	check(row.visible, "flipping the controlling value reveals the row live, with no rebuild")

	backend.set_value(&"cond/advanced", false)
	check(not row.visible, "and clearing it hides the row again")

	# Through the CONTROL, not just the store — the gesture a user actually performs.
	var toggle := _first(panel, CheckBox) as CheckBox
	toggle.button_pressed = true
	check(row.visible, "pressing the controlling toggle reveals the row through the same path")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## The fallback for an UNSET controlling value is that row's own default_value.
##
## An untouched setting is absent from the store (seeding a control writes nothing), so on a fresh
## install every condition resolves through this path — and resolving it as a hardcoded false is how
## a default-TRUE controller shipped with its dependent row hidden while its own box read checked.
func _test_visible_condition_defaults_to_the_controlling_row() -> void:
	var backend := _make_backend()
	var controller := _def(&"cond2/advanced", MKSettingDef.RowType.TOGGLE, "Advanced")
	controller.default_value = true

	var dependent := _slider_def(&"cond2/size", 0.0, 4.0, 1.0)
	dependent.visible_condition_id = &"cond2/advanced"

	# Controlled by an id no row on this panel declares: nothing says it should be shown, so it is not.
	var orphan := _slider_def(&"cond2/orphan", 0.0, 4.0, 1.0)
	orphan.visible_condition_id = &"cond2/nobody"

	# A controller that authored NO default: bool(null) is a script error, so this pins the null guard
	# as well as the policy.
	var defaultless := _def(&"cond2/plain", MKSettingDef.RowType.TOGGLE, "Plain")
	defaultless.default_value = null
	var dependent_on_null := _slider_def(&"cond2/null_dep", 0.0, 4.0, 1.0)
	dependent_on_null.visible_condition_id = &"cond2/plain"

	var panel := await _make_panel(backend, [_page("cond2", "Cond2",
		[controller, dependent, orphan, defaultless, dependent_on_null])])

	check_eq(backend.get_value(&"cond2/advanced", null), null,
		"the store is genuinely EMPTY for the controlling id — this is the first-run path, not a seeded one")

	var sliders := _all(panel, HSlider)
	check_eq(sliders.size(), 3, "all three dependent rows built")
	if sliders.size() < 3:
		panel.queue_free()
		backend.queue_free()
		return

	check(_row_root(panel, sliders[0] as Control).visible,
		"a dependent row is VISIBLE at build when its controller defaults to true and the store is empty")
	check(not _row_root(panel, sliders[1] as Control).visible,
		"a condition naming no built row resolves false rather than guessing")
	check(not _row_root(panel, sliders[2] as Control).visible,
		"and a controller with no default_value resolves false without a bool(null) script error")

	# The live path still wins over the default the moment the store says otherwise.
	backend.set_value(&"cond2/advanced", false)
	check(not _row_root(panel, sliders[0] as Control).visible,
		"an explicit stored false hides it again — the default is a fallback, not an override")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## The shipped Gameplay page, on a FRESH store, is the case the fallback above exists for: Subtitles
## defaults on, so Subtitle Size must be on screen the first time a player opens the page. Asserted
## against the real resource rather than a fixture, because the defect was in the shipped data's
## interaction with the panel and a fixture-only test is what let it ship.
func _test_shipped_gameplay_page_shows_its_dependent_row() -> void:
	var backend := _make_backend()
	var page := load("res://addons/menu_kit/settings/defaults/gameplay_page.tres") as MKSettingsPageDef
	check(page != null, "the shipped Gameplay page loads")
	if page == null:
		backend.queue_free()
		return
	var panel := await _make_panel(backend, [page])

	var toggle: Variant = panel._controls.get(&"gameplay/subtitles", null)
	var dependent: Variant = panel._controls.get(&"gameplay/subtitle_size", null)
	check(toggle is CheckBox and dependent is HSlider, "both shipped rows built")
	if not (toggle is CheckBox and dependent is HSlider):
		panel.queue_free()
		backend.queue_free()
		return

	check((toggle as CheckBox).button_pressed,
		"Subtitles reads CHECKED on a fresh store, from its default_value")
	check(_row_root(panel, dependent as Control).visible,
		"and Subtitle Size is VISIBLE — a checked toggle beside a missing dependent row is the first thing a cold drop shows")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Ship gate 2 in miniature: the four shipped pages are what a cold drop builds, and §3.1 keeps them
## deliberately provision-free (Master-only audio, no KEYBIND rows) so that build is SILENT.
##
## Asserted two ways, because either alone is weak: zero MKLog warnings during the build, and a
## control present for every row those pages declare — a page that warned nothing because it skipped
## everything would pass the first test only.
func _test_shipped_default_pages_build_silently() -> void:
	var backend := _make_backend()
	var pages: Array[MKSettingsPageDef] = []
	for path in DEFAULT_PAGES:
		var page := load(path) as MKSettingsPageDef
		check(page != null, "the shipped page %s loads as an MKSettingsPageDef" % path.get_file())
		if page != null:
			pages.append(page)

	_watch_warnings()
	var panel := await _make_panel(backend, pages)
	var warnings := _stop_watching()

	check_eq(warnings.size(), 0,
		"the four shipped pages build with ZERO warnings — the cold-drop expectation (gate 2). Saw: %s"
			% [warnings])
	check_eq(panel._tabs.get_tab_count(), 4, "all four became tabs")

	var expected := 0
	for page in pages:
		for def in page.rows:
			if def != null and def.is_valid() and def.type != MKSettingDef.RowType.HEADER:
				expected += 1
				check(panel._controls.has(def.id),
					"shipped row '%s' built a control" % def.id)
	check(expected > 0, "the shipped pages declare value rows at all")

	# Every shipped ENUM must offer choices: an empty dropdown is the shape this build would take if a
	# curated list stopped reaching the panel, and it warns rather than crashing — which the zero-warning
	# assertion above would catch only as a number.
	for button in _all(panel, OptionButton):
		check((button as OptionButton).item_count > 0,
			"a shipped ENUM row renders with options rather than as an empty dropdown")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## An unassigned settings slot renders the page DISABLED with ONE warning. A panel that vanished would
## be indistinguishable from a crashed page and the host's actual mistake would go unnamed; one
## warning per row would bury every other diagnostic on a twenty-row page.
func _test_no_backend_renders_disabled() -> void:
	var page := _page("dead", "Dead", [
		_def(&"dead/toggle", MKSettingDef.RowType.TOGGLE, "Toggle"),
		_slider_def(&"dead/slider", 0.0, 1.0, 0.1),
		_enum_def(&"dead/enum", ["A", "B"], [1, 2]),
		_def(&"dead/text", MKSettingDef.RowType.TEXT, "Text"),
	])

	_watch_warnings()
	var panel := await _make_panel(null, [page])
	var warnings := _stop_watching()

	check(panel.is_built(), "a panel with no backend still BUILDS rather than vanishing")
	check_eq(warnings.size(), 1,
		"exactly ONE warning for the whole panel, not one per row. Saw: %s" % [warnings])
	check((_first(panel, CheckBox) as CheckBox).disabled, "the TOGGLE renders disabled")
	check(not (_first(panel, HSlider) as HSlider).editable, "the SLIDER renders non-editable")
	check((_first(panel, OptionButton) as OptionButton).disabled, "the ENUM renders disabled")
	check(not (_first(panel, LineEdit) as LineEdit).editable, "the TEXT row renders non-editable")

	# Nothing to write to, and nothing that crashes trying.
	var toggle := _first(panel, CheckBox) as CheckBox
	toggle.button_pressed = true
	check(toggle.button_pressed, "and interacting with a disabled-render row is inert, not fatal")

	panel.queue_free()
	await step_frame()


## The resolution row (plan §4.3, finding F4).
##
## [b]Headless boundary.[/b] Godot exposes no API that enumerates supported modes, so the list is a
## curated array filtered against [method DisplayServer.screen_get_size] — and under the headless
## driver that query is meaningless, which is why the panel passes the list through unfiltered there.
## Asserting "1920x1080 was filtered out on a 1280x720 screen" is therefore impossible in this suite
## WITHOUT lying about which branch ran; that filtering and the native-size insertion are a phase
## exit criterion on a real display. What is asserted here is the value logic underneath: the curated
## list reaches the dropdown, a non-Vector2i entry is dropped with a warning, and the stored window
## mode — the branch [code]_is_windowed[/code] takes under the headless driver, where there is no
## window for a DisplayServer query to be about — drives the row's enabled state.
##
## [b]The deferral in [code]_on_setting_changed[/code] is deliberately NOT covered here, and this says
## so rather than pretending.[/b] It exists because setting_changed fires from set_value, BEFORE
## apply_one pushes the mode at the DisplayServer, so an immediate query would read the mode being
## left. Headless there is no such query — the stored value is already correct at signal time — so
## turning the call_deferred into a direct call changes nothing this suite can observe, and an
## assertion claiming otherwise would be measuring the frame count, not the ordering. It belongs to
## the human pass on a real display, with the rest of the DisplayServer branch.
func _test_resolution_row() -> void:
	var backend := _make_backend()
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 0)

	var resolution := _enum_def(MKSettingsPanel.ID_RESOLUTION,
		["1280 x 720", "1920 x 1080", "bogus"],
		[Vector2i(1280, 720), Vector2i(1920, 1080), "not a size"])
	resolution.tooltip = "Base tooltip."
	var window_mode := _enum_def(MKSettingsPanel.ID_WINDOW_MODE,
		["Windowed", "Fullscreen"], [0, 3])

	_watch_warnings()
	var panel := await _make_panel(backend, [_page("video", "Video", [window_mode, resolution])])
	var warnings := _stop_watching()

	var button := panel._resolution_button
	check(button != null, "the resolution row built and the panel tracks it")
	if button == null:
		panel.queue_free()
		backend.queue_free()
		return

	check_eq(button.item_count, 2,
		"the two curated Vector2i entries reach the dropdown; the non-Vector2i one does not")
	check_eq(button.get_item_text(0), "1280 x 720", "entries are labelled from the size itself")
	check_eq(_count_containing(warnings, "not a Vector2i"), 1,
		"and the bad entry is named rather than silently dropped")

	check(not button.disabled,
		"with the STORED window mode windowed, the row is enabled")
	check_eq(button.tooltip_text, "Base tooltip.",
		"and carries only the author's tooltip")

	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 3)
	await step_frame()
	await step_frame()
	check(button.disabled,
		"a stored fullscreen mode DISABLES the row — window_set_size is a no-op there, and an enabled row would appear to work and change nothing")
	check(button.tooltip_text.contains("Windowed mode only"),
		"and the tooltip explains why, because a disabled control with no explanation is a support ticket")

	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 0)
	await step_frame()
	await step_frame()
	check(not button.disabled, "returning to windowed re-enables it")

	# The selection round-trips through a Vector2i, which JSON cannot represent natively — the reason
	# _index_of_value carries a numeric second pass at all.
	button.select(1)
	button.item_selected.emit(1)
	check_eq(backend.get_value(MKSettingsPanel.ID_RESOLUTION, null), Vector2i(1920, 1080),
		"choosing a resolution writes the Vector2i itself")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## The re-show edge of the resolution row's enablement (see [code]MKSettingsPanel._is_windowed[/code]).
##
## [b]Headless boundary, stated precisely.[/b] With a real display the row's enabled state is decided
## by [method DisplayServer.window_get_mode], so the divergence this edge exists for — alt+enter, a
## host calling window_set_mode, a window manager forcing a mode — cannot be staged here: the headless
## driver has no window to diverge, which is exactly why the stored value is consulted under it. That
## branch selection and the visible correction of a stale row on a real display are a phase exit
## criterion on the human pass.
##
## What IS assertable, and is: the panel re-evaluates on being shown again at all. The row is put into
## a state the current inputs do not justify, the panel is hidden and re-shown, and the re-evaluation
## must have corrected it. Drop the visibility_changed wiring and this fails.
func _test_resolution_enabled_rechecks_on_reshow() -> void:
	var backend := _make_backend()
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 0)
	var resolution := _enum_def(MKSettingsPanel.ID_RESOLUTION,
		["1280 x 720", "1920 x 1080"], [Vector2i(1280, 720), Vector2i(1920, 1080)])
	var panel := await _make_panel(backend, [_page("video", "Video", [resolution])])

	var button := panel._resolution_button
	check(button != null, "the resolution row built")
	if button == null:
		panel.queue_free()
		backend.queue_free()
		return
	check(not button.disabled, "and starts enabled, matching the inputs")

	# Stands in for a mode change the panel never saw: the row is left in a state nothing re-derives
	# on its own.
	button.disabled = true
	panel.visible = false
	await step_frame()
	check(button.disabled, "hiding the panel re-derives nothing — there is nobody looking at it")

	panel.visible = true
	await step_frame()
	check(not button.disabled,
		"showing it again re-evaluates enablement, which is the edge that catches a mode changed while the player was in gameplay")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## A write that did not come from a row must still move that row's widget. The panel is not the only
## writer — a host writing the value itself, a load, the revert path — and a store the widget
## disagrees with is the bug reported as "the setting didn't take": brightening the image through the
## backend used to leave the brightness slider sitting exactly where the player had left it.
func _test_external_write_syncs_the_control() -> void:
	var backend := _make_backend()
	backend.set_value(&"sync/slider", 0.25)
	backend.set_value(&"sync/toggle", false)
	backend.set_value(&"sync/text", "before")
	backend.set_value(&"sync/enum", 1)

	var panel := await _make_panel(backend, [_page("sync", "Sync", [
		_slider_def(&"sync/slider", 0.0, 1.0, 0.01),
		_def(&"sync/toggle", MKSettingDef.RowType.TOGGLE, "Toggle"),
		_def(&"sync/text", MKSettingDef.RowType.TEXT, "Text"),
		_enum_def(&"sync/enum", ["A", "B"], [1, 2]),
	])])

	var slider := _first(panel, HSlider) as HSlider
	check_eq(slider.value, 0.25, "the slider starts on the stored value")
	check(_find_label(panel, "0.25") != null, "with its readout agreeing")

	backend.set_value(&"sync/slider", 0.75)
	check_eq(slider.value, 0.75, "a write straight through the backend moves the WIDGET")
	check(_find_label(panel, "0.75") != null,
		"and the readout beside it follows — a brightened image beside a slider still reading 0.25 is the reported shape of this bug")

	backend.set_value(&"sync/toggle", true)
	check((_first(panel, CheckBox) as CheckBox).button_pressed, "the CheckBox follows too")
	backend.set_value(&"sync/text", "after")
	check_eq((_first(panel, LineEdit) as LineEdit).text, "after", "and the LineEdit")
	backend.set_value(&"sync/enum", 2)
	check_eq((_first(panel, OptionButton) as OptionButton).selected, 1, "and the OptionButton")

	check_eq(backend.get_value(&"sync/slider", 0.0), 0.75,
		"and none of it echoed a write back — _syncing suppresses the control's own signal")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## A row interaction must call apply_one for THAT id and never apply_all. A slider drag emits a write
## per pixel; re-pushing every window mode, bus volume and InputMap binding on each of those is slow
## and shows up as window flicker on the display rows. The backend half of this is covered in
## test_apply_one.gd — this pins the panel's call SITE, which that suite cannot see.
func _test_row_interaction_applies_one() -> void:
	_clean()
	var backend := ProbeBackend.new()
	backend._mk_configure({"file_path": STORE_PATH})
	get_root().add_child(backend)

	var panel := await _make_panel(backend, [_page("probe2", "Probe2", [
		_slider_def(&"probe2/slider", 0.0, 1.0, 0.1),
		_def(&"probe2/toggle", MKSettingDef.RowType.TOGGLE, "Toggle"),
	])])
	backend.applied_one.clear()
	backend.applied_all = 0

	(_first(panel, HSlider) as HSlider).value = 0.5
	check_eq(backend.applied_one, [&"probe2/slider"] as Array[StringName],
		"moving a slider applies exactly its own id")
	check_eq(backend.applied_all, 0,
		"and never apply_all — one drag would otherwise re-push every setting in the store, per pixel")

	(_first(panel, CheckBox) as CheckBox).button_pressed = true
	check_eq(backend.applied_one.size(), 2, "a second row applies once more")
	check_eq(backend.applied_one[1], &"probe2/toggle", "for its own id")
	check_eq(backend.applied_all, 0, "still no apply_all")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Cross-type value matching on an ENUM row, both directions of the one comparison that is allowed to
## cross: JSON has a single number type, so an int authored as an option_value comes back as a float
## and vice versa. And the comparison must be TYPE-GATED — [code]Vector2i == String[/code] is a script
## error, not false, so an unmatched hand-edited store would take the whole page down mid-build. The
## gate fails any test whose output carries a script error, which is what makes that half assertable.
func _test_enum_matches_a_numeric_value_across_types() -> void:
	var backend := _make_backend()
	# Stored as an INT against FLOAT option_values.
	backend.set_value(&"cross/mode", 1)
	# ...and the reverse: a float against int option_values.
	backend.set_value(&"cross/level", 2.0)
	# A string where the row's values are Vector2i — the hand-edited-store case.
	backend.set_value(&"cross/size", "1920x1080")

	var panel := await _make_panel(backend, [_page("cross", "Cross", [
		_enum_def(&"cross/mode", ["Zero", "One"], [0.0, 1.0]),
		_enum_def(&"cross/level", ["A", "B", "C"], [0, 1, 2]),
		_enum_def(&"cross/size", ["720", "1080"], [Vector2i(1280, 720), Vector2i(1920, 1080)]),
	])])

	var buttons := _all(panel, OptionButton)
	check_eq(buttons.size(), 3, "all three ENUM rows built — a script error mid-build would cost the page")
	if buttons.size() < 3:
		panel.queue_free()
		backend.queue_free()
		return
	check_eq((buttons[0] as OptionButton).selected, 1,
		"an int in the store selects the entry whose option_value is the equivalent float")
	check_eq((buttons[1] as OptionButton).selected, 2,
		"and a float in the store selects the equivalent int entry")
	check_eq((buttons[2] as OptionButton).selected, 0,
		"an unmatchable value falls back to the first entry rather than comparing across types")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Sliders get a focus indicator, because [HSlider] has none: the engine's Slider theme styles the
## groove, the grabber and its highlight, and nothing that changes when focus arrives. A keyboard or
## gamepad player had no way to tell which slider the arrow keys were about to move — the D12 promise
## failing on the one control type that cannot honour it by itself.
##
## The ring is the MKFocusRing type variation, which the generated Theme has always defined and which
## nothing consumed until now, so this is theme mechanics rather than a theme override (gate 1).
##
## [b]Headless boundary.[/b] That the ring is legible on screen is an eyeball question and was checked
## by capture. What is asserted here: the ring exists, it carries the variation, and it tracks focus.
func _test_slider_rows_carry_a_focus_ring() -> void:
	var backend := _make_backend()
	var panel := await _make_panel(backend, [_page("ring", "Ring", [
		_slider_def(&"ring/value", 0.0, 1.0, 0.1),
	])])

	var slider := _first(panel, HSlider) as HSlider
	check(slider != null, "the slider row built")
	if slider == null:
		panel.queue_free()
		backend.queue_free()
		return
	var ring := slider.get_node_or_null("FocusRing") as Panel
	check(ring != null, "the slider carries a focus ring of its own")
	if ring == null:
		panel.queue_free()
		backend.queue_free()
		return
	check_eq(ring.theme_type_variation, MKTheme.FOCUS_RING,
		"styled by the MKFocusRing VARIATION — a palette swap must restyle it with everything else")
	check_eq(ring.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"and it never eats a drag on the slider beneath it")
	check(not ring.visible, "hidden while the slider is not focused")

	slider.grab_focus()
	await step_frame()
	check(ring.visible, "focusing the slider shows the ring — the only feedback a gamepad player gets")

	slider.release_focus()
	await step_frame()
	check(not ring.visible, "and leaving it hides the ring again")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Regression: a TOGGLE or SLIDER def whose author omitted default_value (it defaults to null) must
## still build — bool(null)/float(null) are SCRIPT ERRORS, not coercions, and the shipped pages all
## author defaults, so only a host's first hand-written row ever hit this. Found by the Phase 3 test
## leg; the fix falls back to false / the slider minimum.
func _test_null_default_rows_build() -> void:
	var backend := _make_backend()
	# The fixtures author defaults precisely to steer other tests AROUND this defect, so the null must
	# be restored explicitly here — the null IS the test.
	var bare_toggle := _def(&"nulls/toggle", MKSettingDef.RowType.TOGGLE, "Bare toggle")
	bare_toggle.default_value = null
	var bare_slider := _slider_def(&"nulls/slider", 0.25, 2.0, 0.05)
	bare_slider.default_value = null
	var page := _page("nulls", "Nulls", [bare_toggle, bare_slider])
	var panel := await _make_panel(backend, [page])

	var toggle := _first(panel, CheckBox) as CheckBox
	check(toggle != null, "TOGGLE with a null default_value still builds a CheckBox")
	if toggle != null:
		check_eq(toggle.button_pressed, false, "null default seeds a TOGGLE unchecked")
	var slider := _first(panel, HSlider) as HSlider
	check(slider != null, "SLIDER with a null default_value still builds an HSlider")
	if slider != null:
		check_eq(slider.value, 0.25, "null default seeds a SLIDER at the def's own minimum")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## The Control check in [code]_build_custom[/code] must run BEFORE [code]_mk_bind[/code], and
## asserting only "the row was skipped" passes with the two in either order — the panel skips a
## non-Control root either way. So the probe scene's root RECORDS whether it was bound.
##
## Why the order is load-bearing: [code]_mk_bind[/code] is where a row reads the store, wires signals
## and may register itself with the host. Running all of that on an instance the panel is about to
## free leaves those side effects behind — a listener on the backend, an entry in a host registry —
## with nothing on screen to show for them.
func _test_custom_row_root_must_be_a_control() -> void:
	var backend := _make_backend()
	var probe_script: GDScript = load("res://tests/probes/mk_probe_non_control_row.gd")
	probe_script.bind_calls = 0

	var def := _def(&"custom/non_control", MKSettingDef.RowType.CUSTOM, "Non-control")
	def.custom_scene = _scene_non_control_with_bind()

	_watch_warnings()
	var panel := await _make_panel(backend, [_page("nc", "NC", [def])])
	var warnings := _stop_watching()

	check(not panel._controls.has(&"custom/non_control"),
		"a CUSTOM root that is not a Control is SKIPPED — there is no row shell that could hold it")
	check_eq(_count_containing(warnings, "not a Control"), 1,
		"and the skip is named, with the offending class")
	check_eq(probe_script.bind_calls, 0,
		"and _mk_bind was NEVER called: the Control check precedes the bind, so a scene the panel is about to free never gets to subscribe signals or register itself with a host")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Every external write now routes through [code]_sync_control[/code], and a store can legitimately
## hold a null — a host resetting an id, a load of a file with a null in it. [code]bool(null)[/code]
## and [code]float(null)[/code] are SCRIPT ERRORS, not coercions, so the sync path needs the same
## fallbacks the build path has always carried; they are one helper now precisely so they cannot
## diverge again.
func _test_external_null_write_does_not_break_a_built_row() -> void:
	var backend := _make_backend()
	backend.set_value(&"nullw/toggle", true)
	backend.set_value(&"nullw/slider", 1.5)
	backend.set_value(&"nullw/text", "before")

	var toggle_def := _def(&"nullw/toggle", MKSettingDef.RowType.TOGGLE, "Toggle")
	var slider_def := _slider_def(&"nullw/slider", 0.25, 2.0, 0.05)
	var text_def := _def(&"nullw/text", MKSettingDef.RowType.TEXT, "Text")
	var panel := await _make_panel(backend, [_page("nullw", "Nullw",
		[toggle_def, slider_def, text_def])])

	var toggle := _first(panel, CheckBox) as CheckBox
	var slider := _first(panel, HSlider) as HSlider
	var edit := _first(panel, LineEdit) as LineEdit
	check(toggle.button_pressed, "the toggle starts on the stored true")
	check_eq(slider.value, 1.5, "and the slider on the stored 1.5")

	# The write that used to take the panel down at the two coercion sites.
	backend.set_value(&"nullw/toggle", null)
	backend.set_value(&"nullw/slider", null)
	backend.set_value(&"nullw/text", null)
	await step_frame()

	check_eq(toggle.button_pressed, false,
		"an external null lands on a built TOGGLE as the build path's fallback — unchecked, not a script error")
	check_eq(slider.value, 0.25,
		"and on a built SLIDER as the def's own minimum, which is the fallback the build path uses")
	check_eq(edit.text, "", "and on a built LineEdit as the empty string")
	check_eq(backend.get_value(&"nullw/slider", 999.0), null,
		"and the sync echoed nothing back — the store keeps the null the host wrote")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## An ENUM whose stored value matches no option KEEPS its selection rather than jumping to the first
## entry the way the build path does. A live control silently reselecting would be claiming the store
## holds something it does not; the build path can afford that (nothing was on screen yet, and a blank
## dropdown reads as broken) and a sync cannot. It is reported instead of being silent.
func _test_enum_sync_keeps_an_unmatched_selection() -> void:
	var backend := _make_backend()
	backend.set_value(&"sync3/enum", 2)
	var panel := await _make_panel(backend, [_page("sync3", "Sync3", [
		_enum_def(&"sync3/enum", ["A", "B"], [1, 2]),
	])])

	var button := _first(panel, OptionButton) as OptionButton
	check_eq(button.selected, 1, "the row starts on the stored value's option")

	_watch_log()
	backend.set_value(&"sync3/enum", 99)
	await step_frame()
	var messages := _stop_watching()

	check_eq(button.selected, 1,
		"a store value matching no option leaves the selection ALONE — it does not misrepresent the store as option 0")
	check_eq(backend.get_value(&"sync3/enum", null), 99,
		"and the store is not rewritten to match the widget either")
	check_eq(_count_containing(messages, "sync3/enum"), 1,
		"but the divergence is reported — a widget and a store disagreeing in silence is undebuggable")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## A [Range] snaps an assigned value to its step, so an off-step external write cannot be shown
## exactly. The STORE keeps the host's value; the widget shows what its step allows; MenuKit does not
## write the snapped value back. Reconciling would mean a display sync silently rewriting a value the
## host set on purpose, from a code path the host never called.
func _test_slider_sync_snaps_the_widget_and_leaves_the_store() -> void:
	var backend := _make_backend()
	backend.set_value(&"snap/slider", 0.0)
	var panel := await _make_panel(backend, [_page("snap", "Snap", [
		_slider_def(&"snap/slider", 0.0, 1.0, 0.1),
	])])
	var slider := _first(panel, HSlider) as HSlider

	_watch_log()
	backend.set_value(&"snap/slider", 0.33)
	await step_frame()
	var messages := _stop_watching()

	check(is_equal_approx(slider.value, 0.3),
		"the widget shows the SNAPPED value its step allows (got %s)" % slider.value)
	check_eq(backend.get_value(&"snap/slider", 0.0), 0.33,
		"and the store keeps the host's EXACT value — a display sync must not rewrite what the host set")
	check_eq(_count_containing(messages, "snapped"), 1,
		"with the divergence logged, because a widget that cannot show the stored value in silence is the same undebuggable state")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Two rows sharing an id is the ordinary result of duplicating a page and editing half of it. The
## tracking dictionaries are keyed by id alone, so one row used to silently take the other's place:
## the survivor received every external sync, revert and condition lookup while the other sat on
## screen answering to nothing. Both rows still build — dropping one would hide the mistake — and the
## collision is named once, with BOTH pages, because "which two resources" is the whole question.
func _test_duplicate_row_ids_are_named() -> void:
	var backend := _make_backend()
	var first := _def(&"dupe/value", MKSettingDef.RowType.TOGGLE, "First")
	var second := _def(&"dupe/value", MKSettingDef.RowType.TOGGLE, "Second")

	_watch_warnings()
	var panel := await _make_panel(backend, [
		_page("page_one", "One", [first]),
		_page("page_two", "Two", [second]),
	])
	var warnings := _stop_watching()

	check_eq(_all(panel, CheckBox).size(), 2, "both rows are still BUILT — a dropped row hides the mistake")
	check_eq(panel._defs.get(&"dupe/value", null), first,
		"the FIRST registration keeps the id; the later row is displayed but untracked")
	var named := 0
	for message in warnings:
		if message.contains("dupe/value") and message.contains("page_one") \
				and message.contains("page_two"):
			named += 1
	check_eq(named, 1,
		"exactly one warning, naming the id and BOTH pages — anything less means diffing two resources by eye")

	panel.queue_free()
	backend.queue_free()
	await step_frame()


## [b]The window beats the store, and the divergence is staged rather than assumed.[/b]
##
## The store only knows about mode changes that went through this panel: alt+enter, a host calling
## [method DisplayServer.window_set_mode], and a window manager forcing a mode all move the real
## window and write nothing. Against a stale "windowed" the resolution row would render ENABLED while
## [method DisplayServer.window_set_size] silently did nothing — the worst of the three possible
## behaviours and the exact one this row exists to avoid.
##
## Headless has no window to diverge from the store, so both orderings behaved identically here and
## the rule could be inverted without an assertion moving. [code]window_mode_probe[/code] supplies the
## window's answer, which is the ONLY thing the test stubs — every other input, and the whole decision,
## is the shipped code.
func _test_the_window_beats_the_store() -> void:
	var backend := _make_backend()
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, DisplayServer.WINDOW_MODE_WINDOWED)
	var panel := await _make_panel(backend, [_page("video", "Video", [
		_enum_def(MKSettingsPanel.ID_RESOLUTION, ["1280 x 720", "1920 x 1080"],
			[Vector2i(1280, 720), Vector2i(1920, 1080)]),
	])])

	var button := panel._resolution_button
	check(button != null, "the resolution row built")
	if button == null:
		panel.queue_free()
		backend.queue_free()
		await step_frame()
		return
	check(not button.disabled, "with no divergence, a stored windowed mode leaves it enabled")

	# The window went fullscreen without telling the store — alt+enter.
	panel.window_mode_probe = func() -> int: return DisplayServer.WINDOW_MODE_FULLSCREEN
	await _reshow(panel)
	check(button.disabled,
		"the WINDOW says fullscreen while the store still says windowed, and the row is DISABLED — deciding by the store would leave it enabled over a window_set_size that does nothing")

	# And the reverse: the store caught up to fullscreen, the window went back to windowed.
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, DisplayServer.WINDOW_MODE_FULLSCREEN)
	panel.window_mode_probe = func() -> int: return DisplayServer.WINDOW_MODE_WINDOWED
	await _reshow(panel)
	check(not button.disabled,
		"and a stored fullscreen against a WINDOWED window re-enables it — a store-first decision would leave a working row dead")

	panel.window_mode_probe = Callable()
	panel.queue_free()
	backend.queue_free()
	await step_frame()


## Hides and re-shows the panel, which is one of the three real edges enablement is re-derived on.
func _reshow(panel: MKSettingsPanel) -> void:
	panel.visible = false
	await step_frame()
	panel.visible = true
	await step_frame()


# --- Fixtures -----------------------------------------------------------------

## A real backend that counts which application call a row reached for. A subclass rather than a
## stub: the panel must be observed against the backend it actually ships with, and everything except
## the counting is inherited behaviour.
class ProbeBackend extends MKJsonSettingsBackend:
	var applied_one: Array[StringName] = []
	var applied_all := 0

	func apply_one(id: StringName) -> void:
		applied_one.append(id)
		super(id)

	func apply_all() -> void:
		applied_all += 1
		super()


func _make_backend() -> MKJsonSettingsBackend:
	_clean()
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": STORE_PATH})
	get_root().add_child(backend)
	return backend


## Binds BEFORE the panel enters the tree, which is the documented seam — and, for the null case, the
## only way to stop `_ready` resolving a backend from somewhere else.
func _make_panel(backend: MKSettingsBackend, pages: Array) -> MKSettingsPanel:
	var panel := MKSettingsPanel.new()
	var typed: Array[MKSettingsPageDef] = []
	for page in pages:
		typed.append(page)
	panel.pages = typed
	if backend != null:
		panel.bind_backend(backend)
	get_root().add_child(panel)
	await step_frame()
	return panel


## Every def gets a type-appropriate [member MKSettingDef.default_value].
##
## Not cosmetic: [code]MKSettingsPanel._current[/code] returns [code]null[/code] for a def with no
## default whose id is unset in the store, and the TOGGLE and SLIDER builders pass that straight into
## [code]bool()[/code] / [code]float()[/code] — which is a script error, not a zero. Authoring the
## defaults here keeps this suite on the row types rather than on that defect; it is reported
## separately, and a regression test belongs with its fix.
func _def(id: StringName, type: MKSettingDef.RowType, label: String) -> MKSettingDef:
	var def := MKSettingDef.new()
	def.id = id
	def.type = type
	def.label = label
	match type:
		MKSettingDef.RowType.TOGGLE:
			def.default_value = false
		MKSettingDef.RowType.TEXT:
			def.default_value = ""
	return def


func _slider_def(id: StringName, low: float, high: float, step_size: float) -> MKSettingDef:
	var def := _def(id, MKSettingDef.RowType.SLIDER, String(id))
	def.min_value = low
	def.max_value = high
	def.step = step_size
	def.default_value = low
	return def


func _enum_def(id: StringName, options: Array, values: Array) -> MKSettingDef:
	var def := _def(id, MKSettingDef.RowType.ENUM, String(id))
	var typed: Array[String] = []
	for option in options:
		typed.append(option)
	def.options = typed
	def.option_values = values.duplicate()
	return def


func _page(id: StringName, title: String, rows: Array) -> MKSettingsPageDef:
	var page := MKSettingsPageDef.new()
	page.id = id
	page.title = title
	var typed: Array[MKSettingDef] = []
	for row in rows:
		typed.append(row)
	page.rows = typed
	return page


## A PackedScene whose root does NOT implement _mk_bind, built in code so the addon ships no
## counter-example resource of its own.
func _scene_without_bind() -> PackedScene:
	var root := HBoxContainer.new()
	root.name = "Unbound"
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene


## A PackedScene whose root DOES implement _mk_bind but is a plain [Node]. The script is a real file
## (tests/probes/) rather than a [GDScript] built in memory, because [method PackedScene.pack]
## serialises a script by resource path and an unsaved one does not survive the round trip.
func _scene_non_control_with_bind() -> PackedScene:
	var root := Node.new()
	root.name = "NonControlBound"
	root.set_script(load("res://tests/probes/mk_probe_non_control_row.gd"))
	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene


# --- Observation --------------------------------------------------------------

func _watch_warnings() -> void:
	_warnings = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_warnings.append(message)


## Records EVERY observed level, not just warnings. Some behaviours are defined as "keep the widget as
## it is and say so" (an ENUM sync with no matching option, a slider snapping an off-step write); the
## saying-so is at DEBUG level, because it is a divergence a developer needs and not a misconfiguration
## the author must fix.
func _watch_log() -> void:
	_warnings = []
	MKLog.observer = func(_level: MKLog.Level, message: String) -> void:
		_warnings.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _warnings


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found


# --- Tree helpers -------------------------------------------------------------

## A fresh array per call. GDScript reuses ONE instance for an [Array] default argument across every
## call, so the obvious recursive form accumulates every node this suite has ever seen — which both
## keeps freed panels reachable and makes later lookups find controls belonging to a previous test.
func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	_collect(node, out)
	return out


func _collect(node: Node, out: Array[Node]) -> void:
	for child in node.get_children():
		out.append(child)
		_collect(child, out)


func _all(root: Node, type) -> Array[Node]:
	var found: Array[Node] = []
	for node in _descendants(root):
		if is_instance_of(node, type):
			found.append(node)
	return found


func _first(root: Node, type) -> Node:
	var found := _all(root, type)
	return found[0] if not found.is_empty() else null


func _find_label(root: Node, text: String) -> Label:
	for node in _descendants(root):
		var label := node as Label
		if label != null and label.text == text:
			return label
	return null


## The row shell a control lives in — the node whose visibility a visible_condition_id drives. SLIDER
## rows nest one deeper than the rest, so this walks up to the child of the rows column rather than
## assuming a depth.
func _row_root(panel: MKSettingsPanel, control: Control) -> Control:
	var node: Node = control
	while node.get_parent() != null and node.get_parent().name != "Rows":
		node = node.get_parent()
	return node as Control


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := STORE_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)


const SERVICE_NAME := "MKSettingsService"


## The registered autoload is parked, not freed: it belongs to the engine's autoload list.
func _park_autoload() -> Node:
	var service := get_root().get_node_or_null(SERVICE_NAME)
	if service == null:
		return null
	get_root().remove_child(service)
	return service


func _restore_autoload(service: Node) -> void:
	if service != null and is_instance_valid(service):
		get_root().add_child(service)
