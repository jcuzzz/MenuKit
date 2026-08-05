@tool
class_name MKBackendSlot
extends Resource
## One configured backend: which script to instantiate, and the plain data it needs (plan §4.1).
##
## Backends are Script references rather than Resource instances because they need scene-tree
## access (scene changes, DisplayServer calls, timers, a multiplayer peer's lifetime) and must not
## serialize runtime state. That creates a gap: a runtime-instantiated Script only ever gets its
## export [i]defaults[/i], so a host had nowhere to say "start [b]this[/b] scene" without
## subclassing a backend for a single value. [member params] is that place.
##
## This is also what keeps the shipped defaults demo-free. [code]MKSceneMenuBackend[/code] names no
## path of its own — [code]default_config.tres[/code] leaves its params empty and the demo supplies
## real scenes from its own [code].tres[/code], so no addon file ever references a demo path and
## ship gate 1 holds by construction.

## The backend implementation. Must extend the abstract base its slot expects; [code]MKRoot[/code]
## checks that at boot and reports a contract violation rather than failing at first call.
##
## [b]Never name this member [code]script[/code].[/b] [code]script[/code] is a reserved built-in on
## every [Object]: exporting it is a parse error, and any route around the parser would make an
## inspector assignment replace this resource's own script — turning the slot into an instance of
## the backend class.
@export var backend_script: Script:
	set(value):
		backend_script = value
		emit_changed()

## Plain data handed to the backend's [code]_mk_configure(params) -> Array[String][/code] before it
## enters the tree. Keys are the backend's own vocabulary (e.g. [code]game_scene[/code]).
##
## Only the backend knows its keys and only [code]MKRoot[/code] knows this slot's identity, which is
## why [code]_mk_configure[/code] returns the keys it consumed: MKRoot diffs that against
## [method Dictionary.keys] and warns by name on leftovers. A silently ignored typo in a config
## dictionary is otherwise a bad afternoon.
@export var params: Dictionary = {}:
	set(value):
		params = value
		emit_changed()


## True when this slot has something to instantiate. An empty slot is [b]valid config[/b], not an
## error — the shipped [code]default_config.tres[/code] leaves the network slot empty precisely so
## the cold drop has no server browser, and gate 2 stays warning-free.
func is_assigned() -> bool:
	return backend_script != null


## Verifies the assigned script extends [param expected_base]. Returns an empty string when valid,
## or a ready-to-log reason naming both scripts. MKRoot crashes loudly on failure (plan §4.8: a
## backend that does not extend its base is a contract violation, not a recoverable misconfig).
func validate_against(expected_base: Script) -> String:
	if not is_assigned():
		return ""
	if expected_base == null:
		return ""
	var walker: Script = backend_script
	while walker != null:
		if walker == expected_base:
			return ""
		walker = walker.get_base_script()
	return "%s: backend_script '%s' does not extend '%s'" % [
		MKLog.context(self, "backend_script"),
		backend_script.resource_path,
		expected_base.resource_path,
	]
