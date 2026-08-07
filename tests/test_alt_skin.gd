extends MKTest
## Ship gate 3: the alt skin proves the re-theme promise with a SECOND authored palette.
##
## `test_theme.gd` proves the mechanism using probe colours mutated onto a duplicate of the shipped
## palette. That leaves one thing unproven: an independently AUTHORED palette resource, loaded from
## disk, restyling the shell. This suite is that half — and it is deliberately written against the
## shipped `demo/alt_skin/alt_palette.tres`, not a fixture, because a fixture cannot go stale in the
## same way the shipped asset can.

const DEFAULT_PALETTE_PATH := "res://addons/menu_kit/themes/default_palette.tres"
const ALT_PALETTE_PATH := "res://demo/alt_skin/alt_palette.tres"
const CONFIG_PATH := "res://addons/menu_kit/default_config.tres"


func run_tests() -> void:
	var alt := ResourceLoader.load(ALT_PALETTE_PATH) as MKPalette
	check(alt != null, "the alt palette loads as an MKPalette")
	if alt == null:
		return
	check_eq(alt.get_validation_problems(), PackedStringArray(),
		"the alt palette validates clean — a re-skin that trips the validator is not a proof")

	var default_palette := ResourceLoader.load(DEFAULT_PALETTE_PATH) as MKPalette
	check(default_palette != null, "the default palette loads for comparison")
	if default_palette == null:
		return

	var alt_theme := MKThemeGenerator.build(alt)
	check(alt_theme != null, "the generator produces a Theme from the alt palette")
	check(MKTheme.theme_defines_all(alt_theme),
		"the alt Theme defines every variation in MKTheme.VARIATION_BASE — a re-skin may not drop vocabulary")
	for variation in MKTheme.VARIATION_BASE:
		check(MKTheme.variation_is_styled(alt_theme, variation),
			"%s is really styled under the alt palette" % variation)

	# --- the palette DRIVES the output ---------------------------------------
	# Building both and comparing is what separates "the generator ran" from "the generator read this
	# resource". A generator with a hard-coded colour passes every assertion above.
	var default_theme := MKThemeGenerator.build(default_palette)
	_check_theme_matches(alt_theme, alt, "alt")
	_check_theme_matches(default_theme, default_palette, "default")

	var alt_primary := alt_theme.get_stylebox(&"normal", MKTheme.PRIMARY_BUTTON) as StyleBoxFlat
	var default_primary := default_theme.get_stylebox(&"normal", MKTheme.PRIMARY_BUTTON) as StyleBoxFlat
	check(alt_primary != null and default_primary != null, "both Themes carry the primary-button box")
	if alt_primary != null and default_primary != null:
		check(alt_primary.bg_color != default_primary.bg_color,
			"the two palettes produce DIFFERENT primary buttons — the accent is read, not baked in")
		check(alt_primary.border_width_top != default_primary.border_width_top,
			"and different border widths, so a metric field drives the output too")
	check(alt_theme.get_color(&"font_color", MKTheme.HEADER)
			!= default_theme.get_color(&"font_color", MKTheme.HEADER),
		"headers differ between the two skins")
	check(alt_theme.get_font_size(&"font_size", MKTheme.HEADER)
			!= default_theme.get_font_size(&"font_size", MKTheme.HEADER),
		"and so do their sizes")

	# --- the live root takes the alt skin ------------------------------------
	# The gate's actual wording is "swapping the palette restyles every panel with no per-panel edits".
	# MKRoot regenerates off `config.changed` (the reassign) plus a subscription to the palette itself;
	# this drives the reassign with the SHIPPED alt resource.
	var config := ResourceLoader.load(CONFIG_PATH) as MKConfig
	check(config != null, "default config loads")
	if config == null:
		return
	# Duplicated so the swap cannot write an alt palette through the resource cache into every later
	# test in the sweep.
	config = config.duplicate(true)

	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var before: Theme = root.theme
	check(before != null, "the root applied a generated theme at boot")

	config.palette = alt
	await step_frame()

	check(root.theme != before, "assigning the alt palette regenerated the live root's Theme")
	_check_theme_matches(root.theme, alt, "live root")

	# Every panel is themed by INHERITANCE from the root's Theme — there is no per-panel theme to
	# update, which is the whole gate. Assert the absence rather than trusting it: a panel that owned
	# its own Theme would keep the old skin and nothing else here would notice.
	var owned := _nodes_owning_a_theme(root)
	check(owned.is_empty(),
		"no node under the shell owns its own Theme, so the swap reaches every panel with no per-panel edit (found: %s)"
			% ", ".join(owned))

	# The scrim is a plain ColorRect, not a Theme item, so the swap must drive it separately —
	# it was the last palette field a swap did not reach, and an alt skin that dims with the old
	# skin's colour fails the gate's "every panel" clause on the one surface every modal shows.
	check_eq(root.get_modal_layer().scrim_color, alt.scrim,
		"and the modal scrim follows the palette too — the swap reaches the one non-Theme surface")

	root.free()
	await step_frame()


## Asserts the Theme's key entries are the PALETTE's values, per skin. Failing here means the
## generator invented a colour rather than reading the resource.
func _check_theme_matches(theme: Theme, pal: MKPalette, label: String) -> void:
	if theme == null:
		fail("%s: no Theme to check" % label)
		return
	var primary := theme.get_stylebox(&"normal", MKTheme.PRIMARY_BUTTON) as StyleBoxFlat
	check(primary != null, "%s: primary-button box exists" % label)
	if primary != null:
		check_eq(primary.bg_color, pal.accent, "%s: the primary button is the palette's accent" % label)
		check_eq(primary.border_width_top, pal.border_width,
			"%s: its border is the palette's border_width" % label)
		check_eq(primary.corner_radius_top_left, pal.corner_radius,
			"%s: and its corners the palette's radius" % label)
	check_eq(theme.get_color(&"font_color", MKTheme.HEADER), pal.text_bright,
		"%s: headers use the palette's text_bright" % label)
	check_eq(theme.get_font_size(&"font_size", MKTheme.HEADER), pal.font_size_header,
		"%s: headers use the palette's header size" % label)
	var panel := theme.get_stylebox(&"panel", MKTheme.PANEL) as StyleBoxFlat
	check(panel != null, "%s: panel box exists" % label)
	if panel != null:
		check_eq(panel.bg_color, pal.surface, "%s: panels use the palette's surface" % label)


## Every descendant Control carrying its own [Theme]. Excludes the root itself, which is the one node
## that is SUPPOSED to own one.
func _nodes_owning_a_theme(root: Node) -> PackedStringArray:
	var found := PackedStringArray()
	for child in root.get_children():
		_collect_theme_owners(child, found)
	return found


func _collect_theme_owners(node: Node, found: PackedStringArray) -> void:
	var control := node as Control
	if control != null and control.theme != null:
		found.append(control.name)
	for child in node.get_children():
		_collect_theme_owners(child, found)
