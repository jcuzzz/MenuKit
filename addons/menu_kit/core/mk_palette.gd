@tool
class_name MKPalette
extends Resource
## The single re-skin surface: every colour, radius, spacing step and font size the generated
## [Theme] is built from (plan §1.2, D4).
##
## MenuKit ships zero [code]add_theme_*_override[/code] calls, so this resource is the ONLY place a
## host changes how the package looks. Swapping one [MKPalette] for another and regenerating must
## restyle the whole menu — that is ship gate 3. Consequently nothing here may be a visual constant
## hidden in the generator, and nothing here may be a per-control tweak: a field earns its place
## only if more than one control reads it, or if a re-skinner would obviously reach for it.
##
## Field names are a published contract (plan §4.8): panels, host palettes and
## [MKThemeGenerator] are all written against them, so a rename is a CHANGELOG [b]Breaking[/b]
## entry.
##
## Every setter calls [method Resource.emit_changed]. The [code]@tool[/code] bake path and
## [code]MKRoot[/code] listen on [signal Resource.changed] to regenerate, so a silent setter would
## make editor palette edits appear to do nothing — the failure mode is indistinguishable from a
## broken generator, which is why the boilerplate is written out per field rather than skipped.

# --- Surfaces --------------------------------------------------------------

@export_group("Surfaces")

## The furthest-back menu fill, behind panels. Also the popup/menu-list backing.
@export var background: Color = Color(0.05, 0.055, 0.07, 1.0):
	set(value):
		background = value
		emit_changed()

## Default panel body and the resting fill of interactive controls.
@export var surface: Color = Color(0.09, 0.10, 0.13, 0.98):
	set(value):
		surface = value
		emit_changed()

## One step forward of [member surface] — hovered controls and panels stacked on panels.
@export var surface_raised: Color = Color(0.145, 0.16, 0.19, 1.0):
	set(value):
		surface_raised = value
		emit_changed()

## One step back of [member surface] — pressed controls, sunken fields, track grooves.
@export var surface_sunken: Color = Color(0.035, 0.04, 0.055, 0.95):
	set(value):
		surface_sunken = value
		emit_changed()

# --- Lines -----------------------------------------------------------------

@export_group("Lines")

## Resting border on every bordered surface.
@export var border: Color = Color(0.34, 0.37, 0.43, 0.9):
	set(value):
		border = value
		emit_changed()

## Border of the focused control. Distinct from [member accent] because keyboard/gamepad focus
## (D12) must stay legible even when a host tints the accent close to the border colour.
@export var border_focus: Color = Color(0.96, 0.82, 0.48, 0.95):
	set(value):
		border_focus = value
		emit_changed()

# --- Text ------------------------------------------------------------------

@export_group("Text")

## Default body/label/button text.
@export var text: Color = Color(0.84, 0.86, 0.90, 1.0):
	set(value):
		text = value
		emit_changed()

## Brightest text: titles, headers, hover and pressed states.
@export var text_bright: Color = Color(0.97, 0.98, 1.0, 1.0):
	set(value):
		text_bright = value
		emit_changed()

## De-emphasised text: descriptions, placeholders, secondary rows.
@export var text_dim: Color = Color(0.62, 0.65, 0.72, 1.0):
	set(value):
		text_dim = value
		emit_changed()

## Text of a control that cannot be used. Kept separate from [member text_dim] so a host can make
## "unavailable" read differently from "quiet" — conflating them is why disabled rows so often look
## merely decorative.
@export var text_disabled: Color = Color(0.45, 0.47, 0.53, 1.0):
	set(value):
		text_disabled = value
		emit_changed()

# --- Accent ----------------------------------------------------------------

@export_group("Accent")

## The one brand colour: primary actions, active nav tab, slider fill, check marks.
@export var accent: Color = Color(0.42, 0.55, 0.72, 1.0):
	set(value):
		accent = value
		emit_changed()

@export var accent_hover: Color = Color(0.55, 0.68, 0.86, 1.0):
	set(value):
		accent_hover = value
		emit_changed()

@export var accent_pressed: Color = Color(0.31, 0.42, 0.57, 1.0):
	set(value):
		accent_pressed = value
		emit_changed()

## Text drawn on top of an accent fill. Authored rather than derived, because a luminance guess
## fails for mid-tone accents and would silently produce unreadable primary buttons.
@export var accent_text: Color = Color(0.04, 0.05, 0.07, 1.0):
	set(value):
		accent_text = value
		emit_changed()

# --- Danger ----------------------------------------------------------------

@export_group("Danger")

## Destructive actions (delete character) and error text.
@export var danger: Color = Color(0.56, 0.18, 0.16, 1.0):
	set(value):
		danger = value
		emit_changed()

@export var danger_hover: Color = Color(0.74, 0.26, 0.21, 1.0):
	set(value):
		danger_hover = value
		emit_changed()

@export var danger_pressed: Color = Color(0.40, 0.12, 0.10, 1.0):
	set(value):
		danger_pressed = value
		emit_changed()

@export var danger_text: Color = Color(1.0, 0.92, 0.90, 1.0):
	set(value):
		danger_text = value
		emit_changed()

# --- Overlay ---------------------------------------------------------------

@export_group("Overlay")

## Fill of the modal scrim. Alpha is part of the value — a modal dim with no alpha hides the menu
## behind it, so hosts re-skinning this must keep it translucent.
@export var scrim: Color = Color(0.0, 0.0, 0.0, 0.55):
	set(value):
		scrim = value
		emit_changed()

# --- Metrics ---------------------------------------------------------------

@export_group("Metrics")

## Corner radius shared by every [StyleBoxFlat] the generator builds. One value, not per-control,
## so "make it rounder" stays a one-field edit.
@export_range(0, 32, 1) var corner_radius: int = 4:
	set(value):
		corner_radius = value
		emit_changed()

@export_range(0, 8, 1) var border_width: int = 1:
	set(value):
		border_width = value
		emit_changed()

## Border width of the focus StyleBox. Thicker than [member border_width] by default: focus is the
## only affordance a gamepad player has (D12), so it must survive a palette whose colours are low
## contrast.
@export_range(0, 8, 1) var focus_width: int = 2:
	set(value):
		focus_width = value
		emit_changed()

# --- Spacing ---------------------------------------------------------------

@export_group("Spacing")

## A four-step scale, used for content margins and container separations. Panels pick a step by
## meaning ("tight", "roomy") rather than a pixel count, so a density change is four edits here
## instead of a sweep through every scene.
@export_range(0, 64, 1) var spacing_xs: int = 4:
	set(value):
		spacing_xs = value
		emit_changed()

@export_range(0, 64, 1) var spacing_sm: int = 8:
	set(value):
		spacing_sm = value
		emit_changed()

@export_range(0, 64, 1) var spacing_md: int = 12:
	set(value):
		spacing_md = value
		emit_changed()

@export_range(0, 64, 1) var spacing_lg: int = 20:
	set(value):
		spacing_lg = value
		emit_changed()

# --- Typography ------------------------------------------------------------

@export_group("Typography")

## Optional face for every text control. Left null so the cold drop uses the engine default font —
## MenuKit bundles no font for licensing reasons (plan §2.1) and this is the documented swap point.
@export var font: Font = null:
	set(value):
		font = value
		emit_changed()

@export_range(6, 96, 1) var font_size_small: int = 13:
	set(value):
		font_size_small = value
		emit_changed()

@export_range(6, 96, 1) var font_size_normal: int = 16:
	set(value):
		font_size_normal = value
		emit_changed()

@export_range(6, 96, 1) var font_size_header: int = 22:
	set(value):
		font_size_header = value
		emit_changed()

@export_range(6, 96, 1) var font_size_title: int = 34:
	set(value):
		font_size_title = value
		emit_changed()


## Reports every field whose value would produce a broken or invisible Theme, all at once rather
## than at the first fault (plan §4.8). Returns the problem strings so callers can surface them in
## [code]MKConfig[/code] validation; [method validate] is the logging front door.
func get_validation_problems() -> PackedStringArray:
	var problems := PackedStringArray()
	if font_size_normal <= 0 or font_size_header <= 0 or font_size_title <= 0 or font_size_small <= 0:
		problems.append("%s: font sizes must be greater than zero"
			% MKLog.context(self, "font_size_normal"))
	if text.a <= 0.0:
		problems.append("%s: fully transparent — all body text would be invisible"
			% MKLog.context(self, "text"))
	if focus_width <= 0:
		problems.append("%s: zero focus border makes keyboard and gamepad focus invisible (D12)"
			% MKLog.context(self, "focus_width"))
	if border_focus.a <= 0.0:
		problems.append("%s: fully transparent — the focus ring would never be seen (D12)"
			% MKLog.context(self, "border_focus"))
	if scrim.a >= 1.0:
		problems.append("%s: fully opaque — a modal would hide the menu behind it instead of dimming it"
			% MKLog.context(self, "scrim"))
	return problems


## Validates and warns. Every problem is recoverable — a bad palette still generates a Theme — so
## this warns rather than errors, per the plan's "warn, do not crash, on recoverable
## misconfiguration" rule. Returns true when the palette is clean.
func validate() -> bool:
	var problems := get_validation_problems()
	for problem in problems:
		MKLog.warn(problem)
	return problems.is_empty()
