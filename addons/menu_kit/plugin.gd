@tool
extends EditorPlugin
## Editor-side registration for MenuKit.
##
## Enabling the plugin registers everything a host would otherwise wire by hand:
## [br]- The [code]menu_kit/config_path[/code] project setting, which is how the
##    [code]MKSettingsService[/code] autoload finds its config — an autoload cannot see a
##    scene-assigned [code]MKConfig[/code].
## [br]- The [code]MKSettingsService[/code] autoload, so persisted settings and rebinds apply on a
##    host that boots straight into gameplay without ever instancing a MenuKit scene. Hosts that
##    refuse third-party autoloads disable it in Project Settings and take the documented manual
##    path.
## [br]- A tool menu entry that bakes the palette-generated [Theme] to disk for editor preview.
##    Runtime never needs the bake; [code]MKRoot[/code] generates the same Theme at
##    [method Node._ready], so a cold drop is styled with zero manual steps.

## Registered under the same name the runtime RESOLVES it by, derived from
## [constant MKConfig.SETTINGS_SERVICE_NAME] rather than spelled again here. Registering under a name
## nothing looks for fails silently: every lookup falls back to its no-autoload path, and the host
## runs two settings backends over one JSON file and two brightness controllers over one screen,
## with no error anywhere.
const SETTINGS_SERVICE_NAME := MKConfig.SETTINGS_SERVICE_NAME
const SETTINGS_SERVICE_SCRIPT := "res://addons/menu_kit/core/mk_settings_service.gd"
const CONFIG_PATH_SETTING := "menu_kit/config_path"
const DEFAULT_CONFIG_PATH := "res://addons/menu_kit/default_config.tres"
const BAKE_MENU_ITEM := "Bake MenuKit Theme"
const BAKED_THEME_PATH := "res://addons/menu_kit/themes/generated_theme.tres"
const DEFAULT_PALETTE_PATH := "res://addons/menu_kit/themes/default_palette.tres"

## Deliberately no [code]add_custom_type[/code] call: [code]class_name MKRoot[/code] already
## registers the type globally, and the custom-type entry would hand out a bare scripted [Control]
## rather than [code]mk_root.tscn[/code], which is what hosts actually want to instance.
func _enter_tree() -> void:
	_register_config_path_setting()
	add_autoload_singleton(SETTINGS_SERVICE_NAME, SETTINGS_SERVICE_SCRIPT)
	add_tool_menu_item(BAKE_MENU_ITEM, _bake_theme)


func _exit_tree() -> void:
	remove_tool_menu_item(BAKE_MENU_ITEM)
	# The autoload goes; the project setting deliberately stays — it is the host's own choice of
	# config path, and removing it would discard a repointed path on a disable/enable cycle.
	remove_autoload_singleton(SETTINGS_SERVICE_NAME)


## Writes the config-path setting. Two silent-failure traps, not preferences:
## [br]- [method ProjectSettings.set_setting] mutates the in-memory map only; without an explicit
##   [method ProjectSettings.save] the key evaporates on the next editor launch and the service
##   falls back to the default path.
## [br]- The key is written [b]only when unset[/b], or re-enabling the plugin stomps a host that
##   repointed it.
##
## [method EditorPlugin.add_autoload_singleton] needs no equivalent save — the editor persists
## autoloads itself. Do not add one assuming symmetry.
func _register_config_path_setting() -> void:
	if ProjectSettings.has_setting(CONFIG_PATH_SETTING):
		return
	ProjectSettings.set_setting(CONFIG_PATH_SETTING, DEFAULT_CONFIG_PATH)
	# The initial value must DIFFER from the value being written: Godot omits from project.godot any
	# setting whose current value equals its initial value, which makes save() a silent no-op. Empty
	# means "the host has not chosen one", which is what the default actually represents.
	ProjectSettings.set_initial_value(CONFIG_PATH_SETTING, "")
	ProjectSettings.add_property_info({
		"name": CONFIG_PATH_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.tres",
	})
	var err := ProjectSettings.save()
	if err != OK:
		MKLog.error("failed to persist %s (error %d)" % [CONFIG_PATH_SETTING, err])


## Bakes the default palette's Theme to disk for editor preview, so panel scenes are not unstyled
## while authoring them. The artifact is gitignored and its absence changes nothing at runtime — it
## is never the source of truth.
func _bake_theme() -> void:
	var palette := ResourceLoader.load(DEFAULT_PALETTE_PATH) as MKPalette
	if palette == null:
		MKLog.error("theme bake: no MKPalette at %s" % DEFAULT_PALETTE_PATH)
		return
	var theme := MKThemeGenerator.build(palette)
	if theme == null:
		MKLog.error("theme bake: generator returned null for %s" % DEFAULT_PALETTE_PATH)
		return
	DirAccess.make_dir_recursive_absolute(BAKED_THEME_PATH.get_base_dir())
	var err := ResourceSaver.save(theme, BAKED_THEME_PATH)
	if err != OK:
		MKLog.error("theme bake: could not write %s (error %d)" % [BAKED_THEME_PATH, err])
		return
	MKLog.info("baked editor-preview theme to %s" % BAKED_THEME_PATH)
