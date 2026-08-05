extends MKTest
## `MKConfig` self-validation and the slot params route (plan §4.8, §4.1).
##
## Two contracts here, and both were previously asserted only against a *clean* config, which proves
## nothing about the reporting they exist for:
##
## [br]1. [b]Report every problem at once, naming path and field.[/b] A first-time integrator should
##    get one list to work through, not a fix-run-fix loop, and "invalid setting" in a bug report
##    costs a round trip that a path and a field name do not.
## [br]2. [b]Slot params reach the backend, and an unknown key warns by name.[/b] Only the backend
##    knows its own keys and only MKRoot knows the slot's identity, so neither can produce that
##    warning alone — which is why `_mk_configure` returns the keys it consumed. Deleting the entire
##    unknown-key warning previously left the suite green.

func run_tests() -> void:
	_test_reports_every_problem_at_once()
	await _test_slot_params_reach_the_backend()


func _test_reports_every_problem_at_once() -> void:
	var config := MKConfig.new()

	# Four independent problems, deliberately stacked.
	var dup_a := MKMenuPageDef.new()
	dup_a.id = &"same"
	var dup_b := MKMenuPageDef.new()
	dup_b.id = &"same"
	var nameless := MKMenuPageDef.new()
	nameless.id = &""
	config.pages.append(dup_a)
	config.pages.append(dup_b)
	config.pages.append(nameless)
	config.initial_page = &"does_not_exist"

	var problems := config.validate()
	check(problems.size() >= 3,
		"validate reports EVERY problem in one pass, not just the first (got %d)" % problems.size())

	var joined := "\n".join(problems)
	check(joined.contains("same"), "the duplicate page id is named")
	check(joined.contains("does_not_exist"), "the dangling initial_page is named")
	check(joined.contains("pages"), "messages name the offending FIELD, not just a description")
	check(joined.contains("initial_page"), "each problem names its own field")

	# A clean config must stay clean, or the check above is just noise.
	var good := MKConfig.new()
	var page := MKMenuPageDef.new()
	page.id = &"ok"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	good.pages.append(page)
	good.initial_page = &"ok"
	check_eq(good.validate(), PackedStringArray(), "a valid config reports nothing")


## Through the real route — an MKBackendSlot on an MKConfig, instantiated by MKRoot — not by calling
## `_mk_configure` directly, which is what the previous test did and which bypasses the mechanism
## under test entirely.
func _test_slot_params_reach_the_backend() -> void:
	var config := MKConfig.new()
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	var page := MKMenuPageDef.new()
	page.id = &"only"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(page)
	config.initial_page = &"only"

	var slot := MKBackendSlot.new()
	slot.backend_script = MKJsonProfileBackend
	slot.params = {
		"file_path": "user://test_params_route.json",
		"typo_key": 1,
	}
	config.profile_backend = slot

	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var backend := root.get_profile_backend() as MKJsonProfileBackend
	check(backend != null, "MKRoot instantiated the backend from the slot")
	if backend != null:
		check_eq(backend.get_file_path(), "user://test_params_route.json",
			"the slot's params reached the backend through _mk_configure")

	# The consumed-keys contract itself: _mk_configure must report exactly what it took, because that
	# return value is the only thing that makes the unknown-key warning possible. A backend that
	# quietly returned everything (or nothing) would silence a typo'd config key forever.
	var probe := MKJsonProfileBackend.new()
	var consumed := probe._mk_configure({"file_path": "user://x.json", "typo_key": 1})
	check(consumed.has("file_path"), "_mk_configure reports the key it consumed")
	check(not consumed.has("typo_key"),
		"and does NOT claim one it ignored — the diff against params.keys() is what names the typo")
	probe.free()

	root.free()
	await step_frame()
	_clean("user://test_params_route.json")


func _clean(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	var stem := path.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
