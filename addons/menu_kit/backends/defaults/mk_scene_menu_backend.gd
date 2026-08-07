class_name MKSceneMenuBackend
extends MKMenuBackend
## The zero-code menu backend: "start the game" means "change to that scene".
##
## [b]It names no scene of its own.[/b] Both targets arrive as [member MKBackendSlot.params] through
## [method _mk_configure]; an addon file containing a path into a host project would make the package
## non-self-contained. The shipped [code]default_config.tres[/code] leaves the params empty and the
## host supplies real scenes from its own config.
##
## [b]Unassigned params are valid config.[/b] A missing target warns when something invokes it —
## clicking Play — and never at boot, so a fresh install is warning-free.
##
## Hosts needing more than a scene change (a loading screen, a save load, a lobby join) write their
## own [MKMenuBackend]; this one covers the case where the whole answer is one scene swap.

## Params key naming the scene [method start_game] switches to.
const PARAM_GAME_SCENE := "game_scene"

## Params key naming the scene [method to_main_menu] switches to.
const PARAM_MENU_SCENE := "menu_scene"

var _game_scene := ""
var _menu_scene := ""


## Reads both scene paths from the slot's params and reports which keys it claimed, so [MKRoot] can
## warn by name about a misspelled one instead of silently ignoring it.
func _mk_configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	if params.has(PARAM_GAME_SCENE):
		_game_scene = _read_path(params[PARAM_GAME_SCENE], PARAM_GAME_SCENE)
		consumed.append(PARAM_GAME_SCENE)
	if params.has(PARAM_MENU_SCENE):
		_menu_scene = _read_path(params[PARAM_MENU_SCENE], PARAM_MENU_SCENE)
		consumed.append(PARAM_MENU_SCENE)
	return consumed


## Switches to the configured game scene. [param profile] is ignored here: a scene change carries no
## payload, and a host that needs the selected roster entry in-game is past what this default covers
## and should write its own backend.
func start_game(_profile: Dictionary) -> void:
	_change_scene(_game_scene, PARAM_GAME_SCENE)


## Switches to the configured menu scene — the quit-to-menu half of the pair.
func to_main_menu() -> void:
	_change_scene(_menu_scene, PARAM_MENU_SCENE)


## Leaves the application through [method SceneTree.quit], which lets the engine run normal shutdown
## (notifications, autoload teardown) rather than killing the process.
func quit() -> void:
	var tree := get_tree()
	if tree == null:
		MKLog.error("MKSceneMenuBackend.quit called while outside the tree — nothing to quit")
		return
	tree.quit()


## Warns rather than errors on a missing or failed target: a host with no game scene yet is an
## incomplete integration, not a broken contract, and the menu stays usable either way.
func _change_scene(path: String, key: String) -> void:
	if path.is_empty():
		MKLog.warn("MKSceneMenuBackend has no '%s' param — nothing to switch to. Set it in the backend slot's params." % key)
		return
	var tree := get_tree()
	if tree == null:
		MKLog.error("MKSceneMenuBackend cannot change scenes while outside the tree ('%s')" % key)
		return
	var err := tree.change_scene_to_file(path)
	if err != OK:
		MKLog.warn("MKSceneMenuBackend failed to load '%s' for '%s' (error %d)" % [path, key, err])


## Accepts a path String. Anything else is a config mistake worth naming, since a wrong-typed param
## would otherwise surface only as a dead Play button.
func _read_path(value: Variant, key: String) -> String:
	if value is String:
		return value as String
	if value is StringName:
		return String(value)
	MKLog.warn("MKSceneMenuBackend param '%s' should be a scene path String, got %s — ignoring"
		% [key, type_string(typeof(value))])
	return ""
