@tool
class_name MKBackdropDef
extends Resource
## One swappable fullscreen backdrop: an image (or a generated gradient), a tint, and blur/scroll.
##
## Backdrops are data so the visible background can be changed from one resolution point — a host's
## seasonal/served backdrop only needs to select a different id, never touch menu code. This is a
## trimmed port of the source project's def: the game-specific bits are gone, and the ability to
## describe a backdrop with NO texture is new, because the shipped catalog must contain a working
## entry that references no external image (plan §3.1, cold-drop gate 2).
##
## Presentation-only and inert: it draws nothing itself, [MKBackdrop] applies it.

## Stable identifier used to select this backdrop from [MKBackdropCatalog].
@export var id: StringName = &""

## Human-readable name for a backdrop-picker row.
@export var display_name: String = ""

## The backdrop image. [b]Null is fully supported[/b] — [MKBackdrop] then generates a vertical
## gradient from [member gradient_top] / [member gradient_bottom], which is how the shipped default
## works without shipping or requiring an image asset.
@export var texture: Texture2D = null

## Top color of the generated gradient. Ignored when [member texture] is set.
@export var gradient_top: Color = Color(0.07, 0.08, 0.11, 1.0)

## Bottom color of the generated gradient. Ignored when [member texture] is set.
@export var gradient_bottom: Color = Color(0.02, 0.02, 0.03, 1.0)

## Multiplicative tint (alpha included). Applied to image and generated backdrops alike, so a host
## can dim a bright screenshot behind the panels without editing the asset.
@export var tint: Color = Color(1, 1, 1, 1)

## Blur radius in pixels for the vendored blur shader. 0 disables the shader entirely (the material
## is dropped, not merely zeroed) so a sharp backdrop costs nothing.
@export_range(0.0, 16.0, 0.1) var blur_amount: float = 0.0

## Horizontal drift in UV units per second. 0 is static. Non-zero relies on texture repeat, so it
## only reads correctly on a horizontally tileable image or on a generated gradient (which is
## uniform horizontally and therefore always safe).
@export_range(-1.0, 1.0, 0.001) var scroll_speed: float = 0.0


## True when this def is selectable from a catalog. An id-less def cannot be resolved by
## [code]get_backdrop()[/code], so the catalog reports it instead of silently keeping it.
func is_valid() -> bool:
	return id != &""


## True when the def needs no external image and can be rendered from its gradient colors alone.
## Exists so callers (and tests) can assert the cold-drop property directly.
func is_generated() -> bool:
	return texture == null
