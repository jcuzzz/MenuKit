class_name MKNoPausePolicy
extends MKPausePolicy
## The multiplayer answer: the menu opens, the world keeps running (plan §4.2a).
##
## [method MKPausePolicy.can_pause] returns [code]false[/code], which [MKRoot] reads on the 0→1 edge
## as "skip [method enter_menu]" — never as a veto on opening the menu. Mouse mode and page state
## proceed exactly as under [MKTreePausePolicy]; only the world-stopping is skipped.
##
## [b]Why a near-empty class earns a file.[/b] The behaviour is identical to leaving the pause-policy
## slot unassigned, so this class adds no logic — it adds a [i]name[/i]. A host reading
## [code]MKConfig.pause_policy[/code] and finding it empty cannot tell "multiplayer, deliberately
## never pauses" from "nobody wired this up yet", and that ambiguity sits on the one seam the whole
## backend design exists to serve. A named class in the slot is a stated decision, it is discoverable
## from the class list when a host goes looking for the multiplayer story, and it is the thing the
## Phase 6 policy-swap test swaps [i]to[/i]. It is also the natural starting point for a real
## multiplayer policy: override [method MKPausePolicy.enter_menu] to duck audio or tell the server
## the player is in menus, and the [code]false[/code] below still holds.
##
## Footgun this policy hands the host: the world runs while MenuKit frees the cursor, so a
## first-person camera keeps consuming relative mouse motion behind the menu. Gate camera input on
## [signal MKRoot.pause_menu_toggled] — MenuKit cannot do it, because it does not own the camera.

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
