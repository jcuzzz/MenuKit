@tool
class_name MKThemeGenerator
extends RefCounted
## Builds the whole [Theme] from one [MKPalette] (plan §1.2).
##
## This is the replacement for the reference project's imperative styling API. That API applied
## StyleBoxes per control at call sites, which meant a re-skin was impossible: an
## [code]add_theme_*_override[/code] beats the [Theme]. Here, the palette is the only input and the
## Theme is the only output, so swapping palettes restyles everything (D4, ship gate 3).
##
## Two responsibilities that are easy to under-serve, called out because both are shipped bugs when
## missed:
## [br]- Every variation in [constant MKTheme.VARIATION_BASE] must be defined. A missing one leaves
##   whichever panel uses it unstyled, and an unstyled control in a screenshot reads as a layout
##   mistake rather than a theming one.
## [br]- Every Button-derived variation defines all five StyleBoxes, [b]focus included[/b]. Focus is
##   the only feedback a gamepad or keyboard player gets (D12); a missing focus box ships blind
##   traversal.
##
## The result is generated at runtime by [code]MKRoot[/code] and, for editor preview only, baked to
## [code]themes/generated_theme.tres[/code]. The bake is a convenience artifact, never the source of
## truth (plan §1.2, F6).


## Builds a Theme from [param palette]. Falls back to a default-constructed palette when passed
## null so a host with an unassigned config field still boots into a styled menu rather than an
## unreadable one — the misconfiguration is reported, not fatal.
static func build(palette: MKPalette) -> Theme:
	var pal := palette
	if pal == null:
		MKLog.warn("%s: no palette supplied — generating with built-in defaults"
			% MKLog.context("MKThemeGenerator", "palette"))
		pal = MKPalette.new()
	pal.validate()

	var theme := Theme.new()
	if pal.font != null:
		theme.default_font = pal.font
	theme.default_font_size = pal.font_size_normal

	_build_base_types(theme, pal)
	_build_variations(theme, pal)

	if not MKTheme.theme_defines_all(theme):
		MKLog.error("%s: generated Theme is missing a type variation from MKTheme.VARIATION_BASE"
			% MKLog.context("MKThemeGenerator", "build"))
	MKLog.debug("generated Theme from %s" % MKLog.context(pal))
	return theme


## Makes a bordered [StyleBoxFlat] from palette metrics. Public because host tooling and the demo
## occasionally need a box that matches the generated Theme exactly; deriving one by hand is how
## palettes drift out of sync.
static func flat(pal: MKPalette, bg: Color, border: Color, border_width: int,
		margin_h: int, margin_v: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(pal.corner_radius)
	box.content_margin_left = margin_h
	box.content_margin_right = margin_h
	box.content_margin_top = margin_v
	box.content_margin_bottom = margin_v
	return box


## The focus StyleBox for a control with the given content margins. Centralised so every focusable
## control in the package reads as focused the same way — the D12 traversal is only followable if
## the ring never changes shape between control kinds.
static func focus_box(pal: MKPalette, margin_h: int, margin_v: int) -> StyleBoxFlat:
	var box := flat(pal, Color(pal.border_focus, 0.10), pal.border_focus, pal.focus_width,
		margin_h, margin_v)
	return box


# --- Base types ------------------------------------------------------------
# Styled so that a control a panel author drops in WITHOUT a variation still looks intentional.
# Leaving base types at engine defaults is what makes a themed package look half-finished the first
# time someone adds a plain Button.

static func _build_base_types(theme: Theme, pal: MKPalette) -> void:
	_style_button_type(theme, pal, &"Button", pal.surface, pal.surface_raised,
		pal.surface_sunken, pal.text, pal.text_bright, pal.font_size_normal)
	_style_label(theme, pal)
	_style_panels(theme, pal)
	_style_line_edit(theme, pal)
	_style_slider(theme, pal)
	_style_checks(theme, pal)
	_style_option_button(theme, pal)
	_style_scroll(theme, pal)
	_style_tab_container(theme, pal)
	_style_popup_menu(theme, pal)


## Writes the full five-state Button surface for a type or variation. All five StyleBoxes and all
## font colours are always written: a partially styled Button inherits the engine default for the
## rest, which mixes two visual languages in one control.
static func _style_button_type(theme: Theme, pal: MKPalette, type: StringName,
		normal_bg: Color, hover_bg: Color, pressed_bg: Color,
		font_color: Color, font_hover: Color, font_size: int) -> void:
	var margin_h := pal.spacing_md + pal.spacing_xs
	var margin_v := pal.spacing_sm

	theme.set_stylebox(&"normal", type,
		flat(pal, normal_bg, pal.border, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"hover", type,
		flat(pal, hover_bg, pal.border_focus, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"pressed", type,
		flat(pal, pressed_bg, pal.accent, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"disabled", type,
		flat(pal, Color(normal_bg, normal_bg.a * 0.5), Color(pal.border, pal.border.a * 0.5),
			pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"focus", type, focus_box(pal, margin_h, margin_v))

	theme.set_color(&"font_color", type, font_color)
	theme.set_color(&"font_hover_color", type, font_hover)
	theme.set_color(&"font_pressed_color", type, font_hover)
	theme.set_color(&"font_focus_color", type, font_hover)
	theme.set_color(&"font_hover_pressed_color", type, font_hover)
	theme.set_color(&"font_disabled_color", type, pal.text_disabled)
	theme.set_font_size(&"font_size", type, font_size)
	if pal.font != null:
		theme.set_font(&"font", type, pal.font)
	theme.set_constant(&"h_separation", type, pal.spacing_sm)


static func _style_label(theme: Theme, pal: MKPalette) -> void:
	theme.set_color(&"font_color", &"Label", pal.text)
	theme.set_font_size(&"font_size", &"Label", pal.font_size_normal)
	theme.set_stylebox(&"normal", &"Label", StyleBoxEmpty.new())
	if pal.font != null:
		theme.set_font(&"font", &"Label", pal.font)


static func _style_panels(theme: Theme, pal: MKPalette) -> void:
	theme.set_stylebox(&"panel", &"PanelContainer",
		flat(pal, pal.surface, pal.border, pal.border_width, pal.spacing_lg, pal.spacing_md))
	theme.set_stylebox(&"panel", &"Panel",
		flat(pal, pal.background, pal.border, pal.border_width, 0, 0))
	theme.set_constant(&"separation", &"VBoxContainer", pal.spacing_sm)
	theme.set_constant(&"separation", &"HBoxContainer", pal.spacing_sm)
	# MarginContainer's padding is the ONLY way a themed layout can inset content — the constants
	# have no StyleBox equivalent, and an add_theme_*_override is forbidden in the addon (spelled with
	# a wildcard because the isolation scan does not exempt comments). With
	# these unset every panel's content renders flush against the viewport edge, which the Phase 1
	# capture showed and which no compile or unit assertion can see.
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		theme.set_constant(side, &"MarginContainer", pal.spacing_lg)


static func _style_line_edit(theme: Theme, pal: MKPalette) -> void:
	var margin_h := pal.spacing_md
	var margin_v := pal.spacing_sm
	theme.set_stylebox(&"normal", &"LineEdit",
		flat(pal, pal.surface_sunken, pal.border, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"focus", &"LineEdit", focus_box(pal, margin_h, margin_v))
	theme.set_stylebox(&"read_only", &"LineEdit",
		flat(pal, Color(pal.surface_sunken, pal.surface_sunken.a * 0.6),
			Color(pal.border, pal.border.a * 0.5), pal.border_width, margin_h, margin_v))
	theme.set_color(&"font_color", &"LineEdit", pal.text_bright)
	theme.set_color(&"font_placeholder_color", &"LineEdit", Color(pal.text_dim, 0.7))
	theme.set_color(&"font_uneditable_color", &"LineEdit", pal.text_disabled)
	theme.set_color(&"font_selected_color", &"LineEdit", pal.accent_text)
	theme.set_color(&"caret_color", &"LineEdit", pal.border_focus)
	theme.set_color(&"selection_color", &"LineEdit", Color(pal.accent, 0.4))
	theme.set_font_size(&"font_size", &"LineEdit", pal.font_size_normal)
	if pal.font != null:
		theme.set_font(&"font", &"LineEdit", pal.font)


## Sliders get the track/fill treatment only; the grabber stays the engine texture because MenuKit
## bundles no art (plan §2.1) and a drawn-in-code grabber would be the one control that cannot be
## re-skinned from the palette.
static func _style_slider(theme: Theme, pal: MKPalette) -> void:
	# The groove's on-screen thickness IS the stylebox's content margins — a zero-margin StyleBoxFlat
	# renders a 0px-tall track, leaving the grabber floating in space (caught by eyeball on the first
	# Phase 3 capture; every headless assertion passed). spacing_xs per side gives a visible track
	# that still scales with the palette.
	var groove := pal.spacing_xs
	for type in [&"HSlider", &"VSlider"]:
		theme.set_stylebox(&"slider", type,
			flat(pal, pal.surface_sunken, pal.border, pal.border_width, groove, groove))
		theme.set_stylebox(&"grabber_area", type,
			flat(pal, pal.accent, pal.accent, 0, groove, groove))
		theme.set_stylebox(&"grabber_area_highlight", type,
			flat(pal, pal.accent_hover, pal.accent_hover, 0, groove, groove))


static func _style_checks(theme: Theme, pal: MKPalette) -> void:
	for type in [&"CheckButton", &"CheckBox"]:
		_style_button_type(theme, pal, type, Color(pal.surface, 0.0), Color(pal.surface_raised, 0.5),
			Color(pal.surface_sunken, 0.6), pal.text, pal.text_bright, pal.font_size_normal)
		theme.set_stylebox(&"normal", type,
			flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0,
				pal.spacing_sm, pal.spacing_xs))
		theme.set_constant(&"h_separation", type, pal.spacing_sm)


static func _style_option_button(theme: Theme, pal: MKPalette) -> void:
	_style_button_type(theme, pal, &"OptionButton", pal.surface, pal.surface_raised,
		pal.surface_sunken, pal.text, pal.text_bright, pal.font_size_normal)
	theme.set_constant(&"arrow_margin", &"OptionButton", pal.spacing_sm)
	theme.set_constant(&"modulate_arrow", &"OptionButton", 1)


static func _style_scroll(theme: Theme, pal: MKPalette) -> void:
	theme.set_stylebox(&"panel", &"ScrollContainer", StyleBoxEmpty.new())
	for type in [&"VScrollBar", &"HScrollBar"]:
		theme.set_stylebox(&"scroll", type,
			flat(pal, Color(pal.surface_sunken, 0.6), Color(pal.border, 0.0), 0, 0, 0))
		theme.set_stylebox(&"grabber", type,
			flat(pal, Color(pal.border, 0.8), Color(pal.border, 0.0), 0, 0, 0))
		theme.set_stylebox(&"grabber_highlight", type,
			flat(pal, pal.accent, Color(pal.accent, 0.0), 0, 0, 0))
		theme.set_stylebox(&"grabber_pressed", type,
			flat(pal, pal.accent_pressed, Color(pal.accent, 0.0), 0, 0, 0))


static func _style_tab_container(theme: Theme, pal: MKPalette) -> void:
	var margin_h := pal.spacing_md
	var margin_v := pal.spacing_sm
	theme.set_stylebox(&"panel", &"TabContainer",
		flat(pal, pal.surface, pal.border, pal.border_width, pal.spacing_md, pal.spacing_md))
	theme.set_stylebox(&"tabbar_background", &"TabContainer", StyleBoxEmpty.new())
	theme.set_stylebox(&"tab_selected", &"TabContainer",
		flat(pal, pal.surface_raised, pal.accent, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"tab_unselected", &"TabContainer",
		flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0, margin_h, margin_v))
	theme.set_stylebox(&"tab_hovered", &"TabContainer",
		flat(pal, Color(pal.surface_raised, 0.6), pal.border, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"tab_disabled", &"TabContainer",
		flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0, margin_h, margin_v))
	theme.set_stylebox(&"tab_focus", &"TabContainer", focus_box(pal, margin_h, margin_v))
	theme.set_color(&"font_selected_color", &"TabContainer", pal.text_bright)
	theme.set_color(&"font_unselected_color", &"TabContainer", pal.text_dim)
	theme.set_color(&"font_hovered_color", &"TabContainer", pal.text)
	theme.set_color(&"font_disabled_color", &"TabContainer", pal.text_disabled)
	theme.set_font_size(&"font_size", &"TabContainer", pal.font_size_normal)


## PopupMenu is styled even though no MenuKit panel instantiates one directly: [OptionButton] owns
## a PopupMenu, so an unstyled popup is the visible seam every settings dropdown would show.
static func _style_popup_menu(theme: Theme, pal: MKPalette) -> void:
	theme.set_stylebox(&"panel", &"PopupMenu",
		flat(pal, pal.background, pal.border, pal.border_width, pal.spacing_sm, pal.spacing_sm))
	theme.set_stylebox(&"hover", &"PopupMenu",
		flat(pal, pal.surface_raised, pal.border_focus, pal.border_width,
			pal.spacing_sm, pal.spacing_xs))
	theme.set_stylebox(&"separator", &"PopupMenu",
		flat(pal, Color(pal.border, 0.55), Color(pal.border, 0.0), 0, 0, 0))
	theme.set_color(&"font_color", &"PopupMenu", pal.text)
	theme.set_color(&"font_hover_color", &"PopupMenu", pal.text_bright)
	theme.set_color(&"font_disabled_color", &"PopupMenu", pal.text_disabled)
	theme.set_color(&"font_accelerator_color", &"PopupMenu", pal.text_dim)
	theme.set_color(&"font_separator_color", &"PopupMenu", pal.text_dim)
	theme.set_font_size(&"font_size", &"PopupMenu", pal.font_size_normal)
	theme.set_constant(&"item_start_padding", &"PopupMenu", pal.spacing_md)
	theme.set_constant(&"item_end_padding", &"PopupMenu", pal.spacing_md)
	theme.set_constant(&"v_separation", &"PopupMenu", pal.spacing_xs)


# --- Variations ------------------------------------------------------------

static func _build_variations(theme: Theme, pal: MKPalette) -> void:
	for variation in MKTheme.VARIATION_BASE:
		theme.set_type_variation(variation, MKTheme.VARIATION_BASE[variation])

	_build_nav_tabs(theme, pal)
	_build_panel_button(theme, pal)
	_build_primary_button(theme, pal)
	_build_danger_button(theme, pal)
	_build_panel_variation(theme, pal)
	_build_focus_ring(theme, pal)
	_build_labels(theme, pal)


## Nav tabs are transparent at rest and highlight on hover, with the active tab carrying the accent
## fill. All states share content margins on purpose: differing margins make the tab resize as the
## pointer crosses it, which reads as the whole nav bar jittering.
static func _build_nav_tabs(theme: Theme, pal: MKPalette) -> void:
	var margin_h := pal.spacing_md
	var margin_v := pal.spacing_sm

	theme.set_stylebox(&"normal", MKTheme.NAV_TAB,
		flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0, margin_h, margin_v))
	theme.set_stylebox(&"hover", MKTheme.NAV_TAB,
		flat(pal, Color(pal.surface_raised, 0.55), Color(pal.border, 0.6), pal.border_width,
			margin_h, margin_v))
	theme.set_stylebox(&"pressed", MKTheme.NAV_TAB,
		flat(pal, Color(pal.surface_raised, 0.8), pal.accent, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"disabled", MKTheme.NAV_TAB,
		flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0, margin_h, margin_v))
	theme.set_stylebox(&"focus", MKTheme.NAV_TAB, focus_box(pal, margin_h, margin_v))
	_nav_font(theme, pal, MKTheme.NAV_TAB, pal.text)

	theme.set_stylebox(&"normal", MKTheme.NAV_TAB_ACTIVE,
		flat(pal, Color(pal.accent, 0.22), pal.accent, pal.border_width, margin_h, margin_v))
	theme.set_stylebox(&"hover", MKTheme.NAV_TAB_ACTIVE,
		flat(pal, Color(pal.accent_hover, 0.30), pal.accent_hover, pal.border_width,
			margin_h, margin_v))
	theme.set_stylebox(&"pressed", MKTheme.NAV_TAB_ACTIVE,
		flat(pal, Color(pal.accent_pressed, 0.34), pal.accent_pressed, pal.border_width,
			margin_h, margin_v))
	theme.set_stylebox(&"disabled", MKTheme.NAV_TAB_ACTIVE,
		flat(pal, Color(pal.accent, 0.12), Color(pal.accent, 0.5), pal.border_width,
			margin_h, margin_v))
	theme.set_stylebox(&"focus", MKTheme.NAV_TAB_ACTIVE, focus_box(pal, margin_h, margin_v))
	_nav_font(theme, pal, MKTheme.NAV_TAB_ACTIVE, pal.text_bright)


static func _nav_font(theme: Theme, pal: MKPalette, type: StringName, base: Color) -> void:
	theme.set_color(&"font_color", type, base)
	theme.set_color(&"font_hover_color", type, pal.text_bright)
	theme.set_color(&"font_pressed_color", type, pal.text_bright)
	theme.set_color(&"font_focus_color", type, pal.text_bright)
	theme.set_color(&"font_hover_pressed_color", type, pal.text_bright)
	theme.set_color(&"font_disabled_color", type, pal.text_disabled)
	theme.set_font_size(&"font_size", type, pal.font_size_normal)
	if pal.font != null:
		theme.set_font(&"font", type, pal.font)


static func _build_panel_button(theme: Theme, pal: MKPalette) -> void:
	_style_button_type(theme, pal, MKTheme.PANEL_BUTTON, pal.surface, pal.surface_raised,
		pal.surface_sunken, pal.text, pal.text_bright, pal.font_size_normal)


## The call to action. Filled with the accent rather than merely outlined, so exactly one control on
## a page can claim to be the obvious next step.
static func _build_primary_button(theme: Theme, pal: MKPalette) -> void:
	_style_button_type(theme, pal, MKTheme.PRIMARY_BUTTON, pal.accent, pal.accent_hover,
		pal.accent_pressed, pal.accent_text, pal.accent_text, pal.font_size_normal)
	theme.set_color(&"font_disabled_color", MKTheme.PRIMARY_BUTTON, pal.text_disabled)


static func _build_danger_button(theme: Theme, pal: MKPalette) -> void:
	_style_button_type(theme, pal, MKTheme.DANGER_BUTTON, pal.danger, pal.danger_hover,
		pal.danger_pressed, pal.danger_text, pal.text_bright, pal.font_size_normal)
	theme.set_color(&"font_disabled_color", MKTheme.DANGER_BUTTON, pal.text_disabled)


static func _build_panel_variation(theme: Theme, pal: MKPalette) -> void:
	theme.set_stylebox(&"panel", MKTheme.PANEL,
		flat(pal, pal.surface, pal.border, pal.border_width, pal.spacing_lg, pal.spacing_md))


## A standalone ring drawn behind or around a control that cannot own a focus StyleBox itself —
## runtime-generated rows and the preview slot. Transparent fill, so it never obscures its subject.
static func _build_focus_ring(theme: Theme, pal: MKPalette) -> void:
	theme.set_stylebox(&"panel", MKTheme.FOCUS_RING,
		flat(pal, Color(pal.border_focus, 0.0), pal.border_focus, pal.focus_width, 0, 0))


static func _build_labels(theme: Theme, pal: MKPalette) -> void:
	theme.set_color(&"font_color", MKTheme.HEADER, pal.text_bright)
	theme.set_font_size(&"font_size", MKTheme.HEADER, pal.font_size_header)
	theme.set_stylebox(&"normal", MKTheme.HEADER, StyleBoxEmpty.new())

	theme.set_color(&"font_color", MKTheme.ROW_LABEL, pal.text_dim)
	theme.set_font_size(&"font_size", MKTheme.ROW_LABEL, pal.font_size_small)
	theme.set_stylebox(&"normal", MKTheme.ROW_LABEL, StyleBoxEmpty.new())

	if pal.font != null:
		theme.set_font(&"font", MKTheme.HEADER, pal.font)
		theme.set_font(&"font", MKTheme.ROW_LABEL, pal.font)
