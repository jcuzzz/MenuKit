class_name MKCSharpProfileBackend
extends MKProfileBackend
## An [MKProfileBackend] whose roster lives in a C# node.
##
## The C# node implements [code]ListProfiles()[/code] (returning
## [code]Godot.Collections.Array<Godot.Collections.Dictionary>[/code] or a plain
## [code]Godot.Collections.Array[/code] of dictionaries), [code]CreateProfile(Dictionary)[/code],
## [code]DeleteProfile(string)[/code], [code]LoadProfile(string)[/code], and optionally
## [code]IsNameAvailable(string)[/code] and [code]MkConfigure(Dictionary)[/code].
##
## [b]Bridged signal:[/b] [signal MKProfileBackend.roster_changed], arity 0 — a delegate signal named
## [code]roster_changed[/code] or [code]RosterChanged[/code] re-emits here, which is what makes the
## select panel refresh after a C#-side mutation.
##
## A delegate that never exposes [code]IsNameAvailable[/code] still gets correct behaviour: the base
## default scans [method list_profiles], and that call comes straight back through this adapter.

var _bridge := MKCSharpDelegate.new("MKCSharpProfileBackend")


func _init() -> void:
	_bridge.bridge("roster_changed", _on_delegate_roster_changed)


func _mk_configure(params: Dictionary) -> Array[String]:
	return _bridge.configure(params)


func _ready() -> void:
	_bridge.ensure_resolved()


func list_profiles() -> Array[Dictionary]:
	return _bridge.to_dictionary_array("list_profiles", _bridge.forward("list_profiles"))


func create_profile(payload: Dictionary) -> Dictionary:
	return _bridge.to_dictionary("create_profile", _bridge.forward("create_profile", [payload]))


func delete_profile(id: String) -> bool:
	return _bridge.to_bool("delete_profile", _bridge.forward("delete_profile", [id]), false)


func load_profile(id: String) -> Dictionary:
	return _bridge.to_dictionary("load_profile", _bridge.forward("load_profile", [id]))


func is_name_available(profile_name: String) -> bool:
	if _bridge.supports_quiet("is_name_available"):
		return _bridge.to_bool(
			"is_name_available", _bridge.forward("is_name_available", [profile_name]), true)
	return super.is_name_available(profile_name)


func get_delegate() -> Node:
	return _bridge.get_delegate()


func _on_delegate_roster_changed() -> void:
	roster_changed.emit()
