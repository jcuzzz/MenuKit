extends MKTest
## The creation flow engine: key ownership, merge order, navigation and the refusal path
## (plan §4.5, findings F8/D17).
##
## [b]Every case builds its own steps.[/b] The rules under test are statements about an ARBITRARY
## ordered set — two steps claiming one key, a skip that must not commit, an archetype default whose
## key a step owns — and none of them is reachable from the three steps the addon ships, because no
## pair of them collides. So the flow is driven through [MKProbeCreationStep] scenes packed in
## memory, which is the same relationship [code]tests/probes/[/code] already has with the settings
## panel's custom rows.
##
## [b]Navigation is driven through the host's REAL buttons[/b] (focus + a pushed ui_accept, the
## test_rebind [code]_activate[/code] idiom), never by calling [code]_advance[/code]: the gating IS
## the behaviour — a disabled Next that nothing can press is the whole of the null-backend and
## invalid-step contracts, and calling the private mover would pass against a host that never
## disabled anything. The mouse route to the same signal is dead under the dummy display driver
## (verified in test_rebind), so keyboard activation is the honest gesture here.
##
## [b]Headless boundary.[/b] Everything asserted is payload content, step counts, button state and
## logged messages. Nothing here depends on layout or on a pixel.

## The one deliberate error this suite provokes: the duplicate-owned-key contract violation, which is
## an MKLog.error by design (the class doc explains why it is not a precedence rule). Declared with
## the narrowest substring that identifies it.
const DUP_KEY_NOISE := "is already owned by step"
const F8_NOISE := "owns that key"

var _log: Array[String] = []
var _errors: Array[String] = []


func run_tests() -> void:
	expect_engine_error(DUP_KEY_NOISE)
	expect_engine_error(F8_NOISE)
	await _test_duplicate_owned_key_drops_the_later_step()
	await _test_f8_archetype_collision_is_reported_once_and_never_seeded()
	await _test_merge_order_defaults_first_steps_win()
	await _test_switching_archetype_clears_only_its_own_seeds()
	await _test_refusal_stays_on_the_last_step_and_says_so()
	await _test_skip_never_commits_and_a_skipped_last_step_still_confirms()
	await _test_back_keeps_committed_keys_and_a_recommit_overwrites()
	await _test_a_pointbuy_shaped_step_with_no_schema_is_dropped_quietly()
	await _test_a_null_backend_warns_once_and_disables_navigation()
	await _test_the_confirmed_payload_reaches_create_profile_verbatim()


# --- Ownership ----------------------------------------------------------------

## Two ENABLED steps claiming one payload key is a contract violation, and the LATER one is dropped
## whole. Three consequences, all asserted: the error names both defs and the key, the dropped step
## never bound (so none of its wiring ran), and the flow the player walks is one step shorter.
func _test_duplicate_owned_key_drops_the_later_step() -> void:
	var backend := _spy_backend()
	MKProbeCreationStep.reset()
	_watch_log()
	var host := await _make_host([
		_step(&"first", ["name"], {"name": "A"}),
		_step(&"second", ["name"], {"name": "B"}),
	], [], backend, null)
	var messages := _stop_watching()

	check_eq(_count_containing(_errors, DUP_KEY_NOISE), 1,
		"the collision is reported exactly ONCE, at configure — a check deferred to 'when you reach step 2' fires in front of the player instead of the author")
	var joined := "\n".join(_errors)
	check(joined.contains("'name'"), "the message names the contested KEY")
	check(joined.contains("first") and joined.contains("second"),
		"and BOTH step ids — an error naming one of them cannot be acted on")
	check_eq(_count_containing(messages, DUP_KEY_NOISE), 1,
		"and nothing repeated it at another level")

	check_eq(host.get_step_count(), 1,
		"the LATER step is dropped from the flow — a partially admitted step would commit less than it displays")
	check_eq(MKProbeCreationStep.binds, 1, "and its bind never ran")
	check_eq(MKProbeCreationStep.bound_ids, ["first"] as Array[String],
		"specifically: the EARLIER step is the one that survived, because the array is the author's order")

	await _drop(host, backend)


## Finding F8: an archetype default whose key a step owns is refused and named ONCE, at configure.
## Re-selecting that archetype must not re-raise it — the player's mouse would otherwise drive a log
## flood off one authoring mistake — and the default must never be seeded.
func _test_f8_archetype_collision_is_reported_once_and_never_seeded() -> void:
	var backend := _spy_backend()
	var arch := _archetype(&"knight", {"name": "Sir Default", "gold": 50})
	MKProbeCreationStep.reset()
	_watch_log()
	var host := await _make_host([_step(&"name", ["name"], {"name": "Typed"})], [arch], backend, null)
	var at_configure := _stop_watching()

	check_eq(_count_containing(_errors, F8_NOISE), 1,
		"the collision is reported once at configure")
	var joined := "\n".join(_errors)
	check(joined.contains("knight") and joined.contains("'name'"),
		"naming the archetype and the key — 'an archetype default was ignored' with neither cannot be acted on")
	check_eq(_count_containing(at_configure, F8_NOISE), 1, "and only once across every level")

	_watch_log()
	host.notify_archetype_chosen(arch)
	var first_choice := _stop_watching()
	# Counted over the CHOICE's own observation window (the watch reset the buffer), so this asserts
	# "no error while choosing" rather than re-counting the configure-time one.
	check_eq(_count_containing(_errors, F8_NOISE), 0,
		"choosing the archetype does NOT re-raise the error — the loud line stays where it can be acted on")
	check_eq(_count_containing(first_choice, "already reported"), 1,
		"the skip is restated at debug level instead, once per collision")

	var payload := host.get_payload()
	check(not payload.has("name"),
		"and the colliding default was never seeded — the step's commit is the only author of that key")
	check_eq(payload.get("gold", null), 50,
		"while the archetype's OTHER default seeded normally: the refusal is per-key, not per-archetype")

	# Re-selecting the SAME archetype is a cheap no-op, so nothing is logged a second time either.
	_watch_log()
	host.notify_archetype_chosen(arch)
	check_eq(_count_containing(_stop_watching(), "already reported"), 0,
		"re-choosing the archetype already seeded logs nothing at all")

	await _drop(host, backend)


## The documented merge order: defaults are a starting point, the player's own choices win. Asserted
## at the END of the flow — what create_profile receives is the only place the order has consequences.
func _test_merge_order_defaults_first_steps_win() -> void:
	var backend := _spy_backend()
	var arch := _archetype(&"scout", {"kit": "bow", "gold": 25})
	MKProbeCreationStep.reset()
	var host := await _make_host([_step(&"name", ["name"], {"name": "Typed"})], [arch], backend, null)

	host.notify_archetype_chosen(arch)
	check_eq(host.get_payload().get("kit", ""), "bow", "precondition: the unowned default seeded")

	await _confirm(host)
	check_eq(backend.created.size(), 1, "Confirm reached the backend")
	if backend.created.size() == 1:
		var sent: Dictionary = backend.created[0]
		check_eq(sent.get("kit", ""), "bow",
			"an unowned archetype default survives to create_profile verbatim")
		check_eq(sent.get("gold", null), 25, "including a numeric one")
		check_eq(sent.get("name", ""), "Typed",
			"and the owned key carries the STEP's value, which is the whole of the merge order")

	await _drop(host, backend)


## Changing your mind about the class must not take your typed name with it: the host clears exactly
## the keys the previous choice seeded and nothing else.
func _test_switching_archetype_clears_only_its_own_seeds() -> void:
	var backend := _spy_backend()
	var a := _archetype(&"a", {"kit": "bow", "a_only": 1})
	var b := _archetype(&"b", {"kit": "staff"})
	MKProbeCreationStep.reset()
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Typed"}),
		_step(&"tail", [], {}),
	], [a, b], backend, null)

	host.notify_archetype_chosen(a)
	# Commit the name step by advancing, so the payload carries a step write as well as the seeds.
	await _press(host._next_button)
	check_eq(host.get_payload().get("name", ""), "Typed", "precondition: the name step committed")
	check_eq(host.get_payload().get("a_only", null), 1, "precondition: A's defaults are seeded")

	host.notify_archetype_chosen(b)
	var payload := host.get_payload()
	check(not payload.has("a_only"),
		"switching archetype erases the keys the PREVIOUS choice seeded")
	check_eq(payload.get("kit", ""), "staff", "and seeds the new one's")
	check_eq(payload.get("name", ""), "Typed",
		"while the typed name survives — clearing the whole payload instead is the data loss this rule exists to prevent")

	await _drop(host, backend)


# --- Navigation ---------------------------------------------------------------

## [MKProfileBackend]'s refusals are silent by contract, so the host cannot say WHICH refusal it was.
## What it must do is say SOMETHING, in place, and stay on the step whose field can fix it.
func _test_refusal_stays_on_the_last_step_and_says_so() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var host := await _make_host([_step(&"name", ["name"], {"name": "Taken"})], [], backend, null)

	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))

	check_eq(host.get_message(), "", "precondition: nothing is claimed before the attempt")
	await _confirm(host)

	check_eq(backend.created.size(), 1, "the payload did reach the backend")
	check_eq(confirmed.size(), 0,
		"a refusal emits NO creation_confirmed — the embedding page would navigate away from a character that does not exist")
	check_eq(host.current_step_index(), 0,
		"and the flow stays on the last step, where the field that could fix it is")
	check_eq(host.get_message(), MKCreationHost.REFUSAL_MESSAGE,
		"with the refusal stated inline rather than as a modal the player must dismiss to reach the field")

	await _drop(host, backend)


## Skip is Next MINUS the commit, and that is the only difference — including on the last step, which
## must still finish the flow or a trailing skippable step is a dead end.
func _test_skip_never_commits_and_a_skipped_last_step_still_confirms() -> void:
	var backend := _spy_backend()
	MKProbeCreationStep.reset()
	var required := _step(&"first", ["name"], {"name": "Typed"})
	var optional := _step(&"last", ["look"], {"look": "hat"})
	optional.required = false
	optional.skippable = true
	var host := await _make_host([required, optional], [], backend, null)

	check(not host._skip_button.visible,
		"a REQUIRED step shows no Skip, whatever skippable says — required beats skippable")
	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "advanced to the skippable step")
	check(host._skip_button.visible, "which does offer Skip")

	var commits_before := MKProbeCreationStep.commits
	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))
	await _press(host._skip_button)

	check_eq(MKProbeCreationStep.commits, commits_before,
		"Skip does NOT call the step's commit")
	check_eq(confirmed.size(), 1,
		"but skipping the LAST step still confirms — the flow has to be finishable from wherever its last skippable step leaves the player")
	if backend.created.size() == 1:
		check(not (backend.created[0] as Dictionary).has("look"),
			"and the skipped step's key is absent from the payload rather than written empty")
		check_eq((backend.created[0] as Dictionary).get("name", ""), "Typed",
			"while the committed step's key is there")

	await _drop(host, backend)


## Back deliberately leaves what a step already committed in place — a Back that erased the field the
## player went back to LOOK at is the opposite of what the gesture promises — and moving forward again
## recommits over it.
func _test_back_keeps_committed_keys_and_a_recommit_overwrites() -> void:
	var backend := _spy_backend()
	MKProbeCreationStep.reset()
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "First"}),
		_step(&"tail", [], {}),
	], [], backend, null)

	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "precondition: advanced past the name step")
	check_eq(host.get_payload().get("name", ""), "First", "precondition: it committed")

	await _press(host._back_button)
	check_eq(host.current_step_index(), 0, "Back returned to it")
	check_eq(host.get_payload().get("name", ""), "First",
		"and the committed key is STILL there — Back is navigation, not an undo")

	# The player edits the field and walks forward again.
	var step_node := host._step_nodes[0] as MKProbeCreationStep
	step_node.commit_values = {"name": "Second"}
	await _press(host._next_button)
	check_eq(host.get_payload().get("name", ""), "Second",
		"walking forward recommits OVER the previous value rather than merging with it")

	await _drop(host, backend)


# --- Configuration ------------------------------------------------------------

## D17: point-buy is disabled by default, so a point-buy-shaped step with no schema is normal
## operation. It is dropped at DEBUG level — warning every host about an optional feature they
## declined is how a log gets ignored.
func _test_a_pointbuy_shaped_step_with_no_schema_is_dropped_quietly() -> void:
	var backend := _spy_backend()
	MKProbeCreationStep.reset()
	var pointbuy := _step(&"stats", ["stats"], {"stats": {}})
	_watch_log()
	var host := await _make_host([_step(&"name", ["name"], {"name": "T"}), pointbuy],
		[], backend, null, true)
	var messages := _stop_watching()

	check_eq(host.get_step_count(), 1,
		"the point-buy step is dropped when no MKStatSchema was supplied")
	check_eq(MKProbeCreationStep.binds, 1, "and it never bound")
	check_eq(_count_containing(messages, "point-buy is disabled by default"), 1,
		"with one line explaining the drop")
	check_eq(_count_containing(_warnings_only(messages), "point-buy is disabled by default"), 0,
		"at DEBUG, never WARN — declining an optional feature is not a misconfiguration")

	await _drop(host, backend)


## A null backend builds the flow DISABLED rather than refusing to render: a page that vanished when a
## slot is unassigned is indistinguishable from a crashed page, and the host's real mistake goes
## unnamed. One warning for the whole flow, not one per step.
func _test_a_null_backend_warns_once_and_disables_navigation() -> void:
	MKProbeCreationStep.reset()
	_watch_log()
	var host := await _make_host([
		_step(&"one", ["a"], {"a": 1}),
		_step(&"two", ["b"], {"b": 2}),
		_step(&"three", ["c"], {"c": 3}),
	], [], null, null)
	var warnings := _warnings_only(_stop_watching())

	check_eq(_count_containing(warnings, "no MKProfileBackend supplied"), 1,
		"ONE warning for a three-step flow — one per step would bury everything else in the log")
	check_eq(host.get_step_count(), 3, "the flow still built every step")
	check(host._next_button.disabled, "with Next disabled: nothing can be saved")
	check(host._skip_button.disabled, "and Skip too — it is a forward move like any other")
	check(not host._cancel_button.disabled,
		"but Cancel stays live, or the player is trapped on a page that can do nothing")

	# The disabled Next is asserted as BEHAVIOUR, not just as a flag: a real activation must not move.
	await _press(host._next_button)
	check_eq(host.current_step_index(), 0, "and pressing it really does nothing")

	var cancelled: Array = []
	host.creation_cancelled.connect(func() -> void: cancelled.append(true))
	await _press(host._cancel_button)
	check_eq(cancelled.size(), 1, "while Cancel emits, which is the only way off the page")

	await _drop(host, null)


## The end-to-end tie between the flow and the persisted format: the dictionary the last step assembled
## reaches [method MKProfileBackend.create_profile] VERBATIM, including an [int] that is still an int.
## (test_json_persistence.gd owns the disk half of that; this is the hop before it.)
func _test_the_confirmed_payload_reaches_create_profile_verbatim() -> void:
	var backend := _spy_backend()
	MKProbeCreationStep.reset()
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Alice"}),
		_step(&"stats", ["level", "stats"], {"level": 7, "stats": {"might": 3}}),
	], [], backend, null)

	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))
	await _press(host._next_button)
	await _confirm(host)

	check_eq(backend.created.size(), 1, "one create_profile call for one Confirm")
	if backend.created.size() == 1:
		var sent: Dictionary = backend.created[0]
		check_eq(sent, {"name": "Alice", "level": 7, "stats": {"might": 3}},
			"the payload arrives verbatim — MenuKit adds, removes and renames nothing")
		check_eq(typeof(sent.get("level")), TYPE_INT,
			"and an int is still an int at the backend seam, which is what the store's envelope then has to preserve")
		check_eq(typeof((sent.get("stats") as Dictionary).get("might")), TYPE_INT,
			"including inside a nested container")
	check_eq(confirmed.size(), 1, "and the STORED entry is what creation_confirmed carries")
	if confirmed.size() == 1:
		check((confirmed[0] as Dictionary).has("id"),
			"with the backend's assigned id — never the raw payload, which has no id yet")

	await _drop(host, backend)


# --- Fixtures -----------------------------------------------------------------

## Builds a step def whose scene is a probe packed in memory. [param owned] and [param commits] are
## what make each case's rule expressible; everything else is left at the def's own defaults.
func _step(id: StringName, owned: Array, commits: Dictionary,
		requires_schema := false) -> MKCreationStepDef:
	var node := MKProbeCreationStep.new()
	node.name = "Step_" + String(id)
	var typed: Array[String] = []
	for key in owned:
		typed.append(String(key))
	node.owned_keys = typed
	node.commit_values = commits
	node.requires_schema = requires_schema
	var packed := PackedScene.new()
	# pack() on a lone node keeps its script and its changed exports, which is all a probe needs —
	# and it keeps every case's data in the test that reads it rather than in a fan of .tscn files.
	packed.pack(node)
	node.free()

	var def := MKCreationStepDef.new()
	def.id = id
	def.title = String(id).capitalize()
	def.scene = packed
	return def


func _archetype(id: StringName, defaults: Dictionary) -> MKArchetype:
	var arch := MKArchetype.new()
	arch.id = id
	arch.display_name = String(id).capitalize()
	arch.payload_defaults = defaults
	return arch


## Sized and given frames, because navigation is driven through real button activations and an
## unsized host lays its footer out at zero.
func _make_host(steps: Array, archetypes: Array, backend: MKProfileBackend,
		schema: MKStatSchema, pointbuy_last := false) -> MKCreationHost:
	var typed_steps: Array[MKCreationStepDef] = []
	for step in steps:
		typed_steps.append(step)
	if pointbuy_last:
		# The last def is re-made as a point-buy-shaped step: the marker lives on the SCENE, not the def.
		var last := typed_steps[typed_steps.size() - 1]
		typed_steps[typed_steps.size() - 1] = _step(last.id, ["stats"], {"stats": {}}, true)
	var typed_archetypes: Array[MKArchetype] = []
	for arch in archetypes:
		typed_archetypes.append(arch)

	var host := MKCreationHost.new()
	host.size = Vector2(1280, 720)
	get_root().add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.configure(typed_steps, typed_archetypes, backend, schema)
	await step_frame()
	await step_frame()
	return host


func _confirm(host: MKCreationHost) -> void:
	check_eq(host._next_button.text, "Confirm",
		"the last step's Next IS Confirm — a separate always-visible Confirm would be disabled for the whole flow")
	await _press(host._next_button)


func _drop(host: Node, backend: Node) -> void:
	if host != null and is_instance_valid(host):
		host.queue_free()
	if backend != null and is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()


## Focus the button and push a REAL ui_accept press/release through the viewport, so the engine's own
## GUI dispatch runs BaseButton's activation — including its disabled check, which is what makes the
## null-backend assertions above meaningful. (Emitting `pressed` directly would fire on a button
## nothing could reach; the mouse route is dead under the dummy display driver, per test_rebind.)
func _press(button: Button) -> void:
	if button == null or not is_instance_valid(button):
		fail("tried to press a button that does not exist")
		return
	button.grab_focus()
	await step_frame()
	get_root().push_input(_key(KEY_ENTER, true), true)
	get_root().push_input(_key(KEY_ENTER, false), true)
	await step_frame()
	await step_frame()


func _key(code: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.pressed = pressed
	return event


func _spy_backend() -> SpyBackend:
	var backend := SpyBackend.new()
	get_root().add_child(backend)
	return backend


## A profile backend that records what it was handed and can be made to refuse. Recording the payload
## by VALUE (a deep duplicate) rather than holding the reference: the host reuses its own dictionary,
## so a live reference would report whatever it looked like at assertion time, not at the call.
class SpyBackend extends MKProfileBackend:
	var created: Array[Dictionary] = []
	var refuse := false
	var _roster: Array[Dictionary] = []

	func list_profiles() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for entry in _roster:
			out.append(entry.duplicate(true))
		return out

	func create_profile(payload: Dictionary) -> Dictionary:
		created.append(payload.duplicate(true))
		if refuse:
			return {}
		var entry := payload.duplicate(true)
		entry["id"] = "spy_%d" % created.size()
		_roster.append(entry)
		roster_changed.emit()
		return entry.duplicate(true)

	func delete_profile(id: String) -> bool:
		for i in _roster.size():
			if String(_roster[i].get("id", "")) == id:
				_roster.remove_at(i)
				roster_changed.emit()
				return true
		return false

	func load_profile(id: String) -> Dictionary:
		for entry in _roster:
			if String(entry.get("id", "")) == id:
				return entry.duplicate(true)
		return {}


# --- Observation --------------------------------------------------------------

## Watches every level, and keeps ERRORs separately: the ownership rules are stated as "an error
## naming both defs", and a suite that only counted messages could not tell an error from the debug
## line that follows it.
func _watch_log() -> void:
	_log = []
	_errors = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		_log.append("%d|%s" % [level, message])
		if level == MKLog.Level.ERROR:
			_errors.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	var out: Array[String] = []
	for entry in _log:
		out.append(entry.substr(entry.find("|") + 1))
	return out


## The WARN subset of a watched run, so "reported at debug, not warn" is assertable rather than
## inferred from a total that both levels satisfy.
func _warnings_only(_messages: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for entry in _log:
		if entry.begins_with("%d|" % MKLog.Level.WARN):
			out.append(entry.substr(entry.find("|") + 1))
	return out


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found
