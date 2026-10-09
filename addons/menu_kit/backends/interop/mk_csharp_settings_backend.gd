class_name MKCSharpSettingsBackend
extends MKSettingsBackend
## An [MKSettingsBackend] whose store and engine application live in a C# node.
##
## The C# node implements [code]GetValue(StringName, Variant)[/code],
## [code]SetValue(StringName, Variant)[/code], [code]Save()[/code], [code]Load()[/code],
## [code]ApplyAll()[/code], [code]SnapshotInputDefaults()[/code], and optionally
## [code]ApplyOne[/code], [code]ApplyAction[/code], the six input-store methods, and
## [code]MkConfigure(Dictionary)[/code].
##
## [b]Bridged signal:[/b] [signal MKSettingsBackend.setting_changed], arity 2
## [code](id: StringName, value: Variant)[/code]. A C# signal declared with a [code]string[/code]
## first parameter is fine — the adapter re-emits it as a [StringName].
##
## [b]Still exactly one instance per project[/b] (the base's rule): two adapters over one C# store
## desync the D14 revert countdown the same way two GDScript backends do. The
## [code]MKSettingsService[/code] autoload's slot is the place to configure it.
##
## [b]Autoload ORDER caveat.[/b] [code]MKSettingsService[/code] makes its boot triad —
## [method MKSettingsBackend.snapshot_input_defaults], [method MKSettingsBackend.load],
## [method MKSettingsBackend.apply_all] — synchronously in its own [method Node._ready]. Register
## your C# delegate autoload [b]ABOVE[/b] [code]MKSettingsService[/code] in Project Settings so it
## exists when that runs. Below it, all three forward into an unresolved delegate; this adapter then
## self-heals by replaying the triad, in order, on the first resolution that succeeds, and refuses to
## [method save] until its [method load] has actually reached the delegate (a save of a
## never-loaded store overwrites the player's file with C#-side defaults). The replay is a safety
## net for a misordered project, not a substitute for the order — correct order is the supported
## configuration, and it is the only one where the triad runs at the moment the service intends.
##
## Every input-store method the delegate omits keeps the base's inert answer, so a store-only C#
## backend degrades to "Unbound" rows with disabled Resets rather than to wrong bindings.

var _bridge := MKCSharpDelegate.new("MKCSharpSettingsBackend")
## The boot triad, held in CALL order while the delegate is unresolved and replayed in that order on
## the first resolution that finds it. Deduped, and deliberately not a general call queue: these
## three are the once-per-boot calls whose loss is unrecoverable (defaults never snapshotted, the
## player's file never read, nothing applied), where a replayed [method set_value] would be a
## re-write of a value the panel has since changed.
var _pending_boot: Array[String] = []
## The delegate INSTANCE whose store [method load] actually reached. [method save] refuses unless it
## is still the CURRENT instance — a bool would survive a delegate replaced at the same path (a dev
## hot-reload swap), and the replacement's store was never loaded, which is exactly the
## data-destroying save this guard exists to refuse.
var _loaded_delegate: Node = null
var _warned_save_before_load := false


func _init() -> void:
	_bridge.bridge("setting_changed", _on_delegate_setting_changed)
	_bridge.on_resolved = _flush_pending_boot


func _mk_configure(params: Dictionary) -> Array[String]:
	return _bridge.configure(params)


func _ready() -> void:
	_bridge.ensure_resolved()


## The delegate's answer verbatim — the base declares a Variant return, so no coercion applies. A
## delegate that cannot answer leaves [param default_value] standing, which is what a store with no
## entry for the id would have returned anyway.
func get_value(id: StringName, default_value: Variant) -> Variant:
	if not _bridge.supports("get_value"):
		return default_value
	return _bridge.forward("get_value", [id, default_value])


func set_value(id: StringName, value: Variant) -> void:
	_bridge.forward("set_value", [id, value])


## Refuses while the store was never loaded. This is the data-destroying case the whole pending-boot
## mechanism exists for: a [method load] lost to autoload order leaves the delegate holding its C#
## -side defaults, and a [method save] of those — the service flushes one in [method Node._exit_tree]
## — writes them over the player's real file.
func save() -> void:
	if _loaded_delegate == null or _loaded_delegate != _bridge.get_delegate():
		if not _warned_save_before_load:
			_warned_save_before_load = true
			MKLog.warn(("MKCSharpSettingsBackend: refusing to save() — load() never reached delegate '%s', "
				+ "so this would write never-loaded defaults over the player's stored settings")
				% _bridge.get_delegate_path())
		return
	_bridge.forward("save")


func load() -> void:
	_forward_boot("load")


func apply_all() -> void:
	_forward_boot("apply_all")


func snapshot_input_defaults() -> void:
	_forward_boot("snapshot_input_defaults")


## One boot-triad call: recorded first, then flushed whole if the delegate is reachable. Recording
## before the resolve attempt is what keeps the ORDER right — the flush replays the queue in the
## sequence the service called it, with this call last, rather than delivering this one ahead of the
## two that were held. A resolution that happens on some OTHER call entirely flushes the same queue
## through [member MKCSharpDelegate.on_resolved], so the triad is not waiting on a fourth boot call
## that never comes.
func _forward_boot(method: String) -> void:
	if not _pending_boot.has(method):
		_pending_boot.append(method)
	if _bridge.ensure_resolved():
		_flush_pending_boot()
		return
	# Unresolved: takes the warn-once unavailable path without delivering. The queue keeps the call.
	_bridge.forward(method)


func _flush_pending_boot() -> void:
	if _pending_boot.is_empty():
		return
	var queued := _pending_boot
	_pending_boot = []
	for method in queued:
		_bridge.forward(method)
		if method == "load" and _bridge.was_delivered():
			_loaded_delegate = _bridge.get_delegate()


func apply_one(id: StringName) -> void:
	if _bridge.supports_quiet("apply_one"):
		_bridge.forward("apply_one", [id])
		return
	super.apply_one(id)


func apply_action(action: StringName) -> void:
	if _bridge.supports_quiet("apply_action"):
		_bridge.forward("apply_action", [action])
		return
	super.apply_action(action)


func get_action_events(action: StringName) -> Array[InputEvent]:
	if _bridge.supports_quiet("get_action_events"):
		return _bridge.to_event_array(
			"get_action_events", _bridge.forward("get_action_events", [action]))
	return super.get_action_events(action)


func set_action_events(action: StringName, events: Array) -> void:
	if _bridge.supports_quiet("set_action_events"):
		_bridge.forward("set_action_events", [action, events])
		return
	super.set_action_events(action, events)


func get_default_action_events(action: StringName) -> Array[InputEvent]:
	if _bridge.supports_quiet("get_default_action_events"):
		return _bridge.to_event_array(
			"get_default_action_events", _bridge.forward("get_default_action_events", [action]))
	return super.get_default_action_events(action)


func reset_action_to_default(action: StringName) -> void:
	if _bridge.supports_quiet("reset_action_to_default"):
		_bridge.forward("reset_action_to_default", [action])
		return
	super.reset_action_to_default(action)


func reset_all_actions_to_defaults() -> void:
	if _bridge.supports_quiet("reset_all_actions_to_defaults"):
		_bridge.forward("reset_all_actions_to_defaults")
		return
	super.reset_all_actions_to_defaults()


func has_action_override(action: StringName) -> bool:
	if _bridge.supports_quiet("has_action_override"):
		return _bridge.to_bool(
			"has_action_override", _bridge.forward("has_action_override", [action]), false)
	return super.has_action_override(action)


func get_delegate() -> Node:
	return _bridge.get_delegate()


func _on_delegate_setting_changed(id: Variant, value: Variant) -> void:
	# Through String() rather than StringName() directly: converting a non-string Variant straight to
	# StringName is an error, and a delegate emitting the wrong id type must not crash the panel.
	setting_changed.emit(StringName(String(id)), value)
