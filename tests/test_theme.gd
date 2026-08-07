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

	# A slider's groove has no size of its own: its on-screen thickness IS the stylebox's content
	# margins, so a zero-margin StyleBoxFlat renders a 0px-tall track with the grabber floating in
	# space. That shipped once and was caught by eyeball on a capture while every headless assertion
	# passed — this is the assertion that would have caught it.
	for slider_type in [&"HSlider", &"VSlider"]:
		var groove := theme.get_stylebox(&"slider", slider_type) as StyleBoxFlat
		check(groove != null, "%s defines a groove stylebox" % slider_type)
		if groove == null:
			continue
		check_eq(groove.content_margin_top, float(palette.spacing_xs),
			"%s's groove is spacing_xs thick, not zero — the margin IS the visible track" % slider_type)
		check_eq(groove.content_margin_bottom, float(palette.spacing_xs),
			"%s's groove is thick on both sides" % slider_type)
		var fill := theme.get_stylebox(&"grabber_area", slider_type) as StyleBoxFlat
		check(fill != null and fill.content_margin_top == float(palette.spacing_xs),
			"%s's filled portion matches the groove, so the track does not change height at the grabber"
				% slider_type)

	# MKFocusRing is drawn on controls that cannot own a focus StyleBox — the settings panel's sliders.
	# It must be a BORDER over a transparent fill: an opaque ring would cover its own subject.
	var ring := theme.get_stylebox(&"panel", MKTheme.FOCUS_RING) as StyleBoxFlat
	check(ring != null, "MKFocusRing is a StyleBoxFlat")
	if ring != null:
		check(ring.border_width_top > 0, "with a real border, which is the entire ring")
		check_eq(ring.bg_color.a, 0.0, "and a transparent fill, so it never obscures the control inside")

	# --- the CheckBox glyph and the check focus boxes (Phase 8) ---
	# The unchecked box rendered near-invisible on the shipped dark panel, and no palette edit could
	# move it: the glyph is an ICON, the one part of a control a StyleBox cannot reach. The generator
	# now draws all four states from the palette, so this is where "the checkbox is visible" becomes
	# assertable at all.
	for state in [&"unchecked", &"checked", &"unchecked_disabled", &"checked_disabled"]:
		var icon := theme.get_icon(state, &"CheckBox") as Texture2D
		check(icon != null, "CheckBox defines a '%s' icon" % state)
		if icon == null:
			continue
		check_eq(icon.get_size(),
			Vector2(MKThemeGenerator.CHECK_ICON_SIZE, MKThemeGenerator.CHECK_ICON_SIZE),
			"'%s' is drawn at the glyph size, not at whatever an empty Image defaults to" % state)
		var glyph := icon.get_image()
		check(glyph != null and not glyph.is_empty(), "'%s' carries real pixels" % state)
		if glyph != null and not glyph.is_empty():
			# Every pixel of the box is written by the generator's loop; a fully transparent glyph is
			# exactly what the invisible-checkbox defect looked like.
			check(glyph.get_pixel(0, 0).a > 0.0,
				"'%s' has an opaque border pixel — a transparent glyph IS the defect this fix exists for"
					% state)

	var unchecked := theme.get_icon(&"unchecked", &"CheckBox") as Texture2D
	var checked := theme.get_icon(&"checked", &"CheckBox") as Texture2D
	check(unchecked != null and checked != null and unchecked != checked,
		"checked and unchecked are two different textures")
	if unchecked != null and checked != null:
		# The load-bearing one: same size, same border, and the whole difference is the tick. Comparing
		# the raw buffers is what catches a generator that drew the same box for both states, which
		# would leave a CheckBox with no visible on/off distinction at all.
		check(unchecked.get_image().get_data() != checked.get_image().get_data(),
			"and they are different PIXELS — a checkbox whose two states draw the same glyph reads as permanently off")
		check(_has_pixel(checked.get_image(), palette.accent_text),
			"the checked glyph carries the tick, drawn in the palette's accent_text")
		check(not _has_pixel(unchecked.get_image(), palette.accent_text),
			"and the unchecked one does not — which is the difference above, named")

	# The engine modulates a button's icon per state. These glyphs already carry palette colours, so
	# every state is plain white: without this a hover or a focus re-tints a box drawn on purpose.
	for state in [&"icon_normal_color", &"icon_hover_color", &"icon_pressed_color",
			&"icon_hover_pressed_color", &"icon_focus_color"]:
		check(theme.has_color(state, &"CheckBox"), "CheckBox sets '%s'" % state)
		check_eq(theme.get_color(state, &"CheckBox"), Color.WHITE,
			"'%s' is white, so the generated glyph is shown as drawn rather than re-tinted" % state)
	check(theme.has_color(&"icon_disabled_color", &"CheckBox"),
		"the disabled state is dimmed instead")
	check(theme.get_color(&"icon_disabled_color", &"CheckBox").a < 1.0,
		"which is the only thing still saying 'unavailable' if a future engine renames the *_disabled icon slots")

	# Both check types gain a focus box, and its margins must match their own `normal` box: a Button's
	# minimum size is the largest of its styleboxes', so roomier focus margins silently pad every check
	# row — and a ring inset differently from the control reads as a ring around nothing.
	for check_type in [&"CheckBox", &"CheckButton"]:
		var focus := theme.get_stylebox(&"focus", check_type) as StyleBoxFlat
		var normal := theme.get_stylebox(&"normal", check_type) as StyleBoxFlat
		check(focus != null, "%s defines a focus stylebox — keyboard traversal is invisible without one"
			% check_type)
		if focus == null or normal == null:
			continue
		check(focus.border_width_top > 0, "%s's focus box is a real ring" % check_type)
		check_eq(focus.content_margin_left, normal.content_margin_left,
			"%s's focus margins match its normal box horizontally, so focusing one does not resize it"
				% check_type)
		check_eq(focus.content_margin_top, normal.content_margin_top,
			"%s's focus margins match vertically too" % check_type)

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


## True when [param image] contains a pixel of [param color]. Used to tell the checked glyph from the
## unchecked one by the presence of the TICK specifically, rather than by "the buffers differ" alone —
## a generator that drew two different boxes and no tick would satisfy the weaker claim.
func _has_pixel(image: Image, color: Color) -> bool:
	if image == null or image.is_empty():
		return false
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			# Per-channel tolerance rather than is_equal_approx: the glyph is rasterised into an 8-bit
			# RGBA image, so every palette colour comes back QUANTISED and an exact read of a colour
			# that was written correctly reports absent.
			if absf(pixel.r - color.r) < 0.01 and absf(pixel.g - color.g) < 0.01 \
					and absf(pixel.b - color.b) < 0.01 and absf(pixel.a - color.a) < 0.01:
				return true
	return false
