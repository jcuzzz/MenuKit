@tool
class_name MKTheme
extends RefCounted
## The type-variation vocabulary, and the only sanctioned way to restyle a control at runtime.
##
## MenuKit ships ZERO [code]add_theme_*_override[/code] calls (plan §1.2): an override beats the
## [Theme], so a package that used them could never be re-skinned by swapping an [MKPalette] —
## which is the whole promise of D4 and ship gate 3. Dynamic state (a nav tab going active) is
## expressed by swapping [member Control.theme_type_variation] between two variations that the
## generated Theme defines, never by writing a StyleBox onto the control.
##
## The names below are the contract every panel, the generator, and the host's alternate palettes
## are written against. Renaming one is a CHANGELOG [b]Breaking[/b] entry (plan §4.8).

## Base type each variation derives from. The generator needs this to register the variation, and
## host tooling needs it to author overrides sanely, so it lives beside the names rather than
## being implicit in the generator.
const VARIATION_BASE := {
	&"MKNavTab": &"Button",
	&"MKNavTabActive": &"Button",
	&"MKPanelButton": &"Button",
	&"MKPrimaryButton": &"Button",
	&"MKDangerButton": &"Button",
	&"MKPanel": &"PanelContainer",
	&"MKFocusRing": &"Panel",
	&"MKHeader": &"Label",
	&"MKRowLabel": &"Label",
}

const NAV_TAB := &"MKNavTab"
const NAV_TAB_ACTIVE := &"MKNavTabActive"
const PANEL_BUTTON := &"MKPanelButton"
const PRIMARY_BUTTON := &"MKPrimaryButton"
const DANGER_BUTTON := &"MKDangerButton"
const PANEL := &"MKPanel"
const FOCUS_RING := &"MKFocusRing"
const HEADER := &"MKHeader"
const ROW_LABEL := &"MKRowLabel"


## Applies a variation to a control. Null-tolerant so callers building UI in a loop need no guard.
## Warns on an unknown name rather than failing silently — a typo'd variation renders as an
## unstyled control, which is exactly the bug that is hard to spot in a screenshot.
static func set_variation(control: Control, variation: StringName) -> void:
	if control == null:
		return
	if not VARIATION_BASE.has(variation):
		MKLog.warn("unknown theme type variation '%s' on %s — see MKTheme.VARIATION_BASE"
			% [variation, control.name])
		return
	control.theme_type_variation = variation


## Swaps between two variations from one boolean. The nav bar's active/inactive tab is the
## motivating case; conditional styling elsewhere should route through here so there is one place
## that knows a state change is a variation swap and never an override.
static func set_variation_if(control: Control, condition: bool, when_true: StringName,
		when_false: StringName) -> void:
	set_variation(control, when_true if condition else when_false)


## True when [param theme] defines every variation in the vocabulary. Used by the Phase 1 tests and
## by [code]MKRoot[/code] boot validation: a palette-generated Theme missing a variation would
## silently un-style whichever panel used it.
static func theme_defines_all(theme: Theme) -> bool:
	if theme == null:
		return false
	for name in VARIATION_BASE:
		if theme.get_type_variation_base(name) == StringName():
			return false
	return true
