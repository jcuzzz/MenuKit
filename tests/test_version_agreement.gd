extends MKTest
## Ship gate 10's automatable half: [code]MKVersion.VERSION[/code] and [code]plugin.cfg[/code]'s
## version must agree.
##
## The constant is mirrored into `plugin.cfg` BY HAND (an EditorPlugin config cannot read a GDScript
## constant), and a hand-mirrored value drifts silently — the addon reports one version in
## `dump_diagnostics()` while the editor's plugin list shows another, and nothing fails. The CHANGELOG
## entry and the git tag are the other two corners of the gate; those stay human, this one does not.

const PLUGIN_CFG_PATH := "res://addons/menu_kit/plugin.cfg"


func run_tests() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(PLUGIN_CFG_PATH)
	check_eq(err, OK, "plugin.cfg parses as a ConfigFile")
	if err != OK:
		return

	var declared: Variant = cfg.get_value("plugin", "version", null)
	check(declared is String and not (declared as String).is_empty(),
		"plugin.cfg declares a non-empty [plugin] version")
	if not (declared is String):
		return

	check_eq(declared, MKVersion.VERSION,
		"plugin.cfg's version matches MKVersion.VERSION — the hand-mirrored constant has not drifted")

	# The release value itself, so a stray "-dev" or an un-bumped constant is caught at the source
	# rather than only as a mismatch (both halves can be wrong together).
	check_eq(MKVersion.VERSION, "0.1.0",
		"MKVersion.VERSION is the 0.1.0 release value")

	# The other fields the gate reads: a plugin.cfg missing its name or script is not installable, and
	# no other test opens this file.
	check_eq(cfg.get_value("plugin", "name", ""), "MenuKit", "plugin.cfg names the plugin")
	check_eq(cfg.get_value("plugin", "script", ""), "plugin.gd", "and points at the EditorPlugin script")

	# The version reaches the surface a bug report is pasted from.
	check(MKVersion.version_string().contains(MKVersion.VERSION),
		"version_string() carries the version, which is what dump_diagnostics surfaces")
