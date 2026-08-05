extends MKTest
## Ship gate 1, inside the suite (plan §6).
##
## The same two scans [code]tools/isolation_check.ps1[/code] runs, duplicated here on purpose: the
## PowerShell script is the ship-gate entry point, but a rule enforced only by a script someone has
## to remember to run is a rule that decays. Living in [code]check.ps1 -Smokes[/code] means the
## isolation guarantee is checked on every phase gate from Phase 1 onward, which is exactly when a
## stray [code]res://demo/[/code] reference gets introduced.

const ADDON_ROOT := "res://addons/menu_kit"
const SCANNED_EXTS := ["gd", "tscn", "tres", "gdshader", "cfg"]


func run_tests() -> void:
	var files := _collect(ADDON_ROOT)
	check(files.size() > 0, "found addon files to scan")

	var foreign: Array[String] = []
	var overrides: Array[String] = []
	var path_re := RegEx.new()
	path_re.compile('res://[^"\'\\s\\)\\]]+')
	var override_re := RegEx.new()
	# The .tscn form is a serialised PROPERTY (theme_override_colors/font_color), not the call — a
	# call-only pattern left the scene half of this scan dead.
	override_re.compile("add_theme_\\w+_override|theme_override_\\w+/")

	for path in files:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		for m in path_re.search_all(text):
			var p := m.get_string(0)
			if not p.begins_with(ADDON_ROOT + "/"):
				foreign.append("%s -> %s" % [path, p])
		if path.ends_with(".gd") or path.ends_with(".tscn"):
			for m in override_re.search_all(text):
				overrides.append("%s -> %s" % [path, m.get_string(0)])

	check(foreign.is_empty(), "no res:// reference escapes the addon: %s" % ", ".join(foreign))
	check(overrides.is_empty(),
		"no add_theme_*_override in the addon (a Theme could never re-skin past one): %s"
			% ", ".join(overrides))


func _collect(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				out.append_array(_collect(full))
			elif SCANNED_EXTS.has(entry.get_extension()):
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
