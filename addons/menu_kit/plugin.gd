@tool
extends EditorPlugin
## Editor-side registration for MenuKit.
##
## Owns three things a host would otherwise have to do by hand — the plan's position is that the
## delivery mechanism for integration should be the plugin itself, not a step buried in docs:
## [br]1. The [code]MKRoot[/code] custom type, so the shell is a Create-Node entry.
## [br]2. The [code]menu_kit/config_path[/code] project setting, which is how the (Phase 2)
##    [code]MKSettingsService[/code] autoload finds its config — an autoload cannot see a
##    scene-assigned [code]MKConfig[/code].
## [br]3. A tool menu entry that bakes the palette-generated [Theme] to disk for editor preview.
##    Runtime never needs the bake; [code]MKRoot[/code] generates the same Theme at
##    [method Node._ready], so a cold drop is styled with zero manual steps.

const CONFIG_PATH_SETTING := "menu_kit/config_path"
const DEFAULT_CONFIG_PATH := "res://addons/menu_kit/default_config.tres"
const BAKE_MENU_ITEM := "Bake MenuKit Theme"
const BAKED_THEME_PATH := "res://addons/menu_kit/themes/generated_theme.tres"
const DEFAULT_PALETTE_PATH := "res://addons/menu_kit/themes/default_palette.tres"

## No [code]add_custom_type[/code] call: [code]class_name MKRoot[/code] already registers the type
## globally, so adding it again would duplicate the Create-Node entry — and the custom-type entry
## hands out a bare scripted [Control], not [code]mk_root.tscn[/code], which is the thing hosts
## actually want to instance. [code]INTEGRATION.md[/code] says "instance
## [code]addons/menu_kit/core/mk_root.tscn[/code]" for that reason.
func _enter_tree() -> void:
	_register_config_path_setting()
	add_tool_menu_item(BAKE_MENU_ITEM, _bake_theme)


func _exit_tree() -> void:
	remove_tool_menu_item(BAKE_MENU_ITEM)
	# The project setting is deliberately left in place: removing it would discard a host's
	# repointed path on a plugin disable/enable cycle.


## Writes the config-path setting, with two details that are silent-failure traps rather than
## preferences:
## [br]- [method ProjectSettings.set_setting] mutates the in-memory map only, so without an explicit
##   [method ProjectSettings.save] the key evaporates on the next editor launch and the service
##   silently falls back to the default path — a bug whose signature only appears on the
##   [i]second[/i] run.
## [br]- The key is written [b]only when unset[/b], or re-enabling the plugin stomps a host that
##   repointed it.
##
## [method EditorPlugin.add_autoload_singleton] needs no equivalent save — the editor persists
## autoloads itself. Do not add one assuming symmetry.
func _register_config_path_setting() -> void:
	if ProjectSettings.has_setting(CONFIG_PATH_SETTING):
		return
	ProjectSettings.set_setting(CONFIG_PATH_SETTING, DEFAULT_CONFIG_PATH)
	# The initial value must DIFFER from the value being written. Godot omits from project.godot any
	# setting whose current value equals its initial value, so setting both to the same path made
	# save() a silent no-op: the key never reached disk, has_setting() stayed false on every launch,
	# and the settings-service autoload — which is specified to find its config through this key —
	# would always fall back to the default. An empty initial value means "the host has not chosen
	# one", which is what the default actually represents.
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


## Bakes the default palette's Theme to disk purely for editor preview, so panel scenes are not
## unstyled while authoring them. The artifact is gitignored and its absence changes nothing at
## runtime — it is never the source of truth.
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
