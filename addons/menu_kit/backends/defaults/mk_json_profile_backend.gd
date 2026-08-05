class_name MKJsonProfileBackend
extends MKProfileBackend
## The shipped default roster: one JSON file under [code]user://[/code] (plan §4.1).
##
## Profiles are stored [b]verbatim[/b]. Whatever dictionary the creation flow assembles is what
## lands on disk; this backend adds exactly one key of its own ([code]id[/code]) and enforces
## exactly one rule of its own (unique [code]name[/code]). It never reads, validates, defaults, or
## migrates a gameplay field — that boundary is why the same file format serves an ARPG character
## and an FPS loadout, and why a host can add a field without touching MenuKit.
##
## [b]One caveat the "verbatim" promise cannot cover:[/b] JSON has a single number type, so a payload
## [code]int[/code] comes back from disk as a [code]float[/code] (verified: [code]3[/code] stored,
## [code]3.0[/code] returned after a reload — before the reload the in-memory copy is still an int).
## A host comparing a loaded stat with [code]==[/code] against an int literal must convert. This is
## a property of JSON, not a choice made here, but it is the surprise this backend hands over.
##
## [b]Id scheme.[/b] Ids come from a monotonic counter persisted in the file itself
## ([code]next_id[/code]), formatted [code]p_000001[/code]. The obvious alternative — a
## [Time] stamp — collides whenever two profiles are created inside the same millisecond, which is
## trivially reachable from a loop or a test, so it is not used here. The counter is only ever
## incremented, never reset by a delete, so a deleted profile's id is never reissued and stale
## references fail as "absent" rather than resolving to a stranger. On load the counter is raised
## past the highest id actually present, so a hand-edited file cannot make the backend mint a
## duplicate; [method create_profile] additionally skips any id already in the roster.
##
## [b]Persistence hygiene[/b] (plan §4.3). The file carries a [code]version[/code] integer. A file
## that will not parse, or whose structure does not match this schema, is [i]renamed aside[/i] to
## [code]<name>.corrupt-<n>.json[/code] (first free [code]n[/code]) and an empty roster boots, with
## one warning naming the file and the reason. Corruption is recoverable misconfiguration, not a
## contract violation, so it warns rather than erroring — and nothing is ever deleted, so a user
## who lost a roster to a bad write still has the bytes.
##
## On-disk schema (version 1):
## [codeblock]
## {
##   "version": 1,
##   "next_id": 3,
##   "profiles": [
##     {"id": "p_000001", "name": "Alice", ...host fields...},
##     {"id": "p_000002", "name": "Bob",   ...host fields...}
##   ]
## }
## [/codeblock]

## Bumped only when the on-disk layout changes in a way this script must branch on. A file whose
## version is unknown (a newer MenuKit wrote it) is treated as unreadable rather than guessed at.
const SCHEMA_VERSION := 1

const DEFAULT_FILE_PATH := "user://menukit_profiles.json"

## Keys this backend owns. A payload carrying one of these is a wiring mistake on the host's side
## (a creation step claiming a reserved key), so it warns and the backend's value wins.
const RESERVED_KEYS: Array[String] = ["id"]

var _file_path := DEFAULT_FILE_PATH
var _max_profiles := 0
var _profiles: Array[Dictionary] = []
var _next_id := 1
var _loaded := false


## Reads [code]file_path[/code] (String) and [code]max_profiles[/code] (int, 0 = unlimited) so a
## host can point two roster slots at different files, or cap a roster, without subclassing —
## the whole reason [MKBackendSlot] carries params (plan §4.1). Returns the keys consumed so
## MKRoot can warn about the ones it did not recognise.
func _mk_configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	if params.has("file_path"):
		consumed.append("file_path")
		var raw := String(params["file_path"])
		if raw.is_empty():
			MKLog.warn("%s: file_path is empty; falling back to '%s'" % [
				MKLog.context(get_script(), "file_path"), DEFAULT_FILE_PATH,
			])
		else:
			_file_path = raw
	if params.has("max_profiles"):
		consumed.append("max_profiles")
		var cap := int(params["max_profiles"])
		if cap < 0:
			MKLog.warn("%s: max_profiles is %d; negative is meaningless, treating as unlimited" % [
				MKLog.context(get_script(), "max_profiles"), cap,
			])
			cap = 0
		_max_profiles = cap
	# Configuration happens before the node enters the tree, so any already-cached state was read
	# from the wrong file. Drop it; the next call re-reads.
	_loaded = false
	return consumed


## Copies out, in stored order. Callers get their own dictionaries so a select panel holding a row
## cannot mutate the cache behind the backend's back and desync it from disk.
func list_profiles() -> Array[Dictionary]:
	_ensure_loaded()
	var out: Array[Dictionary] = []
	for entry in _profiles:
		out.append(entry.duplicate(true))
	return out


## Stores [param payload] verbatim with a backend-assigned id appended, and returns the stored
## entry. Returns an empty dictionary — the base class's documented failure signal — when the name
## is missing, blank, already taken, or the roster is at its configured cap. Those are ordinary
## outcomes of a user typing into a form, so they are not warnings; the creation flow is expected
## to have asked [method is_name_available] first and to surface the refusal itself.
func create_profile(payload: Dictionary) -> Dictionary:
	_ensure_loaded()
	if _max_profiles > 0 and _profiles.size() >= _max_profiles:
		MKLog.debug("MKJsonProfileBackend: roster is at max_profiles (%d); create refused" % _max_profiles)
		return {}
	var profile_name := String(payload.get("name", "")).strip_edges()
	if profile_name.is_empty():
		MKLog.debug("MKJsonProfileBackend: create refused, payload has no non-blank 'name'")
		return {}
	if not is_name_available(profile_name):
		MKLog.debug("MKJsonProfileBackend: create refused, name '%s' is taken" % profile_name)
		return {}

	var entry := payload.duplicate(true)
	for key in RESERVED_KEYS:
		if entry.has(key):
			MKLog.warn("%s: creation payload carries reserved key '%s'; the backend's value wins" % [
				MKLog.context(get_script(), key), key,
			])
	entry["id"] = _mint_id()
	_profiles.append(entry)
	_save()
	roster_changed.emit()
	return entry.duplicate(true)


## Returns whether the id existed. An absent id is a normal query result — a stale button, a
## double-click, a host asking speculatively — not a misconfiguration, so it does not warn.
func delete_profile(id: String) -> bool:
	_ensure_loaded()
	for i in _profiles.size():
		if String(_profiles[i].get("id", "")) == id:
			_profiles.remove_at(i)
			_save()
			roster_changed.emit()
			return true
	return false


## Full record, or an empty dictionary when absent. This backend keeps everything in memory, so
## there is no cheap-list/expensive-detail split to exploit; the method exists because the base
## contract has it and because a backend with a real database will need the seam.
func load_profile(id: String) -> Dictionary:
	_ensure_loaded()
	for entry in _profiles:
		if String(entry.get("id", "")) == id:
			return entry.duplicate(true)
	return {}


## The file this instance is actually reading and writing, for [code]dump_diagnostics()[/code]
## (plan §4.8) — the resolved path is one of the first things a bug report needs.
func get_file_path() -> String:
	return _file_path


## Forces the next access to re-read from disk. For tests and for a host that edits the file out
## from under a running menu; ordinary use never needs it.
func reload() -> void:
	_loaded = false
	_ensure_loaded()


func _mint_id() -> String:
	# Loop rather than trust the counter: a hand-edited file can contain an id that does not match
	# the p_%06d shape at all, so "counter is past the highest parsed id" is not by itself a
	# uniqueness proof.
	# Bounded rather than `while true` so a pathological file can never hang the menu: the roster is
	# finite, so size()+1 attempts must reach a free id.
	for _i in _profiles.size() + 1:
		var candidate := "p_%06d" % _next_id
		_next_id += 1
		if not _has_id(candidate):
			return candidate
	return "p_%06d" % _next_id


func _has_id(id: String) -> bool:
	for entry in _profiles:
		if String(entry.get("id", "")) == id:
			return true
	return false


func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_profiles = []
	_next_id = 1
	if not FileAccess.file_exists(_file_path):
		return

	var file := FileAccess.open(_file_path, FileAccess.READ)
	if file == null:
		# Unreadable is not corrupt — the bytes may be perfectly good and the file merely locked or
		# permission-denied. Renaming it aside would be the destructive response to a transient
		# problem, so boot empty and leave it alone. Writes will overwrite it if the user creates a
		# profile; that is the documented cost of not being able to read it.
		MKLog.warn("%s: cannot open profile store (error %d); starting with an empty roster" % [
			MKLog.context(_file_path), FileAccess.get_open_error(),
		])
		return
	var text := file.get_as_text()
	file.close()

	# JSON.new().parse() rather than the JSON.parse_string() static: the static pushes an engine-level
	# "ERROR: Parse JSON failed" of its own, which would make the ordinary, fully handled corrupt-file
	# path emit an ERROR line. Verified in this repo — the instance API reports through the return
	# value only, so the recovery stays a warning as §4.8 requires.
	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK:
		_quarantine("file is not valid JSON (line %d: %s)" % [
			json.get_error_line(), json.get_error_message(),
		])
		return
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		_quarantine("root of the file is not a JSON object")
		return
	var data: Dictionary = parsed

	var version := int(data.get("version", 0))
	if version > SCHEMA_VERSION:
		# A NEWER file is a downgraded install, not corruption. Leave it exactly where it is and boot
		# empty: renaming it would destroy the roster the newer install still reads, which is the very
		# harm quarantine exists to prevent. This matches MKJsonSettingsBackend — the two backends
		# previously took opposite positions on the same situation, and this one did what the other
		# named as the harm.
		MKLog.warn("%s: %s was written by a newer MenuKit (schema %d, this build reads %d) — starting with an empty roster and leaving the file untouched"
			% [MKLog.context(get_script()), _file_path, version, SCHEMA_VERSION])
		return
	if version < 1:
		_quarantine("schema version %d is not readable by MenuKit (expected 1..%d)" % [
			version, SCHEMA_VERSION,
		])
		return
	if typeof(data.get("profiles")) != TYPE_ARRAY:
		_quarantine("'profiles' is missing or is not an array")
		return

	var seen := {}
	var loaded: Array[Dictionary] = []
	for raw in (data["profiles"] as Array):
		if typeof(raw) != TYPE_DICTIONARY:
			_quarantine("a profile entry is not a JSON object")
			return
		var entry: Dictionary = raw
		var id := String(entry.get("id", ""))
		var entry_name := String(entry.get("name", ""))
		# id and name are the two fields the MKProfileBackend contract guarantees to callers, so an
		# entry missing either is unusable rather than merely odd. Dropping just that entry would be
		# the silent data loss §4.3 forbids, so the whole file goes aside intact instead.
		if id.is_empty() or entry_name.is_empty():
			_quarantine("a profile entry is missing 'id' or 'name'")
			return
		if seen.has(id):
			_quarantine("duplicate profile id '%s'" % id)
			return
		seen[id] = true
		loaded.append(entry)

	_profiles = loaded
	_next_id = maxi(1, int(data.get("next_id", 1)))
	for entry in _profiles:
		var id := String(entry["id"])
		if id.begins_with("p_"):
			var suffix := id.substr(2)
			if suffix.is_valid_int():
				_next_id = maxi(_next_id, suffix.to_int() + 1)


## Renames the unreadable file aside and boots an empty roster. Never deletes: the whole point is
## that a user who lost a roster to a bad write can still hand the bytes to support.
func _quarantine(reason: String) -> void:
	_profiles = []
	_next_id = 1
	var target := _next_corrupt_path()
	var err := DirAccess.rename_absolute(_file_path, target)
	if err == OK:
		MKLog.warn("%s: %s; renamed to '%s' and starting with an empty roster" % [
			MKLog.context(_file_path), reason, target,
		])
	else:
		MKLog.warn("%s: %s; could not rename it aside (error %d), so it will be overwritten on the next write" % [
			MKLog.context(_file_path), reason, err,
		])


func _next_corrupt_path() -> String:
	var base := _file_path.get_basename()
	# Bounded so a directory somehow full of corrupt-N files cannot spin forever. Past the bound the
	# returned path already exists; whether the rename then overwrites or fails is platform
	# behaviour I have not verified, and either way _quarantine reports the outcome.
	for n in range(1, 1000):
		var candidate := "%s.corrupt-%d.json" % [base, n]
		if not FileAccess.file_exists(candidate):
			return candidate
	return "%s.corrupt-1.json" % base


func _save() -> void:
	var data := {
		"version": SCHEMA_VERSION,
		"next_id": _next_id,
		"profiles": _profiles,
	}
	var dir := _file_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var mk_err := DirAccess.make_dir_recursive_absolute(dir)
		if mk_err != OK:
			MKLog.warn("%s: cannot create directory '%s' (error %d); roster not saved" % [
				MKLog.context(_file_path), dir, mk_err,
			])
			return
	var file := FileAccess.open(_file_path, FileAccess.WRITE)
	if file == null:
		# Warn, not error: a full disk or a locked file is an environment problem the menu can keep
		# running through. The in-memory roster stays valid for this session and is simply not durable.
		MKLog.warn("%s: cannot write profile store (error %d); the roster is in memory only" % [
			MKLog.context(_file_path), FileAccess.get_open_error(),
		])
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
