extends RefCounted
## Capture rig: opens a confirm dialog over the shell so the scrim, dialog layout, and destructive
## styling can be eyeballed.
##
## The modal stack is the one Phase 1 deliverable whose failure mode is entirely visual — a scrim
## that does not cover, a dialog that renders behind the page, or a focus ring that never appears
## all pass every headless assertion in the suite.

func wait_frames() -> int:
	return 20


func setup(node: Node, tree: SceneTree) -> void:
	var root := node as MKRoot
	if root == null:
		push_error("modal_rig expects an MKRoot as the captured scene")
		return
	# MKRoot._ready() ran synchronously inside add_child, so the shell and the modal layer already
	# exist here. Awaiting a frame first would make setup() a coroutine, and the capture harness
	# calls rigs without awaiting them — the dialog would open after the PNG was taken.
	var layer := root.get_modal_layer()
	if layer == null:
		push_error("modal_rig: MKRoot exposed no modal layer")
		return
	MKConfirmDialog.open(layer, "Delete profile",
		"This cannot be undone. The scrim behind this dialog should dim the page without hiding the nav bar entirely.",
		"Delete", "Cancel", true)
