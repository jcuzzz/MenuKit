@tool
class_name MKCreationHost
extends Control
## The character creation flow: an ordered [MKCreationStepDef] array, one shared payload, and the
## navigation around them (plan §4.5).
##
## [b]This is not a page.[/b] It is a Control a panel embeds, and it emits [signal creation_confirmed]
## / [signal creation_cancelled] instead of navigating anywhere itself. Creation is reached from a
## character SELECT screen in some hosts, from a "New Game" button in others, and from a modal in a
## third; a host that owns navigation can put this anywhere, whereas a host that had to accept
## MenuKit's idea of "where you go after Confirm" would fork it on the first disagreement.
##
## [b]The payload is opaque and the host never interprets it.[/b] Steps write their declared keys into
## one [Dictionary], an archetype seeds defaults into it, and on Confirm it goes VERBATIM to
## [method MKProfileBackend.create_profile]. MenuKit does not know what "class" or "stats" mean — the
## same boundary [MKProfileBackend] draws, and the reason the same flow can produce an ARPG character
## or an FPS loadout.
##
## [b]Key ownership is asserted, loudly.[/b] Every step declares the payload keys it writes, and two
## ENABLED steps claiming one key is a contract violation rather than a precedence question: whichever
## ran last would silently erase the other's field, and the symptom is a profile missing data with
## nothing in the log. The collision is an [method MKLog.error] naming both defs and the key, and the
## LATER step is dropped. Dropping is the loud outcome — a visibly missing step sends the author to the
## error; a silently overwritten field sends them to their save format.
##
## [b]Merge order, always:[/b] archetype defaults are seeded FIRST, step commits overwrite (the plan's
## sentence). A default is a starting point that the player's own choices win over, which is the only
## order in which "the Knight starts with 50 gold" and "the player typed a name" can both be true.
##
## [b]It is enforced by EXCLUSION, and an overwrite therefore never actually happens.[/b] Finding F8's
## check ([method _validate_archetype_defaults]) refuses, at configure and with an error naming both
## sides, any archetype default whose key a step OWNS — the default is never seeded, and
## [method notify_archetype_chosen] skips it again on every choice. So the two authors of a payload key
## are disjoint by construction: every key in the payload was written either by a seed or by a commit,
## never by both, and "steps win" is a statement about who is ALLOWED to write a key rather than about
## the order two writes landed in.
##
## [b]The exclusion holds whatever order the steps are authored in, and that takes an explicit
## mechanism.[/b] [method configure] runs in THREE passes: every surviving step's owned keys are
## claimed first (collisions resolved), THEN the archetype defaults are validated against the complete
## ownership map, and only THEN is any step scene bound. The order matters because binding is not inert
## — [MKStepArchetype] auto-selects its first card at bind and calls
## [method notify_archetype_chosen] from there, so a seed can happen DURING the build. Claiming every
## key before the first bind runs is what makes that seed consult a finished map rather than a
## half-built one; with the passes interleaved, an archetype step declared before the step that owns
## [code]name[/code] seeded that key while the F8 error line said it had not been.
##
## What IS ordered — and is a real invariant — is that a seed for an UNOWNED key survives
## from [method notify_archetype_chosen] through to [method _confirm] unless the player changes
## archetype, at which point exactly that choice's own keys are cleared and no others.
##
## [b]A null backend is not an error[/b] — the same policy [MKSettingsPanel] applies to a null settings
## backend. The flow builds, warns ONCE, and renders its navigation disabled. A creation screen that
## refused to appear because a slot was unassigned is indistinguishable from a crashed page, and the
## host's actual mistake goes unnamed.

## The stored profile [method MKProfileBackend.create_profile] returned — never the raw payload, since
## the backend assigns the id and may normalise fields.
signal creation_confirmed(profile: Dictionary)

## Cancel was pressed. The embedding panel decides what that means (back to select, back to the main
## menu, close a modal); this host has no opinion and no navigation of its own.
signal creation_cancelled()

## Emitted after [method configure] has finished building the flow, so tests and hosts act on a real
## tree rather than guessing at a frame boundary. Same convention as [signal MKSettingsPanel.built].
signal built()

## Shown on the last step when [method MKProfileBackend.create_profile] returns an empty dictionary.
## Inline on the host rather than as a modal, deliberately: the fix is on this screen (change the
## name), so a dialog the player must dismiss before they can reach the field adds a gesture and hides
## the field behind a scrim.
const REFUSAL_MESSAGE := "Could not create the character. The name may have just been taken, or the roster may be full."

const NO_BACKEND_MESSAGE := "No profile backend is assigned, so nothing can be saved."

var _steps: Array[MKCreationStepDef] = []
## The instantiated step scene root for each entry of [member _steps], same order, same size. Built
## eagerly at [method configure] because the ownership assertion needs every step's declared keys
## BEFORE the first one is shown — a check deferred to "when you reach step 4" is a check that fires in
## front of the player rather than in front of the author.
var _step_nodes: Array[Control] = []
var _archetypes: Array[MKArchetype] = []
var _backend: MKProfileBackend
var _schema: MKStatSchema

## The shared payload. Never read for meaning, only merged and handed over.
var _payload: Dictionary = {}
## Payload key -> the [MKCreationStepDef] that claimed it, for the duplicate-key assertion and for the
## F8 archetype-default check.
var _owned_by: Dictionary = {}
## Keys the CURRENT archetype's defaults seeded, so re-choosing clears exactly what the previous choice
## put in and nothing else. Erasing the whole payload instead would take the player's typed name with
## it when they changed their mind about the class.
var _seeded_keys: Array[String] = []
## The archetype whose defaults are currently seeded, so a repeat notification is a cheap no-op.
var _seeded_archetype: MKArchetype

var _index := 0
## Set when [method MKProfileBackend.create_profile] refused the payload, and cleared as soon as every
## step answers valid again. While it is set, Confirm is gated on the WHOLE flow — see [method _confirm].
var _refusal_pending := false
var _title_label: Label
var _progress_label: Label
var _content: MarginContainer
var _message_label: Label
var _back_button: Button
var _skip_button: Button
var _next_button: Button
var _cancel_button: Button
var _footer: HBoxContainer
var _built := false


func _ready() -> void:
	# @tool guard: without it, opening a scene that embeds this host materialises the whole UI as
	# unowned children that get saved into whatever scene instanced it.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Builds (or rebuilds) the entire flow. This is the ONE entry point: there is no incremental
## "add_step", because the duplicate-key assertion and the F8 archetype check are both statements about
## the whole set, and a set that can be mutated afterwards can be mutated back into the state the
## assertion refused.
##
## [param profile_backend] may be null — see the class doc for why that builds disabled rather than
## refusing. [param stat_schema] may be null, which DROPS a point-buy step from [param steps] with a
## debug line: point-buy is disabled by default (D17), so declining it is normal operation and not
## something to warn about. A schema that is present but fails [method MKStatSchema.is_valid] drops the
## same step with a WARNING naming the resource — that one is an authoring mistake, not a declined
## feature.
##
## The step contract, in the order this method exercises it — note that every step's step 1 runs before
## any step's step 2, which is the ordering the class doc's exclusion paragraph depends on:
## [br]1. [code]_mk_step_owned_keys() -> Array[String][/code] — the payload keys this step writes.
##   Called BEFORE the bind, which is why it must be a static declaration and not a function of the
##   context: a step that loses the ownership race is dropped, and calling its bind first would leave
##   its side effects (signal subscriptions, host notifications) behind with nothing on screen.
## [br]2. [code]_mk_step_bind(host, def, ctx)[/code] — hand over the context and build the widgets.
##   [code]ctx[/code] carries [code]"archetypes"[/code], [code]"profile_backend"[/code] (may be null),
##   [code]"stat_schema"[/code] (may be null) and [code]"payload"[/code], the last being a DUPLICATE
##   rather than the live dictionary, so a step cannot write the payload by a route the ownership
##   assertion cannot see.
## [br]3. [code]step_state_changed[/code] — emitted by the step on any input change that could alter
##   validity; the host re-polls [code]_mk_step_is_valid()[/code] and re-gates Next.
## [br]4. [code]_mk_step_commit(payload)[/code] — write the owned keys. Called on Next and on Confirm,
##   never on Skip, and never on Back (which deliberately leaves the visited step's committed keys in
##   place; returning forward recommits over them).
##
## An optional fifth method, [code]_mk_step_requires_stat_schema() -> bool[/code], is how a step
## declares itself point-buy-shaped for the drop rule above. Absent means "does not need one", so no
## host step has to implement it.
func configure(steps: Array[MKCreationStepDef], archetypes: Array[MKArchetype],
		profile_backend: MKProfileBackend, stat_schema: MKStatSchema) -> void:
	_teardown()
	# assign() rather than `= archetypes.duplicate()`: Array.duplicate() is declared as returning an
	# untyped Array, so the assignment is an unsafe narrowing the compiler is entitled to reject.
	# assign() copies element-wise into the typed array and is the sanctioned form.
	_archetypes.assign(archetypes)
	_backend = profile_backend
	_schema = stat_schema
	_payload = {}
	_owned_by = {}
	_seeded_keys = []
	_seeded_archetype = null
	_index = 0
	_refusal_pending = false

	if _backend == null:
		# ONE warning for the whole flow, not one per step — the settings panel's rule, for the same
		# reason: a four-step flow would otherwise print the same diagnosis four times for one unassigned
		# slot and bury everything else.
		MKLog.warn("%s: no MKProfileBackend supplied — the flow builds with navigation disabled and nothing can be created"
			% _context("configure"))

	_build_shell()
	# Three passes, and the order is load-bearing — see the class doc. Binding is the only one of them
	# with side effects, so it runs last, after ownership and the archetype defaults are both settled.
	_accept_steps(steps)
	_validate_archetype_defaults()
	_bind_steps()

	if _step_nodes.is_empty():
		# A flow with no usable step is not something to render half of. Said out loud and left showing
		# the shell, so the screen names its own problem instead of appearing as an empty rectangle.
		MKLog.warn("%s: no usable steps — check that each def has an id and a scene whose root implements _mk_step_bind"
			% _context("configure"))
		_message_label.text = "This creation flow has no steps."
		_message_label.visible = true
	else:
		_show_step(0)

	_built = true
	built.emit()


## A read-only copy of the shared payload. Deep, so a caller poking the returned dictionary's nested
## [code]stats[/code] sub-dictionary cannot reach the live one either — a shallow copy of a payload
## whose values are themselves containers is not a copy of the payload.
func get_payload() -> Dictionary:
	return _payload.duplicate(true)


func current_step_index() -> int:
	return _index


## Number of steps that survived [method configure]'s validation. Dropped steps are NOT counted — the
## progress indicator and this both describe the flow the player is actually walking.
func get_step_count() -> int:
	return _step_nodes.size()


## The inline message currently shown ("" when hidden). The refusal path (see [method _confirm]) is
## defined as "say so and stay on the last step", and the saying-so is the assertable half — the same
## reasoning behind [member MKLog.observer].
func get_message() -> String:
	if _message_label == null or not is_instance_valid(_message_label) or not _message_label.visible:
		return ""
	return _message_label.text


func is_built() -> bool:
	return _built


## Re-seeds [member MKArchetype.payload_defaults] for a newly chosen archetype. Called by the archetype
## step; a host step that offers its own picker calls the same method.
##
## [b]Seeding lives here and not in the step[/b] because it is a statement about the whole payload: the
## host is the only thing that knows the merge order, the only thing holding every step's owned keys,
## and the only thing that can clear the PREVIOUS choice's defaults without also clearing the player's
## typed name. A step that seeded its own would re-derive all three and get one wrong.
##
## Changing choice clears exactly the keys the last choice seeded, then seeds the new ones. Step
## commits are untouched by both halves — they overwrite defaults on the way forward, which is the
## documented merge order.
func notify_archetype_chosen(archetype: MKArchetype) -> void:
	if archetype == _seeded_archetype:
		return
	for key in _seeded_keys:
		_payload.erase(key)
	_seeded_keys.clear()
	_seeded_archetype = archetype
	if archetype == null:
		return
	for key_variant in archetype.payload_defaults.keys():
		var key := String(key_variant)
		if _owned_by.has(key):
			# Already reported ONCE, by name, in _validate_archetype_defaults at configure time. Repeating
			# the error on every card click would turn one authoring mistake into a log flood driven by the
			# player's mouse, so the skip is restated at debug level and the loud line stays where it can be
			# acted on.
			MKLog.debug("%s: skipping archetype default '%s' — a step owns that key (already reported)"
				% [MKLog.context(archetype, "payload_defaults"), key])
			continue
		_payload[key] = archetype.payload_defaults[key_variant]
		_seeded_keys.append(key)


# --- Build --------------------------------------------------------------------

func _teardown() -> void:
	_steps.clear()
	_step_nodes.clear()
	_built = false
	for child in get_children():
		# remove_child before queue_free: a queued node stays in the tree until the end of the frame, so a
		# reconfigure would briefly have two shells both answering focus queries.
		remove_child(child)
		child.queue_free()


func _build_shell() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	MKTheme.set_variation(frame, MKTheme.PANEL)
	add_child(frame)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	margin.add_child(column)

	_title_label = Label.new()
	_title_label.name = "Title"
	MKTheme.set_variation(_title_label, MKTheme.HEADER)
	column.add_child(_title_label)

	_progress_label = Label.new()
	_progress_label.name = "Progress"
	MKTheme.set_variation(_progress_label, MKTheme.ROW_LABEL)
	column.add_child(_progress_label)

	# The step's own scene goes here. One slot, one visible step: a flow that showed every step at once
	# would have no meaning for "Next" and no reason to gate validity per step.
	_content = MarginContainer.new()
	_content.name = "StepContent"
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_content)

	_message_label = Label.new()
	_message_label.name = "Message"
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.visible = false
	MKTheme.set_variation(_message_label, MKTheme.ROW_LABEL)
	column.add_child(_message_label)

	_footer = HBoxContainer.new()
	_footer.name = "Footer"
	column.add_child(_footer)

	_cancel_button = _make_button("Cancel", MKTheme.DANGER_BUTTON)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_footer.add_child(_cancel_button)

	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.add_child(spacer)

	_back_button = _make_button("Back", MKTheme.PANEL_BUTTON)
	_back_button.pressed.connect(_on_back_pressed)
	_footer.add_child(_back_button)

	_skip_button = _make_button("Skip", MKTheme.PANEL_BUTTON)
	_skip_button.pressed.connect(_on_skip_pressed)
	_footer.add_child(_skip_button)

	_next_button = _make_button("Next", MKTheme.PRIMARY_BUTTON)
	_next_button.pressed.connect(_on_next_pressed)
	_footer.add_child(_next_button)


func _make_button(text: String, variation: StringName) -> Button:
	var button := Button.new()
	button.name = text
	button.text = text
	button.focus_mode = Control.FOCUS_ALL
	MKTheme.set_variation(button, variation)
	return button


## Pass 1: validates and instantiates each def, in order, CLAIMS the owned keys of the ones that
## survive, and parents them hidden. Nothing is bound here — see [method _bind_steps].
##
## Every rejection is named and every rejection is loud enough to find, but the LEVEL differs by what
## the rejection means: a missing scene or an unimplemented contract is a host authoring mistake
## ([method MKLog.warn], the CUSTOM-row precedent); a duplicate owned key is a contract violation
## ([method MKLog.error]); a point-buy step with no schema is a supported configuration
## ([method MKLog.debug]); a point-buy step with an UNUSABLE schema is an authoring error
## ([method MKLog.warn], naming the resource).
func _accept_steps(steps: Array[MKCreationStepDef]) -> void:
	for i in steps.size():
		var def := steps[i]
		if def == null:
			MKLog.warn("%s: step entry %d is null — skipping it" % [_context("configure"), i])
			continue
		if not def.is_valid():
			MKLog.warn("%s: step entry %d has an empty id — skipping it" % [MKLog.context(def, "id"), i])
			continue
		if def.scene == null:
			MKLog.warn("%s: step '%s' has no scene — skipping it" % [MKLog.context(def, "scene"), def.id])
			continue
		var node := _instantiate_step(def)
		if node == null:
			continue
		_steps.append(def)
		_step_nodes.append(node)


## Returns the accepted (not yet bound) step root, or null when the def could not produce one. Every
## early return frees the instance it made: an orphaned instantiate is a leak the editor reports at
## exit with no hint of which step produced it.
func _instantiate_step(def: MKCreationStepDef) -> Control:
	var inst := def.scene.instantiate()
	if not inst.has_method("_mk_step_bind"):
		MKLog.warn("%s: step '%s' root does not implement _mk_step_bind(host, def, ctx) — skipping it. See mk_step_name.gd"
			% [MKLog.context(def, "scene"), def.id])
		inst.free()
		return null
	# The Control check precedes the bind for the same reason the CUSTOM row's does: the bind is where a
	# step wires signals and may call back into this host, and running that on an instance about to be
	# freed leaves the side effects behind with nothing on screen.
	var control := inst as Control
	if control == null:
		MKLog.warn("%s: step '%s' root is a %s, not a Control — skipping it"
			% [MKLog.context(def, "scene"), def.id, inst.get_class()])
		inst.free()
		return null
	if control.has_method("_mk_step_requires_stat_schema") \
			and bool(control.call("_mk_step_requires_stat_schema")):
		# D17: a point-buy step with no schema is DROPPED, quietly. See configure()'s doc.
		if _schema == null:
			MKLog.debug("%s: step '%s' needs an MKStatSchema and none was supplied — dropping it (point-buy is disabled by default)"
				% [MKLog.context(def, "scene"), def.id])
			control.free()
			return null
		# An UNUSABLE schema is the other half of the same drop, at WARN rather than debug: declining
		# point-buy is a choice, but authoring a schema with no stats or a non-positive pool is a mistake
		# — the step would render a budget readout over an empty list, or one where every + is dead from
		# the first frame. Both look like the step is broken, so the resource is named instead.
		if not _schema.is_valid():
			MKLog.warn("%s: step '%s' needs a usable MKStatSchema — this one has no valid stat or a non-positive total_points, so the step is dropped rather than rendered dead"
				% [MKLog.context(_schema, "total_points"), def.id])
			control.free()
			return null

	# Ownership is settled BEFORE any bind (pass 2), so a step that loses the race never runs any of its
	# own wiring. This is why _mk_step_owned_keys must be answerable without a context.
	var keys := _declared_keys(control, def)
	if not _claim_keys(def, keys):
		control.free()
		return null

	# Parented hidden here rather than at bind: the step's widgets are built by _mk_step_bind, and a
	# step that grabbed focus or measured itself would otherwise do so from outside the tree.
	control.visible = false
	_content.add_child(control)
	return control


## Pass 3: binds every accepted step, in order. Split from the claim pass because binding is where a
## step wires signals and may call back into this host — [MKStepArchetype] auto-selects its first card
## at bind and seeds the payload through [method notify_archetype_chosen] from there. Running that
## while the ownership map was still half-built let an archetype declared BEFORE a claiming step seed
## that step's key, and the F8 error printed at the same configure said the opposite.
func _bind_steps() -> void:
	for i in _step_nodes.size():
		var control := _step_nodes[i]
		var def := _steps[i]
		if control == null or not is_instance_valid(control):
			continue
		control.call("_mk_step_bind", self, def, _make_context())
		if control.has_signal("step_state_changed"):
			control.connect("step_state_changed", _on_step_state_changed)
		else:
			# Not fatal: a step with no mutable input (the appearance placeholder is exactly that) has
			# nothing to announce, and its validity is polled once at every _show_step anyway. Said at debug
			# level so a step that DOES have inputs and forgot the signal — the "Next stays greyed out while
			# I type" report — has a line to find.
			MKLog.debug("%s: step '%s' declares no step_state_changed signal — validity is polled on navigation only"
				% [MKLog.context(def, "scene"), def.id])


## The step's declared payload keys, defensively normalised. A step is allowed to own NOTHING (the
## appearance placeholder does), so an absent method is a debug line and an empty list, not a warning.
func _declared_keys(control: Control, def: MKCreationStepDef) -> Array[String]:
	var out: Array[String] = []
	if not control.has_method("_mk_step_owned_keys"):
		MKLog.debug("%s: step '%s' declares no _mk_step_owned_keys — treated as owning no payload keys"
			% [MKLog.context(def, "scene"), def.id])
		return out
	var raw: Variant = control.call("_mk_step_owned_keys")
	if raw == null or not (raw is Array):
		MKLog.warn("%s: step '%s' returned %s from _mk_step_owned_keys instead of an Array[String] — treating it as owning no keys"
			% [MKLog.context(def, "scene"), def.id, type_string(typeof(raw))])
		return out
	for entry in (raw as Array):
		if entry == null:
			continue
		var key := String(entry)
		if key.is_empty() or out.has(key):
			continue
		out.append(key)
	return out


## Registers [param keys] to [param def], or refuses the whole step when any of them is taken.
##
## [b]All or nothing, and the LATER step is the one dropped.[/b] Partially admitting a step — keeping
## its uncontested keys and dropping the contested one — would put a step on screen whose commit
## silently writes less than it displays, which is the failure mode this assertion exists to remove.
## Earlier wins because the array is the author's declared order and the first claim is the one every
## preceding diagnostic already refers to.
func _claim_keys(def: MKCreationStepDef, keys: Array[String]) -> bool:
	for key in keys:
		var owner_def: MKCreationStepDef = _owned_by.get(key, null)
		if owner_def != null:
			MKLog.error("%s: payload key '%s' is already owned by step '%s' (%s) and is claimed again by step '%s' (%s). Two steps writing one key means one of them is silently discarded, so the LATER step is DROPPED from the flow"
				% [MKLog.context(def, "scene"), key, owner_def.id, MKLog.context(owner_def),
					def.id, MKLog.context(def)])
			return false
	for key in keys:
		_owned_by[key] = def
	return true


## Finding F8: an archetype default whose key a step owns is an authoring error, checked ONCE at
## configure against the union of every accepted step's keys.
##
## It is an error rather than a precedence rule because the two answers are both wrong. Letting the
## default win discards what the player typed; letting the step win — which is the documented merge
## order and what actually happens — means the authored default has no effect at all and never says so.
## The archetype and the key are both named, because "an archetype default was ignored" with neither is
## a message you cannot act on.
##
## The default is refused (never seeded); the step keeps the key.
func _validate_archetype_defaults() -> void:
	for archetype in _archetypes:
		if archetype == null:
			continue
		for key_variant in archetype.payload_defaults.keys():
			var key := String(key_variant)
			var owner_def: MKCreationStepDef = _owned_by.get(key, null)
			if owner_def == null:
				continue
			MKLog.error("%s: archetype '%s' authors a payload default for '%s', but step '%s' (%s) owns that key. The step's commit always wins, so the default could never take effect — it is NOT seeded. Remove it, or move the value into the step"
				% [MKLog.context(archetype, "payload_defaults"), archetype.id, key,
					owner_def.id, MKLog.context(owner_def)])


## The bind context. [code]"payload"[/code] is a DEEP DUPLICATE: a step must write through
## [code]_mk_step_commit[/code] so the host sees every write, and handing over the live dictionary
## would offer a second route that the ownership assertion cannot police.
func _make_context() -> Dictionary:
	return {
		"archetypes": _archetypes,
		"profile_backend": _backend,
		"stat_schema": _schema,
		"payload": _payload.duplicate(true),
	}


# --- Navigation ---------------------------------------------------------------

func _show_step(index: int) -> void:
	if _step_nodes.is_empty():
		return
	_index = clampi(index, 0, _step_nodes.size() - 1)
	for i in _step_nodes.size():
		var node := _step_nodes[i]
		if node != null and is_instance_valid(node):
			node.visible = i == _index
	var def := _steps[_index]
	_title_label.text = def.title if not def.title.is_empty() else String(def.id)
	# One-based and spelled out: "Step 2 of 4" is what a player reads; a progress BAR alone cannot say
	# how many steps are left in a flow whose length the host chose.
	_progress_label.text = "Step %d of %d" % [_index + 1, _step_nodes.size()]
	_set_message("")
	_refresh_buttons()
	# Chained after every step change, not once at build: the visible set changed, and MKFocus collects
	# only what is visible in the tree — a chain built over hidden steps would walk into them.
	MKFocus.chain_container(self)
	# Focus lands in the step's CONTENT rather than on Next, so a gamepad player starts on the thing the
	# step is asking them to do. A menu that opens with nothing focused is dead to a gamepad (D12).
	var current := _step_nodes[_index]
	if current != null and is_instance_valid(current) and MKFocus.focus_first(current) == null:
		# Nothing focusable in the step itself (the appearance placeholder). Put focus on the footer so
		# the flow is still drivable without a mouse.
		MKFocus.focus_first(_footer)


func _refresh_buttons() -> void:
	if _step_nodes.is_empty():
		_back_button.disabled = true
		_skip_button.visible = false
		_next_button.disabled = true
		return
	var def := _steps[_index]
	var is_last := _index == _step_nodes.size() - 1
	# The last step's Next IS Confirm — one button, because a separate always-visible Confirm would be
	# disabled for the whole flow and read as broken.
	_next_button.text = "Confirm" if is_last else "Next"
	_back_button.disabled = _index == 0 or _backend == null
	# required beats skippable, and the def's doc says why the two flags are not one.
	_skip_button.visible = def.skippable and not def.required
	_skip_button.disabled = _backend == null
	# After a refused create, the whole flow is re-polled rather than only the current step: the step
	# whose answer changed (the name, taken by another route) is usually behind the player. See _confirm.
	var refused_and_still_invalid := _refusal_pending and not _all_steps_valid()
	_next_button.disabled = _backend == null or not _step_is_valid(_index) or refused_and_still_invalid
	if _refusal_pending and not refused_and_still_invalid:
		_refusal_pending = false


## Polls the current step's validity. A step that does not implement the method is treated as VALID:
## the alternative is a Next button that can never enable, which reads as a dead flow rather than as
## the missing method it is — and the missing method is already reported at bind time.
func _step_is_valid(index: int) -> bool:
	if index < 0 or index >= _step_nodes.size():
		return false
	var node := _step_nodes[index]
	if node == null or not is_instance_valid(node):
		return false
	if not node.has_method("_mk_step_is_valid"):
		return true
	return bool(node.call("_mk_step_is_valid"))


## True only when every step in the flow answers valid. Used exclusively by the post-refusal re-gate:
## the ordinary Next gate is per-step by design, because a step the player has not reached yet is
## legitimately incomplete.
func _all_steps_valid() -> bool:
	for i in _step_nodes.size():
		if not _step_is_valid(i):
			return false
	return true


func _on_step_state_changed() -> void:
	_refresh_buttons()


## Writes the current step's owned keys into the shared payload.
##
## Called on Next and on Confirm, never on Skip and never on Back. Back deliberately leaves what a step
## already committed in place — a Back that erased the field the player is going back to LOOK at is the
## opposite of what the gesture promises — and moving forward again recommits over it.
func _commit_current() -> void:
	if _index < 0 or _index >= _step_nodes.size():
		return
	var node := _step_nodes[_index]
	if node == null or not is_instance_valid(node) or not node.has_method("_mk_step_commit"):
		return
	node.call("_mk_step_commit", _payload)


func _on_next_pressed() -> void:
	_advance(true)


func _on_skip_pressed() -> void:
	_advance(false)


## The one forward path. [param commit] is false for Skip, which is the ONLY difference between the two
## gestures: a skipped last step still confirms, because the flow has to be finishable from wherever
## its last skippable step leaves the player.
func _advance(commit: bool) -> void:
	if _backend == null or _step_nodes.is_empty():
		return
	if commit and not _step_is_valid(_index):
		# Defensive: the button is already gated, but a keyboard activation racing a state change should
		# not be able to commit an invalid step.
		_refresh_buttons()
		return
	if commit:
		_commit_current()
	if _index < _step_nodes.size() - 1:
		_show_step(_index + 1)
		return
	_confirm()


## The end of the flow: hand the payload over verbatim and interpret only the SHAPE of the answer.
##
## An empty dictionary means REFUSED (a name taken between the step's pre-check and now, a roster cap,
## a disk failure) — [MKProfileBackend]'s refusals are silent by contract, so the host cannot say WHICH
## and does not guess. It shows one inline message and stays on the last step, where the fields that
## could fix it are.
func _confirm() -> void:
	if _backend == null:
		_set_message(NO_BACKEND_MESSAGE)
		return
	var profile := _backend.create_profile(get_payload())
	if profile.is_empty():
		MKLog.warn("%s: create_profile refused the payload — staying on the last step" % _context("_confirm"))
		_set_message(REFUSAL_MESSAGE)
		# Re-gate over EVERY step, not just the current one. The refusal is usually a name that is no
		# longer available, and the name step's own check does now agree — but that step is almost never
		# the last one, and re-polling only the current step therefore left Confirm enabled on a payload
		# the backend had just rejected, one press away from an identical refusal. So the flag below makes
		# _refresh_buttons ask the whole flow instead; it lifts as soon as every step answers valid again
		# (the player fixes the field, or navigates, which is a fresh attempt either way).
		_refusal_pending = true
		_refresh_buttons()
		return
	creation_confirmed.emit(profile)


func _on_back_pressed() -> void:
	if _index <= 0:
		return
	_show_step(_index - 1)


func _on_cancel_pressed() -> void:
	# No confirmation dialog, and no payload teardown: this host does not own the screen it is on, so
	# whoever embedded it decides whether cancelling costs a confirm and whether this instance is reused
	# or freed. Emitting and doing nothing else is the only behaviour that cannot be wrong for both.
	creation_cancelled.emit()


func _set_message(text: String) -> void:
	if _message_label == null or not is_instance_valid(_message_label):
		return
	_message_label.text = text
	_message_label.visible = not text.is_empty()


## This host is a Node, not a Resource, so [method MKLog.context] has no resource path to name. The
## script path is the identifying thing a reader needs — the settings panel's convention.
func _context(field := "") -> String:
	var script := get_script() as Script
	if script != null and not script.resource_path.is_empty():
		return MKLog.context(script.resource_path, field)
	return MKLog.context("MKCreationHost", field)
