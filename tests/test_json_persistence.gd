extends MKTest
## Round-trip and corrupt-file recovery for both JSON backends (plan §4.3 "Persistence hygiene").
##
## The rule is narrow and absolute: a corrupt or unparseable store is renamed aside and defaults
## boot, with a warning. Never a crash, never silent data loss. Both halves matter — quarantining
## without renaming destroys the user's data, and booting without warning hides that it happened.
##
## Each backend's own leg proved this in a throwaway script. That is not the same as covering it:
## a throwaway proves the code worked once on the author's machine, while ship gate 8 counts what
## the suite runs. These are the in-suite versions.

const SETTINGS_PATH := "user://test_settings_persistence.json"
const PROFILES_PATH := "user://test_profiles_persistence.json"


func run_tests() -> void:
	_clean(SETTINGS_PATH)
	_clean(PROFILES_PATH)
	await _test_settings_round_trip()
	await _test_settings_type_changing_write()
	await _test_settings_corrupt_recovery()
	await _test_profiles_round_trip()
	await _test_profiles_corrupt_recovery()
	await _test_profile_payload_keeps_its_types()
	await _test_the_settings_store_is_deliberately_not_enveloped()
	await _test_a_legacy_plain_profile_file_still_loads()
	await _test_a_malformed_envelope_warns_once_and_reads_as_null()
	await _test_a_profile_entry_that_is_itself_an_envelope_quarantines()
	_clean(SETTINGS_PATH)
	_clean(PROFILES_PATH)


func _test_settings_round_trip() -> void:
	var backend := _make_settings()
	backend.set_value(&"video/max_fps", 144)
	backend.set_value(&"audio/bus/Master", 0.5)
	backend.set_value(&"gameplay/subtitles", true)
	backend.set_value(&"gameplay/name", "probe")
	backend.save()

	# A FRESH instance, not a reload of the same object — the point is that the bytes on disk carry
	# the state, not that an in-memory cache survived.
	var reloaded := _make_settings()
	reloaded.load()
	check_eq(int(reloaded.get_value(&"video/max_fps", 0)), 144, "settings: int survives a round trip")
	check_eq(reloaded.get_value(&"audio/bus/Master", 0.0), 0.5, "settings: float survives")
	check_eq(reloaded.get_value(&"gameplay/subtitles", false), true, "settings: bool survives")
	check_eq(reloaded.get_value(&"gameplay/name", ""), "probe", "settings: String survives")
	check_eq(reloaded.get_value(&"absent/id", "fallback"), "fallback",
		"settings: an unset id returns the caller's default")

	backend.free()
	reloaded.free()


## Regression: writing a value of a DIFFERENT type over a stored one must not error. The dedup
## compared int == String directly, which is a script error ("Invalid operands in operator '=='") —
## reachable from a hand-edited store or any host that changes a value's type. Found by the Phase 3
## test leg; the fix gates the dedup on typeof equality first.
func _test_settings_type_changing_write() -> void:
	var backend := _make_settings()
	backend.set_value(&"probe/shifty", 3)
	var announced: Array = []
	backend.setting_changed.connect(func(id: StringName, value: Variant) -> void:
		announced.append([id, value]))
	backend.set_value(&"probe/shifty", "three")
	check_eq(backend.get_value(&"probe/shifty", null), "three",
		"a type-changing write lands instead of erroring in the dedup comparison")
	check_eq(announced.size(), 1, "the type-changing write announces exactly once")
	# The dedup itself must survive the fix: an identical same-type rewrite stays silent.
	backend.set_value(&"probe/shifty", "three")
	check_eq(announced.size(), 1, "an identical rewrite is still deduplicated after the type guard")
	backend.free()


## Truncating mid-object is the realistic corruption: a power cut during a write, not random bytes.
func _test_settings_corrupt_recovery() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	check(f != null, "settings: could open the store to corrupt it")
	if f == null:
		return
	f.store_string('{"version": 1, "values": {"video/max_fps": 14')
	f.close()

	var backend := _make_settings()
	backend.load()
	check_eq(backend.get_value(&"video/max_fps", 60), 60,
		"settings: a corrupt store boots defaults rather than crashing")
	# Assert the rename ONLY. The previous form also accepted "the file no longer exists", which is
	# satisfied by deleting it — the precise failure the assertion names. Replacing the quarantine
	# with DirAccess.remove_absolute kept the suite green.
	check(_corrupt_sibling_exists(SETTINGS_PATH),
		"settings: the bad file was renamed aside, not deleted — the user's data is recoverable")
	backend.free()


func _test_profiles_round_trip() -> void:
	var backend := _make_profiles()
	var created := backend.create_profile({"name": "Alice", "archetype": "scout"})
	check(not created.is_empty(), "profiles: create returns the stored entry")
	check(created.has("id"), "profiles: the backend assigned an id")
	check_eq(created.get("archetype", ""), "scout",
		"profiles: host fields are stored verbatim — MenuKit never interprets a payload")

	var second := backend.create_profile({"name": "Bob"})
	check(not second.is_empty(), "profiles: a second profile is accepted")
	check(created.get("id") != second.get("id"), "profiles: ids are unique")

	check(backend.create_profile({"name": "alice"}).is_empty(),
		"profiles: a duplicate name is refused case-insensitively")

	var reloaded := _make_profiles()
	check_eq(reloaded.list_profiles().size(), 2, "profiles: the roster survives a fresh instance")
	check_eq(reloaded.load_profile(String(created.get("id"))).get("name", ""), "Alice",
		"profiles: an individual profile loads by id")
	check(reloaded.delete_profile(String(created.get("id"))), "profiles: delete reports success")
	check(not reloaded.delete_profile("no_such_id"),
		"profiles: deleting something absent returns false rather than warning — that is a query result")
	check_eq(reloaded.list_profiles().size(), 1, "profiles: the roster shrank")

	backend.free()
	reloaded.free()


func _test_profiles_corrupt_recovery() -> void:
	var f := FileAccess.open(PROFILES_PATH, FileAccess.WRITE)
	check(f != null, "profiles: could open the store to corrupt it")
	if f == null:
		return
	f.store_string('{"version": 1, "profiles": [{"id": "p_000001", "na')
	f.close()

	var backend := _make_profiles()
	check_eq(backend.list_profiles().size(), 0,
		"profiles: a corrupt store boots an empty roster rather than crashing")
	check(_corrupt_sibling_exists(PROFILES_PATH),
		"profiles: the bad file was renamed aside, not deleted")
	# Still usable afterwards — quarantine must not leave the backend wedged.
	check(not backend.create_profile({"name": "Recovered"}).is_empty(),
		"profiles: the backend still works after a quarantine")
	backend.free()

	# A file written by a NEWER MenuKit is left alone, not quarantined. The two backends took
	# opposite positions on this, and the profile side did exactly what the settings side's comment
	# named as the harm: renaming aside destroys the roster the newer install still reads.
	_clean(PROFILES_PATH)
	var newer := FileAccess.open(PROFILES_PATH, FileAccess.WRITE)
	check(newer != null, "profiles: could write a future-version store")
	if newer != null:
		newer.store_string('{"version": 99, "next_id": 1, "profiles": []}')
		newer.close()
	var downgraded := _make_profiles()
	check_eq(downgraded.list_profiles().size(), 0, "profiles: a newer store boots an empty roster")
	check(FileAccess.file_exists(PROFILES_PATH),
		"profiles: and is LEFT IN PLACE — renaming it would destroy what the newer install reads")
	check(not _corrupt_sibling_exists(PROFILES_PATH),
		"profiles: specifically, it is not quarantined")
	downgraded.free()


## [b]The type envelope, from the host's side of the boundary[/b] (Phase 5). A profile payload is
## OPAQUE host data, so the backend has no read site at which it could coerce a number back — its only
## options are int fidelity or silently degrading somebody else's field. Fidelity was chosen, and this
## is what pins it: an int that reloads as 7.0 passes `== 7` and then fails the first `is int`, an
## array index, or a `match` a host writes against it.
##
## The bool case is asserted on the BYTES as well as on the type, because a bool that had been
## enveloped would come back as 0/1 and still pass every truthiness test in a host project — which is
## exactly the kind of wrong nobody notices.
func _test_profile_payload_keeps_its_types() -> void:
	_clean(PROFILES_PATH)
	var backend := _make_profiles()
	var created := backend.create_profile({
		"name": "Alice", "level": 7, "hardcore": true, "speed": 1.5, "gear": {"slots": 3},
	})
	check(not created.is_empty(), "precondition: the profile was created")
	backend.free()

	# A FRESH instance on the same file: the point is the bytes, not an in-memory cache.
	var reloaded := _make_profiles()
	var entries := reloaded.list_profiles()
	check_eq(entries.size(), 1, "the roster reloaded")
	if entries.size() == 1:
		var entry: Dictionary = entries[0]
		check_eq(typeof(entry.get("level")), TYPE_INT,
			"an int payload field is still an INT after a full save/load cycle — JSON alone cannot do this")
		check_eq(entry.get("level"), 7, "with its value")
		check_eq(typeof(entry.get("speed")), TYPE_FLOAT, "a float stays a float")
		check_eq(entry.get("speed"), 1.5, "unrounded")
		check_eq(typeof(entry.get("hardcore")), TYPE_BOOL,
			"and a bool stays a BOOL rather than becoming an enveloped 0/1")
		check_eq(entry.get("hardcore"), true, "with its value")
		var gear: Variant = entry.get("gear")
		check(gear is Dictionary, "a nested container survives")
		if gear is Dictionary:
			check_eq(typeof((gear as Dictionary).get("slots")), TYPE_INT,
				"and the codec recursed into it — an int nested one level deep is enveloped too")

	var raw := FileAccess.get_file_as_string(PROFILES_PATH)
	check(raw.contains('"hardcore": true'),
		"the bool is written as a plain JSON true, with no envelope around it — asserted on the bytes, because an enveloped bool would still read as truthy")
	check(raw.contains(MKJsonCodec.TYPE_TAG),
		"precondition: this file DOES carry envelopes, so the line above is about the bool specifically")
	check(raw.contains('"name": "Alice"'),
		"and a String passes through unenveloped, so a hand-inspected file stays readable")
	reloaded.free()
	_clean(PROFILES_PATH)


## [b]The settings store deliberately does NOT envelope ints, and that is preserved on purpose.[/b]
## Its format predates the envelope and is already shipped, every application site coerces with an
## explicit int(...) anyway, and enveloping would make every settings file this repo has written a
## mixed-format file. So a stored int reading back as a float here is the CONTRACT, not a defect — and
## [Vector2i], which JSON cannot carry at all, is enveloped in both backends.
func _test_the_settings_store_is_deliberately_not_enveloped() -> void:
	_clean(SETTINGS_PATH)
	var backend := _make_settings()
	backend.set_value(&"video/max_fps", 144)
	backend.set_value(&"video/resolution", Vector2i(1920, 1080))
	backend.save()
	var raw := FileAccess.get_file_as_string(SETTINGS_PATH)
	backend.free()

	var reloaded := _make_settings()
	reloaded.load()
	check_eq(typeof(reloaded.get_value(&"video/max_fps", null)), TYPE_FLOAT,
		"a settings int reads back as a FLOAT — the profile backend's envelope is not applied here, by decision")
	check_eq(int(reloaded.get_value(&"video/max_fps", 0)), 144,
		"with the value intact, which is why every application site's int(...) is sufficient")
	check(not raw.contains('"__mk_type": "int"'),
		"and no int envelope was written into the settings file at all")
	var resolution: Variant = reloaded.get_value(&"video/resolution", null)
	check_eq(typeof(resolution), TYPE_VECTOR2I,
		"Vector2i IS enveloped in both backends — without it the value is not merely imprecise but absent from the format")
	check_eq(resolution, Vector2i(1920, 1080), "and round-trips exactly")
	reloaded.free()
	_clean(SETTINGS_PATH)


## A roster written before the envelope existed gets NO migration: its ints are plain JSON numbers and
## still read back as floats, exactly as they always did. Rewriting them would mean guessing which of a
## host's numbers were "meant" to be ints — the interpretation this backend refuses to do — and the
## file must not be treated as corrupt for being old.
func _test_a_legacy_plain_profile_file_still_loads() -> void:
	_clean(PROFILES_PATH)
	var file := FileAccess.open(PROFILES_PATH, FileAccess.WRITE)
	check(file != null, "the legacy store was written")
	if file == null:
		return
	# Hand-written, because the point is a file this build's serializer would never produce.
	file.store_string('{"version": 1, "next_id": 2, "profiles": [{"id": "p_000001", "name": "Alice", "level": 7}]}')
	file.close()

	var backend := _make_profiles()
	var entries := backend.list_profiles()
	check_eq(entries.size(), 1, "a pre-envelope roster loads")
	check(not _corrupt_sibling_exists(PROFILES_PATH),
		"and is NOT quarantined — an old file is not a corrupt one")
	if entries.size() == 1:
		check_eq(typeof((entries[0] as Dictionary).get("level")), TYPE_FLOAT,
			"its plain number reads back as a float, as it always did: no migration, no guessing")
		check_eq((entries[0] as Dictionary).get("level"), 7.0, "with the value preserved")
	backend.free()
	_clean(PROFILES_PATH)


## [b]Right tag, wrong payload shape.[/b] A hand-edited or half-converted file must not produce a
## plausible-looking wrong value that then gets applied, and must not crash: the codec drops it to null
## with ONE warning naming the tag. Both backends are exercised, because the codec decodes every known
## tag regardless of which one is reading — the bytes are the authority, not the caller's flag.
func _test_a_malformed_envelope_warns_once_and_reads_as_null() -> void:
	_clean(PROFILES_PATH)
	var profiles_file := FileAccess.open(PROFILES_PATH, FileAccess.WRITE)
	check(profiles_file != null, "the malformed profile store was written")
	if profiles_file == null:
		return
	profiles_file.store_string('{"version": 1, "next_id": 2, "profiles": [{"id": "p_000001", "name": "Alice", "level": {"__mk_type": "int", "v": "seven"}}]}')
	profiles_file.close()

	_watch_warnings()
	var backend := _make_profiles()
	var entries := backend.list_profiles()
	var profile_warnings := _stop_watching()

	check_eq(_count_containing(profile_warnings, "malformed int envelope"), 1,
		"exactly one warning for one malformed int envelope, naming the tag")
	check(_contains_any(profile_warnings, PROFILES_PATH),
		"and naming the resolved file the user has to go look at")
	check_eq(entries.size(), 1,
		"the entry still loads: a dropped field is not a corrupt roster, and its id and name are intact")
	if entries.size() == 1:
		check_eq((entries[0] as Dictionary).get("level", "absent"), null,
			"with the malformed value dropped to null rather than to a plausible-looking wrong number")
	check(not _corrupt_sibling_exists(PROFILES_PATH),
		"and nothing was quarantined — a bad field is recoverable misconfiguration, not an unreadable file")
	backend.free()
	_clean(PROFILES_PATH)

	_clean(SETTINGS_PATH)
	var settings_file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	check(settings_file != null, "the malformed settings store was written")
	if settings_file == null:
		return
	settings_file.store_string('{"version": 1, "values": {"video/resolution": {"__mk_type": "Vector2i", "v": [1]}}}')
	settings_file.close()

	_watch_warnings()
	var settings := _make_settings()
	settings.load()
	var settings_warnings := _stop_watching()

	check_eq(_count_containing(settings_warnings, "malformed Vector2i envelope"), 1,
		"one warning for a two-element envelope carrying one element")
	check_eq(settings.get_value(&"video/resolution", "untouched"), null,
		"and the value is null rather than a Vector2i invented from half a payload")
	check(not _corrupt_sibling_exists(SETTINGS_PATH),
		"a malformed VALUE is not an unreadable FILE, so the store is left where it is")
	settings.free()
	_clean(SETTINGS_PATH)


## The one shape that cannot merely warn: an entry that is ITSELF an envelope decodes to an int, not a
## dictionary — so it can carry no id and no name and satisfies nothing the [MKProfileBackend] contract
## promises its callers. Dropping just that entry would be silent data loss, so the whole file goes
## aside intact. (It is also why the backend decodes BEFORE it validates: assigning a decoded int into
## a typed Dictionary local would be a hard script error rather than this quarantine.)
func _test_a_profile_entry_that_is_itself_an_envelope_quarantines() -> void:
	_clean(PROFILES_PATH)
	var file := FileAccess.open(PROFILES_PATH, FileAccess.WRITE)
	check(file != null, "the store was written")
	if file == null:
		return
	file.store_string('{"version": 1, "next_id": 2, "profiles": [{"__mk_type": "int", "v": 3}]}')
	file.close()

	_watch_warnings()
	var backend := _make_profiles()
	var entries := backend.list_profiles()
	var warnings := _stop_watching()

	check_eq(entries.size(), 0, "an empty roster boots rather than a script error on the decoded int")
	check_eq(_count_containing(warnings, "not a JSON object"), 1,
		"with one warning naming the reason")
	check(_corrupt_sibling_exists(PROFILES_PATH),
		"and the file is renamed aside intact — never deleted, so the user still has the bytes")
	check(not backend.create_profile({"name": "Recovered"}).is_empty(),
		"the backend is usable afterwards rather than wedged")
	backend.free()
	_clean(PROFILES_PATH)


func _make_settings() -> MKJsonSettingsBackend:
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": SETTINGS_PATH})
	get_root().add_child(backend)
	return backend


func _make_profiles() -> MKJsonProfileBackend:
	var backend := MKJsonProfileBackend.new()
	backend._mk_configure({"file_path": PROFILES_PATH})
	get_root().add_child(backend)
	return backend


## Quarantine renames to `<base>.corrupt-<n>.json`; the exact n depends on how many quarantines have
## happened, so the assertion is that SOME sibling exists rather than a specific name.
func _corrupt_sibling_exists(path: String) -> bool:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return false
	var stem := path.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem) and file.contains("corrupt"):
			return true
	return false


# --- Observation --------------------------------------------------------------

## The malformed-envelope rule is stated as a COUNT of warnings ("one warning, naming the tag"), and a
## count is only assertable through MKLog's observer seam — the same reason test_settings_schema.gd
## carries this pair.
var _warnings: Array[String] = []


func _watch_warnings() -> void:
	_warnings = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_warnings.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _warnings


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found


func _contains_any(messages: Array[String], needle: String) -> bool:
	return _count_containing(messages, needle) > 0


func _clean(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	var stem := path.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
