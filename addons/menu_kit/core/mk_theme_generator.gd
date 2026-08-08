@tool
class_name MKThemeGenerator
extends RefCounted
## Builds the whole [Theme] from one [MKPalette].
##
## The palette is the only input and the Theme is the only output, so swapping palettes restyles
## everything. Styling controls imperatively at call sites would make that impossible: an
## [code]add_theme_*_override[/code] beats the [Theme].
##
## Two responsibilities that are easy to under-serve, called out because both are shipped bugs when
## missed:
## [br]- Every variation in [constant MKTheme.VARIATION_BASE] must be defined. A missing one leaves
##   whichever panel uses it unstyled, and an unstyled control in a screenshot reads as a layout
##   mistake rather than a theming one.
## [br]- Every Button-derived variation defines all five StyleBoxes, [b]focus included[/b]. Focus is
##   the only feedback a gamepad or keyboard player gets; a missing focus box ships blind traversal.
##
## [b]The focus audit, recorded so the next reader does not have to redo it.[/b] Every focusable
## control type MenuKit instantiates was walked against "does the theme make focus visible here":
## [br]- [Button] and its four variations, [OptionButton], [LineEdit], the [TabContainer] tab strip —
##   all carry a [code]focus[/code] StyleBox from [method focus_box], all now with the same content
##   margins as their own [code]normal[/code] box ([CheckBox]/[CheckButton] were the exception and are
##   corrected in [method _style_checks]).
## [br]- [HSlider]/[VSlider] are the one genuine hole and it is the ENGINE's: a Slider defines no
##   focus StyleBox at all, so there is nothing here to write. That is why [MKSettingsPanel] and
##   [code]MKRebindRow[/code] parent a [constant MKTheme.FOCUS_RING] [Panel] to the control instead —
##   the ring is the vocabulary's answer for any control that cannot own a focus box, and it is
##   themed, so it re-skins with everything else.
## [br]- [SpinBox] takes focus through its internal [LineEdit], which is styled above.
##
## The result is generated at runtime by [code]MKRoot[/code] and, for editor preview only, baked to
## [code]themes/generated_theme.tres[/code]. The bake is a convenience artifact, never the source of
## truth.


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
## control in the package reads as focused the same way — traversal is only followable if
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
	# a wildcard because the isolation scan does not exempt comments). With these unset every panel's
	# content renders flush against the viewport edge — visible only in a capture, never in a compile
	# or unit assertion.
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


## Sliders get the track/fill treatment only; the grabber stays the engine texture because the addon
## bundles no art, and a drawn-in-code grabber would be the one control that cannot be re-skinned
## from the palette.
static func _style_slider(theme: Theme, pal: MKPalette) -> void:
	# The groove's on-screen thickness IS the stylebox's content margins — a zero-margin StyleBoxFlat
	# renders a 0px-tall track, leaving the grabber floating in space. spacing_xs per side gives a
	# visible track that still scales with the palette.
	var groove := pal.spacing_xs
	for type in [&"HSlider", &"VSlider"]:
		theme.set_stylebox(&"slider", type,
			flat(pal, pal.surface_sunken, pal.border, pal.border_width, groove, groove))
		theme.set_stylebox(&"grabber_area", type,
			flat(pal, pal.accent, pal.accent, 0, groove, groove))
		theme.set_stylebox(&"grabber_area_highlight", type,
			flat(pal, pal.accent_hover, pal.accent_hover, 0, groove, groove))


## Side of the generated check glyph, in pixels. A fixed size rather than a palette step: the box is
## a GLYPH sitting beside text, so it is sized against the engine's own check icons (which it
## replaces) and not against the panel's spacing rhythm.
const CHECK_ICON_SIZE := 20


static func _style_checks(theme: Theme, pal: MKPalette) -> void:
	for type in [&"CheckButton", &"CheckBox"]:
		_style_button_type(theme, pal, type, Color(pal.surface, 0.0), Color(pal.surface_raised, 0.5),
			Color(pal.surface_sunken, 0.6), pal.text, pal.text_bright, pal.font_size_normal)
		theme.set_stylebox(&"normal", type,
			flat(pal, Color(pal.surface, 0.0), Color(pal.border, 0.0), 0,
				pal.spacing_sm, pal.spacing_xs))
		# Re-write the focus box with the margins the line above gave `normal`, replacing the BUTTON
		# margins _style_button_type wrote. A Button's minimum size is the largest of its styleboxes'
		# minimum sizes, so a roomier focus box silently pads every checkbox on the page; and a ring inset
		# differently from the control's own box reads as a ring around nothing.
		theme.set_stylebox(&"focus", type, focus_box(pal, pal.spacing_sm, pal.spacing_xs))
		theme.set_constant(&"h_separation", type, pal.spacing_sm)

	_style_check_box_icons(theme, pal)


## [b]The check glyph is generated from the palette, because the engine's is not ours to re-skin.[/b]
##
## An unchecked [CheckBox] renders near-invisible on a dark panel: the glyph is an ICON, and icons
## are the one part of a control that a StyleBox cannot reach — so no amount of palette editing moves
## it, and the row reads as a label with nothing beside it. A per-control theme-item override call is
## forbidden in this addon (the isolation scan matches the call name even in prose, which is why this
## sentence does not spell it) and would break the alt skin anyway, so the fix belongs here, in
## the Theme, keyed off [MKPalette] like everything else.
##
## [b]Drawn, not bundled.[/b] Two flat boxes and a tick, rasterised at generation time from palette
## colours — no image file, so the addon's isolation scan and the no-third-party-art rule are both
## untouched, and a host swapping palettes gets a re-coloured glyph for free.
##
## [b][CheckButton] is deliberately left on the engine's art.[/b] Its icon is a SWITCH, a different
## shape with different states; substituting a box there would make the two controls read as the same
## widget.
##
## The [code]radio_*[/code] icons are likewise untouched: a [CheckBox] only draws them when it carries
## a [ButtonGroup], and no MenuKit row assigns one.
static func _style_check_box_icons(theme: Theme, pal: MKPalette) -> void:
	theme.set_icon(&"unchecked", &"CheckBox", _check_icon(pal, false, true))
	theme.set_icon(&"checked", &"CheckBox", _check_icon(pal, true, true))
	theme.set_icon(&"unchecked_disabled", &"CheckBox", _check_icon(pal, false, false))
	theme.set_icon(&"checked_disabled", &"CheckBox", _check_icon(pal, true, false))
	# The engine modulates a button's icon per state. The glyphs above already carry their own colours,
	# so every state is set to plain white — otherwise a hover or a focus would re-tint a box that was
	# drawn from the palette on purpose.
	for state in [&"icon_normal_color", &"icon_hover_color", &"icon_pressed_color",
			&"icon_hover_pressed_color", &"icon_focus_color"]:
		theme.set_color(state, &"CheckBox", Color.WHITE)
	# Dimmed rather than white, and the two dimmings are deliberately allowed to compound: if a future
	# engine version renames the *_disabled icon slots above, the disabled state falls back to the
	# ENABLED glyph and this modulate is the only thing still saying "unavailable".
	theme.set_color(&"icon_disabled_color", &"CheckBox", Color(1.0, 1.0, 1.0, 0.6))


## One check glyph: a bordered box, plus a tick when [param checked].
##
## Contrast is the whole job, so the border is the palette's [member MKPalette.border] (its accent
## when checked) over the SUNKEN fill rather than the panel fill — the same figure/ground pair the
## LineEdit and the slider groove use.
##
## The border is at least 2px wide regardless of [member MKPalette.border_width]: a panel-scale
## hairline on a 20px glyph vanishes. The palette still scales it upward.
static func _check_icon(pal: MKPalette, checked: bool, enabled: bool) -> ImageTexture:
	var size := CHECK_ICON_SIZE
	# No initial fill: the loop below writes EVERY pixel of the box, so a pre-fill would be overwritten
	# in its entirety. The tick then draws over that.
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)

	var line := maxi(2, pal.border_width)
	var edge := pal.accent if checked else pal.border
	var fill := Color(pal.accent, 0.30) if checked else pal.surface_sunken
	if not enabled:
		edge = pal.text_disabled
		fill = Color(fill, fill.a * 0.5)

	for y in size:
		for x in size:
			var on_border := x < line or y < line or x >= size - line or y >= size - line
			image.set_pixel(x, y, edge if on_border else fill)

	if checked:
		# A tick, drawn as two strokes: down-right into the low corner, then up-right. Proportional to
		# the icon so a host raising CHECK_ICON_SIZE gets the same mark rather than a mark in a corner.
		var mark := pal.accent_text if enabled else pal.text_disabled
		var thickness := maxf(2.0, float(size) * 0.12)
		_stroke(image, Vector2(size * 0.26, size * 0.52), Vector2(size * 0.44, size * 0.72),
			thickness, mark)
		_stroke(image, Vector2(size * 0.44, size * 0.72), Vector2(size * 0.76, size * 0.30),
			thickness, mark)

	return ImageTexture.create_from_image(image)


## Draws a round-capped line into [param image] by testing every pixel's distance to the segment.
## Per-pixel rather than a Bresenham walk because the caps and the width come out right for free, and
## a 20x20 glyph generated once per Theme build is not a budget worth optimising.
static func _stroke(image: Image, from: Vector2, to: Vector2, thickness: float,
		color: Color) -> void:
	var half := thickness * 0.5
	var segment := to - from
	var length_squared := segment.length_squared()
	for y in image.get_height():
		for x in image.get_width():
			var point := Vector2(float(x) + 0.5, float(y) + 0.5)
			# Zero-length segments would divide by zero; clamping t to 0 turns the segment into its own
			# start point, which is the correct degenerate answer (a dot) rather than a skipped stroke.
			var t := 0.0 if length_squared <= 0.0 \
				else clampf((point - from).dot(segment) / length_squared, 0.0, 1.0)
			if point.distance_to(from + segment * t) <= half:
				image.set_pixel(x, y, color)


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
