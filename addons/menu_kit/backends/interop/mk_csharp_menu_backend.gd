class_name MKCSharpMenuBackend
extends MKMenuBackend
## An [MKMenuBackend] whose behaviour lives in a C# node.
##
## Point a menu slot at this script and give it [code]params = {"delegate_path": "/root/YourNode"}[/code];
## the C# node implements [code]StartGame(Godot.Collections.Dictionary)[/code],
## [code]ToMainMenu()[/code], [code]Quit()[/code] and optionally [code]OpenUrl(string)[/code] and
## [code]MkConfigure(Godot.Collections.Dictionary)[/code]. Either spelling is accepted — see
## [MKCSharpDelegate] for the mapping rule and the degrade-visible warnings.
##
## [b]No signals.[/b] [MKMenuBackend] declares none, so this adapter bridges none.

var _bridge := MKCSharpDelegate.new("MKCSharpMenuBackend")


func _mk_configure(params: Dictionary) -> Array[String]:
	return _bridge.configure(params)


func _ready() -> void:
	_bridge.ensure_resolved()


func start_game(profile: Dictionary) -> void:
	_bridge.forward("start_game", [profile])


func to_main_menu() -> void:
	_bridge.forward("to_main_menu")


func quit() -> void:
	_bridge.forward("quit")


## Forwarded only when the delegate implements it; otherwise the base's OS.shell_open answer stands,
## which is the right one for almost every host.
func open_url(url: String) -> void:
	if _bridge.supports_quiet("open_url"):
		_bridge.forward("open_url", [url])
		return
	super.open_url(url)


## The delegate this adapter forwards to, or null. Diagnostics only.
func get_delegate() -> Node:
	return _bridge.get_delegate()
