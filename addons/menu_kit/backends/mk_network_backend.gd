@abstract
class_name MKNetworkBackend
extends Node
## Server discovery and connection (plan §4.1, D7).
##
## Optional by design: the shipped [code]default_config.tres[/code] leaves this slot [b]empty[/b],
## so a cold drop has no server browser at all — the right first impression for a single-player
## Doom-like, and what keeps the cold-drop gate honest. Assigning a slot is what makes the panel
## appear.
##
## MenuKit ships no actual networking (plan §8). The stub exists so the panel and its states are
## real and testable; the host supplies the transport.

## Connection lifecycle, kept as an enum rather than free strings so the panel can render each state
## without matching on message text.
enum ConnectState { IDLE, CONNECTING, CONNECTED, FAILED, CANCELLED }

## Emitted when the list changes — including mid-refresh, so the panel can render entries as they
## arrive rather than waiting for a complete sweep.
signal servers_changed()

## [param message] is user-facing and may be empty for states that need no explanation.
signal connect_state_changed(state: ConnectState, message: String)

## Known servers. Entries carry at least [code]id[/code] and [code]name[/code]; the panel renders
## [code]players[/code], [code]max_players[/code], [code]ping[/code], and [code]map[/code] when
## present, so a minimal backend is not forced to invent them.
@abstract func list_servers() -> Array[Dictionary]

## Begin connecting to one entry from [method list_servers]. Progress is reported through
## [signal connect_state_changed] rather than a return value, because connection is asynchronous
## and the panel must stay responsive (and cancellable) throughout.
@abstract func connect_to(entry: Dictionary) -> void

## Abort an in-flight connection. Must be safe to call when idle.
@abstract func cancel() -> void


## Ask for a fresh sweep. Non-abstract and a no-op by default: a backend with a static list has
## nothing to do, and forcing every implementation to write an empty override is noise.
func refresh() -> void:
	pass


## Optional parameterization hook (plan §4.1). Returns the keys consumed from [param params].
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
