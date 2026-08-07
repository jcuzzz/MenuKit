@abstract
class_name MKSettingsBackend
extends Node
## Setting values plus their application to the engine.
##
## Storage and application live together deliberately: a host swapping to cloud-synced settings
## should not also have to reimplement "what window mode 2 does", and a host with unusual display
## handling should not have to fork persistence to change it.
##
## [b]Exactly one instance must exist per project.[/b] With two over one JSON file, the D14 revert
## countdown snapshots one and the panel writes the other, and the last [method save] silently wins.
## [MKRoot] adopts the [code]MKSettingsService[/code] autoload's instance when present rather than
## building its own.

## Emitted on every value change so panels, the brightness controller, and host code all react from
## one place instead of polling.
signal setting_changed(id: StringName, value: Variant)

@abstract func get_value(id: StringName, default_value: Variant) -> Variant

@abstract func set_value(id: StringName, value: Variant) -> void

## Flush to storage. Called on panel close and on confirmed display changes, not per keystroke.
@abstract func save() -> void

## Read from storage. A corrupt or unparseable store must rename the bad file aside and boot
## defaults with a warning — never crash, never silently lose data.
@abstract func load() -> void

## Push every stored value at the engine (window mode, vsync, bus volumes, InputMap overrides).
## Called at boot by [code]MKSettingsService[/code], and by any host taking the documented
## no-autoload path.
@abstract func apply_all() -> void

## Push ONE stored value at the engine — the instant-apply counterpart of [method apply_all]
## (D14).
##
## Non-abstract and a no-op by default: a backend that only stores values is a legitimate
## implementation (the host consumes them off [signal setting_changed]).
##
## [b]Why not [method apply_all] per change.[/b] A slider drag emits a write per pixel, and
## re-pushing every window mode, resolution, bus volume and InputMap binding on each is slow and
## flickers the window on the display rows. Panels call [method set_value] then this.
##
## Implementations must treat an unrecognised id as normal operation and stay silent — plain values
## like FOV and mouse sensitivity are the majority of ids and are the host's to consume.
func apply_one(_id: StringName) -> void:
	pass


## Push ONE action's binding at the live [InputMap] — the rebind counterpart of [method apply_one].
##
## A rebind cannot wait for the next [method apply_all]: a player who has just pressed a key expects
## it to work immediately, without leaving the settings page.
##
## The base body delegates to [method apply_all] rather than being abstract, so existing store-only
## subclasses keep parsing. Delegating is correct but broad — it re-pushes every window, bus and
## binding value for one key change — so subclasses SHOULD override it with a targeted
## implementation ([MKJsonSettingsBackend] does).
func apply_action(_action: StringName) -> void:
	apply_all()


## Capture stock [InputMap] bindings [b]before[/b] any override is applied — the source of truth for
## "Reset to Defaults". Must run before [method load], or the defaults captured are the user's
## overrides and the recovery path silently becomes a no-op.
@abstract func snapshot_input_defaults() -> void


## The input-store half of the contract: what the rebind rows read and write.
##
## All six are non-abstract with inert bodies, so a store-only backend stays a legitimate
## implementation. The inert answers are chosen so a rebind row over such a backend degrades VISIBLY
## rather than wrongly: no events means every row reads "Unbound", [code]false[/code] from
## [method has_action_override] keeps each Reset disabled, and the writes drop silently — the same
## face the panel shows for a null backend.
##
## Overriding [method set_action_events] without the read side (or vice versa) produces rows that
## capture but never display, so implement the six together ([MKJsonSettingsBackend] is the
## reference).

## The events bound to [param action]: its override when one exists, its stock bindings otherwise.
func get_action_events(_action: StringName) -> Array[InputEvent]:
	return []


## Records [param events] as the user's override for [param action]. Store-only: call
## [method apply_action] to push it at the live [InputMap].
func set_action_events(_action: StringName, _events: Array) -> void:
	pass


## The stock bindings captured by [method snapshot_input_defaults] — what "Reset to Defaults"
## restores, and what the panel derives the reserved-event list from.
func get_default_action_events(_action: StringName) -> Array[InputEvent]:
	return []


## Drops [param action]'s override and restores its stock bindings.
func reset_action_to_default(_action: StringName) -> void:
	pass


## Drops every override at once — the global recovery net.
func reset_all_actions_to_defaults() -> void:
	pass


## Whether [param action] currently carries a user override — what enables a row's Reset button.
func has_action_override(_action: StringName) -> bool:
	return false


## Optional parameterization hook. Returns the keys consumed from [param params].
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
