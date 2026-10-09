class_name MKCSharpPausePolicy
extends MKPausePolicy
## An [MKPausePolicy] whose pause semantics live in a C# node.
##
## The C# node implements [code]EnterMenu(StringName)[/code], [code]ExitMenu(StringName)[/code], and
## optionally [code]CanPause()[/code], [code]MkConfigure(Dictionary)[/code] and
## [code]MkExitTree()[/code].
##
## [b]No signals.[/b] [MKPausePolicy] declares none, so this adapter bridges none.
##
## [b]Teardown crosses the boundary through [code]MkExitTree[/code].[/b] The base's contract is that
## a policy undoes its own effects in [method Node._exit_tree] — but the effects live in the
## delegate, which is typically an autoload that never leaves the tree, so it would never learn that
## the shell it was pausing for is gone and the next game would boot frozen. This adapter's
## [method Node._exit_tree] forwards that one notification. A delegate not exposing the hook is
## silent (optional), and owns the consequence.

var _bridge := MKCSharpDelegate.new("MKCSharpPausePolicy")


func _mk_configure(params: Dictionary) -> Array[String]:
	return _bridge.configure(params)


func _ready() -> void:
	_bridge.ensure_resolved()


func enter_menu(reason: StringName) -> void:
	_bridge.forward("enter_menu", [reason])


func exit_menu(reason: StringName) -> void:
	_bridge.forward("exit_menu", [reason])


func can_pause() -> bool:
	if _bridge.supports_quiet("can_pause"):
		return _bridge.to_bool("can_pause", _bridge.forward("can_pause"), true)
	return super.can_pause()


func get_delegate() -> Node:
	return _bridge.get_delegate()


func _exit_tree() -> void:
	if _bridge.supports_quiet("_mk_exit_tree"):
		_bridge.forward("_mk_exit_tree")
