@abstract
class_name MKMenuBackend
extends Node
## Application-level actions the menu triggers but does not define.
##
## MenuKit knows a button was pressed; only the host knows what "start the game" means — a scene
## change, a level load, a lobby join.
##
## Backends are Nodes, not Resources, because these actions need scene-tree access. [MKRoot]
## instantiates the slot's script as a child at runtime and calls [method _mk_configure] first.

## Begin play. [param profile] is the selected roster entry verbatim from [MKProfileBackend], or an
## empty dictionary when the host has no profile concept.
@abstract func start_game(profile: Dictionary) -> void

## Return to the main menu from gameplay — the other half of [method start_game], and what the
## pause menu's quit-to-menu calls.
@abstract func to_main_menu() -> void

## Leave the application. Separate from [method to_main_menu] because a host may need to save,
## disconnect, or confirm first.
@abstract func quit() -> void


## Open an external URL (credits links, support pages). Non-abstract: the engine-level answer is
## almost always the right one, so hosts rarely override it.
func open_url(url: String) -> void:
	if url.is_empty():
		MKLog.warn("open_url called with an empty URL")
		return
	var err := OS.shell_open(url)
	if err != OK:
		MKLog.warn("open_url failed for '%s' (error %d)" % [url, err])


## Optional parameterization hook. Return the keys consumed from [param params] so [MKRoot] can warn
## by name about the ones nothing claimed. A backend needing no parameters does not override this.
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
