extends SceneTree
## Compile / scene gate for MenuKit. Loads every project .gd and .tscn — compiling scripts,
## validating scenes and their script refs — and reports failures.
##
## res://addons IS scanned here, because the addon is the product.
##
##   <godot_console> --headless --path . --script tools/check_compile.gd
##
## Exit 0 = all loaded; exit 1 = one or more failed.

const ROOTS := ["res://addons", "res://demo", "res://tests", "res://tools"]
const SKIP_DIRS := [".godot"]

var _ok := 0
var _failed: Array[String] = []


func _initialize() -> void:
	call_deferred("_go")


func _go() -> void:
	for root in ROOTS:
		_scan(root)
	for f in _failed:
		printerr("[FAIL] %s" % f)
	print("COMPILE: %d ok / %d failed" % [_ok, _failed.size()])
	quit(0 if _failed.is_empty() else 1)


func _scan(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not SKIP_DIRS.has(entry):
				_scan(full)
		elif entry.ends_with(".gd") or entry.ends_with(".tscn"):
			_check(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _check(path: String) -> void:
	var res = ResourceLoader.load(path)
	if res == null:
		_failed.append(path)
		return
	# A .gd with a parse error can still load as a NON-null GDScript resource; can_instantiate() is
	# false until it actually compiles.
	#
	# Abstract scripts report can_instantiate() false BY DESIGN, so they cannot use that signal.
	# Exempting them outright would let a parse error in any abstract base compile green, so they
	# get reload(), which surfaces the parse result directly.
	if res is GDScript:
		var script := res as GDScript
		if _is_abstract(path):
			var err := script.reload()
			if err != OK:
				_failed.append("%s (parse/compile error %d in abstract script)" % [path, err])
				return
		elif not script.can_instantiate():
			_failed.append("%s (parse/compile error)" % path)
			return
	# Godot tolerates a .tscn whose ext_resource is missing (load returns non-null, ref nulled).
	if path.ends_with(".tscn"):
		var missing := _missing_ext_resources(path)
		if not missing.is_empty():
			_failed.append("%s (missing ext_resource: %s)" % [path, ", ".join(missing)])
			return
	_ok += 1


## `@abstract` scripts cannot be instantiated by design, so can_instantiate() is a false positive
## for them. Detected from source rather than a hardcoded list so new abstract bases need no edit.
func _is_abstract(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	for line in text.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("@abstract"):
			return true
		# Only the header matters; stop once past it.
		if t.begins_with("func ") or t.begins_with("var ") or t.begins_with("const "):
			break
	return false


func _missing_ext_resources(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var text := f.get_as_text()
	f.close()
	var re := RegEx.new()
	re.compile('ext_resource.*path="(res://[^"]+)"')
	for m in re.search_all(text):
		var p := m.get_string(1)
		if not ResourceLoader.exists(p) and not FileAccess.file_exists(p):
			out.append(p)
	return out
