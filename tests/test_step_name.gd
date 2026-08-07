extends MKTest
## The name step's inline reason label.
##
## [b]The rule under test:[/b] every invalid state says WHY, in place. A greyed-out Next with no
## explanation is the most common way a creation screen dead-ends a player, and the hard case is the
## one input the player does not drive — AVAILABILITY: a name that becomes taken while the step sits
## open disables Next with no keystroke to trigger a re-render.
##
## [b]Why polling is the whole mechanism.[/b] [MKProfileBackend] has no "availability changed" signal
## to subscribe to; the host's [code]_mk_step_is_valid[/code] poll on every navigation and state change
## is the only moment this step ever hears about it. So the assertion drives that poll, exactly as the
## host does, rather than pushing a signal the contract does not have.
##
## The step is bound directly (no [MKCreationHost]) because the label is the step's own contract, and a
## whole flow around it would put the host's gating between the assertion and the thing it is about.


func run_tests() -> void:
	await _test_the_reason_follows_an_availability_flip_under_unchanged_text()
	await _test_the_reason_still_tracks_ordinary_typing()


## Text unchanged, answer flipped. Nothing the player did causes a re-render, so the only place the
## label can be repaired is the validity poll itself.
func _test_the_reason_follows_an_availability_flip_under_unchanged_text() -> void:
	var backend := FlipBackend.new()
	get_root().add_child(backend)
	var step := await _bind(backend)

	_edit(step).text = "Aldric"
	_edit(step).text_changed.emit("Aldric")
	check(step._mk_step_is_valid(), "precondition: the name is available, so the step is valid")
	check_eq(_reason(step).text, "Looks good.", "and the label says so")

	backend.available = false
	check(not step._mk_step_is_valid(),
		"the poll picks up the flip — availability is checked on every ask, not cached from the keystroke")
	check_eq(_reason(step).text, "That name is already taken.",
		"and the LABEL moved with it, under text the player never touched — a disabled Next over 'Looks good.' is the dead end this step exists to prevent")

	backend.available = true
	check(step._mk_step_is_valid(), "the flip back re-validates")
	check_eq(_reason(step).text, "Looks good.",
		"and the reason clears too, rather than leaving a stale refusal over a name that is now fine")

	await _drop(step, backend)


## The ordinary path must keep working: the poll-side repair is an ADDITION to the text_changed
## refresh — a step that only updated its label on a validity FLIP goes silent while the player types
## through two different invalid reasons.
func _test_the_reason_still_tracks_ordinary_typing() -> void:
	var backend := FlipBackend.new()
	get_root().add_child(backend)
	var step := await _bind(backend)

	check_eq(_reason(step).text, "Enter a name.", "an empty field asks for one")
	_edit(step).text = "A"
	_edit(step).text_changed.emit("A")
	check_eq(_reason(step).text, "Names must be at least 2 characters.",
		"one character names the length rule")
	_edit(step).text = "A!"
	_edit(step).text_changed.emit("A!")
	check_eq(_reason(step).text, "Use letters, numbers, spaces, underscores or hyphens only.",
		"and a disallowed character names the character rule — two invalid states, two different reasons, both while the step's ANSWER stayed false")

	await _drop(step, backend)


# --- Fixtures -----------------------------------------------------------------

func _bind(backend: MKProfileBackend) -> MKStepName:
	var scene := load("res://addons/menu_kit/creation/steps/mk_step_name.tscn") as PackedScene
	var step := scene.instantiate() as MKStepName
	get_root().add_child(step)
	var def := MKCreationStepDef.new()
	def.id = &"name"
	step._mk_step_bind(null, def, {"archetypes": [], "profile_backend": backend,
		"stat_schema": null, "payload": {}})
	await step_frame()
	return step


func _edit(step: MKStepName) -> LineEdit:
	return step.find_child("NameEdit", true, false) as LineEdit


func _reason(step: MKStepName) -> Label:
	return step.find_child("Reason", true, false) as Label


func _drop(step: Node, backend: Node) -> void:
	if step != null and is_instance_valid(step):
		step.queue_free()
	if backend != null and is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()


## A backend whose availability answer can be flipped between polls — the other route taking the name,
## compressed to one flag.
##
## The roster methods are implemented as empties rather than left to the base, because
## [MKProfileBackend] declares them abstract: a subclass that skipped them is a PARSE error, which is
## the base asserting that a backend answering half its contract is not a backend. The name step reads
## none of them — it asks [method MKProfileBackend.is_name_available] and nothing else, which is what
## makes the flip the only variable in this suite.
class FlipBackend extends MKProfileBackend:
	var available := true

	func is_name_available(_profile_name: String) -> bool:
		return available

	func list_profiles() -> Array[Dictionary]:
		return []

	func create_profile(_payload: Dictionary) -> Dictionary:
		return {}

	func delete_profile(_id: String) -> bool:
		return false

	func load_profile(_id: String) -> Dictionary:
		return {}
