extends MKTest
## [MKBrightnessController] and the ownership rule around it (plan §4.3).
##
## Two things are being protected here and they fail in opposite directions.
##
## [b]The value logic[/b] — clamping, and switching the overlay off at neutral. A slider that can
## render a game unplayable has no in-game route back to a readable menu, and a neutral overlay left
## drawing would make the configuration nobody touches the expensive one.
##
## [b]The ownership rule[/b] — exactly ONE controller may exist. Two stack two gamma passes and the
## image is corrected twice, which nobody reads as "there are two controllers". The service owns it
## because a host may boot straight into gameplay without ever instancing a MenuKit scene; MKRoot
## builds one only in the standalone no-service tier, and the adopt path must build none.
##
## [b]Headless boundary[/b] (plan §4.8). The overlay's visible EFFECT — an actually darker frame — is
## not observable under the headless driver and is a phase exit criterion on a real display. What is
## observable, and asserted, is every decision that produces it: the clamped value, whether the quad
## exists and is visible, and which node owns it.

const STORE_PATH := "user://test_brightness.json"
const CONFIG_PATH := "user://test_brightness_config.tres"
const SERVICE_NAME := "MKSettingsService"
const SERVICE_SCRIPT := preload("res://addons/menu_kit/core/mk_settings_service.gd")
const CONFIG_PATH_SETTING := "menu_kit/config_path"


func run_tests() -> void:
	# These tests mount their own service under the same node name, so the registered autoload is
	# parked for the duration — otherwise "/root/MKSettingsService" keeps resolving to the real one and
	# the ownership assertions describe an instance nobody under test created.
	var parked := _park_autoload()
	_clean()

	await _test_clamping()
	await _test_neutral_deactivates_the_overlay()
	await _test_non_finite_is_refused()
	await _test_service_owns_exactly_one()
	await _test_service_forwards_setting_changed()
	await _test_adopt_never_yields_two()
	await _test_root_standalone_builds_its_own()
	await _test_manage_brightness_false_builds_none()

	_clean()
	_restore_autoload(parked)


func _test_clamping() -> void:
	var controller := _make_controller()
	controller.set_brightness(0.0)
	check_eq(controller.get_brightness(), MKBrightnessController.MIN_BRIGHTNESS,
		"a value below the floor is CLAMPED, not refused — a stored value from an older build must still land somewhere usable")
	controller.set_brightness(-5.0)
	check_eq(controller.get_brightness(), MKBrightnessController.MIN_BRIGHTNESS,
		"and so is a negative one")
	controller.set_brightness(99.0)
	check_eq(controller.get_brightness(), MKBrightnessController.MAX_BRIGHTNESS,
		"a value above the ceiling is clamped to MAX_BRIGHTNESS")
	controller.set_brightness(1.4)
	check_eq(controller.get_brightness(), 1.4, "an in-range value is applied verbatim")
	check(MKBrightnessController.MIN_BRIGHTNESS < 1.0
			and MKBrightnessController.MAX_BRIGHTNESS > 1.0,
		"and the range brackets neutral, so 1.0 is always reachable")

	controller.queue_free()
	await step_frame()


## Neutral hides the overlay entirely rather than drawing a no-op pass. Every player who never touches
## the slider is on that path.
func _test_neutral_deactivates_the_overlay() -> void:
	var controller := _make_controller()
	check(not controller.is_overlay_active(),
		"a fresh controller draws nothing — the quad is built lazily, on first non-neutral use")

	controller.set_brightness(1.0)
	check(not controller.is_overlay_active(), "an explicit neutral value keeps it off")
	check_eq(controller.get_child_count(), 0,
		"and builds no quad at all: the default configuration must not pay for a fullscreen screen read")

	controller.set_brightness(1.0 + MKBrightnessController.NEUTRAL_EPSILON * 0.5)
	check(not controller.is_overlay_active(),
		"a value within NEUTRAL_EPSILON counts as neutral — a JSON round trip is rarely bit-exact")

	controller.set_brightness(1.6)
	check(controller.is_overlay_active(), "a non-neutral value activates the overlay")
	check(controller.get_child_count() > 0, "which is a real child node")

	controller.set_brightness(0.7)
	check(controller.is_overlay_active(), "darkening keeps it active")

	controller.set_brightness(1.0)
	check(not controller.is_overlay_active(),
		"and returning to neutral switches it back off rather than leaving a built quad drawing")

	controller.queue_free()
	await step_frame()


## NAN would poison every later comparison, so it is dropped rather than clamped.
func _test_non_finite_is_refused() -> void:
	var controller := _make_controller()
	controller.set_brightness(1.3)
	controller.set_brightness(NAN)
	check_eq(controller.get_brightness(), 1.3,
		"a non-finite value is ignored and the last good one stands")
	controller.set_brightness(INF)
	check_eq(controller.get_brightness(), 1.3, "infinity too")

	controller.queue_free()
	await step_frame()


# --- Ownership ----------------------------------------------------------------

## The supported configuration: the autoload resolves its config, builds the backend, and creates
## exactly one controller seeded from the stored value.
func _test_service_owns_exactly_one() -> void:
	var previous: Variant = _set_config_path("res://addons/menu_kit/default_config.tres")
	var service := _install_service()
	await step_frame()

	var controller: MKBrightnessController = service.get_brightness_controller()
	check(controller != null,
		"with manage_brightness true, the service creates a brightness controller")
	check_eq(_count_controllers(get_root()), 1,
		"exactly ONE exists in the whole tree — two would stack two gamma passes")
	if controller != null:
		check_eq(controller.get_parent(), service,
			"and it hangs off the SERVICE, so it survives every scene swap the way a persisted setting must")
		check_eq(controller.process_mode, Node.PROCESS_MODE_ALWAYS,
			"running ALWAYS: the slider is live-apply and the pause menu is where it is dragged")

	_remove_service(service)
	await step_frame()
	_restore_config_path(previous)


## The wiring is through setting_changed, not a direct call from the panel — the panel is not the only
## writer, and a host writing the value itself must move the image too.
func _test_service_forwards_setting_changed() -> void:
	var previous: Variant = _set_config_path("res://addons/menu_kit/default_config.tres")
	var service := _install_service()
	await step_frame()

	var controller: MKBrightnessController = service.get_brightness_controller()
	var backend: MKSettingsBackend = service.get_settings_backend()
	check(controller != null and backend != null, "the service booted both halves")
	if controller != null and backend != null:
		backend.set_value(MKBrightnessController.SETTING_ID, 1.7)
		check_eq(controller.get_brightness(), 1.7,
			"a write to the store reaches the controller — every writer routes through one place")

		backend.set_value(MKBrightnessController.SETTING_ID, 2)
		check_eq(controller.get_brightness(), 2.0, "an int from a JSON round trip is accepted too")

		backend.set_value(&"video/vsync", 1)
		check_eq(controller.get_brightness(), 2.0,
			"and every OTHER setting is ignored — this node must not become a second application path")

		# Emitted rather than written through set_value: that method compares the new value against the
		# stored one with `==`, and `int == String` is a script error in GDScript — a defect of its own,
		# reported separately. The handler under test is connected to this signal, so this reaches it by
		# the same route a load or a host write would.
		backend.setting_changed.emit(MKBrightnessController.SETTING_ID, "bright")
		check_eq(controller.get_brightness(), 2.0,
			"a hand-edited non-numeric value is refused rather than crashing inside a signal handler")

	_remove_service(service)
	await step_frame()
	_restore_config_path(previous)


## The adopt path: a service is up, so MKRoot must build NEITHER a second backend nor a second
## controller. The belt-and-braces check in _boot_own_brightness is what this pins.
func _test_adopt_never_yields_two() -> void:
	var previous: Variant = _set_config_path("res://addons/menu_kit/default_config.tres")
	var service := _install_service()
	await step_frame()
	check(service.get_brightness_controller() != null, "the service owns a controller")

	var root := _make_root(true, {})
	await step_frame()

	check(root.get_brightness_controller() == null,
		"MKRoot builds NO controller of its own while a service owns one")
	check_eq(_count_controllers(get_root()), 1,
		"so exactly one exists across service and scene — two gamma passes would correct the image twice")

	root.queue_free()
	await step_frame()
	_remove_service(service)
	await step_frame()
	_restore_config_path(previous)


## The standalone no-service tier. Weaker by construction (it dies with its per-scene root), but it
## must exist, and it must seed from the store — a controller that boots at 1.0 while the store says
## 0.8 is a slider that snaps back every scene change.
func _test_root_standalone_builds_its_own() -> void:
	_clean()
	var seed_backend := MKJsonSettingsBackend.new()
	seed_backend._mk_configure({"file_path": STORE_PATH})
	get_root().add_child(seed_backend)
	seed_backend.set_value(MKBrightnessController.SETTING_ID, 0.8)
	seed_backend.save()
	seed_backend.free()

	var root := _make_root(true, {"file_path": STORE_PATH})
	await step_frame()

	var controller := root.get_brightness_controller()
	check(controller != null, "with no service present, MKRoot creates its own controller")
	check_eq(_count_controllers(get_root()), 1, "and only one")
	if controller != null:
		check_eq(controller.get_parent(), root, "parented to the root, so it dies with the scene")
		check_eq(controller.get_brightness(), 0.8,
			"seeded from the STORE at boot — not left at neutral until the user opens the slider")

	var backend := root.get_settings_backend()
	check(backend != null, "the standalone root owns a backend")
	if backend != null:
		backend.set_value(MKBrightnessController.SETTING_ID, 1.9)
		check_eq(controller.get_brightness(), 1.9,
			"and forwards later writes to it, exactly as the service does")

	root.queue_free()
	await step_frame()
	_clean()


## manage_brightness false is the documented opt-out: the row stays a plain value the host consumes,
## and MenuKit creates nothing.
func _test_manage_brightness_false_builds_none() -> void:
	var root := _make_root(false, {"file_path": STORE_PATH})
	await step_frame()

	check(root.get_brightness_controller() == null,
		"manage_brightness false builds no controller")
	check_eq(_count_controllers(get_root()), 0, "none exists anywhere")
	check(root.get_settings_backend() != null,
		"while the setting itself still stores and reaches the host — the value is the floor, the controller is on top of it")

	root.queue_free()
	await step_frame()

	# The same flag on the SERVICE path, which resolves it from a config on disk rather than from a
	# scene-assigned one — a different code path reading the same field.
	var config := MKConfig.new()
	config.manage_brightness = false
	var slot := MKBackendSlot.new()
	slot.backend_script = MKJsonSettingsBackend
	slot.params = {"file_path": STORE_PATH}
	config.settings_backend = slot
	var saved := ResourceSaver.save(config, CONFIG_PATH)
	check_eq(saved, OK, "the opt-out config saved for the service to resolve")

	var previous: Variant = _set_config_path(CONFIG_PATH)
	var service := _install_service()
	await step_frame()
	check(service.get_settings_backend() != null,
		"the service still built the backend that config names")
	check(service.get_brightness_controller() == null,
		"but created no controller — the flag is honoured on the autoload path too")
	check_eq(_count_controllers(get_root()), 0, "and nothing exists in the tree")

	_remove_service(service)
	await step_frame()
	_restore_config_path(previous)


# --- Fixtures -----------------------------------------------------------------

func _make_controller() -> MKBrightnessController:
	var controller := MKBrightnessController.new()
	get_root().add_child(controller)
	return controller


func _make_root(manage_brightness: bool, params: Dictionary) -> MKRoot:
	var config := MKConfig.new()
	config.manage_brightness = manage_brightness
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	var slot := MKBackendSlot.new()
	slot.backend_script = MKJsonSettingsBackend
	slot.params = params
	config.settings_backend = slot
	var page := MKMenuPageDef.new()
	page.id = &"only"
	page.title = "Only"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(page)
	config.initial_page = &"only"
	var root := MKRoot.new()
	root.config = config
	get_root().add_child(root)
	return root


func _count_controllers(node: Node) -> int:
	var found := 0
	for child in node.get_children():
		if child is MKBrightnessController:
			found += 1
		found += _count_controllers(child)
	return found


func _install_service() -> Node:
	var service: Node = SERVICE_SCRIPT.new()
	service.name = SERVICE_NAME
	get_root().add_child(service)
	return service


func _remove_service(service: Node) -> void:
	if is_instance_valid(service):
		get_root().remove_child(service)
		service.free()


func _set_config_path(path: String) -> Variant:
	var previous: Variant = ProjectSettings.get_setting(CONFIG_PATH_SETTING) \
		if ProjectSettings.has_setting(CONFIG_PATH_SETTING) else null
	ProjectSettings.set_setting(CONFIG_PATH_SETTING, path)
	return previous


func _restore_config_path(previous: Variant) -> void:
	ProjectSettings.set_setting(CONFIG_PATH_SETTING, previous)


const SERVICE_PARK_NAME := SERVICE_NAME


func _park_autoload() -> Node:
	var service := get_root().get_node_or_null(SERVICE_PARK_NAME)
	if service == null:
		return null
	get_root().remove_child(service)
	return service


func _restore_autoload(service: Node) -> void:
	if service != null and is_instance_valid(service):
		get_root().add_child(service)


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := STORE_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
	if FileAccess.file_exists(CONFIG_PATH):
		dir.remove(CONFIG_PATH.get_file())
