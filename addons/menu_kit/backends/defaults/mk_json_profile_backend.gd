class_name MKJsonProfileBackend
extends MKProfileBackend
## The shipped default roster: one JSON file under [code]user://[/code].
##
## Profiles are stored [b]verbatim[/b]. Whatever dictionary the creation flow assembles is what lands
## on disk; this backend adds one key of its own ([code]id[/code]), enforces one rule of its own
## (unique [code]name[/code]), and normalises that same field — storing the
## [method String.strip_edges]-trimmed name it actually checked, because a rule enforced over a
## trimmed value while the untrimmed value is stored is a rule two spaces defeat. It never reads,
## validates, defaults, or migrates a gameplay field.
##
## [b]Payload [int]s keep their type across a save/load cycle[/b], which JSON on its own cannot do —
## it has one number type, so a stored [code]3[/code] would come back as [code]3.0[/code]. Ints are
## written through [MKJsonCodec]'s [code]{"__mk_type": "int", "v": 3}[/code] envelope and decoded
## back on load, so [method @GlobalScope.typeof] reports [constant TYPE_INT] after a reload.
## [br][b][Vector2i] round-trips too[/b], through the same codec and unconditionally (JSON has no form
## for it at all). A payload may carry one at any nesting depth and gets a [Vector2i] back.
## [br][b]A payload may not carry the discriminator key itself.[/b] [constant MKJsonCodec.TYPE_TAG] is
## the codec's namespace, and a host dictionary containing it — at any depth — is refused by
## [method create_profile].
## [br][b]Floats stay floats and bools stay bools[/b] — only ints are enveloped, and a bool is not an
## int for this purpose.
## [br][b]Legacy files get no migration.[/b] A roster written before the envelope existed stores its
## ints as plain JSON numbers and they still read back as floats; rewriting them would mean guessing
## which of a host's numbers were "meant" to be ints. Any profile re-saved after this build (a create
## or a delete rewrites the whole file) picks up the envelope for whatever is an int in memory.
##
## [b]Id scheme.[/b] Ids come from a monotonic counter persisted in the file itself
## ([code]next_id[/code]), formatted [code]p_000001[/code] — not a [Time] stamp, which collides when
## two profiles are created inside the same millisecond. The counter is only ever incremented, never
## reset by a delete, so a deleted profile's id is never reissued and stale references fail as
## "absent" rather than resolving to a stranger. On load the counter is raised past the highest id
## actually present, so a hand-edited file cannot make the backend mint a duplicate;
## [method create_profile] additionally skips any id already in the roster.
##
## [b]Persistence hygiene.[/b] The file carries a [code]version[/code] integer. A file that will not
## parse, or whose structure does not match this schema, is [i]renamed aside[/i] to
## [code]<name>.corrupt-<n>.json[/code] (first free [code]n[/code]) and an empty roster boots, with
## one warning naming the file and the reason. It warns rather than erroring, and nothing is ever
## deleted — a user who lost a roster to a bad write still has the bytes.
##
## On-disk schema (version 1):
## [codeblock]
## {
##   "version": 1,
##   "next_id": 3,
##   "profiles": [
##     {"id": "p_000001", "name": "Alice", "level": {"__mk_type": "int", "v": 7}, ...host fields...},
##     {"id": "p_000002", "name": "Bob",   ...host fields...}
##   ]
## }
## [/codeblock]
## [code]version[/code] and [code]next_id[/code] are plain numbers; the type envelope appears only
## INSIDE a profile entry, and only for a value JSON cannot carry faithfully ([MKJsonCodec] owns it
## and is shared with [MKJsonSettingsBackend]). [code]id[/code] and [code]name[/code] are Strings, so
## they pass through it unchanged and stay readable in a hand-inspected file.

## Bumped only when the on-disk layout changes in a way this script must branch on.
##
## A file written by a NEWER MenuKit is left exactly where it is: this build boots an empty roster
## and warns. Renaming it aside would destroy the roster the newer install still reads, which is the
## harm quarantine exists to prevent. Only a file that is genuinely unreadable — bad JSON, wrong
## shape, or a version below 1 — is quarantined. [MKJsonSettingsBackend] takes the same position.
##
## [b]Leaving the file also means not WRITING over it[/b], and that takes a latch. Unlike a settings
## store, a roster cannot survive being overwritten: the first create from this build would rewrite
## the whole file and the newer install's characters would be gone with no sidecar. So detecting a
## newer file also latches this backend READ-ONLY ([member _read_only_newer]): [method create_profile]
## returns an empty dictionary and [method delete_profile] returns false, each with one warning naming
## the version, and the bytes on disk are never touched. Both refusals are shapes their callers
## already handle. The latch is cleared by the next successful load — replace or remove the file and
## the backend writes again.
##
## [b]The int envelope did NOT bump this[/b]: the change is purely additive (an enveloped int is a
## JSON object where a bare number used to sit, and a legacy bare number still reads), and it is part
## of the INITIAL shipped format rather than a migration between two versions users ever had.
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
## Set by [method _ensure_loaded] when the file on disk carries a schema version this build cannot
## read, and the reason every write is refused while it is set — see [constant SCHEMA_VERSION].
## Re-evaluated by every load, so it is not sticky past the file that caused it.
var _read_only_newer := false
## The version that latched it, so the refusal warning can name the number rather than say "newer".
var _newer_version := 0


## Reads [code]file_path[/code] (String) and [code]max_profiles[/code] (int, 0 = unlimited) so a host
## can point two roster slots at different files, or cap a roster, without subclassing. Returns the
## keys consumed so MKRoot can warn about the ones it did not recognise.
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


## Stores [param payload] with a backend-assigned id appended and [code]name[/code] trimmed, and
## returns the stored entry. Every other field is verbatim; [code]name[/code] is normalised because
## the uniqueness rule is checked against the trimmed form, so storing the raw one would let
## [code]"  Alice  "[/code] and [code]"Alice"[/code] coexist as two rows a player cannot tell apart.
## Returns an empty dictionary — the base class's documented failure signal — when the name is
## missing, blank, already taken, the roster is at its configured cap, or the store on disk was
## written by a newer MenuKit (see [constant SCHEMA_VERSION]; that one warns). The first four are
## ordinary outcomes of a user typing into a form, so they are not warnings; the creation flow is
## expected to have asked [method is_name_available] first and to surface the refusal itself.
##
## [b]It also refuses a payload carrying [constant MKJsonCodec.TYPE_TAG] anywhere inside it[/b], and
## THAT one warns. The tag is the codec's namespace, so a host dictionary spelling it is a wiring
## mistake, and accepting it writes a file the loader cannot survive: decoding an entry containing
## [code]{"__mk_type": ...}[/code] collapses that dictionary to an int or to null, failing the "every
## entry is a JSON object with an id and a name" check — whose answer is a quarantine of the WHOLE
## roster file. Refusal at the door costs one create; acceptance costs the roster.
func create_profile(payload: Dictionary) -> Dictionary:
	_ensure_loaded()
	if _refuse_write("create"):
		return {}
	var tag_path := _find_type_tag(payload, "payload")
	if not tag_path.is_empty():
		MKLog.warn("%s: creation payload contains the reserved key '%s' at %s; MenuKit owns that key as its JSON type discriminator and a file carrying it would be quarantined on load, taking every other profile with it. The create is refused" % [
			MKLog.context(get_script(), MKJsonCodec.TYPE_TAG), MKJsonCodec.TYPE_TAG, tag_path,
		])
		return {}
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
	# Store the TRIMMED name — the value the uniqueness rule above was checked against. Storing the raw
	# payload makes the rule bypassable by whitespace: "  Alice  " would go to disk untrimmed, so a
	# later create of "Alice" finds no collision and the roster holds two rows that render identically.
	entry["name"] = profile_name
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
##
## Returns false WITHOUT deleting anything while the read-only latch is set (a store written by a
## newer MenuKit — see [constant SCHEMA_VERSION]): the profile the caller named is not in this
## build's roster at all, and the only way to honour a delete would be to rewrite the newer file.
func delete_profile(id: String) -> bool:
	_ensure_loaded()
	if _refuse_write("delete"):
		return false
	for i in _profiles.size():
		if String(_profiles[i].get("id", "")) == id:
			_profiles.remove_at(i)
			_save()
			roster_changed.emit()
			return true
	return false


## Full record, or an empty dictionary when absent. This backend keeps everything in memory, so there
## is no cheap-list/expensive-detail split to exploit; the seam exists for backends with a database.
func load_profile(id: String) -> Dictionary:
	_ensure_loaded()
	for entry in _profiles:
		if String(entry.get("id", "")) == id:
			return entry.duplicate(true)
	return {}


## The file this instance is actually reading and writing, for [code]dump_diagnostics()[/code]
## — the resolved path is one of the first things a bug report needs.
func get_file_path() -> String:
	return _file_path


## Forces the next access to re-read from disk. For tests and for a host that edits the file out
## from under a running menu; ordinary use never needs it.
func reload() -> void:
	_loaded = false
	_ensure_loaded()


## Returns the path of the first Dictionary under [param value] that carries
## [constant MKJsonCodec.TYPE_TAG], or "" when there is none.
##
## The path is built as it descends ([code]payload/inventory/0[/code]) because "your payload contains
## a reserved key" is unactionable on a nested host structure — the author has to be told WHERE. The
## walk must mirror [method MKJsonCodec.encode_value]'s recursion exactly (dictionaries and arrays,
## nothing else), so anything the encoder would descend into is something this scan has seen. First
## hit wins: one named example is enough to send the author to the field.
func _find_type_tag(value: Variant, path: String) -> String:
	if value is Dictionary:
		var d := value as Dictionary
		if d.has(MKJsonCodec.TYPE_TAG):
			return path
		for key in d.keys():
			var found := _find_type_tag(d[key], "%s/%s" % [path, key])
			if not found.is_empty():
				return found
		return ""
	if value is Array:
		var a := value as Array
		for i in a.size():
			var found := _find_type_tag(a[i], "%s/%d" % [path, i])
			if not found.is_empty():
				return found
	return ""


## True when the store on disk was written by a newer MenuKit, in which case [param gesture] is
## refused rather than performed. Warns — unlike the ordinary create refusals, which are debug —
## because this is an installation condition the user cannot fix from the menu, and it is the line
## that explains a New Character button that does nothing. Warned per refusal rather than once per
## latch: creates and deletes are deliberate gestures, not a per-frame path, so there is no flood to
## suppress.
func _refuse_write(gesture: String) -> bool:
	if not _read_only_newer:
		return false
	MKLog.warn("%s: %s was written by a newer MenuKit (schema %d, this build reads %d) — this build is read-only against it, so the %s is refused rather than overwriting that roster"
		% [MKLog.context(get_script()), _file_path, _newer_version, SCHEMA_VERSION, gesture])
	return true


func _mint_id() -> String:
	# Loop rather than trust the counter: a hand-edited file can contain an id that does not match the
	# p_%06d shape at all, so "counter is past the highest parsed id" is not a uniqueness proof.
	# Bounded rather than `while true` so a pathological file cannot hang the menu — the roster is
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
	# Cleared on every load, and set again below only if THIS file is still the newer one. A latch that
	# survived the file that caused it would wedge a backend whose store the user has since replaced.
	_read_only_newer = false
	_newer_version = 0
	if not FileAccess.file_exists(_file_path):
		return

	var file := FileAccess.open(_file_path, FileAccess.READ)
	if file == null:
		# Unreadable is not corrupt — the bytes may be good and the file merely locked. Renaming it
		# aside would be destructive for a transient problem, so boot empty and leave it alone. A later
		# create overwrites it; that is the documented cost of not being able to read it.
		MKLog.warn("%s: cannot open profile store (error %d); starting with an empty roster" % [
			MKLog.context(_file_path), FileAccess.get_open_error(),
		])
		return
	var text := file.get_as_text()
	file.close()

	# JSON.new().parse() rather than the JSON.parse_string() static: the static pushes an engine-level
	# "ERROR: Parse JSON failed" of its own, which would make the handled corrupt-file path emit an
	# ERROR line. The instance API reports through the return value only, so the recovery stays a
	# warning.
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
		# empty: renaming it would destroy the roster the newer install still reads.
		#
		# "Leave it" has to cover the WRITE side too, or the leave is one gesture long: the first create
		# from this build would rewrite the whole file at SCHEMA_VERSION and the newer install's roster
		# would be gone with no sidecar. So the backend latches read-only until a load succeeds against a
		# file it can read.
		_read_only_newer = true
		_newer_version = version
		MKLog.warn("%s: %s was written by a newer MenuKit (schema %d, this build reads %d) — starting with an empty roster, leaving the file untouched and refusing every write until it is replaced"
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
		# DECODE FIRST, VALIDATE SECOND — load-bearing in both directions. Validation must see what
		# callers will see, so validating the raw form would admit an entry whose `id` or `name` a
		# malformed envelope destroyed. And the shape check must run on the DECODED value, because
		# decoding can turn a JSON object into a non-object (a top-level entry that is itself an envelope
		# decodes to an int or null), and assigning that into a typed Dictionary local would be a hard
		# script error rather than the quarantine this class promises.
		var decoded: Variant = MKJsonCodec.decode_value(raw, _file_path)
		if typeof(decoded) != TYPE_DICTIONARY:
			_quarantine("a profile entry is not a JSON object")
			return
		var entry: Dictionary = decoded
		var id := String(entry.get("id", ""))
		var entry_name := String(entry.get("name", ""))
		# id and name are the two fields the MKProfileBackend contract guarantees to callers, so an entry
		# missing either is unusable. Dropping just that entry would be silent data loss, so the whole
		# file goes aside intact instead.
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
	# Bounded so a directory full of corrupt-N files cannot spin forever. Past the bound the returned
	# path already exists; whether the rename overwrites or fails is platform behaviour, and either way
	# _quarantine reports the outcome.
	for n in range(1, 1000):
		var candidate := "%s.corrupt-%d.json" % [base, n]
		if not FileAccess.file_exists(candidate):
			return candidate
	return "%s.corrupt-1.json" % base


func _save() -> void:
	# Encode each profile as a WHOLE dictionary: `id` and `name` are Strings the codec passes through
	# untouched, so encoding everything produces identical bytes to encoding only the host payload and
	# keeps no field list in sync. The roster's own bookkeeping (`version`, `next_id`) sits OUTSIDE the
	# profiles array and is written plain, which keeps the top-level shape readable by eye and by
	# _ensure_loaded's int() reads.
	var encoded: Array = []
	for entry in _profiles:
		encoded.append(MKJsonCodec.encode_value(entry, true))
	var data := {
		"version": SCHEMA_VERSION,
		"next_id": _next_id,
		"profiles": encoded,
	}
	var dir := _file_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var mk_err := DirAccess.make_dir_recursive_absolute(dir)
		if mk_err != OK:
			MKLog.warn("%s: cannot create directory '%s' (error %d); roster not saved" % [
				MKLog.context(_file_path), dir, mk_err,
			])
			return
	# Atomic through the shared helper, same as the settings store: a truncate-then-write here would
	# lose the WHOLE roster to an interrupted save, and the load path would then quarantine the file
	# and boot empty. Warn, not error: a full disk or a locked file is an environment problem the menu
	# keeps running through. The in-memory roster stays valid for this session and is simply not
	# durable.
	var err := MKJsonCodec.write_atomic(_file_path, JSON.stringify(data, "\t"))
	if err != OK:
		MKLog.warn("%s: cannot write profile store (error %d); the roster is in memory only" % [
			MKLog.context(_file_path), err,
		])
		return
