extends RefCounted
## Capture rig: navigates the shell to the settings page so the schema-built panel can be eyeballed.
##
## The settings panel is runtime-built from page defs, so its failure modes are visual by
## construction — an unstyled row, a collapsed tab bar, or a slider with no readout all pass every
## headless assertion.
##
## MK_CAPTURE_PALETTE=<res:// path to an MKPalette .tres>  assigns that palette to the shell's config
##                      BEFORE the tab navigation below, so the shot is the RE-SKINNED panel. This is
##                      the visual half of ship gate 3 (`demo/alt_skin/alt_palette.tres` is the shipped
##                      subject): headless assertions can prove the generated Theme differs, but only
##                      a PNG shows whether the alternative skin is legible. The assignment is an
##                      in-memory mutation of the loaded config in a throwaway capture process —
##                      nothing is saved, so the demo's config on disk is untouched.

## Frames, not seconds: the page builds and MKRoot defers its focus pass, and this count only means
## a duration at an assumed refresh rate — size any change for the fastest common display.
func wait_frames() -> int:
	return 40


func setup(node: Node, tree: SceneTree) -> void:
	var root := node as MKRoot
	if root == null:
		push_error("settings_rig expects an MKRoot as the captured scene")
		return
	# Re-skin BEFORE navigating: MKRoot regenerates its Theme off the palette reassignment, and pages
	# are themed by inheritance, so the order only has to put the assignment ahead of the shot. Doing it
	# first also means a broken path fails before any page is built.
	var palette_path := OS.get_environment("MK_CAPTURE_PALETTE")
	if not palette_path.is_empty():
		if root.config == null:
			push_error("settings_rig: MK_CAPTURE_PALETTE set but the root has no MKConfig")
			return
		var palette := ResourceLoader.load(palette_path) as MKPalette
		if palette == null:
			push_error("settings_rig: MK_CAPTURE_PALETTE '%s' is not an MKPalette resource" % palette_path)
			return
		root.config.palette = palette

	root.go_to_page(&"settings")
	# Optional tab override for eyeballing the non-default pages: MK_CAPTURE_TAB names a tab title
	# (e.g. "Gameplay"). The panel hosts its pages in a TabContainer built at runtime.
	var wanted := OS.get_environment("MK_CAPTURE_TAB")
	if not wanted.is_empty():
		var tabs := root.find_child("Pages", true, false) as TabContainer
		if tabs == null:
			push_error("settings_rig: no TabContainer named 'Pages' found for MK_CAPTURE_TAB")
			return
		var found := false
		for i in tabs.get_tab_count():
			if tabs.get_tab_title(i) == wanted:
				tabs.current_tab = i
				found = true
				break
		if not found:
			push_error("settings_rig: no tab titled '%s'" % wanted)
			return

	# Optional focus override: MK_CAPTURE_FOCUS_ROW names a row shell (the panel names them
	# "Row_<id with / as _>"), whose control is focused before the shot. A slider's focus ring only
	# draws while the slider HAS focus and nothing in a static capture focuses a row on its own, so
	# without this the one thing that needed an eyeball is never on screen. The row is a parameter
	# rather than "the first slider" because focusing brightness also raises its calibration swatch,
	# which then fills that row in the shot.
	var focus_row := OS.get_environment("MK_CAPTURE_FOCUS_ROW")
	if focus_row.is_empty():
		return
	var row := root.find_child(focus_row, true, false)
	if row == null:
		push_error("settings_rig: no row named '%s' for MK_CAPTURE_FOCUS_ROW" % focus_row)
		return
	for child in row.get_children():
		var control := child as Control
		if control != null and control.focus_mode != Control.FOCUS_NONE:
			# Deferred by a beat, not grabbed here: a page entering the tree focuses its own first
			# control, and that happens AFTER this rig runs. Grabbing immediately hands focus straight
			# back to the page and the ring is gone before the shot.
			tree.create_timer(0.15).timeout.connect(control.grab_focus)
			return
	push_error("settings_rig: row '%s' has no focusable control" % focus_row)
