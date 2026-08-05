@abstract
class_name MKPausePolicy
extends Node
## What "pause" means to this game (plan §4.2a).
##
## Pause is a backend for the same reason every other host concern is: [b]you cannot pause a
## multiplayer game[/b]. Hardcoding [code]get_tree().paused = true[/code] inside MenuKit would
## guarantee that a PvP reuse either fights the package or forks it — and a fork breaks the
## pin-a-tag upgrade story the whole versioning approach depends on.
##
## [b]Policies do not count depth.[/b] [MKRoot] owns the single counter and calls [method
## enter_menu] only on the 0→1 edge and [method exit_menu] only on the 1→0 edge. Two counters
## driven by the same events — one of them host-replaceable — is how pause desyncs from cursor
## state with no single place to debug it. A policy still holds state (it must remember what it
## changed, to undo exactly that); what it must not hold is a count.
##
## [b]Teardown is your [method Node._exit_tree], not MKRoot's.[/b] Quit-to-menu frees the game scene
## and its MKRoot while the world is still paused. [constant Node.NOTIFICATION_EXIT_TREE] propagates
## children first, so by the time [code]MKRoot._exit_tree()[/code] runs this node is already out of
## the tree and its [method Node.get_tree] is null — MKRoot calling [method exit_menu] from there
## would crash. Undo your own effects in [method Node._exit_tree] while your tree reference is still
## valid. Leaving that out means the next game boots frozen, minutes from the cause.
##
## Policies needing the tree inside [method enter_menu] / [method exit_menu] should cache the
## [SceneTree] in [method Node._enter_tree] rather than calling [method Node.get_tree] late.

## A menu opened. [param reason] identifies the gesture ([code]&"pause"[/code],
## [code]&"modal"[/code]) so a policy can treat them differently — duck audio for one, autosave for
## another — without MenuKit enumerating every case.
@abstract func enter_menu(reason: StringName) -> void

## The last menu closed. Undo exactly what [method enter_menu] did.
@abstract func exit_menu(reason: StringName) -> void


## Whether this game can stop simulating.
##
## [b]This is never a veto on opening the menu.[/b] [code]false[/code] means the menu opens, the
## world keeps running, and [method enter_menu] is skipped — mouse mode and page state proceed
## identically. A menu you cannot open is never the right answer to "the world cannot pause".
##
## Defaults to [code]true[/code]: the common case is a single-player game, and a policy that
## overrides this to return [code]false[/code] is essentially the whole multiplayer story.
func can_pause() -> bool:
	return true


## Optional parameterization hook (plan §4.1). Returns the keys consumed from [param params].
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
