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
	await _test_settings_corrupt_recovery()
	await _test_profiles_round_trip()
	await _test_profiles_corrupt_recovery()
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


func _clean(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	var stem := path.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
