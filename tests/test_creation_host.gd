extends MKTest
## The creation flow engine: key ownership, merge order, navigation and the refusal path.
##
## [b]Every case builds its own steps.[/b] The rules under test are statements about an ARBITRARY
## ordered set — two steps claiming one key, a skip that must not commit, an archetype default whose
## key a step owns — and none of them is reachable from the three steps the addon ships, because no
## pair of them collides. So the flow is driven through [MKProbeCreationStep] scenes packed in
## memory, which is the same relationship [code]tests/probes/[/code] already has with the settings
## panel's custom rows.
##
## [b]Navigation is driven through the host's REAL buttons[/b] (focus + a pushed ui_accept), never by
## calling [code]_advance[/code]: the gating IS the behaviour — a disabled Next that nothing can press
## is the whole of the null-backend and invalid-step contracts, and calling the private mover would
## pass against a host that never disabled anything. The mouse route to the same signal is dead under
## the dummy display driver, so keyboard activation is the honest gesture here.
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
	await _test_ownership_is_claimed_before_any_step_binds()
	await _test_merge_order_defaults_first_steps_win()
	await _test_switching_archetype_clears_only_its_own_seeds()
	await _test_refusal_stays_on_the_last_step_and_says_so()
	await _test_a_refusal_closes_confirm_until_the_player_commits_forward_again()
	await _test_a_skipped_optional_step_cannot_brick_the_refusal_gate()
	await _test_a_flow_with_no_forward_commit_still_recovers_from_a_refusal()
	await _test_the_refusal_gate_also_closes_a_last_step_skip()
	await _test_a_single_step_flow_recovers_by_editing_the_step()
	await _test_a_multi_step_last_step_ping_does_not_lift_the_gate()
	await _test_skip_never_commits_and_a_skipped_last_step_still_confirms()
	await _test_back_keeps_committed_keys_and_a_recommit_overwrites()
	await _test_a_pointbuy_shaped_step_with_no_schema_is_dropped_quietly()
	await _test_a_pointbuy_step_with_an_unusable_schema_is_dropped_and_named()
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


## An archetype default whose key a step owns is refused and named ONCE, at configure.
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


## [b]The exclusion must not depend on the order the steps were authored in.[/b]
##
## Binding is not inert: [MKStepArchetype] auto-selects its first card at bind (so the grid is never an
## empty dead end) and reports it through [method MKCreationHost.notify_archetype_chosen] from there.
## With claiming and binding interleaved, an archetype step declared BEFORE the step that owns
## [code]name[/code] seeds that key into the payload while [code]_owned_by[/code] is still empty — so
## the same configure prints "it is NOT seeded" and seeds it. Every claim must land before any bind.
##
## Driven through the REAL shipped archetype step rather than a probe: the seeding-at-bind behaviour
## that makes this reachable is that scene's, and a probe reproducing it would be asserting the test's
## own re-implementation of the hazard.
func _test_ownership_is_claimed_before_any_step_binds() -> void:
	var backend := _spy_backend()
	var arch := _archetype(&"knight", {"name": "Ser Default", "gold": 50})
	var arch_def := MKCreationStepDef.new()
	arch_def.id = &"pick"
	arch_def.title = "Archetype"
	arch_def.scene = load("res://addons/menu_kit/creation/steps/mk_step_archetype.tscn") as PackedScene
	check(arch_def.scene != null, "precondition: the shipped archetype step scene loads")
	if arch_def.scene == null:
		await _drop(null, backend)
		return

	MKProbeCreationStep.reset()
	# ORDER IS THE WHOLE POINT: the archetype step is declared FIRST, ahead of the step that owns "name".
	var host := await _make_host([arch_def, _step(&"name", ["name"], {"name": "Typed"})],
		[arch], backend, null)

	var payload := host.get_payload()
	check(not payload.has("name"),
		"the archetype's default for an OWNED key is absent even though the seeding step bound first — every step's keys are claimed before any bind runs (got %s)"
			% payload)
	check_eq(payload.get("gold", null), 50,
		"while the UNOWNED default seeded normally at bind, so the pass split did not simply stop the seeding")
	check(not payload.has("archetype"),
		"and the archetype step's own key is still written on commit rather than seeded")
	check_eq(host.get_step_count(), 2, "both steps survived — this is an ordering case, not a drop case")
	check_eq(MKProbeCreationStep.binds, 1, "and the probe bound exactly once")

	await _drop(host, backend)


## The documented merge order, asserted as what it actually IS: enforcement by EXCLUSION.
##
## "Steps overwrite defaults" can never literally occur, because the host refuses an archetype default whose
## key a step owns — so the owned key is never seeded and there is no second write to be ordered
## against. The archetype below therefore authors a default for BOTH an owned key and an unowned one,
## and the payload is read at three moments (after the choice, before any commit; and after the
## commit; and at the backend seam) rather than only at the end.
##
## [b]What these assertions pin:[/b] at no observed moment does the payload carry the owned key's
## DEFAULT value — not transiently, not before the step ran — while the unowned default is present
## from the choice onward, and the owned key holds the STEP's value once the step commits.
## [b]What they cannot pin:[/b] an implementation that re-seeded after every commit would be
## behaviour-equivalent FOR UNOWNED KEYS by construction (a re-seed writes the same value the first
## seed wrote, and the owned key is excluded from seeding either way), so no assertion over payload
## content can distinguish it. That is a consequence of the exclusion rule, not a gap in the suite:
## with the two authors disjoint, "when the seed ran" has no observable content.
func _test_merge_order_defaults_first_steps_win() -> void:
	var backend := _spy_backend()
	# "name" is OWNED by the step below, so this default is the collision case: refused, never seeded.
	var arch := _archetype(&"scout", {"kit": "bow", "gold": 25, "name": "Sir Default"})
	MKProbeCreationStep.reset()
	var host := await _make_host([_step(&"name", ["name"], {"name": "Typed"})], [arch], backend, null)

	host.notify_archetype_chosen(arch)
	var after_choice := host.get_payload()
	check_eq(after_choice.get("kit", ""), "bow", "the unowned default seeded on the choice")
	check_eq(after_choice.get("gold", null), 25, "including the numeric one")
	check(not after_choice.has("name"),
		"and the OWNED key is absent — the archetype's default for it was never seeded, not even transiently before the step ran, which is what makes 'steps win' unfalsifiable by an ordering bug")

	await _confirm(host)
	check_eq(host.get_payload().get("name", ""), "Typed",
		"after the owning step's commit the key holds the STEP's value, and it is the only value it has ever held")
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


## [b]A refusal closes the flow's exit until the player moves FORWARD over a step again.[/b]
##
## The refusal is usually a name taken between the name step's pre-check and Confirm — and the name
## step is almost never the last one. Re-polling only the current step left Confirm enabled over a
## payload the backend had just rejected: the player pressed it again and got the identical message,
## with nothing on screen pointing at the field that had gone stale.
##
## What lifts it is forward MOVEMENT — a commit, or a non-last Skip — not a validity poll. Back is how
## the player REACHES the field to fix, and it commits nothing: lifting there would re-enable Confirm
## over the exact payload that was refused. Walking forward again is the gesture that says "this is a
## new attempt". (The one exception is a flow whose refused step is index 0, where there is no Back and
## therefore no walk to make — see the single-step test below.)
func _test_a_refusal_closes_confirm_until_the_player_commits_forward_again() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Taken"}),
		_step(&"tail", [], {}),
	], [], backend, null)

	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "precondition: the player is past the name step")
	var name_step := host._step_nodes[0] as MKProbeCreationStep
	check(not host._next_button.disabled,
		"precondition: Confirm is enabled — the CURRENT step is valid, which is all the gate asks before an attempt")

	await _confirm(host)
	check_eq(backend.created.size(), 1, "precondition: the attempt reached the backend and was refused")
	check_eq(host.get_message(), MKCreationHost.REFUSAL_MESSAGE, "and said so inline")
	check(host._next_button.disabled,
		"after the refusal Confirm is DISABLED — a second press over an unchanged payload can only produce the identical refusal")

	# A step announcing a state change does NOT lift the gate: the name step agreeing with itself again
	# says nothing about the payload the backend rejected.
	name_step.set_valid(false)
	name_step.set_valid(true)
	check(host._next_button.disabled,
		"and a step re-polling valid does not lift it — validity was never what the refusal was about")

	await _press(host._back_button)
	check_eq(host.current_step_index(), 0, "Back reaches the field that can fix it")
	check(host._refusal_pending,
		"and Back alone does NOT lift the gate — it commits nothing, so the payload is still the refused one")

	backend.refuse = false
	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "walking forward again recommits the step")
	check(not host._refusal_pending, "which IS the fresh attempt, so the gate lifts")
	check(not host._next_button.disabled, "and Confirm is live again")

	await _confirm(host)
	check_eq(backend.created.size(), 2, "the second attempt reaches the backend")
	check_eq(host.get_message(), "", "and succeeds, with the refusal message gone")

	await _drop(host, backend)


## [b]The dead end the old whole-flow poll produced, driven through the shipped shape.[/b] An OPTIONAL
## step that answers invalid until it is completed is exactly the point-buy step under
## [code]require_full_spend[/code], and the flow INVITES skipping it. Gating the post-refusal Confirm on
## "every step answers valid" then asked that skipped step forever: it never became valid, so Confirm
## could never re-enable, and Cancel was the only way off the screen — with the create refused for a
## reason (a roster cap the server has since freed) that had nothing to do with any step's validity.
##
## The commit-based gate is what makes the ordinary recovery gesture work: Back to a step the player
## can answer, forward again, Confirm.
func _test_a_skipped_optional_step_cannot_brick_the_refusal_gate() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var pointbuy := _step(&"stats", ["stats"], {"stats": {}})
	pointbuy.required = false
	pointbuy.skippable = true
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Typed"}),
		pointbuy,
		_step(&"tail", [], {}),
	], [], backend, null)
	# Invalid until spent — and never spent, because the player takes the Skip the flow offers.
	(host._step_nodes[1] as MKProbeCreationStep).set_valid(false)

	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "precondition: past the name step")
	check(host._skip_button.visible and not host._skip_button.disabled,
		"precondition: the optional step offers Skip, which is what makes it legitimately unanswered")
	await _press(host._skip_button)
	check_eq(host.current_step_index(), 2, "precondition: skipped to the last step")

	await _confirm(host)
	check_eq(backend.created.size(), 1, "precondition: the attempt was refused")
	check(host._next_button.disabled, "Confirm is gated, as it must be")

	# The condition the refusal was about clears on the backend's side — nothing on this screen changed,
	# and under the old gate nothing on this screen COULD change, because the skipped step is still
	# invalid and always will be.
	backend.refuse = false
	await _press(host._back_button)
	check_eq(host.current_step_index(), 1, "Back walks off the last step")
	await _press(host._back_button)
	check_eq(host.current_step_index(), 0, "and back to one the player can answer")
	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "forward again, recommitting it")
	check(not host._refusal_pending,
		"the recommit lifts the gate — under a whole-flow poll the skipped step held it down forever")
	await _press(host._skip_button)
	check_eq(host.current_step_index(), 2, "skip the optional step again, as before")
	check(not host._next_button.disabled,
		"and Confirm is ENABLED: the flow is finishable, rather than Cancel being the only way out")

	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))
	await _confirm(host)
	check_eq(backend.created.size(), 2, "the second attempt reaches the backend")
	check_eq(confirmed.size(), 1, "and creates the character")

	await _drop(host, backend)


## The commit-only lift rule left ONE flow shape unliftable: nothing but invalid OPTIONAL steps before
## a valid required last step has no forward commit ANYWHERE — Next never enables on the invalid step,
## so the only forward gesture the whole flow offers is Skip, and a rule that only a commit could lift
## would make Cancel the sole exit after a single refusal. The rule is
## therefore forward MOVEMENT: a non-last Skip is a deliberate fresh walk toward Confirm and lifts the
## gate; a LAST-step Skip still lifts nothing, which is what keeps the doubled-create door shut (the
## test below this one).
func _test_a_flow_with_no_forward_commit_still_recovers_from_a_refusal() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var optional := _step(&"stats", ["stats"], {"stats": {}})
	optional.required = false
	optional.skippable = true
	var host := await _make_host([
		optional,
		_step(&"tail", [], {}),
	], [], backend, null)
	(host._step_nodes[0] as MKProbeCreationStep).set_valid(false)

	check(host._next_button.disabled, "precondition: the invalid optional step never enables Next")
	await _press(host._skip_button)
	check_eq(host.current_step_index(), 1, "precondition: Skip is the only way forward, and it works")
	await _confirm(host)
	check_eq(backend.created.size(), 1, "precondition: the attempt was refused")
	check(host._next_button.disabled, "precondition: Confirm gated")

	backend.refuse = false
	await _press(host._back_button)
	check_eq(host.current_step_index(), 0, "Back returns to the optional step")
	await _press(host._skip_button)
	check_eq(host.current_step_index(), 1, "and the SKIP forward is accepted")
	check(not host._refusal_pending,
		"a non-last Skip lifts the gate — under the commit-only rule this flow had no liftable gesture at all and Cancel was the only exit")
	check(not host._next_button.disabled, "Confirm is live again")

	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))
	await _confirm(host)
	check_eq(backend.created.size(), 2, "the retry reaches the backend")
	check_eq(confirmed.size(), 1, "and creates the character")

	await _drop(host, backend)


## [b]Skip is the other door into [method MKCreationHost._confirm], and the refusal gate has to cover
## it.[/b] A skippable LAST step confirms when skipped — that is the documented rule that keeps a
## trailing optional step from being a dead end — so a gate that disabled only Confirm left a visible,
## enabled Skip sitting beside it. One press fired a second identical attempt at the backend (measured:
## two create_profile calls for one refused payload), which is the doubled create the gate exists to
## prevent.
##
## Skip is gated only where it would CONFIRM. On any earlier step it is ordinary forward navigation and
## stays live — see the brick test above, which recovers through exactly that.
func _test_the_refusal_gate_also_closes_a_last_step_skip() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var optional := _step(&"look", ["look"], {"look": "hat"})
	optional.required = false
	optional.skippable = true
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Typed"}),
		optional,
	], [], backend, null)

	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "precondition: on the skippable LAST step")
	check(host._skip_button.visible and not host._skip_button.disabled,
		"precondition: Skip is offered and live")

	await _press(host._skip_button)
	check_eq(backend.created.size(), 1,
		"precondition: skipping the last step DOES confirm, which is why it is a door into the refusal")
	check_eq(host.get_message(), MKCreationHost.REFUSAL_MESSAGE, "and it was refused")

	check(host._skip_button.disabled,
		"so after the refusal Skip is disabled too — one gate, both buttons")
	check(host._next_button.disabled, "alongside Confirm")
	await _press(host._skip_button)
	check_eq(backend.created.size(), 1,
		"and pressing it again reaches the backend NOT ONCE more — a doubled create is exactly what the gate is for")

	backend.refuse = false
	await _press(host._back_button)
	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "a forward recommit brings the player back to the last step")
	check(not host._skip_button.disabled,
		"with Skip live again — the gate is a pause on a repeat attempt, not a removal of the gesture")
	await _press(host._skip_button)
	check_eq(backend.created.size(), 2, "and it confirms, as a skipped last step always did")

	await _drop(host, backend)


## [b]A ONE-step flow had no lift site at all, so one refusal ended it.[/b] At index 0 the step is also
## the last, so the gate disables Next AND Skip; Back is disabled at index 0 for having nowhere to go.
## Every forward-movement lift lives behind those two buttons — measured: the player retypes the name,
## the gate stays down, and Cancel is the only way off the screen for a refusal (a name taken a second
## ago) that retyping is the whole fix for.
##
## So on index 0 the step announcing a change IS the fresh attempt: it is the only signal that flow can
## produce, and it is about the very step Confirm is about to submit.
func _test_a_single_step_flow_recovers_by_editing_the_step() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var host := await _make_host([_step(&"name", ["name"], {"name": "Taken"})], [], backend, null)

	check_eq(host.get_step_count(), 1, "precondition: a one-step flow, where the first step is the last")
	check(host._back_button.disabled, "precondition: Back is disabled at index 0 — there is nowhere behind")

	await _confirm(host)
	check_eq(backend.created.size(), 1, "precondition: the attempt was refused")
	check(host._next_button.disabled, "so Confirm is gated")
	check(host._refusal_pending, "with the refusal pending")

	# The player edits the field — the ONLY gesture this flow offers that says anything.
	var step_node := host._step_nodes[0] as MKProbeCreationStep
	step_node.commit_values = {"name": "Retyped"}
	backend.refuse = false
	step_node.set_valid(true)

	check(not host._refusal_pending,
		"editing the step lifts the gate — in a flow with no Back and no non-last Skip this is the only fresh-attempt signal there is")
	check(not host._next_button.disabled, "and Confirm is live again")

	var confirmed: Array = []
	host.creation_confirmed.connect(func(profile: Dictionary) -> void: confirmed.append(profile))
	await _confirm(host)
	check_eq(backend.created.size(), 2, "the retry reaches the backend")
	check_eq(confirmed.size(), 1, "and creates the character, rather than Cancel being the only exit")
	if backend.created.size() == 2:
		check_eq((backend.created[1] as Dictionary).get("name", ""), "Retyped",
			"over the edited payload — the recommit ran on the way into _confirm")

	await _drop(host, backend)


## The scoping half of the exception above: on a MULTI-step flow's last step the player HAS a Back, so
## the walk the gate prices is available and a state ping must not buy its way past it. A step agreeing
## with itself again says nothing about the payload the backend rejected — which the earlier steps
## wrote and this ping cannot speak for.
func _test_a_multi_step_last_step_ping_does_not_lift_the_gate() -> void:
	var backend := _spy_backend()
	backend.refuse = true
	MKProbeCreationStep.reset()
	var host := await _make_host([
		_step(&"name", ["name"], {"name": "Taken"}),
		_step(&"tail", ["tail"], {"tail": 1}),
	], [], backend, null)

	await _press(host._next_button)
	check_eq(host.current_step_index(), 1, "precondition: on the LAST step of a two-step flow")
	await _confirm(host)
	check(host._refusal_pending, "precondition: refused and gated")

	var last_step := host._step_nodes[1] as MKProbeCreationStep
	last_step.set_valid(false)
	last_step.set_valid(true)
	check(host._refusal_pending,
		"a ping on the last step of a MULTI-step flow does NOT lift it — the player has a Back, so the deliberate walk is still available and still the price")
	check(host._next_button.disabled, "and Confirm stays gated")

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

## Point-buy is disabled by default, so a point-buy-shaped step with no schema is normal
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


## The other half of the drop: [method MKStatSchema.is_valid] is only a mechanism if a caller acts on
## it — unenforced, a schema with a zero pool reaches the step and renders a budget every
## [code]+[/code] is dead against from the first frame. WARN rather than the null schema's debug:
## declining point-buy is a choice, authoring an unusable schema is a mistake.
func _test_a_pointbuy_step_with_an_unusable_schema_is_dropped_and_named() -> void:
	var backend := _spy_backend()
	var stat := MKStatDef.new()
	stat.id = &"might"
	stat.label = "Might"
	var schema := MKStatSchema.new()
	schema.stats = [stat]
	schema.total_points = 0
	check(stat.is_valid(), "precondition: the stat row itself is fine, so the pool is the only fault")
	check(not schema.is_valid(),
		"a ZERO pool is invalid, not merely a negative one — a step where every + is dead reads exactly as broken however it got that way")

	MKProbeCreationStep.reset()
	_watch_log()
	var host := await _make_host([_step(&"name", ["name"], {"name": "T"}), _step(&"stats", ["stats"], {})],
		[], backend, schema, true)
	var messages := _stop_watching()

	check_eq(host.get_step_count(), 1, "the point-buy step is dropped rather than rendered dead")
	check_eq(MKProbeCreationStep.binds, 1, "and it never bound")
	check_eq(_count_containing(_warnings_only(messages), "needs a usable MKStatSchema"), 1,
		"with ONE warning — an authoring error, unlike the declined-feature debug line")
	check_eq(_count_containing(messages, "point-buy is disabled by default"), 0,
		"and NOT the null-schema line: a schema that is present but unusable is a different mistake with a different fix")

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
