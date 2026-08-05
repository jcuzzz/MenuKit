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
