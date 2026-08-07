@abstract
class_name MKProfileBackend
extends Node
## The character/save roster.
##
## Profiles are opaque [Dictionary]s end to end: the creation flow assembles one from its steps and
## hands it here verbatim, and the host project defines the meaning of every field. MenuKit never
## interprets a payload.

## Emitted whenever the roster changes by any route, so the select panel never has to poll or be
## told to refresh by whoever mutated it.
signal roster_changed()

## All stored profiles, in display order. Each entry must carry at least an [code]id[/code] and a
## [code]name[/code]; everything else is the host's.
@abstract func list_profiles() -> Array[Dictionary]

## Persist a new profile from a creation payload. Returns the stored entry (with whatever id the
## backend assigned), or an empty dictionary on failure.
@abstract func create_profile(payload: Dictionary) -> Dictionary

## Returns whether the profile existed and was removed.
@abstract func delete_profile(id: String) -> bool

## Full record for one profile, or an empty dictionary when absent. Separate from
## [method list_profiles] so a backend may keep the list cheap and load detail on demand.
@abstract func load_profile(id: String) -> Dictionary


## True when a name is free. The default scans [method list_profiles]; a backend with a real name
## index overrides it.
func is_name_available(profile_name: String) -> bool:
	for entry in list_profiles():
		if String(entry.get("name", "")).nocasecmp_to(profile_name) == 0:
			return false
	return true


## Optional parameterization hook. Returns the keys consumed from [param params].
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
