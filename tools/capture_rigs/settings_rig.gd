extends RefCounted
## Capture rig: navigates the shell to the settings page so the schema-built panel can be eyeballed.
##
## The settings panel is runtime-built from page defs (D5), so its failure modes are visual by
## construction — an unstyled row, a collapsed tab bar, or a slider with no readout all pass every
## headless assertion. This rig exists for exactly the reason the modal rig does.

func wait_frames() -> int:
	return 20


func setup(node: Node, _tree: SceneTree) -> void:
	var root := node as MKRoot
	if root == null:
		push_error("settings_rig expects an MKRoot as the captured scene")
		return
	root.go_to_page(&"settings")
	# Optional tab override for eyeballing the non-default pages: MK_CAPTURE_TAB names a tab title
	# (e.g. "Gameplay"). The panel hosts its pages in a TabContainer built at runtime.
	var wanted := OS.get_environment("MK_CAPTURE_TAB")
	if wanted.is_empty():
		return
	var tabs := root.find_child("Pages", true, false) as TabContainer
	if tabs == null:
		push_error("settings_rig: no TabContainer named 'Pages' found for MK_CAPTURE_TAB")
		return
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == wanted:
			tabs.current_tab = i
			return
	push_error("settings_rig: no tab titled '%s'" % wanted)
