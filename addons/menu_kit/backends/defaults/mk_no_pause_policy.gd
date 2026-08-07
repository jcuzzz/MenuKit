class_name MKNoPausePolicy
extends MKPausePolicy
## The multiplayer answer: the menu opens, the world keeps running.
##
## [method MKPausePolicy.can_pause] returns [code]false[/code], which [MKRoot] reads on the 0→1 edge
## as "skip [method enter_menu]" — never as a veto on opening the menu. Mouse mode and page state
## proceed exactly as under [MKTreePausePolicy]; only the world-stopping is skipped.
##
## The behaviour matches leaving the pause-policy slot unassigned, so this class adds no logic — it
## adds a [i]name[/i]. An empty [code]MKConfig.pause_policy[/code] cannot distinguish "multiplayer,
## deliberately never pauses" from "nobody wired this up yet"; a named class in the slot is a stated
## decision. It is also the starting point for a real multiplayer policy: override
## [method MKPausePolicy.enter_menu] to duck audio or tell the server the player is in menus, and the
## [code]false[/code] below still holds.
##
## [b]Host responsibility:[/b] the world runs while MenuKit frees the cursor, so a first-person
## camera keeps consuming relative mouse motion behind the menu. Gate camera input on
## [signal MKRoot.pause_menu_toggled] — MenuKit does not own the camera and cannot do it for you.

## Always [code]false[/code]: this game does not stop simulating. Everything else about opening a
## menu is unchanged.
func can_pause() -> bool:
	return false


## Never called while [method can_pause] returns [code]false[/code] — MKRoot skips it on the 0→1
## edge. Present because the base declares it abstract, and as the override point for a policy that
## wants a side effect without a pause.
func enter_menu(_reason: StringName) -> void:
	pass


## Counterpart of [method enter_menu], and unreached for the same reason.
func exit_menu(_reason: StringName) -> void:
	pass
