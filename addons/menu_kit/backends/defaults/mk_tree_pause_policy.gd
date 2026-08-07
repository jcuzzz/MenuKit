class_name MKTreePausePolicy
extends MKPausePolicy
## The single-player answer: menus stop the world by setting [member SceneTree.paused].
##
## Shipped as the zero-wiring default so a cold drop gets a working pause menu without the host
## writing a line of code. A multiplayer host swaps in [MKNoPausePolicy] or its own script instead.
##
## [b]No depth counting here.[/b] [MKRoot] owns the one counter and calls [method enter_menu] only on
## the 0→1 edge, [method exit_menu] only on the 1→0 edge. This policy holds exactly one bit of state
## — whether [i]it[/i] was the one that set [member SceneTree.paused] — because its teardown must
## undo its own effect and nothing else. A host that had already paused the world for its own reason
## (a cutscene, a loading step) must still be paused after the menu closes.
##
## [b]Teardown lives in [method Node._exit_tree], not in MKRoot.[/b] Quit-to-menu frees the game
## scene while the world is paused; [constant Node.NOTIFICATION_EXIT_TREE] propagates children first,
## so MKRoot deliberately does not call [method exit_menu] from its own teardown. Without the
## [method Node._exit_tree] below, [member SceneTree.paused] would stay true and the next game would
## boot frozen.
##
## The [SceneTree] is cached in [method Node._enter_tree] because [method Node.get_tree] returns null
## once this node has left the tree, which is precisely when the teardown above has to run.

## The tree this policy pauses. Cached on entry so teardown does not depend on
## [method Node.get_tree], which is null by the time a freed policy needs it.
var _tree: SceneTree

## Whether this policy set [member SceneTree.paused] itself. The undo is conditional on this so a
## world already paused by the host survives the menu unchanged.
var _paused_by_policy := false


func _enter_tree() -> void:
	_tree = get_tree()


## Undo on the way out of the tree — the defined teardown path for every policy.
func _exit_tree() -> void:
	_unpause_if_owned()
	_tree = null


## Pauses the tree on MKRoot's 0→1 edge. [param reason] is unused: every MenuKit surface that
## suspends wants the same thing from a tree pause, and branching on the gesture would be state this
## policy could not unwind correctly in teardown.
func enter_menu(_reason: StringName) -> void:
	if _tree == null:
		MKLog.error("MKTreePausePolicy.enter_menu called with no cached SceneTree — the policy is not in the tree")
		return
	if _paused_by_policy:
		# MKRoot calls edges only, so this would mean two enters without an exit between them.
		MKLog.warn("MKTreePausePolicy.enter_menu called while already holding the pause — ignoring")
		return
	if _tree.paused:
		# Someone else paused first. Take no ownership, so the exit below does not resume a world
		# the host still wants stopped.
		MKLog.debug("tree was already paused on enter_menu — leaving ownership with whoever set it")
		return
	_tree.paused = true
	_paused_by_policy = true


## Resumes on MKRoot's 1→0 edge, and only if this policy was the one that paused.
func exit_menu(_reason: StringName) -> void:
	_unpause_if_owned()


func _unpause_if_owned() -> void:
	if not _paused_by_policy:
		return
	_paused_by_policy = false
	if _tree == null:
		MKLog.error("MKTreePausePolicy lost its SceneTree while holding the pause — the world may stay frozen")
		return
	_tree.paused = false
