extends MKTest
## The point-buy step: the pool arithmetic, the disabled-not-clamped rule, the payload shape and the
## restore path.
##
## [b]The buttons are the contract.[/b] "Disabled, not clamped" is the step's stated rule, so every
## legality assertion here is made twice — the button's [code]disabled[/code] flag AND the value after
## a REAL activation of it — because either alone passes against half an implementation: a step that
## disabled nothing but ignored the press reads as broken on screen, and one that greyed the button
## while still accepting a keyboard-raced activation over-spends the pool.
##
## Activations are focus + a pushed [code]ui_accept[/code] through the viewport (the test_rebind
## idiom), so the engine's own [BaseButton] path — including its disabled check — is what runs. The
## mouse route to the same signal is dead under the dummy display driver.
##
## One thing is asserted through a real [MKCreationHost] rather than on the step alone: the
## [member MKStatSchema.require_full_spend] gate, because "Next stays disabled" is the HOST's
## behaviour polled off the step's validity. The schema-requirement drop belongs to
## test_creation_host.gd and is not repeated here.

const STEP_SCENE := "res://addons/menu_kit/creation/steps/mk_step_pointbuy.tscn"

## The demo's authored schema — the one place the enabled path is shipped rather than constructed.
const DEMO_SCHEMA_PATH := "res://demo/demo_creation/pointbuy_schema.tres"

var _log: Array[String] = []


func run_tests() -> void:
	await _test_plus_disables_at_the_ceiling()
	await _test_plus_disables_when_the_cost_exceeds_the_remainder()
	await _test_minus_disables_at_the_floor()
	await _test_the_floor_is_free()
	await _test_the_payload_shape_is_string_keys_and_ints()
	await _test_a_duplicate_stat_id_warns_and_the_last_row_wins()
	await _test_a_restore_ignores_a_value_the_current_schema_cannot_honour()
	await _test_the_range_guard_holds_when_the_button_is_wrongly_enabled()
	await _test_require_full_spend_gates_next()
	_test_the_demo_schema_ships_the_full_spend_gate_switched_on()


## A [code]+[/code] that would exceed the stat's own ceiling is disabled even with points left in the
## pool — a per-stat cap is the usual way a schema stops one dumped stat consuming the whole budget.
func _test_plus_disables_at_the_ceiling() -> void:
	var step := await _bind(_schema(10, [_stat(&"might", 1, 2, 1)]))

	check(not step._plus_buttons[0].disabled, "precondition: the row can be raised at all")
	await _press(step._plus_buttons[0])
	check_eq(step._values[0], 2, "the press raised the stat")
	check_eq(step._value_labels[0].text, "2", "and the row redrew")

	check(step._plus_buttons[0].disabled, "at max_value the + is DISABLED, not pressable-and-ignored")
	check_eq(_remaining_text(step), "Points remaining: 9",
		"with the pool showing what the raise cost")
	await _press(step._plus_buttons[0])
	check_eq(step._values[0], 2, "and a real activation of it cannot push past the ceiling")

	await _drop(step)


## The pool rule, with a cost that does not divide it: 3 points at 2 each buys one increment and
## leaves a remainder that can never be spent. The + must state that by being disabled.
func _test_plus_disables_when_the_cost_exceeds_the_remainder() -> void:
	var step := await _bind(_schema(3, [_stat(&"might", 0, 5, 2)]))

	check_eq(_remaining_text(step), "Points remaining: 3", "the whole pool is available at the floor")
	await _press(step._plus_buttons[0])
	check_eq(step._values[0], 1, "one increment bought")
	check_eq(_remaining_text(step), "Points remaining: 1", "at its authored cost of 2")

	check(step._plus_buttons[0].disabled,
		"the + is disabled with 1 point left and a cost of 2 — a remainder smaller than the cost is unspendable")
	check(step._values[0] < 5, "precondition: the ceiling is NOT what disabled it")
	await _press(step._plus_buttons[0])
	check_eq(step._values[0], 1, "and pressing it cannot spend a point that is not there")
	check(step._mk_step_is_valid(),
		"an unspendable remainder is still a valid step when require_full_spend is off")

	await _drop(step)


func _test_minus_disables_at_the_floor() -> void:
	var step := await _bind(_schema(10, [_stat(&"might", 2, 6, 1)]))

	check(step._minus_buttons[0].disabled, "at min_value the - is disabled from the first frame")
	await _press(step._minus_buttons[0])
	check_eq(step._values[0], 2, "and cannot take the stat below its floor")

	await _press(step._plus_buttons[0])
	check(not step._minus_buttons[0].disabled, "raising the stat enables it again")
	await _press(step._minus_buttons[0])
	check_eq(step._values[0], 2, "which refunds back to the floor")
	check_eq(_remaining_text(step), "Points remaining: 10", "returning the point to the pool")
	check(step._minus_buttons[0].disabled, "and disables itself at the floor once more")

	await _drop(step)


## Points are spent from the per-stat minimum, so [member MKStatSchema.total_points] is the budget
## ABOVE the free starting spread. Asserted on a schema whose floors are high and expensive: charging
## for them would leave a visibly smaller pool.
func _test_the_floor_is_free() -> void:
	var step := await _bind(_schema(4, [
		_stat(&"might", 5, 8, 3),
		_stat(&"wits", 5, 8, 3),
	]))

	check_eq(step._values[0], 5, "each stat starts at its own floor")
	check_eq(step._values[1], 5, "including the second")
	check_eq(_remaining_text(step), "Points remaining: 4",
		"and the pool is untouched by it — the free starting spread is authored as the minimums")

	await _drop(step)


## The payload is the step's whole output, and its shape is a persisted-format surface: [String] keys
## (the payload crosses to JSON and back) holding [int]s (which the shipped store's envelope then has
## to preserve).
func _test_the_payload_shape_is_string_keys_and_ints() -> void:
	var step := await _bind(_schema(10, [_stat(&"might", 1, 6, 1), _stat(&"wits", 1, 6, 1)]))
	await _press(step._plus_buttons[0])
	await _press(step._plus_buttons[0])

	var payload := {}
	step._mk_step_commit(payload)

	check(payload.has("stats"), "the step writes exactly its declared key")
	check_eq(step._mk_step_owned_keys(), ["stats"] as Array[String],
		"which is the key it declared to the host")
	var stats: Variant = payload.get("stats")
	check(stats is Dictionary, "carrying a sub-dictionary")
	if stats is Dictionary:
		var d := stats as Dictionary
		check_eq(d.size(), 2, "one entry per rendered row")
		check_eq(d.get("might"), 3, "the allocated value, counted from the floor")
		check_eq(d.get("wits"), 1, "and an untouched stat carries its floor rather than being omitted")
		for key in d.keys():
			check_eq(typeof(key), TYPE_STRING,
				"keys are String, not StringName — a key whose type depends on whether the profile has been saved yet is a bug waiting on a load")
			check_eq(typeof(d[key]), TYPE_INT, "and the values are ints")

	await _drop(step)


## A schema that repeats an id renders two independent rows and writes ONE field. That is a lossy
## collapse, so it is said out loud — silently recording half the player's spend is the failure this
## warning exists to make findable.
func _test_a_duplicate_stat_id_warns_and_the_last_row_wins() -> void:
	var step := await _bind(_schema(10, [_stat(&"might", 1, 6, 1), _stat(&"might", 1, 6, 1)]))
	check_eq(step._values.size(), 2, "both rows are rendered — the rows are independent")
	await _press(step._plus_buttons[1])
	check_eq(step._values[0], 1, "the first row is unmoved by the second's button")
	check_eq(step._values[1], 2, "which raised only its own row")

	var payload := {}
	_watch_warnings()
	step._mk_step_commit(payload)
	var warnings := _stop_watching()

	check_eq(_count_containing(warnings, "appears more than once"), 1,
		"the collapse is warned about exactly once")
	var stats: Dictionary = payload.get("stats", {})
	check_eq(stats.size(), 1, "and the payload carries one field for the repeated id")
	check_eq(stats.get("might"), 2, "with the LAST row winning, as the warning states")

	await _drop(step)


## [b]Restore is a filter, not a clamp[/b] — and this asserts what the step actually does. A stored
## value the current schema cannot honour is DROPPED (the row stays at its floor) rather than being
## pulled to the nearest legal value: the payload may hold an allocation made before the host
## reconfigured the flow, and inventing a number the player never chose would be worse than showing
## them the floor with the buttons in front of them.
func _test_a_restore_ignores_a_value_the_current_schema_cannot_honour() -> void:
	var schema := _schema(10, [
		_stat(&"might", 1, 6, 1),
		_stat(&"wits", 1, 6, 1),
		_stat(&"grit", 1, 6, 1),
	])
	var step := await _bind(schema, {
		"stats": {
			"might": 4,          # legal — restored
			"wits": 99,          # above max_value — dropped
			"grit": "three",     # not a number at all — dropped, and int("three") would be a script error
			"ghost": 5,          # not in this schema — ignored entirely
		},
	})

	check_eq(step._values[0], 4, "an in-range stored value is restored, which is what Back promises")
	check_eq(step._values[1], 1,
		"an out-of-range one is dropped to the row's floor, not clamped to a value the player never chose")
	check_eq(step._values[2], 1, "and a non-numeric one is dropped rather than coerced")
	check_eq(_remaining_text(step), "Points remaining: 7",
		"the pool reflects exactly what was restored")
	check(step._mk_step_is_valid(), "and the restored state is walkable")

	await _drop(step)


## [b]The range guard inside [code]_adjust[/code] is the second line of defence, and this is the only
## case that can see it.[/b] Every other assertion in this file goes through a button the step has
## already disabled, so the engine's own BaseButton check stops the activation before
## [code]_adjust[/code] runs.
##
## The race the guard defends is a button that is enabled when it should not be: a keyboard activation
## dispatched between the value changing and [method _refresh] re-computing the disabled flags. That
## state is reproduced directly — the step is walked to its ceiling and floor, then the button is
## re-enabled BY HAND to stand in for the refresh that has not run yet — and the button's
## own [signal BaseButton.pressed] is emitted, which is exactly what the engine emits at the end of an
## activation it allowed. The value must not move, and the committed payload must not carry an
## out-of-range number.
func _test_the_range_guard_holds_when_the_button_is_wrongly_enabled() -> void:
	var step := await _bind(_schema(10, [_stat(&"might", 1, 3, 1)]))

	await _press(step._plus_buttons[0])
	await _press(step._plus_buttons[0])
	check_eq(step._values[0], 3, "precondition: the stat is at its ceiling")
	check(step._plus_buttons[0].disabled, "precondition: which the step expressed by disabling +")

	# The refresh that has not run yet.
	step._plus_buttons[0].disabled = false
	step._plus_buttons[0].pressed.emit()
	check_eq(step._values[0], 3,
		"a press that the disabled check did NOT stop is still refused by _adjust's range guard — the ceiling is the rule, the greyed button is only how it is shown")
	check_eq(step._value_labels[0].text, "3", "and nothing redrew past it")
	check_eq(_remaining_text(step), "Points remaining: 8",
		"the pool is untouched, so no point was spent on a raise that did not happen")

	var payload := {}
	step._mk_step_commit(payload)
	check_eq((payload.get("stats") as Dictionary).get("might"), 3,
		"and the committed payload carries a value the current schema can honour — an over-max number here is what a host would then have to defend against forever")

	# The mirror at the floor: one `if` covers both bounds, so without this case half the guard is
	# unheld.
	await _press(step._minus_buttons[0])
	await _press(step._minus_buttons[0])
	check_eq(step._values[0], 1, "precondition: walked back down to the floor")
	check(step._minus_buttons[0].disabled, "precondition: expressed by disabling -")
	step._minus_buttons[0].disabled = false
	step._minus_buttons[0].pressed.emit()
	check_eq(step._values[0], 1, "and a wrongly-enabled - cannot take the stat below its min_value")

	await _drop(step)


## The gate is the HOST's, polled off the step's validity, so it is asserted through a real host with
## a real Next button — a step reporting invalid that nothing gated on would leave the player walking
## past a half-allocated character.
func _test_require_full_spend_gates_next() -> void:
	var strict := _schema(2, [_stat(&"might", 1, 6, 1)])
	strict.require_full_spend = true
	var backend := StubBackend.new()
	get_root().add_child(backend)
	var host := await _make_host(strict, backend)
	var step := host._step_nodes[0] as MKStepPointBuy

	check(host._next_button.disabled,
		"with require_full_spend and points unspent, Next is disabled")
	check(_remaining_text(step).contains("spend them all"),
		"and the readout says WHY — nothing else on screen connects the greyed button to the number")
	await _press(step._plus_buttons[0])
	check(host._next_button.disabled, "still gated with one point left")
	await _press(step._plus_buttons[0])
	check_eq(_remaining_text(step), "Points remaining: 0", "the pool is empty")
	check(not host._next_button.disabled,
		"and Next enables — the host re-polled on the step's own step_state_changed")

	host.queue_free()
	await step_frame()

	# The permissive schema is the OTHER half: leftover points are a legitimate design (banking for a
	# level-up screen), and MenuKit must not assert a rule it does not hold.
	var lenient := _schema(2, [_stat(&"might", 1, 6, 1)])
	lenient.require_full_spend = false
	var lenient_host := await _make_host(lenient, backend)
	var lenient_step := lenient_host._step_nodes[0] as MKStepPointBuy
	check(not lenient_host._next_button.disabled,
		"with require_full_spend off, Next is live from the first frame with the whole pool unspent")
	check(not _remaining_text(lenient_step).contains("spend them all"),
		"and the readout claims no rule that is not being enforced")

	lenient_host.queue_free()
	backend.queue_free()
	await step_frame()


## [b]The demo's own schema, asserted as CONTRACT rather than as tuning.[/b] The two cases above build
## their schemas in memory, so both sides of the flag stay covered no matter what the shipped resource
## says — which leaves the resource itself pinned by nothing.
##
## The demo is the deliverable that DEMONSTRATES the full-spend gate, so the value of this one bool in
## this one file is a contract, and the schema's own header says as much ("with the flag on, the
## shipped demo shows ... a greyed Confirm"). A host wanting the lenient flow flips it in THEIR
## schema; flipping it here retires the demonstration.
func _test_the_demo_schema_ships_the_full_spend_gate_switched_on() -> void:
	var schema := ResourceLoader.load(DEMO_SCHEMA_PATH) as MKStatSchema
	check(schema != null, "the demo's point-buy schema loads as an MKStatSchema")
	if schema == null:
		return
	check(schema.require_full_spend,
		"and ships require_full_spend TRUE — §5 names the gate as an exit criterion, and the demo is the deliverable that has to show it")
	check(schema.total_points > 0 and not schema.stats.is_empty(),
		"with a pool and rows to spend it on, or the gate it enables has nothing to gate")


# --- Fixtures -----------------------------------------------------------------

func _stat(id: StringName, min_value: int, max_value: int, cost: int) -> MKStatDef:
	var stat := MKStatDef.new()
	stat.id = id
	stat.label = String(id).capitalize()
	stat.min_value = min_value
	stat.max_value = max_value
	stat.cost_per_point = cost
	return stat


func _schema(total: int, stats: Array) -> MKStatSchema:
	var schema := MKStatSchema.new()
	schema.total_points = total
	var typed: Array[MKStatDef] = []
	for stat in stats:
		typed.append(stat)
	schema.stats = typed
	# Off unless a test turns it on: it is the flag under test in exactly one function, and leaving it
	# at the resource default would make every other assertion here depend on it.
	schema.require_full_spend = false
	return schema


## Binds the SHIPPED step scene directly — the host's own drop/ownership behaviour is
## test_creation_host.gd's, and routing every case through a host would make each of these assertions
## depend on that machinery too.
func _bind(schema: MKStatSchema, payload := {}) -> MKStepPointBuy:
	var packed := ResourceLoader.load(STEP_SCENE) as PackedScene
	check(packed != null, "the point-buy step scene loads")
	var step := packed.instantiate() as MKStepPointBuy
	# No explicit size: the step's own _build applies a full-rect preset, and writing `size` over that
	# makes the engine warn about non-equal opposite anchors on every bind. Nothing here hit-tests a
	# rect — activation is focus + ui_accept — so layout geometry is not part of any assertion.
	get_root().add_child(step)
	var def := MKCreationStepDef.new()
	def.id = &"stats"
	def.scene = packed
	step._mk_step_bind(null, def, {
		"archetypes": [] as Array[MKArchetype],
		"profile_backend": null,
		"stat_schema": schema,
		"payload": payload,
	})
	await step_frame()
	await step_frame()
	return step


func _make_host(schema: MKStatSchema, backend: MKProfileBackend) -> MKCreationHost:
	var def := MKCreationStepDef.new()
	def.id = &"stats"
	def.title = "Attributes"
	def.scene = ResourceLoader.load(STEP_SCENE) as PackedScene
	var steps: Array[MKCreationStepDef] = [def]
	var host := MKCreationHost.new()
	host.size = Vector2(1280, 720)
	get_root().add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.configure(steps, [] as Array[MKArchetype], backend, schema)
	await step_frame()
	await step_frame()
	return host


func _remaining_text(step: MKStepPointBuy) -> String:
	return step._remaining_label.text


func _drop(step: Node) -> void:
	if step != null and is_instance_valid(step):
		step.queue_free()
	await step_frame()
	await step_frame()


## Focus + a REAL ui_accept press/release, so the engine's own BaseButton activation runs — including
## its disabled check, which is half of every "disabled, not clamped" assertion above.
func _press(button: Button) -> void:
	if button == null or not is_instance_valid(button):
		fail("tried to press a button that does not exist")
		return
	button.grab_focus()
	await step_frame()
	get_root().push_input(_key(true), true)
	get_root().push_input(_key(false), true)
	await step_frame()


func _key(pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_ENTER
	event.keycode = KEY_ENTER
	event.pressed = pressed
	return event


## The flow needs SOME backend for Next to be enabled at all (a null one disables navigation, which is
## test_creation_host.gd's case). This one does nothing else.
class StubBackend extends MKProfileBackend:
	func list_profiles() -> Array[Dictionary]:
		return [] as Array[Dictionary]

	func create_profile(payload: Dictionary) -> Dictionary:
		return payload.duplicate(true)

	func delete_profile(_id: String) -> bool:
		return false

	func load_profile(_id: String) -> Dictionary:
		return {}


# --- Observation --------------------------------------------------------------

func _watch_warnings() -> void:
	_log = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_log.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _log


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found
