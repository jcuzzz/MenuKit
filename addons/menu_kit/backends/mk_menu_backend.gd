@abstract
class_name MKMenuBackend
extends Node
## Application-level actions the menu triggers but does not define (plan §4.1).
##
## MenuKit knows a button was pressed; only the host knows what "start the game" means — a scene
## change, a level load, a lobby join. Keeping that behind a backend is what lets the same package
## serve a single-player Doom-like and an online PvP FPS without a fork.
##
## Backends are Nodes, not Resources, because these actions need scene-tree access. [MKRoot]
## instantiates the slot's script as a child at runtime and calls [method _mk_configure] first.

## Begin play. [param profile] is the selected roster entry verbatim from [MKProfileBackend], or an
## empty dictionary when the host has no profile concept.
@abstract func start_game(profile: Dictionary) -> void

## Return to the main menu from gameplay — the other half of [method start_game], exercised by the
## pause menu's quit-to-menu and by ship gate 4b.
@abstract func to_main_menu() -> void

## Leave the application. Separate from [method to_main_menu] because a host may need to save,
## disconnect, or confirm first.
@abstract func quit() -> void


## Open an external URL (credits links, support pages). Non-abstract with a working default because
## it is the one action with a sane engine-level answer, and hosts rarely need to change it.
func open_url(url: String) -> void:
	if url.is_empty():
		MKLog.warn("open_url called with an empty URL")
		return
	var err := OS.shell_open(url)
	if err != OK:
		MKLog.warn("open_url failed for '%s' (error %d)" % [url, err])


## Optional parameterization hook (plan §4.1). Return the keys consumed from [param params] so
## [MKRoot] can warn by name about the ones nothing claimed. A backend needing no parameters simply
## does not override this.
func _mk_configure(params: Dictionary) -> Array[String]:
	return []
