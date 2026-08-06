extends Node
## The optional autoload that owns the one live [MKSettingsBackend] and applies settings at boot
## (plan §4.2).
##
## [b]This script deliberately has NO [code]class_name[/code].[/b] Godot forbids a global class name
## that matches an autoload singleton name, and this script is registered as the autoload
## [code]MKSettingsService[/code]. Declaring both made the script fail to parse at every boot —
## "Class ... hides an autoload singleton" — so the autoload never instantiated and §4.2's entire
## mechanism was absent from every real host, while the headless tests (which mount the node
## directly, with no autoload registered) stayed green. [MKRoot] resolves this node duck-typed via
## [method Node.get_node_or_null] plus [method Object.has_method], so nothing needs the type.
##
## [b]Why an autoload exists at all.[/b] Persisted settings — critically [InputMap] overrides — must
## apply even when the host boots straight into gameplay without ever instancing a MenuKit scene. A
## backend owned by [MKRoot] would not exist on that path, so the user's rebinds would apply only
## after they visited a menu. The boot sequence is these three calls, in this order:
## [br]1. [method MKSettingsBackend.snapshot_input_defaults] — capture stock bindings [b]before[/b]
##    any override, or "Reset to Defaults" silently resets to the user's own overrides.
## [br]2. [method MKSettingsBackend.load]
## [br]3. [method MKSettingsBackend.apply_all]
##
## [b]And then it boots brightness[/b] ([method _boot_brightness]), which is not a footnote to that
## list: brightness is the one persisted setting the backend cannot apply on its own — it needs a live
## controller node — and it must be on screen at a boot that never opens a menu, for the same reason
## the rebinds must. This node owns that controller, and [MKRoot] adopts it rather than building a
## second one.
##
## [b]It is optional[/b] (decision D3). A host that refuses third-party autoloads disables it in
## Project Settings and makes the same three calls from its main scene [method Node._ready];
## [code]INTEGRATION.md[/code] documents that as a supported path, and it is tested rather than only
## documented. What is not supported is skipping it and expecting rebinds to apply.
##
## [b]It also resolves the single-instance rule.[/b] Two settings backends over one JSON file means
## the D14 revert countdown snapshots one while a panel writes the other, and last-[method
## MKSettingsBackend.save] silently wins. [MKRoot] therefore checks for this node and adopts
## [method get_settings_backend] rather than building its own — see
## [code]MKRoot._resolve_settings_backend[/code]. The method name is the contract; do not rename it.
##
## An autoload cannot see a scene-assigned [MKConfig], so it resolves its own from the
## [code]menu_kit/config_path[/code] project setting, which [code]plugin.gd[/code] writes on enable.

## Where the config path lives. Duplicated from [code]plugin.gd[/code] rather than shared: the plugin
## is an [EditorPlugin] and is not present in an exported game, so referencing it from runtime code
## would work in the editor and fail in a build.
const CONFIG_PATH_SETTING := "menu_kit/config_path"
const DEFAULT_CONFIG_PATH := "res://addons/menu_kit/default_config.tres"

## Alias of [constant MKBrightnessController.SETTING_ID], which is the single source of truth for
## the id. Both owners of a controller (this node and [code]MKRoot[/code]'s standalone tier) read it
## from the controller rather than each spelling it out — a mismatch there is a slider that stores a
## value nothing reads.
const BRIGHTNESS_SETTING := MKBrightnessController.SETTING_ID

## [b]A testing seam, not a host feature.[/b] Registering a real autoload needs an editor session, so
## a headless test cannot reach this class through the shipped path; assigning this before the node
## enters the tree supplies the slot directly and skips config resolution entirely. Everything after
## that — call order, process mode, [method get_settings_backend] — is identical on both routes, so
## what the tests exercise is the real behaviour and only the slot's origin differs.
##
## A host wanting a different backend repoints [code]menu_kit/config_path[/code] at its own
## [MKConfig] instead; that is the supported gesture and this field is not part of it.
var override_backend_slot: MKBackendSlot

var _backend: MKSettingsBackend
var _config: MKConfig
## Created in [method _boot_brightness]. See that method for why this node owns it rather than
## [MKRoot].
var _brightness: MKBrightnessController


## Boots the store. Every failure here is recoverable and warns rather than crashing: a misconfigured
## config path must not take a host's game down at launch, and an autoload that throws is the worst
## possible place to learn about a typo.
func _ready() -> void:
	# The pause menu runs under `get_tree().paused = true`, and a paused backend cannot apply the
	# display change a D14 countdown is waiting to revert (plan §4.2a). This node lives outside the
	# MKRoot subtree, so it inherits nothing and must set it itself.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var slot := override_backend_slot
	if slot == null or not slot.is_assigned():
		slot = _resolve_slot_from_config()
	if slot == null or not slot.is_assigned():
		# Not a warning: an unassigned settings slot is valid config. The shipped
		# `default_config.tres` does assign one, but a host that repoints `menu_kit/config_path` at
		# a config of its own may legitimately leave it empty, and ship gate 2 demands zero warnings
		# out of the box.
		MKLog.debug("no settings backend configured — MKSettingsService is inert")
		return

	_backend = _instantiate(slot)
	if _backend == null:
		return
	add_child(_backend)

	_backend.snapshot_input_defaults()
	_backend.load()
	_backend.apply_all()

	_boot_brightness()


## The live [MKBrightnessController], or null when none was created (no config resolved, or
## [code]MKConfig.manage_brightness[/code] false). [b][MKRoot] calls exactly this name[/b] to detect
## that brightness is already owned and skip building its own standalone controller — two
## controllers would stack two gamma passes and the image would be corrected twice.
func get_brightness_controller() -> MKBrightnessController:
	return _brightness


## The live backend, or null when none is configured. [b][MKRoot] calls exactly this name[/b] to
## adopt the instance instead of building a second one (plan §4.2).
func get_settings_backend() -> MKSettingsBackend:
	return _backend


## The [MKConfig] this service resolved, or null. Exposed for [code]MKRoot.dump_diagnostics()[/code]
## and for tests that need to see which config actually took effect — "which config is live" is
## otherwise unanswerable from a bug report when a host has repointed the setting.
func get_config() -> MKConfig:
	return _config


## Creates and wires the brightness controller (plan §4.3), and this is the node that must do it.
##
## [b]Why here and not [MKRoot].[/b] This is the same argument that put InputMap overrides in this
## class: brightness is a persisted setting that must apply on a boot which never opens a menu. A
## controller hanging off a per-scene [MKRoot] would not exist on a straight-into-gameplay boot, so
## the player would calibrate in the menu, press Play, and watch the image snap back — with no error
## anywhere. Ship gate 4c tests exactly that boot. This node is an autoload, so it survives every
## scene swap and the correction is continuous.
##
## Wiring is deliberately through [signal MKSettingsBackend.setting_changed] rather than a direct
## call from the settings panel: the panel is not the only writer (a host writing the value itself,
## or a load, must move the image too), and routing every writer through the store keeps one source
## of truth for the applied value.
##
## Skipped entirely when no [MKConfig] was resolved — that is the [member override_backend_slot]
## testing seam, which supplies a backend without a config and therefore cannot answer
## [code]manage_brightness[/code]. Defaulting to "on" there would create a controller the shipped
## path would not.
func _boot_brightness() -> void:
	if _config == null or not _config.manage_brightness:
		return
	_brightness = MKBrightnessController.new()
	_brightness.name = "BrightnessController"
	add_child(_brightness)
	_brightness.set_brightness(float(_backend.get_value(BRIGHTNESS_SETTING, 1.0)))
	_backend.setting_changed.connect(_on_setting_changed)


## Forwards only the brightness row. Every other setting is applied by the backend itself; this node
## does not become a second application path.
func _on_setting_changed(id: StringName, value: Variant) -> void:
	if id != BRIGHTNESS_SETTING:
		return
	if _brightness == null or not is_instance_valid(_brightness):
		return
	# Guarded rather than cast blindly: the store is JSON-backed and a hand-edited file can hold a
	# string here. A warn beats a hard crash inside a signal handler at boot.
	if not (value is float or value is int):
		MKLog.warn("%s: brightness value '%s' is not a number — ignoring"
			% [MKLog.context(_config, "settings"), value])
		return
	_brightness.set_brightness(float(value))


func _resolve_slot_from_config() -> MKBackendSlot:
	var path := DEFAULT_CONFIG_PATH
	if ProjectSettings.has_setting(CONFIG_PATH_SETTING):
		var raw: Variant = ProjectSettings.get_setting(CONFIG_PATH_SETTING)
		if raw is String and not (raw as String).is_empty():
			path = raw as String

	if not ResourceLoader.exists(path):
		MKLog.warn("%s: '%s' names no resource — no settings will be applied at boot"
			% [MKLog.context(CONFIG_PATH_SETTING), path])
		return null

	var res := ResourceLoader.load(path)
	_config = res as MKConfig
	if _config == null:
		MKLog.warn("%s: '%s' is a %s, not an MKConfig — no settings will be applied at boot" % [
			MKLog.context(CONFIG_PATH_SETTING),
			path,
			res.get_class() if res != null else "failed load",
		])
		return null

	MKLog.verbose = MKLog.verbose or _config.verbose
	return _config.settings_backend


## Builds the slot's script as a child-to-be. A near-twin of [code]MKRoot._make_backend[/code] rather
## than a shared helper because that one is a private method on a [Control] the autoload path never
## instances; the shared surface is the [MKBackendSlot] contract itself, which both go through.
func _instantiate(slot: MKBackendSlot) -> MKSettingsBackend:
	var reason := slot.validate_against(MKSettingsBackend)
	if not reason.is_empty():
		# Plan §4.8: a backend that does not extend its base is a contract violation, not a
		# recoverable misconfiguration — every later call against it would fail obscurely.
		MKLog.error(reason)
		return null

	var inst: Object = slot.backend_script.new()
	var backend := inst as MKSettingsBackend
	if backend == null:
		MKLog.error("%s: backend_script '%s' did not produce an MKSettingsBackend"
			% [MKLog.context(slot, "backend_script"), slot.backend_script.resource_path])
		if inst is RefCounted:
			return null
		var orphan := inst as Node
		if orphan != null:
			orphan.free()
		return null

	backend.name = "SettingsBackend"
	backend.process_mode = Node.PROCESS_MODE_ALWAYS

	var consumed: Array = backend._mk_configure(slot.params)
	for key in slot.params.keys():
		if not consumed.has(String(key)):
			MKLog.warn("%s: nothing consumed param '%s' — check the spelling against %s"
				% [MKLog.context(slot, "params"), key, slot.backend_script.resource_path])
	return backend
