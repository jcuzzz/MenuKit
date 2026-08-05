extends MKTest
## Who owns the settings backend (plan §4.2).
##
## The failure this guards against is one of the nastiest in the package: two [MKSettingsBackend]
## instances over one JSON file means the D14 revert countdown snapshots one while the panel writes
## the other, and last-[code]save()[/code] silently wins. Nothing crashes; settings just quietly
## revert, and a bug report reading "my resolution doesn't stick" contains no evidence of the cause.
##
## Three paths, all real (§4.2 is explicit that the no-autoload route is the D3 escape hatch and that
## shipping it unverified is backwards):
## [br]1. [b]Adopt[/b] — the service exists, so MKRoot borrows its instance and builds none.
## [br]2. [b]Standalone[/b] — no service, so MKRoot instantiates from its own config and owns it.
## [br]3. [b]Mismatch[/b] — the scene's config names a different backend script than the service
##    already built. That is a misconfiguration, not a reason to double-instantiate: MKRoot keeps the
##    service's instance and reports an error naming both scripts.

const SERVICE_NAME := "MKSettingsService"


func run_tests() -> void:
	await _test_standalone()
	await _test_adopt()
	await _test_mismatch_keeps_service_instance()
	await _test_service_resolves_from_project_setting()


## The SHIPPED resolution route, not the injection seam.
##
## Every other test here supplies `override_backend_slot`, which skips `_resolve_slot_from_config`
## entirely — the ProjectSettings read, the loadable-path guard, the is-it-an-MKConfig check. That is
## the half a real host actually uses, and it went unexercised while a fatal defect sat in the same
## file: the script declared `class_name MKSettingsService`, which Godot forbids for a script
## registered under that autoload name, so the autoload never instantiated in any real project while
## these tests stayed green.
func _test_service_resolves_from_project_setting() -> void:
	const KEY := "menu_kit/config_path"
	var previous: Variant = ProjectSettings.get_setting(KEY) if ProjectSettings.has_setting(KEY) else null
	ProjectSettings.set_setting(KEY, "res://addons/menu_kit/default_config.tres")

	var service: Node = SERVICE_SCRIPT.new()
	service.name = SERVICE_NAME
	get_root().add_child(service)
	await step_frame()

	var config: MKConfig = service.get_config()
	check(config != null, "the service resolved an MKConfig from menu_kit/config_path")
	var backend: MKSettingsBackend = service.get_settings_backend()
	check(backend != null,
		"and built the backend that config's slot names — the shipped default assigns one")
	if backend != null:
		check(backend is MKJsonSettingsBackend, "which is the shipped JSON backend")
		check_eq(backend.process_mode, Node.PROCESS_MODE_ALWAYS,
			"the service's backend runs ALWAYS: it lives outside MKRoot's subtree, so it inherits nothing, and the D14 countdown runs on it")

	_remove_service(service)
	await step_frame()
	if previous == null:
		ProjectSettings.set_setting(KEY, null)
	else:
		ProjectSettings.set_setting(KEY, previous)


## No autoload: MKRoot builds its own backend from the config slot, owns its lifetime, AND boots it.
##
## The boot half is asserted by seeding a store on disk first. Checking only that a backend exists —
## or that it answers queries — cannot catch the defect this covers, because a cold backend answers
## too, with the caller's defaults. MKRoot used to instantiate the backend and never call
## load/apply_all, so with no autoload present nothing in a shipped configuration ever read the
## store, and the symptom looked like a bug in whatever panel the user happened to be on.
func _test_standalone() -> void:
	BootSpy.reset()
	var config := _make_config(BootSpy)
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var backend := root.get_settings_backend()
	# The boot half, recorded by the backend itself. A store-based assertion would work too, but this
	# also pins the ORDER, which is the part that fails silently: a snapshot taken after the load
	# captures the user's own overrides, so Reset to Defaults resets to them and appears to work.
	check_eq(BootSpy.calls, ["snapshot", "load", "apply"],
		"standalone: MKRoot boots the backend it built — snapshot, then load, then apply")
	check(backend != null, "standalone: MKRoot instantiated a settings backend from its slot")
	check(backend is BootSpy, "standalone: and it is the script the slot named")
	if backend != null:
		check_eq(backend.get_parent(), root,
			"standalone: MKRoot parents the backend it owns, so it dies with the scene")
	check(root.dump_diagnostics().contains("adopted from autoload: false"),
		"standalone: diagnostics report that nothing was adopted")
	root.free()
	await step_frame()


func _clean_store(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return
	var stem := path.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)

	root.free()
	await step_frame()


## With the service present, MKRoot must borrow — not build a second instance over the same file.
func _test_adopt() -> void:
	var service := _install_service(MKJsonSettingsBackend)
	await step_frame()
	var service_backend: MKSettingsBackend = service.get_settings_backend()
	check(service_backend != null, "adopt: the service built a backend of its own")

	var config := _make_config(MKJsonSettingsBackend)
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var adopted := root.get_settings_backend()
	check(adopted == service_backend,
		"adopt: MKRoot borrowed the SERVICE's instance rather than building a second one over the same JSON")
	check(adopted.get_parent() != root,
		"adopt: the adopted backend still belongs to the service, not to this scene")
	check(root.dump_diagnostics().contains("adopted from autoload: true"),
		"adopt: diagnostics say so, because this is the fact a bug report needs")

	# The whole point: one store, so a write through either handle is visible through the other.
	adopted.set_value(&"probe/value", 42)
	check_eq(service_backend.get_value(&"probe/value", 0), 42,
		"adopt: both handles are the same store")

	root.free()
	await step_frame()
	check(is_instance_valid(service_backend),
		"adopt: freeing the scene must NOT destroy a backend the scene does not own")
	_remove_service(service)
	await step_frame()


## A scene naming a different script than the service already built is a misconfiguration. MKRoot
## keeps the service's instance — silently double-instantiating is the failure this section exists
## to prevent, and picking the scene's would discard settings the service already applied at boot.
func _test_mismatch_keeps_service_instance() -> void:
	# This case exists to prove the mismatch IS reported, so the error it provokes is the assertion,
	# not a defect. Declared narrowly so the gate still fails on any other error in this file.
	expect_engine_error("settings backend mismatch")
	var service := _install_service(MKJsonSettingsBackend)
	await step_frame()
	var service_backend: MKSettingsBackend = service.get_settings_backend()

	var config := _make_config(MismatchedSettingsBackend)
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	check(root.get_settings_backend() == service_backend,
		"mismatch: the service's instance is kept, not replaced")
	check(not (root.get_settings_backend() is MismatchedSettingsBackend),
		"mismatch: the scene's script is NOT instantiated as a second backend")

	root.free()
	await step_frame()
	_remove_service(service)
	await step_frame()


func _make_config(backend_script: Script) -> MKConfig:
	var config := MKConfig.new()
	var slot := MKBackendSlot.new()
	slot.backend_script = backend_script
	config.settings_backend = slot
	# A page, so the shell has something to show and boot does not warn about an empty nav.
	var page := MKMenuPageDef.new()
	page.id = &"only"
	page.title = "Only"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(page)
	config.initial_page = &"only"
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	return config


## Installs the autoload under the exact node name MKRoot looks for. Registering a real autoload
## needs an editor, so the test mounts the node at the same path instead — MKRoot resolves it with
## get_node_or_null("/root/MKSettingsService"), which cannot tell the difference.
##
## Loaded by path, not by class name: the service script deliberately has no [code]class_name[/code],
## because Godot forbids one that matches an autoload singleton name. It had one, and the collision
## meant the real autoload never instantiated in any host while this test — which mounts the node
## directly — stayed green.
const SERVICE_SCRIPT := preload("res://addons/menu_kit/core/mk_settings_service.gd")


func _install_service(backend_script: Script) -> Node:
	var service: Node = SERVICE_SCRIPT.new()
	service.name = SERVICE_NAME
	var slot := MKBackendSlot.new()
	slot.backend_script = backend_script
	service.override_backend_slot = slot
	get_root().add_child(service)
	return service


func _remove_service(service: Node) -> void:
	if is_instance_valid(service):
		get_root().remove_child(service)
		service.free()


## Records the boot sequence MKRoot performs on a backend it owns, so the ORDER is assertable.
## Storage is a plain dictionary — this exists to observe calls, not to persist anything.
class BootSpy extends MKSettingsBackend:
	static var calls: Array[String] = []
	var _values := {}

	static func reset() -> void:
		calls = []

	func get_value(id: StringName, default_value: Variant) -> Variant:
		return _values.get(id, default_value)

	func set_value(id: StringName, value: Variant) -> void:
		_values[id] = value
		setting_changed.emit(id, value)

	func save() -> void:
		calls.append("save")

	func load() -> void:
		calls.append("load")

	func apply_all() -> void:
		calls.append("apply")

	func snapshot_input_defaults() -> void:
		calls.append("snapshot")


## A second, distinct MKSettingsBackend subclass, so the mismatch case has two genuinely different
## scripts to disagree about. Deliberately inert — the test never exercises its behaviour, only its
## identity.
class MismatchedSettingsBackend extends MKSettingsBackend:
	var _values := {}

	func get_value(id: StringName, default_value: Variant) -> Variant:
		return _values.get(id, default_value)

	func set_value(id: StringName, value: Variant) -> void:
		_values[id] = value
		setting_changed.emit(id, value)

	func save() -> void:
		pass

	func load() -> void:
		pass

	func apply_all() -> void:
		pass

	func snapshot_input_defaults() -> void:
		pass
