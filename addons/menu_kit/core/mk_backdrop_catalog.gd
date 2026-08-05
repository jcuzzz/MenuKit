@tool
class_name MKBackdropCatalog
extends Resource
## An explicit, authored list of [MKBackdropDef]s — the single resolution point for backdrops.
##
## The source catalog resolved backdrops by scanning a hardcoded game data directory with
## [DirAccess] (including a [code].remap[/code] workaround that is fragile in exported builds) and
## read the active id from a game autoload. All three are replaced here (plan §1.1, §3):
## [br]- the list is an [b]exported array[/b], so it is inspector-authored, export-safe, and carries
##   no resource path pointing outside the addon;
## [br]- resolution is pure data with no autoload lookup, so the addon cold-drops into an empty
##   project and this resource loads headlessly in tests;
## [br]- a miss warns through [MKLog] naming this resource and the field, never silently blanks.

## The backdrops this catalog offers, in author order. A host swaps or extends this array; nothing
## is discovered from the filesystem.
@export var backdrops: Array[MKBackdropDef] = []

## Which entry [method get_default] returns. Empty means "the first valid entry", so a one-entry
## catalog needs no id bookkeeping at all.
@export var default_id: StringName = &""


## Returns the backdrop with [param id], or null. A miss is a misconfiguration (a host selected an
## id that no longer exists), so it warns with the catalog path and field rather than returning a
## surprise default — callers that want a fallback ask for one explicitly via [method get_default].
func get_backdrop(id: StringName) -> MKBackdropDef:
	if id == &"":
		return null
	for def in backdrops:
		if def != null and def.id == id:
			return def
	MKLog.warn("%s: no backdrop with id '%s' (have: %s)"
		% [MKLog.context(self, "backdrops"), id, String(", ").join(_id_strings())])
	return null


## Returns the default backdrop: [member default_id] when set and present, otherwise the first valid
## entry. Returns null only for a genuinely empty catalog, and says so once — an empty catalog is
## legitimate (a host that supplies its own background) so it is a warning, not an error.
func get_default() -> MKBackdropDef:
	if default_id != &"":
		for def in backdrops:
			if def != null and def.id == default_id:
				return def
		MKLog.warn("%s: default_id '%s' is not in backdrops (have: %s) — falling back to the first entry"
			% [MKLog.context(self, "default_id"), default_id, String(", ").join(_id_strings())])
	for def in backdrops:
		if def != null and def.is_valid():
			return def
	MKLog.warn("%s: catalog has no valid backdrop entry" % MKLog.context(self, "backdrops"))
	return null


## True when [param id] resolves. Provided so callers can probe without tripping the miss warning —
## a settings page validating a stored id should not log for a routine check.
func has_backdrop(id: StringName) -> bool:
	for def in backdrops:
		if def != null and def.id == id:
			return true
	return false


## All valid ids in author order. Feeds a backdrop-picker row and the Phase 1 tests.
func get_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for def in backdrops:
		if def != null and def.is_valid():
			ids.append(def.id)
	return ids


func _id_strings() -> Array[String]:
	var out: Array[String] = []
	for id in get_ids():
		out.append(String(id))
	return out
