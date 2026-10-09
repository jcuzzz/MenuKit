class_name MKCSharpNetworkBackend
extends MKNetworkBackend
## An [MKNetworkBackend] whose transport lives in a C# node.
##
## The C# node implements [code]ListServers()[/code], [code]ConnectTo(Dictionary)[/code],
## [code]Cancel()[/code], and optionally [code]Refresh()[/code] and
## [code]MkConfigure(Dictionary)[/code].
##
## [b]Bridged signals:[/b] [signal MKNetworkBackend.servers_changed] (arity 0) and
## [signal MKNetworkBackend.connect_state_changed] (arity 2 —
## [code](state: int, message: String)[/code] across the boundary; C# should emit the state as the
## integer value of [enum MKNetworkBackend.ConnectState]).
##
## An out-of-range state is refused and re-emitted as [code]FAILED[/code] with the delegate's own
## message: the panel renders every enum member and nothing else, so a bogus value must land on a
## terminal state rather than leave the browser on a spinner.

const _STATES: Array = [
	ConnectState.IDLE,
	ConnectState.CONNECTING,
	ConnectState.CONNECTED,
	ConnectState.FAILED,
	ConnectState.CANCELLED,
]

var _bridge := MKCSharpDelegate.new("MKCSharpNetworkBackend")


func _init() -> void:
	_bridge.bridge("servers_changed", _on_delegate_servers_changed)
	_bridge.bridge("connect_state_changed", _on_delegate_connect_state_changed)


func _mk_configure(params: Dictionary) -> Array[String]:
	return _bridge.configure(params)


func _ready() -> void:
	_bridge.ensure_resolved()


func list_servers() -> Array[Dictionary]:
	return _bridge.to_dictionary_array("list_servers", _bridge.forward("list_servers"))


func connect_to(entry: Dictionary) -> void:
	_bridge.forward("connect_to", [entry])


func cancel() -> void:
	_bridge.forward("cancel")


func refresh() -> void:
	if _bridge.supports_quiet("refresh"):
		_bridge.forward("refresh")
		return
	super.refresh()


## The current lifecycle state when the delegate tracks one. Duck-typed by [MKServerBrowser] to seed
## its caption on re-entry, so a delegate exposing [code]GetConnectState()[/code] gets that behaviour
## for free; one that does not is simply never asked.
func get_connect_state() -> ConnectState:
	if not _bridge.supports_quiet("get_connect_state"):
		return ConnectState.IDLE
	return _bridge.to_enum(
		"get_connect_state", _bridge.forward("get_connect_state"), _STATES, ConnectState.IDLE) as ConnectState


func get_delegate() -> Node:
	return _bridge.get_delegate()


func _on_delegate_servers_changed() -> void:
	servers_changed.emit()


func _on_delegate_connect_state_changed(state: Variant, message: Variant) -> void:
	var resolved := _bridge.to_enum(
		"connect_state_changed", state, _STATES, ConnectState.FAILED)
	connect_state_changed.emit(resolved as ConnectState, String(message))
