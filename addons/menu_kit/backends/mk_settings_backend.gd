@abstract
class_name MKSettingsBackend
extends Node
## Setting values plus their application to the engine (plan §4.1, §4.2).
##
## Storage and application live together deliberately: a host swapping to cloud-synced settings
## should not also have to reimplement "what window mode 2 does", and a host with unusual display
## handling should not have to fork persistence to change it.
##
## [b]Exactly one instance must exist per project[/b] (plan §4.2). Two instances over one JSON file
## means the D14 revert countdown snapshots one and the panel writes the other, and last-[method
## save] silently wins — a bug that is near-impossible to diagnose from a report. [MKRoot] adopts
## the [code]MKSettingsService[/code] autoload's instance when present rather than building its own.

## Emitted on every value change so panels, the brightness controller, and host code all react from
## one place instead of polling.
signal setting_changed(id: StringName, value: Variant)

@abstract func get_value(id: StringName, default_value: Variant) -> Variant

@abstract func set_value(id: StringName, value: Variant) -> void

## Flush to storage. Called on panel close and on confirmed display changes, not per keystroke.
@abstract func save() -> void

## Read from storage. A corrupt or unparseable store must rename the bad file aside and boot
## defaults with a warning — never crash, never silently lose data (plan §4.3).
@abstract func load() -> void

## Push every stored value at the engine (window mode, vsync, bus volumes, InputMap overrides).
## Called at boot by [code]MKSettingsService[/code], and by any host taking the documented
## no-autoload path.
@abstract func apply_all() -> void

## Capture stock [InputMap] bindings [b]before[/b] any override is applied — the source of truth for
## "Reset to Defaults". Must run before [method load], or the defaults captured are the user's
## overrides and the recovery path silently becomes a no-op.
@abstract func snapshot_input_defaults() -> void


## Optional parameterization hook (plan §4.1). Returns the keys consumed from [param params].
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
