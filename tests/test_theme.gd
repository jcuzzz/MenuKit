extends MKTest
## The generated Theme and the live re-skin path (plan §1.2, ship gate 3).
##
## The re-skin promise is the package's core value: swapping an [MKPalette] must restyle everything
## with no per-panel edits. Two things have to hold for that, and only one of them is visible in a
## screenshot — the Theme must define the whole type-variation vocabulary, and a palette change must
## actually reach a live root. The second was documented, had `emit_changed()` boilerplate written
## for it in every palette setter, and had no subscriber at all.

const PALETTE_PATH := "res://addons/menu_kit/themes/default_palette.tres"
const CONFIG_PATH := "res://addons/menu_kit/default_config.tres"


func run_tests() -> void:
	var palette := ResourceLoader.load(PALETTE_PATH) as MKPalette
	check(palette != null, "default palette loads")
	if palette == null:
		return
	check_eq(palette.get_validation_problems(), PackedStringArray(),
		"the shipped palette validates clean")

	var theme := MKThemeGenerator.build(palette)
	check(theme != null, "generator produces a Theme")
	check(MKTheme.theme_defines_all(theme),
		"generated Theme defines every variation in MKTheme.VARIATION_BASE")

	# Assert styling per variation, not just registration. The generator registers the whole
	# vocabulary in one unconditional loop, so a registration-only check asked whether that loop ran —
	# deleting the panel styling or the label styling left the package rendering unstyled and the
	# suite green.
	for variation in MKTheme.VARIATION_BASE:
		check(MKTheme.variation_is_styled(theme, variation),
			"%s carries real theme entries, not just a registered base" % variation)

	# The specific entries each base type needs to look intentional.
	check(theme.has_stylebox(&"panel", MKTheme.PANEL), "MKPanel draws a background")
	check(theme.has_color(&"font_color", MKTheme.HEADER), "MKHeader colours its text")
	check(theme.has_font_size(&"font_size", MKTheme.HEADER), "MKHeader sizes its text")
	check(theme.has_color(&"font_color", MKTheme.ROW_LABEL), "MKRowLabel colours its text")

	# Every Button variation needs all five StyleBoxes. A missing `focus` box makes keyboard and
	# gamepad traversal invisible — a shipped bug that no headless assertion elsewhere would catch.
	for variation in MKTheme.VARIATION_BASE:
		if MKTheme.VARIATION_BASE[variation] != &"Button":
			continue
		for state in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
			check(theme.has_stylebox(state, variation),
				"%s defines a '%s' stylebox" % [variation, state])

	# --- the live re-skin path ---
	var config := ResourceLoader.load(CONFIG_PATH) as MKConfig
	check(config != null, "default config loads")
	if config == null:
		return
	# Duplicate so mutating the palette cannot write through to the shipped resource cache and leak
	# a red accent into every later test in the sweep.
	config = config.duplicate(true)
	config.palette = config.palette.duplicate(true)

	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var before: Theme = root.theme
	check(before != null, "root applied a generated theme at boot")

	var probe := Color(0.91, 0.13, 0.17)
	config.palette.accent = probe
	await step_frame()

	check(root.theme != before, "a palette edit regenerates the Theme on a live root")
	var box := root.theme.get_stylebox(&"normal", MKTheme.PRIMARY_BUTTON) as StyleBoxFlat
	check(box != null, "regenerated Theme still carries the primary-button stylebox")
	if box != null:
		check_eq(box.bg_color, probe, "the new accent actually reached the styled control")

	# --- swapping the palette outright (D4 / ship gate 3) ---
	# The headline re-skin gesture, and the one that had no reachable code path: the root stayed
	# subscribed to the palette it no longer displayed, so only edits to the OLD palette did anything.
	var swap_probe := Color(0.13, 0.77, 0.41)
	var alt := config.palette.duplicate(true) as MKPalette
	alt.accent = swap_probe
	var old_palette := config.palette
	config.palette = alt
	await step_frame()

	var swapped := root.theme.get_stylebox(&"normal", MKTheme.PRIMARY_BUTTON) as StyleBoxFlat
	check(swapped != null, "theme survives a palette swap")
	if swapped != null:
		check_eq(swapped.bg_color, swap_probe, "swapping the palette restyles the menu")

	# The discarded palette must be unsubscribed, or editing a palette nothing displays still forces
	# a full regenerate on a live root.
	var after_swap: Theme = root.theme
	old_palette.accent = Color(1.0, 0.0, 1.0)
	await step_frame()
	check(root.theme == after_swap, "editing the DISCARDED palette no longer restyles anything")
