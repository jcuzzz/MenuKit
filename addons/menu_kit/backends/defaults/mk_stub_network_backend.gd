class_name MKStubNetworkBackend
extends MKNetworkBackend
## A fake server list with a real connection lifecycle, and no sockets at all.
##
## MenuKit ships no networking. This exists so the server-browser panel has genuine states to render
## — a connect that takes time and succeeds, one that fails, and one a user cancels mid-flight.
## Ships in the addon but is [b]not[/b] assigned by [code]default_config.tres[/code]: an empty network
## slot hides the browser.
##
## [b]Timing is real, not instant.[/b] A stub that returned [constant MKNetworkBackend.ConnectState]
## [code]CONNECTED[/code] synchronously would never let the panel show its connecting state or its
## Cancel button. Delays run on [SceneTreeTimer]s, which keep ticking while [member SceneTree.paused]
## is true — the whole [MKRoot] subtree runs [constant Node.PROCESS_MODE_ALWAYS] for the same reason.

## Params key overriding the simulated connect duration, in seconds.
const PARAM_CONNECT_DELAY := "connect_delay"

## Params key overriding the simulated refresh sweep duration, in seconds.
const PARAM_REFRESH_DELAY := "refresh_delay"

## The entry whose connect always fails, so the failure path is reachable from the panel without any
## way to make it flaky.
const FAILING_SERVER_ID := &"mk_stub_far"

var _connect_delay := 1.2
var _refresh_delay := 0.6

var _servers: Array[Dictionary] = []
var _state: ConnectState = ConnectState.IDLE
## Bumped by every [method cancel] and every new [method connect_to]. A timer callback that does not
## match the current value belongs to a superseded attempt and does nothing — which is what makes
## cancellation actually cancel rather than merely re-label a connection still on its way.
var _generation := 0
var _refreshing := false


func _init() -> void:
	_servers = [
		{
			"id": &"mk_stub_local",
			"name": "Local Test Server",
			"players": 3,
			"max_players": 16,
			"ping": 12,
			"map": "Warehouse",
		},
		{
			"id": &"mk_stub_ranked",
			"name": "Ranked Deathmatch",
			"players": 14,
			"max_players": 16,
			"ping": 48,
			"map": "Foundry",
		},
		{
			"id": FAILING_SERVER_ID,
			"name": "Distant Region (unreachable)",
			"players": 0,
			"max_players": 32,
			"ping": 320,
			"map": "Canyon",
		},
	]


## Reads the two optional timing overrides and reports the keys claimed.
func _mk_configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	if params.has(PARAM_CONNECT_DELAY):
		_connect_delay = _read_delay(params[PARAM_CONNECT_DELAY], PARAM_CONNECT_DELAY, _connect_delay)
		consumed.append(PARAM_CONNECT_DELAY)
	if params.has(PARAM_REFRESH_DELAY):
		_refresh_delay = _read_delay(params[PARAM_REFRESH_DELAY], PARAM_REFRESH_DELAY, _refresh_delay)
		consumed.append(PARAM_REFRESH_DELAY)
	return consumed


## The fake list. Entries are copied on the way out so a panel that decorates a row (a selection
## flag, a display string) cannot mutate this backend's own state through the reference it was given.
func list_servers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in _servers:
		out.append(entry.duplicate())
	return out


## Simulates a sweep: emits [signal MKNetworkBackend.servers_changed] once the fake delay elapses,
## with pings nudged so a repeated refresh visibly changes something. A second call while a sweep is
## in flight is ignored rather than queued — a panel with a held-down refresh button should not stack
## sweeps.
func refresh() -> void:
	if _refreshing:
		return
	_refreshing = true
	var scheduled := _after(_refresh_delay, func() -> void:
		_refreshing = false
		for i in _servers.size():
			var entry := _servers[i]
			# Deterministic drift, not random: a stub reporting different numbers every run makes a panel
			# screenshot impossible to compare against the last.
			entry["ping"] = 8 + ((int(entry["ping"]) + 7) % 200)
			_servers[i] = entry
		servers_changed.emit()
	)
	if not scheduled:
		# Nothing will ever clear the flag, so a later refresh would be refused forever.
		_refreshing = false


## Starts a fake connection. Reports progress through
## [signal MKNetworkBackend.connect_state_changed] only — the panel must stay responsive and
## cancellable while it runs, which a blocking return value would not allow.
##
## Calling this while another attempt is in flight supersedes that attempt: the older one's timer
## callback no longer matches the generation and is discarded, so it cannot report a state for a
## server the user has already moved on from.
func connect_to(entry: Dictionary) -> void:
	var id: StringName = StringName(entry.get("id", &""))
	if String(id).is_empty():
		# The panel passes a list_servers row back verbatim; one without an id means the caller invented
		# an entry. Report it as a failed connection so the UI has a state rather than hanging in
		# CONNECTING.
		MKLog.warn("MKStubNetworkBackend.connect_to received an entry with no 'id'")
		_set_state(ConnectState.FAILED, "Invalid server entry.")
		return
	var known := _find(id)
	if known.is_empty():
		MKLog.warn("MKStubNetworkBackend.connect_to received an unknown server id '%s'" % id)
		_set_state(ConnectState.FAILED, "Unknown server.")
		return
	_generation += 1
	var generation := _generation
	_set_state(ConnectState.CONNECTING, "Connecting to %s…" % String(known.get("name", id)))
	var scheduled := _after(_connect_delay, func() -> void:
		if generation != _generation:
			return
		if id == FAILING_SERVER_ID:
			_set_state(ConnectState.FAILED, "Connection timed out.")
		else:
			_set_state(ConnectState.CONNECTED, "Connected to %s." % String(known.get("name", id)))
	)
	if not scheduled:
		# Out of the tree there is no timer, so nothing would ever move this off CONNECTING and the
		# panel would sit on a spinner forever. Report the terminal state the caller is owed.
		_set_state(ConnectState.FAILED, "Connection unavailable.")


## Aborts an in-flight attempt. Safe when idle: with nothing connecting there is no state to leave,
## and emitting [code]CANCELLED[/code] anyway would make a stray Cancel press wipe a
## [code]FAILED[/code] message the user has not read yet.
func cancel() -> void:
	if _state != ConnectState.CONNECTING:
		return
	_generation += 1
	_set_state(ConnectState.CANCELLED, "Connection cancelled.")


## The current lifecycle state, for a panel binding after a state change has already been emitted.
func get_connect_state() -> ConnectState:
	return _state


func _set_state(state: ConnectState, message: String) -> void:
	_state = state
	connect_state_changed.emit(state, message)


## Runs [param action] after [param seconds]. Connected as a one-shot rather than awaited: a
## [SceneTreeTimer] drops its connection when this node is freed, whereas an awaited coroutine would
## resume inside a freed instance if the menu is torn down mid-connect.
##
## Returns whether the delay was actually scheduled, so a caller that has already announced
## CONNECTING can report a terminal state instead of stranding the panel on a spinner. Being out of
## the tree warns rather than errors — it is recoverable, and [code]MKLog.error[/code] is reserved
## for contract violations.
func _after(seconds: float, action: Callable) -> bool:
	var tree := get_tree()
	if tree == null:
		MKLog.warn("MKStubNetworkBackend is out of the tree; cannot run its simulated delay")
		return false
	var timer := tree.create_timer(maxf(seconds, 0.0))
	timer.timeout.connect(action, CONNECT_ONE_SHOT)
	return true


func _find(id: StringName) -> Dictionary:
	for entry in _servers:
		if StringName(entry.get("id", &"")) == id:
			return entry
	return {}


func _read_delay(value: Variant, key: String, fallback: float) -> float:
	if value is float or value is int:
		return maxf(float(value), 0.0)
	MKLog.warn("MKStubNetworkBackend param '%s' should be a number of seconds, got %s — keeping %.2f"
		% [key, type_string(typeof(value)), fallback])
	return fallback
