@tool
class_name MKSettingDef
extends Resource
## One row of a settings page (plan §4.3, D5).
##
## Everything about a settings row is data: [MKSettingsPanel] builds tabs and controls entirely at
## runtime from an [code]Array[MKSettingsPageDef][/code], so "add Mouse Sensitivity" is authoring one
## [code].tres[/code] sub-resource and never an addon edit. That is the whole point of D5, and it is
## what keeps a host on the pin-a-tag upgrade path instead of a fork.
##
## This resource is inert: it holds no node reference, reads no backend, and performs no application.
## Safe to author in the inspector, duplicate, and load headlessly.
##
## [b]The type enum is CLOSED[/b] (plan §4.3). Extending it is out of scope; [constant RowType.CUSTOM]
## is the escape hatch, and its [member custom_scene] contract is documented on that member.

## The row kinds the panel knows how to build.
##
## [constant RowType.KEYBIND] is present even though the shipped addon pages contain no keybind row
## and the Phase 3 panel skips it: the enum is a persisted, published contract (plan §4.8), and
## inserting a value later would renumber every enum written into an existing [code].tres[/code].
## Reserving it now costs a warning; adding it later is a Breaking change.
enum RowType {
	## Section title. Label only — no control, no value, no backend traffic.
	HEADER,
	## Boolean. Rendered as a [CheckBox].
	TOGGLE,
	## Numeric. Rendered as an [HSlider] plus a live value readout.
	SLIDER,
	## Choice from [member options] / [member option_values]. Rendered as an [OptionButton].
	ENUM,
	## Input rebinding. Phase 4 (plan §4.4); the Phase 3 panel warns and skips the row.
	KEYBIND,
	## Free text. Rendered as a [LineEdit] that commits on submit and on focus loss.
	TEXT,
	## Host-supplied scene implementing [code]_mk_bind[/code]. See [member custom_scene].
	CUSTOM,
}

## Stable value identifier, and the key this row reads and writes through [MKSettingsBackend].
##
## Some ids are [b]reserved[/b]: the shipped [MKJsonSettingsBackend] applies
## [code]video/window_mode[/code], [code]video/resolution[/code], [code]video/vsync[/code],
## [code]video/max_fps[/code] and [code]audio/bus/<BusName>[/code] to the engine, and the panel gives
## [code]video/window_mode[/code], [code]video/resolution[/code] and [code]video/brightness[/code]
## behaviour of its own (its ID_ constants — the window-mode row drives the resolution row's
## enablement, which is why it belongs on this list). Every other id is
## a plain value the host consumes — which is normal operation, not a misconfiguration.
@export var id: StringName = &""

## Human-readable row label. Separate from [member id] so localisation or a rename never changes the
## persisted key or the host's read contract.
@export var label: String = ""

@export var type: RowType = RowType.TOGGLE

## Value used when the store holds nothing for [member id] — the row's initial state on a first run.
##
## [Variant] rather than a per-type field, so one resource serves a bool row, a float row and a
## [Vector2i] row without four unused exports on every def. (Godot 4.4+ exports [Variant] directly.)
@export var default_value: Variant = null

@export_group("Slider")
@export var min_value: float = 0.0
@export var max_value: float = 1.0
## Slider granularity. Zero or negative would make [member Range.step] continuous, which the panel
## permits — an explicit choice for rows like brightness where snapping is undesirable.
@export var step: float = 0.01

@export_group("Enum")
## Display strings, in order.
##
## [b]Never [PackedStringArray].[/b] Godot wipes a populated [PackedStringArray] export when it
## re-saves the owning [code].tres[/code] — a whole project's authored lists vanished to this once,
## with no error. [code]Array[String][/code] round-trips safely.
@export var options: Array[String] = []

## The value written for each entry of [member options], positionally.
##
## Deliberately UNTYPED: it carries [Variant] per option — [Vector2i] resolutions, [DisplayServer]
## mode integers, host enums — and a typed array could hold none of those together. When it is
## shorter than [member options] (or empty) the panel writes the display string itself, which is what
## a plain string choice wants.
@export var option_values: Array = []

@export_group("Behaviour")
## Hover/focus help. Empty means no tooltip. The panel appends its own explanation to this on a row
## it disables for a reason the user cannot otherwise see (the resolution row outside windowed mode).
@export var tooltip: String = ""

## [InputMap] action this row rebinds. [constant RowType.KEYBIND] only; Phase 4 (plan §4.4).
@export var action_name: StringName = &""

## Applies the change immediately, then asks "keep these settings?" with a countdown that reverts on
## timeout (D14).
##
## For window mode and resolution specifically: a display change that leaves the user unable to see
## the screen also leaves them unable to click Undo, so the revert must be on a timer rather than on
## a button.
@export var requires_confirm: bool = false

## When non-empty, this row is visible only while the backend value at this id is truthy — and the
## panel subscribes to [signal MKSettingsBackend.setting_changed] so it updates live rather than only
## on a page rebuild.
##
## The condition id is an ordinary setting id, so the controlling row is usually a [constant
## RowType.TOGGLE] on the same page.
@export var visible_condition_id: StringName = &""

## [constant RowType.CUSTOM] only: the scene the panel instantiates in place of a built-in control.
##
## [b]Binding contract[/b] (plan §4.3, finding M7). The scene's ROOT must implement
## [code]_mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void[/code] and is expected to
## read and write through the backend by [code]def.id[/code]. The panel calls it immediately after
## instantiation. A root without that method gets a named warning and the row is skipped — never a
## silent blank row, which is indistinguishable from a layout bug.
##
## [code]mk_example_custom_row.tscn[/code] ships as the reference implementation.
@export var custom_scene: PackedScene = null


## True when this def can be built into a row at all. Rows failing this are skipped with one named
## warning rather than producing an unlabelled control bound to nothing.
##
## A [constant RowType.HEADER] needs no [member id] — it holds no value — so the id requirement is
## conditional rather than blanket.
func is_valid() -> bool:
	if type == RowType.HEADER:
		return not label.is_empty()
	return id != &""
