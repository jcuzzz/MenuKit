extends SceneTree

# Visual capture harness — renders ONE scene for a fixed number of frames and saves the
# viewport to PNG so an agent (or human) can inspect layout without launching the full game.
# Invoked by tools/capture_scene.ps1; do not run under --headless (needs a real renderer).
#
# A rig may only RAISE the frame count (maxi below), never cap it: rig waits are refresh-rate
# arithmetic, so a rig that knows it needs N frames must not be shortened by the caller.
#
# User args (after `--`), key=value:
#   scene=res://path/to.tscn   (required)
#   out=C:/abs/path.png        (required)
#   rig=res://tools/capture_rigs/x.gd   (optional — presentation-only scene setup)
#   frames=8 width=1280 height=720      (optional)

var _args: Dictionary = {}


func _initialize() -> void:
	for raw in OS.get_cmdline_user_args():
		var eq := raw.find("=")
		if eq > 0:
			_args[raw.substr(0, eq)] = raw.substr(eq + 1)
	call_deferred("_run")


func _fail(msg: String) -> void:
	print("CAPTURE_RESULT status=error exit=1  # ", msg)
	quit(1)


func _run() -> void:
	var scene_path := str(_args.get("scene", ""))
	var out_path := str(_args.get("out", ""))
	var frames := maxi(int(str(_args.get("frames", "8"))), 1)
	var width := int(str(_args.get("width", "1280")))
	var height := int(str(_args.get("height", "720")))
	if scene_path == "" or out_path == "":
		_fail("missing required arg (scene=, out=)")
		return

	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(width, height)

	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		_fail("scene failed to load: %s" % scene_path)
		return
	var node := packed.instantiate()

	# UI scenes get a neutral dark backdrop (else they render on black and dark themes vanish).
	# 3D scenes must NOT be covered — their world renders beneath the 2D layer.
	if node is Control:
		var bg := ColorRect.new()
		bg.color = Color(0.15, 0.15, 0.18)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.size = Vector2(width, height)
		root.add_child(bg)
	root.add_child(node)

	var rig_path := str(_args.get("rig", ""))
	if rig_path != "":
		var rig_script: GDScript = load(rig_path) as GDScript
		if rig_script == null:
			_fail("rig failed to load: %s" % rig_path)
			return
		var rig: Object = rig_script.new()
		if rig.has_method("setup"):
			rig.call("setup", node, self)
		if rig.has_method("wait_frames"):
			frames = maxi(int(rig.call("wait_frames")), frames)

	for i in range(frames):
		await process_frame

	var img: Image = root.get_texture().get_image()
	var err: Error = img.save_png(out_path)
	if err != OK:
		_fail("save_png failed (%d): %s" % [err, out_path])
		return
	print("CAPTURE_RESULT status=ok scene=%s out=%s size=%dx%d exit=0" % [
		scene_path, out_path, img.get_width(), img.get_height()])
	quit(0)
