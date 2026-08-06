class_name MKJsonSettingsBackend
extends MKSettingsBackend
## The shipped default settings store: one JSON file under [code]user://[/code], applied to the
## engine on [method apply_all] (plan §4.1, §4.2, §4.3).
##
## It is a [i]default[/i], not a requirement. A host with cloud-synced settings replaces the whole
## script through its [MKBackendSlot]; nothing in MenuKit reaches past the [MKSettingsBackend] API.
##
## [b]Persistence hygiene[/b] (plan §4.3). The file carries a [code]version[/code] integer, and a
## file that cannot be parsed — or that parses to something this class does not recognise — is
## renamed aside as [code]<name>.corrupt-<n>.json[/code] and defaults boot, with a warning. Losing a
## settings file is an annoyance; crashing at boot because of one, or silently overwriting it, is
## not. Both failure modes stay recoverable by hand because the bad file is still on disk.
##
## [b]Persisted format.[/b] Every key below is a compatibility surface: per plan §4.8's versioning
## rule, changing one is a Breaking change and says so in the CHANGELOG.
## [codeblock]
## {
##   "version": 1,
##   "values": { "<setting id>": <JSON value or type envelope> },
##   "input":  { "<action name>": [ <event dict>, ... ] }
## }
## [/codeblock]
## [code]values[/code] holds whatever panels wrote through [method set_value]; [code]input[/code]
## holds [b]only[/b] rebound actions, never the stock bindings — those are read back from
## [InputMap] each boot by [method snapshot_input_defaults], so a project changing its own defaults
## does not leave users pinned to the old ones.
##
## Each event dict under [code]input[/code] carries a [code]device[/code] field alongside its
## type-specific keys (see [method _serialize_event] for why omitting it was a bug, and
## [method _deserialize_events] for the read side). [b]An ABSENT [code]device[/code] reads as -1[/b]
## — all devices — so a store written before the field existed keeps working and keeps the meaning a
## local rebind actually has. No [constant FORMAT_VERSION] bump: the field lands pre-0.1.0, so
## nothing shipped can carry a store without it, and adding a key that has a compatible default is
## not a shape change a released reader could trip on. It is still part of the initial format and
## MUST appear in Phase 9's CHANGELOG entry stating that format.
##
## [b]Two type caveats a caller should know, both verified rather than assumed:[/b]
## [br]- JSON has one number type, so an [int] written through [method set_value] reads back as a
##   [float] after a save/load cycle. It compares equal (GDScript's [code]2 == 2.0[/code] is true)
##   but [method @GlobalScope.typeof] reports [constant TYPE_FLOAT]. Application sites in this class
##   coerce with [code]int(...)[/code] explicitly for that reason.
## [br]- [Vector2i] (the resolution row's value type) is not a JSON type, so it is written as a
##   [code]{"__mk_type": "Vector2i", "v": [x, y]}[/code] envelope and decoded back. That envelope is
##   the only extended type THIS backend writes; anything else JSON cannot represent round-trips as
##   whatever [method JSON.stringify] made of it. The envelope itself lives in [MKJsonCodec], which
##   also knows an [code]int[/code] tag that this backend does [b]not[/b] write (see [method _encode]
##   for why) — but does read, because decoding is tolerant of any tag the codec knows.

## Storage location. Overridable per slot via [code]params/file_path[/code] so two configurations —
## a test profile and a real one, say — can coexist without subclassing.
const DEFAULT_FILE_PATH := "user://menukit_settings.json"

## Bumped only when the on-disk shape changes. A file whose version this build does not know is left
## untouched (see [method load]): a newer file is a downgrade, not corruption, and renaming it aside
## would destroy settings the user's other install still needs.
const FORMAT_VERSION := 1

const KEY_VERSION := "version"
const KEY_VALUES := "values"
const KEY_INPUT := "input"
## Re-exported from [MKJsonCodec], which owns the envelope. They stay spelled here because they are
## part of THIS class's documented persisted format (see the class doc's format block) and a reader
## — or a test — looking at the settings file naturally looks for them on the settings backend.
## Aliases rather than copies so the two can never drift into disagreeing about a key name.
const TYPE_TAG := MKJsonCodec.TYPE_TAG
const TYPE_PAYLOAD := MKJsonCodec.TYPE_PAYLOAD

## Reserved value ids [method apply_all] pushes at the engine. Every other id is left alone on
## purpose: FOV, mouse sensitivity and friends are plain values the host consumes (plan §4.3), so an
## unrecognised id is normal operation and must not warn.
const ID_WINDOW_MODE := &"video/window_mode"
const ID_RESOLUTION := &"video/resolution"
const ID_VSYNC := &"video/vsync"
const ID_MAX_FPS := &"video/max_fps"

## Volume ids are [code]audio/bus/<BusName>[/code], value in linear 0..1. The bus name is part of the
## id rather than a fixed list because the addon ships a Master-only page while a host adds buses
## freely (plan §4.3).
const BUS_VOLUME_PREFIX := "audio/bus/"

var _file_path := DEFAULT_FILE_PATH
var _values: Dictionary = {}
var _input_overrides: Dictionary = {}
var _input_defaults: Dictionary = {}
var _input_defaults_captured := false


## Consumes [code]file_path[/code]. Returns the keys it used so [code]MKRoot[/code] can warn by name
## about the ones nothing claimed (plan §4.1).
func _mk_configure(params: Dictionary) -> Array[String]:
	var consumed: Array[String] = []
	if params.has("file_path"):
		consumed.append("file_path")
		var raw: Variant = params["file_path"]
		if raw is String and not (raw as String).is_empty():
			_file_path = raw as String
		else:
			MKLog.warn("%s: params/file_path must be a non-empty String — keeping '%s'"
				% [_context(), _file_path])
	return consumed


## The store's resolved path, for diagnostics (plan §4.8 wants resolved [code]user://[/code] paths in
## a bug report) and for tests that need to inspect or corrupt the file.
func get_file_path() -> String:
	return _file_path


func get_value(id: StringName, default_value: Variant) -> Variant:
	var key := String(id)
	if _values.has(key):
		return _values[key]
	return default_value


## Writes a value and announces it. No disk write: panels change values continuously while a slider
## is dragged, and [method save] is the flush point (plan §4.1).
##
## Unchanged writes are dropped rather than re-emitted, so a listener can rebuild state on
## [signal MKSettingsBackend.setting_changed] without guarding against its own echo.
func set_value(id: StringName, value: Variant) -> void:
	var key := String(id)
	# Same-type check BEFORE ==: comparing an int against an incoming String raises a script error
	# ("Invalid operands in operator '=='"), and a type-changing write is reachable from any
	# hand-edited store. is_same-style typeof gating keeps the dedup without the crash; a changed
	# TYPE is by definition a changed value and falls through to the write.
	if _values.has(key) and typeof(_values[key]) == typeof(value) and _values[key] == value:
		return
	_values[key] = value
	setting_changed.emit(id, value)


## Records the events bound to [param action] as a user override. Phase 4's rebind rows are the
## caller; it lives here because the override set is part of the persisted format and only this class
## knows how to serialise an [InputEvent] for it.
##
## Writing does [b]not[/b] touch the live [InputMap]; call [method apply_all] to push it.
##
## There are exactly two application points, both in this class: [method apply_all] and the restore
## inside [method reset_action_to_default]. Reset needs its own because [method apply_all] walks the
## overrides that EXIST, so an action that just lost one is never revisited — dropping the override
## alone left the engine running the binding the user asked to undo, while the row redrew as default.
func set_action_events(action: StringName, events: Array) -> void:
	var rows: Array = []
	for event in events:
		var row := _serialize_event(event)
		if row.is_empty():
			continue
		rows.append(row)
	_input_overrides[String(action)] = rows


## The user's override for [param action], or its stock bindings when it has none. Returns live
## [InputEvent] instances, so mutating them cannot corrupt the store.
func get_action_events(action: StringName) -> Array[InputEvent]:
	var key := String(action)
	var rows: Array = _input_overrides.get(key, _input_defaults.get(key, []))
	return _deserialize_events(rows)


## The stock bindings captured by [method snapshot_input_defaults] — what "Reset to Defaults" means.
## Empty when no snapshot ran, which is itself the diagnosis for a reset button that does nothing.
func get_default_action_events(action: StringName) -> Array[InputEvent]:
	return _deserialize_events(_input_defaults.get(String(action), []))


## Drops [param action]'s override and restores its stock bindings to the live [InputMap]
## immediately — no [method apply_all] needed, and see [method _restore_default_events] for why it
## cannot wait for one.
func reset_action_to_default(action: StringName) -> void:
	_input_overrides.erase(String(action))
	_restore_default_events(action)


## Drops every override at once — the Controls page's global reset.
func reset_all_actions_to_defaults() -> void:
	var actions := _input_overrides.keys()
	_input_overrides.clear()
	for key in actions:
		_restore_default_events(StringName(key))


## Puts the boot snapshot back into the live [InputMap] for [param action].
##
## Dropping the override from the store is only half a reset: [method _apply_input_overrides] walks
## the overrides that EXIST, so an action that just lost one is never revisited and the live InputMap
## keeps the binding the user asked to undo. Reset then appears to work — the row redraws as default
## — while the key still does the new thing, which is the worst shape this bug could take because the
## recovery path for a user who has nuked their bindings is exactly this method.
func _restore_default_events(action: StringName) -> void:
	if not InputMap.has_action(action):
		return
	if not _input_defaults.has(String(action)):
		# No snapshot: snapshot_input_defaults() was never called, which is a host contract breach
		# (§4.2). Leave the live binding alone rather than erasing it into nothing.
		MKLog.warn("%s: no boot snapshot for action '%s' — call snapshot_input_defaults() before load()"
			% [_context(), action])
		return
	_write_action_to_input_map(action, _input_defaults[String(action)])


## The ONE erase-then-re-add implementation in this class. Three callers reach it — the boot sweep
## ([method _apply_input_overrides]), the reset restore ([method _restore_default_events]) and the
## targeted [method apply_action] — and each of them is a full replacement of an action's event list,
## never an addition: [method InputMap.action_add_event] appends, so re-adding without the erase
## leaves the OLD key still bound alongside the new one and the rebound action fires on both.
##
## It deliberately does [b]no[/b] [method InputMap.has_action] check and issues no warning. The three
## callers disagree about what an absent action means — the boot sweep names it (a stored rebind for
## an action the project dropped is worth reporting once), the reset restore stays silent (there is
## nothing the user did wrong) — and folding those into one policy here would change two shipped
## behaviours to unify a two-line loop. Callers verify the action first.
func _write_action_to_input_map(action: StringName, rows: Variant) -> void:
	InputMap.action_erase_events(action)
	for event in _deserialize_events(rows):
		InputMap.action_add_event(action, event)


## True when [param action] carries a user override, so a UI can mark a changed row.
func has_action_override(action: StringName) -> bool:
	return _input_overrides.has(String(action))


## Reads the store, replacing whatever is in memory.
##
## Three outcomes, deliberately different (plan §4.3):
## [br]- No file: defaults boot, silently. A first run is not a problem.
## [br]- Unparseable, or a shape this class does not recognise: the file is renamed aside and
##   defaults boot, with a warning naming the new path. Never a crash, never an overwrite of data
##   that might be hand-recoverable.
## [br]- A [code]version[/code] newer than [constant FORMAT_VERSION]: defaults boot with a warning
##   and the file is left [b]exactly where it is[/b]. That is a downgraded install, not corruption;
##   renaming it would destroy the settings the newer install still reads. The consequence is
##   accepted openly: a subsequent [method save] from this build overwrites it.
func load() -> void:
	_values.clear()
	_input_overrides.clear()

	if not FileAccess.file_exists(_file_path):
		MKLog.debug("no settings file at %s — booting defaults" % _file_path)
		return

	var file := FileAccess.open(_file_path, FileAccess.READ)
	if file == null:
		# Unreadable is not unparseable: the bytes may be perfectly good and the problem a lock or a
		# permission. Renaming would be the wrong move, so this path only reports.
		MKLog.warn("%s: cannot open %s for reading (error %d) — booting defaults"
			% [_context(), _file_path, FileAccess.get_open_error()])
		return
	var text := file.get_as_text()
	file.close()

	# JSON.new().parse(), not the static JSON.parse_string(). The static pushes its own engine
	# "Parse JSON failed" ERROR line before returning null — on a path this backend fully handles by
	# quarantining and booting defaults. That error is indistinguishable in a log from a real one, and
	# the verification gate fails any test whose output carries an ERROR line, so a correctly handled
	# corrupt file would have failed the suite. The instance method reports through its return value
	# instead, which is what a handled path should do.
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		_quarantine("not valid JSON, or not a JSON object (line %d: %s)"
			% [json.get_error_line(), json.get_error_message()])
		return
	var parsed: Variant = json.data

	var data := parsed as Dictionary
	if not data.has(KEY_VERSION) or not _is_number(data[KEY_VERSION]):
		_quarantine("missing or non-numeric '%s'" % KEY_VERSION)
		return
	var version := int(data[KEY_VERSION])
	if version > FORMAT_VERSION:
		MKLog.warn("%s: %s was written by a newer MenuKit (format %d, this build reads %d) — booting defaults and leaving the file untouched"
			% [_context(), _file_path, version, FORMAT_VERSION])
		return

	var raw_values: Variant = data.get(KEY_VALUES, {})
	if raw_values is Dictionary:
		for key in (raw_values as Dictionary).keys():
			_values[String(key)] = _decode(raw_values[key])
	else:
		MKLog.warn("%s: '%s' in %s is not an object — ignoring stored values"
			% [_context(), KEY_VALUES, _file_path])

	var raw_input: Variant = data.get(KEY_INPUT, {})
	if raw_input is Dictionary:
		for key in (raw_input as Dictionary).keys():
			var rows: Variant = raw_input[key]
			if rows is Array:
				_input_overrides[String(key)] = rows
			else:
				MKLog.warn("%s: input override for action '%s' in %s is not an array — ignoring it"
					% [_context(), key, _file_path])
	else:
		MKLog.warn("%s: '%s' in %s is not an object — ignoring stored rebinds"
			% [_context(), KEY_INPUT, _file_path])


## Flushes to disk.
##
## Written to a sibling [code].tmp[/code] and renamed over the target, so an interrupted write leaves
## the previous good file intact rather than a truncated one — the very corruption [method load] then
## has to quarantine.
func save() -> void:
	var encoded_values := {}
	for key in _values.keys():
		encoded_values[key] = _encode(_values[key])

	var payload := {
		KEY_VERSION: FORMAT_VERSION,
		KEY_VALUES: encoded_values,
		KEY_INPUT: _input_overrides,
	}

	var dir := _file_path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(dir)

	var tmp_path := _file_path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		MKLog.warn("%s: cannot write %s (error %d) — settings not saved"
			% [_context(), tmp_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

	var err := DirAccess.rename_absolute(tmp_path, _file_path)
	if err != OK:
		MKLog.warn("%s: could not move %s onto %s (error %d) — settings not saved"
			% [_context(), tmp_path, _file_path, err])
		return
	MKLog.debug("saved settings to %s" % _file_path)


## Captures the stock [InputMap] as the source of truth for "Reset to Defaults".
##
## [b]Must run before [method load] and [method apply_all].[/b] Run after, it captures the user's own
## overrides as the defaults and the reset button silently becomes a no-op — a failure with no error
## and no wrong value to notice. [code]MKSettingsService[/code] enforces the order; a host taking the
## documented no-autoload path (plan §4.2) makes the same three calls itself.
##
## Repeat calls are ignored rather than re-capturing, so a second [code]MKRoot[/code] entering the
## tree after rebinds cannot overwrite the snapshot with the overridden state. That guards the
## repeat, not the first call: if the very first snapshot happens after overrides are live, this
## class cannot tell and the defaults it holds are wrong.
func snapshot_input_defaults() -> void:
	if _input_defaults_captured:
		MKLog.debug("input defaults already captured (%d actions) — ignoring repeat snapshot"
			% _input_defaults.size())
		return
	_input_defaults_captured = true
	_input_defaults.clear()
	for action in InputMap.get_actions():
		var rows: Array = []
		for event in InputMap.action_get_events(action):
			var row := _serialize_event(event)
			if row.is_empty():
				continue
			rows.append(row)
		_input_defaults[String(action)] = rows
	MKLog.debug("captured stock bindings for %d actions" % _input_defaults.size())


## Pushes every stored value at the engine: window mode, resolution, vsync, max FPS, bus volumes and
## [InputMap] overrides.
##
## Display calls are skipped entirely under the headless display driver, where [DisplayServer] is a
## dummy — they are not merely useless there, and the test suite runs headless (plan §4.8). Audio and
## [InputMap] application still run headless because both are real there.
func apply_all() -> void:
	_apply_display()
	_apply_audio()
	_apply_input_overrides()


## True when no real display exists, so window calls are pointless. Named rather than inlined because
## three call sites need the same answer and a wrong guard here is invisible until someone runs the
## build with a window.
func is_headless_display() -> bool:
	return DisplayServer.get_name() == "headless"


## Pushes exactly ONE stored value at the engine — the instant-apply path a settings panel uses on
## every change (plan §4.3, D14).
##
## This does not re-implement anything: it dispatches to the same per-id helpers [method apply_all]
## walks, so there is one place that knows what "window mode 2" does. Two copies of that knowledge is
## how apply-on-change and apply-at-boot drift into disagreeing, which surfaces as "the setting only
## takes effect after a restart".
##
## Unrecognised ids are a silent no-op on purpose: plain values (FOV, mouse sensitivity) are the
## majority and are the host's to consume off [signal MKSettingsBackend.setting_changed], so warning
## on them would make correct usage noisy.
func apply_one(id: StringName) -> void:
	match id:
		ID_MAX_FPS:
			_apply_max_fps()
		ID_VSYNC:
			_apply_vsync()
		ID_WINDOW_MODE:
			_apply_window_mode()
		ID_RESOLUTION:
			_apply_resolution()
		_:
			var name := String(id)
			if name.begins_with(BUS_VOLUME_PREFIX):
				_apply_bus(name)


## Pushes exactly ONE action's binding at the live [InputMap] — the instant-apply path a rebind row
## uses after every commit (plan §4.4).
##
## Targeted rather than the base class's [method MKSettingsBackend.apply_all] delegation: rebinding
## seven movement keys in a row would otherwise re-push the window mode, the resolution and every bus
## volume seven times, and on a windowed build the resolution re-push is a visible flicker for a key
## change that has nothing to do with the display.
##
## [b]Both directions are applied, and the "no override" branch is the load-bearing one.[/b] A row's
## Reset (and the page's global Reset All) DROPS the action's override rather than storing a new one,
## so an implementation that only walked [member _input_overrides] would leave the live [InputMap]
## running the binding the user just asked to undo while the row redrew as default — the exact
## failure [method _restore_default_events] documents, reintroduced at a second call site. So: an
## override applies the override, and its absence re-applies the boot snapshot.
##
## Runs unconditionally, headless included, like every other input application in this class
## (see [method apply_all]): [InputMap] is real under the headless driver, unlike [DisplayServer].
##
## An action this project does not define is warned about and the live map is left ALONE — the same
## warn-and-keep behaviour [method _apply_input_overrides] has, for the same reason: erasing an
## action MenuKit cannot name is a worse outcome than a log line.
func apply_action(action: StringName) -> void:
	var key := String(action)
	if not InputMap.has_action(action):
		MKLog.warn("%s: stored rebind names action '%s', which this project does not define"
			% [_context(), action])
		return
	if _input_overrides.has(key):
		_write_action_to_input_map(action, _input_overrides[key])
		return
	if not _input_defaults.has(key):
		# No snapshot for this action: snapshot_input_defaults() never ran, or ran before the action
		# existed. Same policy as _restore_default_events — leave the live binding alone rather than
		# erasing it into nothing, and name the host contract (§4.2) that was breached.
		MKLog.warn("%s: no boot snapshot for action '%s' — call snapshot_input_defaults() before load()"
			% [_context(), action])
		return
	_write_action_to_input_map(action, _input_defaults[key])


func _apply_display() -> void:
	_apply_max_fps()

	if is_headless_display():
		if _values.has(String(ID_WINDOW_MODE)) or _values.has(String(ID_RESOLUTION)) \
				or _values.has(String(ID_VSYNC)):
			MKLog.debug("headless display driver — skipping window mode, resolution and vsync")
		return

	_apply_vsync()
	_apply_window_mode()
	_apply_resolution()


## [member Engine.max_fps] is not a [DisplayServer] call and is meaningful headless, so it sits
## outside the headless guard every other display helper carries.
func _apply_max_fps() -> void:
	if not _values.has(String(ID_MAX_FPS)):
		return
	Engine.max_fps = int(_values[String(ID_MAX_FPS)])


## Each display helper re-checks [method is_headless_display] itself rather than trusting its caller.
## [method apply_all] guards them as a group, but [method apply_one] reaches them individually — and a
## guard that only exists at one of two entry points is the shape of bug that passes every test run
## with a window and fails the headless suite.
func _apply_vsync() -> void:
	if is_headless_display() or not _values.has(String(ID_VSYNC)):
		return
	DisplayServer.window_set_vsync_mode(int(_values[String(ID_VSYNC)]) as DisplayServer.VSyncMode)


func _apply_window_mode() -> void:
	if is_headless_display() or not _values.has(String(ID_WINDOW_MODE)):
		return
	DisplayServer.window_set_mode(int(_values[String(ID_WINDOW_MODE)]) as DisplayServer.WindowMode)


func _apply_resolution() -> void:
	if is_headless_display() or not _values.has(String(ID_RESOLUTION)):
		return
	var size := _as_vector2i(_values[String(ID_RESOLUTION)])
	if size.x <= 0 or size.y <= 0:
		MKLog.warn("%s: '%s' is %s, which is not a usable window size — ignoring it"
			% [_context(), ID_RESOLUTION, _values[String(ID_RESOLUTION)]])
	elif DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		# window_set_size is a no-op in fullscreen and borderless (plan §4.3), so applying it
		# there would look like it worked and change nothing.
		MKLog.debug("window is not in windowed mode — skipping resolution %s" % size)
	else:
		DisplayServer.window_set_size(size)


func _apply_audio() -> void:
	for key in _values.keys():
		var name := String(key)
		if not name.begins_with(BUS_VOLUME_PREFIX):
			continue
		_apply_bus(name)


## Applies one [code]audio/bus/<BusName>[/code] value. [param name] is the full id; the bus name is
## its suffix, because the addon ships a Master-only page while a host adds buses freely (plan §4.3)
## and a fixed list would make that a code change.
func _apply_bus(name: String) -> void:
	if not _values.has(name):
		return
	var bus := name.substr(BUS_VOLUME_PREFIX.length())
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		# Named, not silent: a volume slider that moves nothing is otherwise diagnosed by
		# reading source (plan §4.3, §4.8).
		MKLog.warn("%s: no audio bus named '%s' — '%s' applies to nothing"
			% [_context(), bus, name])
		return
	var linear := float(_values[name])
	AudioServer.set_bus_volume_db(index, linear_to_db(clampf(linear, 0.0, 1.0)))
	# linear_to_db(0) is -inf, which Godot accepts but which leaves the bus doing pointless work;
	# the explicit mute is also what a "is it off?" check reads.
	AudioServer.set_bus_mute(index, linear <= 0.0)


func _apply_input_overrides() -> void:
	for key in _input_overrides.keys():
		var action := StringName(key)
		if not InputMap.has_action(action):
			# An action the project no longer defines. Recoverable: the override is kept in the store
			# so renaming an action back restores the user's binding rather than losing it.
			MKLog.warn("%s: stored rebind names action '%s', which this project does not define"
				% [_context(), action])
			continue
		_write_action_to_input_map(action, _input_overrides[key])


## Renames the unreadable file aside and warns. Picks the first free [code]<n>[/code] rather than
## overwriting, so a repeatedly corrupting install leaves every sample for diagnosis instead of one.
func _quarantine(reason: String) -> void:
	var base := _file_path.trim_suffix(".json")
	var target := ""
	for n in range(1, 1000):
		var candidate := "%s.corrupt-%d.json" % [base, n]
		if not FileAccess.file_exists(candidate):
			target = candidate
			break
	if target.is_empty():
		MKLog.warn("%s: %s is unreadable (%s) and 999 quarantine slots are taken — booting defaults and leaving it in place"
			% [_context(), _file_path, reason])
		return
	var err := DirAccess.rename_absolute(_file_path, target)
	if err != OK:
		MKLog.warn("%s: %s is unreadable (%s) and could not be moved aside (error %d) — booting defaults"
			% [_context(), _file_path, reason, err])
		return
	MKLog.warn("%s: %s is unreadable (%s) — moved to %s and booting defaults"
		% [_context(), _file_path, reason, target])


## Wraps the types JSON cannot carry. Recurses through containers because a page def's stored value
## can be an array of resolutions.
##
## [b]The logic moved to [MKJsonCodec][/b] when [MKJsonProfileBackend] needed the same envelope;
## these two methods stay as thin shims so this class's call sites and the doc references to them
## keep working, and so the file-path-carrying warning context is still supplied from here.
##
## [code]envelope_ints[/code] is [b]false[/b] here, and deliberately so: this backend's persisted
## format predates the int envelope and every application site in this class already coerces with an
## explicit [code]int(...)[/code] (window mode, vsync, max FPS, resolution components). Enveloping
## its ints would change the bytes of a format already shipped in this repo for no behavioural gain.
## The profile backend passes true because its payloads are opaque host data it cannot coerce at the
## read site — see [MKJsonCodec] for the full argument.
func _encode(value: Variant) -> Variant:
	return MKJsonCodec.encode_value(value, false)


## Decoding is tolerant of every tag the codec knows regardless of the flag above: the bytes on disk
## are the authority, not what this backend happens to write.
func _decode(value: Variant) -> Variant:
	return MKJsonCodec.decode_value(value, _file_path)


## Accepts either a live [Vector2i] or the two-element form a decoded envelope can degrade to, so a
## hand-edited file writing [code][1280, 720][/code] still works rather than failing opaquely.
func _as_vector2i(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	if value is Vector2:
		return Vector2i(value as Vector2)
	if value is Array and (value as Array).size() == 2:
		return Vector2i(int((value as Array)[0]), int((value as Array)[1]))
	return Vector2i.ZERO


## Keyboard events are keyed by [b]physical[/b] keycode, a persisted-format decision (plan §4.4): a
## binding stored by keycode moves under the user's fingers when they switch to an AZERTY layout,
## which is exactly what physical keycodes exist to prevent. [code]keycode[/code] is stored alongside
## only as the fallback for synthetic events whose physical code is 0.
##
## [b][code]device[/code] is carried for EVERY event kind, and dropping it was a real bug.[/b]
## [method InputMap.event_is_action] matching is device-aware: an action event whose device is 0
## does not answer a press delivered by joypad 1, and [code]project.godot[/code]-authored entries
## carry -1 (ALL devices) for exactly that reason. (The engine's own builtin [code]ui_*[/code]
## defaults are the exception: their key/mouse events ship device 16/32, a device-CLASS namespacing —
## a faithful snapshot reproduces those values, and that is correctness, not corruption.)
## Round-tripping an event through this pair without the field
## therefore narrowed a binding to whatever [method InputEvent.device] defaulted to — and the class
## defaults are NOT -1 (measured on 4.7: [InputEventJoypadButton] 0, [InputEventKey] 16,
## [InputEventMouseButton] 32). Both the boot snapshot and the user overrides pass through here, so
## the narrowing hit a plain Reset as well as a rebind: [method apply_action]'s no-override branch
## re-writes the snapshot, which is how a stock all-devices binding silently became device-0-only.
##
## Returns an empty [Dictionary] for event types this format cannot carry; callers skip those rows.
func _serialize_event(event: Variant) -> Dictionary:
	if event is InputEventKey:
		var key := event as InputEventKey
		return {
			"type": "key",
			"physical_keycode": int(key.physical_keycode),
			"keycode": int(key.keycode),
			"alt": key.alt_pressed,
			"shift": key.shift_pressed,
			"ctrl": key.ctrl_pressed,
			"meta": key.meta_pressed,
			"device": int(key.device),
		}
	if event is InputEventMouseButton:
		return {
			"type": "mouse_button",
			"button_index": int((event as InputEventMouseButton).button_index),
			"device": int((event as InputEventMouseButton).device),
		}
	if event is InputEventJoypadButton:
		return {
			"type": "joypad_button",
			"button_index": int((event as InputEventJoypadButton).button_index),
			"device": int((event as InputEventJoypadButton).device),
		}
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return {
			"type": "joypad_motion",
			"axis": int(motion.axis),
			"axis_value": float(motion.axis_value),
			"device": int(motion.device),
		}
	if event is InputEvent:
		MKLog.warn("%s: cannot persist a %s binding — this format carries key, mouse button, joypad button and joypad motion only"
			% [_context(), (event as InputEvent).get_class()])
	return {}


## The inverse of [method _serialize_event].
##
## [b][code]device[/code] defaults to -1 when the key is absent, and the default is the compatible
## one.[/b] -1 means ALL devices, which is both what [code]project.godot[/code] authors for stock
## bindings and the correct meaning for a local rebind (see [method _serialize_event]). A store file
## written before the field existed therefore reads back as an all-devices binding rather than
## inheriting the engine's per-class default, which for a pad button would have pinned it to
## controller 0.
func _deserialize_events(rows: Variant) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if not (rows is Array):
		return out
	for row in rows as Array:
		if not (row is Dictionary):
			continue
		var d := row as Dictionary
		match String(d.get("type", "")):
			"key":
				var key := InputEventKey.new()
				key.physical_keycode = int(d.get("physical_keycode", 0)) as Key
				key.keycode = int(d.get("keycode", 0)) as Key
				key.alt_pressed = bool(d.get("alt", false))
				key.shift_pressed = bool(d.get("shift", false))
				key.ctrl_pressed = bool(d.get("ctrl", false))
				key.meta_pressed = bool(d.get("meta", false))
				key.device = int(d.get("device", -1))
				out.append(key)
			"mouse_button":
				var mb := InputEventMouseButton.new()
				mb.button_index = int(d.get("button_index", 0)) as MouseButton
				mb.device = int(d.get("device", -1))
				out.append(mb)
			"joypad_button":
				var jb := InputEventJoypadButton.new()
				jb.button_index = int(d.get("button_index", 0)) as JoyButton
				jb.device = int(d.get("device", -1))
				out.append(jb)
			"joypad_motion":
				var jm := InputEventJoypadMotion.new()
				jm.axis = int(d.get("axis", 0)) as JoyAxis
				jm.axis_value = float(d.get("axis_value", 0.0))
				jm.device = int(d.get("device", -1))
				out.append(jm)
			_:
				MKLog.warn("%s: stored binding has unknown type '%s' — skipping it"
					% [_context(), d.get("type", "")])
	return out


func _is_number(value: Variant) -> bool:
	return value is int or value is float


## This backend is instantiated from a Script, not loaded from a [code].tres[/code], so
## [method MKLog.context] has no resource path to name. The script path is the identifying thing a
## reader needs.
func _context() -> String:
	var script := get_script() as Script
	if script != null and not script.resource_path.is_empty():
		return MKLog.context(script.resource_path)
	return MKLog.context("MKJsonSettingsBackend")
