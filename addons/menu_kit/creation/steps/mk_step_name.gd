@tool
class_name MKStepName
extends Control
## The name step: one [LineEdit], one inline reason, and the payload key [code]name[/code]
## (plan §4.5).
##
## [b]Every invalid state says WHY, in place.[/b] A greyed-out Next with no explanation is the single
## most common way a creation screen dead-ends a player: the button is off, the field looks fine, and
## nothing on screen connects the two. So the label under the field always carries the current reason —
## too short, too long, a character that is not allowed, or a name already taken.
##
## [b]The availability check is a PRE-CHECK, not the authority.[/b] [MKProfileBackend]'s refusals are
## silent by contract (an empty dictionary from [method MKProfileBackend.create_profile]), which is
## exactly why this step asks [method MKProfileBackend.is_name_available] before letting the player walk
## forward — the alternative is discovering the collision after four more steps of work. It cannot be
## authoritative: another route can take the name between here and Confirm, and the host handles THAT
## as a refusal on the last step. Two checks, two jobs, neither redundant.
##
## A null backend is legal (the host builds disabled and warned once): availability is then unknowable,
## so the step validates on FORMAT alone rather than blocking on a question nobody can answer.

signal step_state_changed()

## The payload key this step owns. A constant rather than a literal in three places, because the
## ownership assertion, the commit and the doc must not be able to drift apart.
const PAYLOAD_KEY := "name"

## Trimmed length bounds. Two so a name is at least pronounceable and a stray keypress is not a
## character; twenty-four because it has to fit a roster row, a save-file label and a nameplate without
## the host having to truncate it everywhere.
const MIN_LENGTH := 2
const MAX_LENGTH := 24

## Letters, digits, spaces, underscore and hyphen. Deliberately conservative: this string ends up in a
## file name in the shipped JSON backend and in whatever the host does with it afterwards, and the
## characters excluded here are the ones that make that a problem (path separators, quotes, control
## characters) rather than a stylistic preference.
const ALLOWED_PATTERN := "^[A-Za-z0-9 _-]+$"

var _host: MKCreationHost
var _def: MKCreationStepDef
var _backend: MKProfileBackend
var _edit: LineEdit
var _reason: Label
var _regex: RegEx


func _ready() -> void:
	# @tool guard: the UI is built at bind, but an editor-opened instance must still not materialise
	# anything into the scene that instanced it.
	if Engine.is_editor_hint():
		return


## Declared BEFORE the bind and answerable without a context — see [method MKCreationHost.configure]
## for why the host settles ownership first.
func _mk_step_owned_keys() -> Array[String]:
	return [PAYLOAD_KEY]


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	_host = host
	_def = def
	# Null-guarded reads throughout: the ctx values are documented as possibly-null, and String(null) /
	# a null cast in a typed local is a script error rather than a graceful empty.
	var backend_variant: Variant = ctx.get("profile_backend", null)
	_backend = backend_variant as MKProfileBackend if backend_variant != null else null
	_regex = RegEx.new()
	_regex.compile(ALLOWED_PATTERN)
	_build()
	# Seeded from the payload the host handed over, so returning to this step through Back shows what
	# was committed rather than an empty field. The ctx payload is a copy; the live one is only ever
	# written through _mk_step_commit.
	var payload_variant: Variant = ctx.get("payload", null)
	if payload_variant is Dictionary:
		var existing: Variant = (payload_variant as Dictionary).get(PAYLOAD_KEY, null)
		if existing != null:
			_edit.text = String(existing)
	_refresh_reason()


func _mk_step_is_valid() -> bool:
	return _validation_error().is_empty()


func _mk_step_commit(payload: Dictionary) -> void:
	# The TRIMMED name is what is stored — the value the validation actually approved. Committing the
	# raw field would persist trailing spaces that every later comparison (uniqueness, display, file
	# naming) would have to strip again, in more places than one.
	payload[PAYLOAD_KEY] = _current_name()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(column)

	var prompt := Label.new()
	prompt.name = "Prompt"
	prompt.text = "Name"
	MKTheme.set_variation(prompt, MKTheme.ROW_LABEL)
	column.add_child(prompt)

	_edit = LineEdit.new()
	_edit.name = "NameEdit"
	# The engine's own cap, set from the same constant as the validation: letting the player type past
	# the limit and only then telling them it is too long is a worse gesture than stopping the keystroke.
	# The length rule is still CHECKED below, because a host can assign text programmatically and because
	# max_length says nothing about the minimum.
	_edit.max_length = MAX_LENGTH
	# Editable even with no backend, unlike a settings row. The host has already disabled the navigation
	# that would persist anything, and a field the player cannot type into says "broken" where a field
	# that types but cannot be confirmed says "unassigned backend", which is the truth.
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.text_changed.connect(_on_text_changed)
	# Submitting is not "advance": the host owns navigation, and a step that pressed Next on the host's
	# behalf would fire before the host had re-polled validity.
	_edit.text_submitted.connect(func(_text: String) -> void: _emit_state())
	column.add_child(_edit)

	_reason = Label.new()
	_reason.name = "Reason"
	_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MKTheme.set_variation(_reason, MKTheme.ROW_LABEL)
	column.add_child(_reason)


func _on_text_changed(_text: String) -> void:
	_refresh_reason()
	_emit_state()


func _emit_state() -> void:
	step_state_changed.emit()


func _current_name() -> String:
	if _edit == null or not is_instance_valid(_edit):
		return ""
	return _edit.text.strip_edges()


## The single source of both the gate and the message — one function, so the reason shown can never
## disagree with the reason Next is disabled. Returns "" when the name is acceptable.
func _validation_error() -> String:
	var value := _current_name()
	if value.length() < MIN_LENGTH:
		if value.is_empty():
			return "Enter a name."
		return "Names must be at least %d characters." % MIN_LENGTH
	if value.length() > MAX_LENGTH:
		return "Names must be at most %d characters." % MAX_LENGTH
	if _regex == null or _regex.search(value) == null:
		return "Use letters, numbers, spaces, underscores or hyphens only."
	# Availability last, because it is the only check that costs a backend call and the only one that can
	# be unanswerable. With no backend the format rules stand alone — see the class doc.
	if _backend != null and is_instance_valid(_backend) and not _backend.is_name_available(value):
		return "That name is already taken."
	return ""


func _refresh_reason() -> void:
	if _reason == null or not is_instance_valid(_reason):
		return
	var error := _validation_error()
	# The label is never emptied to a blank line that reflows the step on every keystroke: a valid name
	# gets an affirmative instead, so the column height is stable while typing.
	_reason.text = error if not error.is_empty() else "Looks good."
