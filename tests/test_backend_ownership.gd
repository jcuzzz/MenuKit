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


## No autoload: MKRoot builds its own backend from the config slot and owns its lifetime.
func _test_standalone() -> void:
	var config := _make_config(MKJsonSettingsBackend)
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	await step_frame()

	var backend := root.get_settings_backend()
	check(backend != null, "standalone: MKRoot instantiated a settings backend from its slot")
	check(backend is MKJsonSettingsBackend, "standalone: and it is the script the slot named")
	if backend != null:
		check_eq(backend.get_parent(), root,
			"standalone: MKRoot parents the backend it owns, so it dies with the scene")
	check(root.dump_diagnostics().contains("adopted from autoload: false"),
		"standalone: diagnostics report that nothing was adopted")

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
func _install_service(backend_script: Script) -> MKSettingsService:
	var service := MKSettingsService.new()
	service.name = SERVICE_NAME
	var slot := MKBackendSlot.new()
	slot.backend_script = backend_script
	service.override_backend_slot = slot
	get_root().add_child(service)
	return service


func _remove_service(service: MKSettingsService) -> void:
	if is_instance_valid(service):
		get_root().remove_child(service)
		service.free()


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
