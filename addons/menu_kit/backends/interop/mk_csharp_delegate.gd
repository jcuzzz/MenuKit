class_name MKCSharpDelegate
extends RefCounted
## The one-way bridge every C# adapter backend forwards through.
##
## Godot does not let a C# class extend a GDScript one, so a C# backend cannot subclass
## [MKMenuBackend] and friends. The adapters in this folder subclass the bases instead and forward
## every call to a host-supplied node â€” typically a C# autoload â€” resolved from the slot param
## [constant PARAM_DELEGATE_PATH]. This class owns the three mechanisms all five need.
##
## [b]Name mapping.[/b] GDScript contracts are snake_case; C# registers methods and signals under
## their exact (conventionally PascalCase) names. Every lookup tries the snake_case name FIRST, then
## the PascalCase form derived by: strip leading underscores, split on [code]_[/code], upper-case
## each segment's first character, join. So [code]list_profiles[/code] â†’ [code]ListProfiles[/code],
## [code]connect_state_changed[/code] â†’ [code]ConnectStateChanged[/code], and the configure hook
## [code]_mk_configure[/code] â†’ [constant CONFIGURE_METHOD_PASCAL] ([code]MkConfigure[/code]) â€” the
## leading underscore is dropped because a C# member cannot idiomatically carry one, and
## [code]Mk[/code] rather than [code]MK[/code] because the rule is mechanical, not a special case.
##
## [b]Degradation is visible, never fatal.[/b] An unresolvable delegate warns ONCE naming the path
## and the adapter; a delegate answering neither spelling of a method warns ONCE naming both
## spellings and the delegate. In both cases the adapter answers with its base's own default, so a
## misconfigured C# host behaves like an unassigned slot rather than crashing at first call.

## Slot param naming the delegate node. Two spellings are accepted and mean the same thing: an
## absolute path under the window root ([code]/root/GameBackends[/code] â€” the [code]/root/[/code]
## segment is matched case-INSENSITIVELY) and the equivalent root-relative path
## ([code]GameBackends[/code]). Anything else absolute (e.g. [code]/Main/Foo[/code]) is treated as
## unresolvable and takes the warn-once degrade path rather than reaching [method Node.get_node] â€”
## see [method _resolve] for why no absolute NodePath is ever handed to the engine.
const PARAM_DELEGATE_PATH := "delegate_path"

## The GDScript spelling of the optional configure hook forwarded to the delegate.
const CONFIGURE_METHOD := "_mk_configure"

## The C# spelling of that hook. Stated as a constant because it is a published contract name, not
## an implementation detail a host can derive by reading this file.
const CONFIGURE_METHOD_PASCAL := "MkConfigure"

var _label: String
var _path := ""
var _delegate: Node = null
var _warned_missing := false
var _warned_methods := {}
var _warned_types := {}
var _bridges: Array = []
## Whether the LAST [method forward] reached the delegate. Read immediately after a call by an
## adapter that must know its call actually landed (the settings adapter's boot [code]load[/code]).
var _delivered := false
## Held only while the delegate is unresolvable, so params configured before a late C# autoload
## exists are delivered on the resolve that finds it rather than lost.
var _pending_configure = null
## Optional adapter hook fired once per successful resolution, AFTER the held configure params go
## over. Same purpose as [member _pending_configure] one level up: an adapter with its own calls to
## replay (the settings boot triad) needs to know the delegate just appeared, and it must see a
## delegate that is already configured when it does.
var on_resolved := Callable()


## [param label] names the adapter in every warning this bridge emits.
func _init(label: String) -> void:
	_label = label


## Reads [constant PARAM_DELEGATE_PATH] out of a slot's params and reports the keys claimed.
##
## Every remaining key is forwarded to the delegate's configure hook and claimed on its behalf: the
## delegate may not be resolvable yet (a C# autoload can sit below the adapter in autoload order),
## and reporting a key as unconsumed because of resolution ORDER would warn on correct config. The
## cost is that a typo in a delegate's own param key is the delegate's to catch, not MKRoot's.
func configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	var forwarded := {}
	for key in params.keys():
		var name := String(key)
		if name == PARAM_DELEGATE_PATH:
			_path = String(params[key])
			consumed.append(name)
			continue
		forwarded[key] = params[key]
		consumed.append(name)
	_send_configure(forwarded)
	return consumed


## True when the delegate is reachable and answers [param method] under either spelling. Warns once
## per method when the delegate is live but answers neither â€” the degrade-visible path.
func supports(method: String) -> bool:
	if _resolved_method(method) != "":
		return true
	_warn_unsupported(method)
	return false


## Presence test for OPTIONAL hooks: same lookup, no warning. A delegate is not required to expose
## a hook it has no use for.
func supports_quiet(method: String) -> bool:
	return _resolved_method(method) != ""


## Calls [param method] on the delegate under whichever spelling exists. Returns [code]null[/code]
## when nothing is callable (after the warn-once paths above), which is why every caller returning a
## typed value routes the result through one of the coercions below.
##
## Exactly ONE resolution pass per call: the miss path warns through [method _warn_unsupported]
## rather than re-entering [method supports], which would resolve the delegate a second time on the
## call that is already the slowest.
func forward(method: String, args: Array = []) -> Variant:
	_delivered = false
	var resolved := _resolved_method(method)
	if resolved == "":
		_warn_unsupported(method)
		return null
	_delivered = true
	return _delegate.callv(resolved, args)


## Whether the last [method forward] reached the delegate, as opposed to taking a degrade path. Read
## it immediately after the call it asks about.
func was_delivered() -> bool:
	return _delivered


## Registers a delegate signal to re-emit through [param sink]. [param sink] must be a Callable with
## the EXACT arity of the base's signal â€” arity is stated per signal at each adapter, never guessed
## here, because a mismatched connection fails at emit time rather than at wiring time.
##
## Registering after the delegate is already resolved connects immediately rather than waiting for a
## re-resolution that may never come.
func bridge(signal_name: String, sink: Callable) -> void:
	_bridges.append([signal_name, sink])
	if _delegate != null and is_instance_valid(_delegate):
		_connect_bridges()


## Resolves the delegate if it is not resolved yet. Adapters call this once after entering the tree
## so signal bridging does not have to wait for the first forwarded call.
func ensure_resolved() -> bool:
	return _resolve() != null


## The resolved delegate, or [code]null[/code]. Diagnostics only.
func get_delegate() -> Node:
	return _delegate


## The configured path, for diagnostics and warnings.
func get_delegate_path() -> String:
	return _path


## Leading underscores need no strip pass of their own: [method String.split] with
## [code]allow_empty = false[/code] already drops the empty segments they produce, so
## [code]_mk_configure[/code] and [code]mk_configure[/code] map onto the same [code]MkConfigure[/code].
func to_pascal_case(method: String) -> String:
	var out := ""
	for segment in method.split("_", false):
		out += segment.substr(0, 1).to_upper() + segment.substr(1)
	return out


## [param raw] as a bool, or [param fallback] when the delegate answered another type.
func to_bool(method: String, raw: Variant, fallback: bool) -> bool:
	if typeof(raw) == TYPE_BOOL:
		return bool(raw)
	_warn_type(method, raw, "bool")
	return fallback


func to_dictionary(method: String, raw: Variant) -> Dictionary:
	if typeof(raw) == TYPE_DICTIONARY:
		var out: Dictionary = raw
		return out
	_warn_type(method, raw, "Dictionary")
	return {}


## Narrowing is elementwise on purpose: [method Array.duplicate] returns an UNTYPED array and a
## whole-array assign would fail the moment one element is not a Dictionary.
func to_dictionary_array(method: String, raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		_warn_type(method, raw, "Array")
		return out
	var source: Array = raw
	for element in source:
		if typeof(element) == TYPE_DICTIONARY:
			out.append(element)
		else:
			_warn_type(method, element, "Dictionary element")
	return out


func to_event_array(method: String, raw: Variant) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if typeof(raw) != TYPE_ARRAY:
		_warn_type(method, raw, "Array")
		return out
	var source: Array = raw
	for element in source:
		if element is InputEvent:
			out.append(element)
		else:
			_warn_type(method, element, "InputEvent element")
	return out


## [param raw] as an int within [param values] â€” the shape enum returns cross the boundary as.
func to_enum(method: String, raw: Variant, values: Array, fallback: int) -> int:
	if typeof(raw) == TYPE_INT and values.has(int(raw)):
		return int(raw)
	_warn_type(method, raw, "one of %s" % [values])
	return fallback


## Resolution runs off [method Engine.get_main_loop] rather than a node reference: `_mk_configure`
## reaches an adapter BEFORE `MKRoot` adds it as a child, and a configure hook that could not be
## forwarded until the next frame would arrive after the first roster read.
func _resolve() -> Node:
	if _delegate != null and is_instance_valid(_delegate):
		return _delegate
	_delegate = null
	if _path.is_empty():
		_warn_missing("no '%s' param was set" % PARAM_DELEGATE_PATH)
		return null
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	# NEVER an absolute NodePath: `get_node_or_null` with one pushes an engine ERROR whenever there is
	# no active scene (every `--script` run, and boot before the main scene exists), and an adapter
	# whose only fault is being early â€” or misconfigured â€” must not print errors. So an absolute path
	# is PARSED here instead: split the first segment off, and only a case-insensitive `root` resolves
	# (relative to the window root, which is what `/root/` names). Any other leading segment cannot
	# name a node reachable from the window root, and takes the warn-once degrade path rather than
	# handing the engine a path it will reject loudly, twice per forwarded call, forever.
	var relative := _path
	if relative.begins_with("/"):
		var rest := relative.substr(1)
		var slash := rest.find("/")
		var head := rest if slash < 0 else rest.substr(0, slash)
		if head.to_lower() != "root":
			_warn_missing("an absolute path must begin with '/root/'")
			return null
		relative = "" if slash < 0 else rest.substr(slash + 1)
	if relative.is_empty():
		return _accept(loop.root)
	var found := loop.root.get_node_or_null(NodePath(relative))
	if found == null:
		_warn_missing("no node exists at that path")
		return null
	return _accept(found)


func _accept(found: Node) -> Node:
	_delegate = found
	_connect_bridges()
	_flush_pending_configure()
	if on_resolved.is_valid():
		on_resolved.call()
	return _delegate


func _resolved_method(method: String) -> String:
	if _resolve() == null:
		return ""
	if _delegate.has_method(method):
		return method
	var pascal := to_pascal_case(method)
	if _delegate.has_method(pascal):
		return pascal
	return ""


## Runs on every resolution rather than once for the lifetime of the bridge. A delegate REPLACED at
## the same path (a hot-reloaded C# autoload, a test's stand-in swapped out) is a different instance,
## and bridging that was done against the old one is silently gone â€” Godot drops a freed node's
## connections for us, so re-running here is the whole repair, with no old-connection cleanup to do.
## [method Object.is_connected] keeps the re-run idempotent when the instance has NOT changed, which
## is also what lets [method bridge] connect a late registration immediately.
func _connect_bridges() -> void:
	if _delegate == null:
		return
	for entry in _bridges:
		var signal_name: String = entry[0]
		var sink: Callable = entry[1]
		var resolved := ""
		if _delegate.has_signal(signal_name):
			resolved = signal_name
		elif _delegate.has_signal(to_pascal_case(signal_name)):
			resolved = to_pascal_case(signal_name)
		if resolved.is_empty():
			# Not a warning: a delegate is free to implement a contract that never fires a given
			# signal (a static roster never changes), and the adapter simply never re-emits.
			continue
		if not _delegate.is_connected(resolved, sink):
			_delegate.connect(resolved, sink)


func _send_configure(params: Dictionary) -> void:
	if _resolve() == null:
		# The delegate may appear later; the params must not be lost in the meantime.
		_pending_configure = params
		return
	_pending_configure = null
	if supports_quiet(CONFIGURE_METHOD):
		forward(CONFIGURE_METHOD, [params])


func _flush_pending_configure() -> void:
	if _pending_configure == null:
		return
	var params: Dictionary = _pending_configure
	_pending_configure = null
	if supports_quiet(CONFIGURE_METHOD):
		forward(CONFIGURE_METHOD, [params])


func _warn_missing(reason: String) -> void:
	if _warned_missing:
		return
	_warned_missing = true
	MKLog.warn("%s: delegate '%s' is unavailable (%s) â€” the adapter degrades like an unassigned slot"
		% [_label, _path, reason])


## The "delegate is live but answers neither spelling" warn-once. Silent when the delegate is not
## resolved at all â€” [method _warn_missing] has already named that fault, and reporting one
## misconfiguration as two unrelated ones is the thing these paths exist to avoid.
func _warn_unsupported(method: String) -> void:
	if _delegate == null:
		return
	if _warned_methods.has(method):
		return
	_warned_methods[method] = true
	MKLog.warn("%s: delegate '%s' implements neither '%s' nor '%s' â€” using the base default"
		% [_label, _path, method, to_pascal_case(method)])


func _warn_type(method: String, raw: Variant, expected: String) -> void:
	if typeof(raw) == TYPE_NIL:
		# Nil is what an unforwarded call returns, and that path has already warned by name. Warning
		# again would report one misconfiguration as two unrelated ones.
		return
	var key := "%s|%s" % [method, expected]
	if _warned_types.has(key):
		return
	_warned_types[key] = true
	MKLog.warn("%s: delegate '%s' returned %s from '%s' where %s was required â€” using the base default"
		% [_label, _path, type_string(typeof(raw)), method, expected])
