@tool
class_name MKStepPointBuy
extends Control
## The point-buy step: one row per [MKStatDef], a live remaining-points readout, and the payload key
## [code]stats[/code] (plan §4.5, D17).
##
## [b]MenuKit never interprets a stat.[/b] It counts points and renders authored text. There is no
## derived-value formula anywhere in this file, and [member MKStatDef.effect_hint] is shown verbatim —
## see [MKStatDef] for why a menu package that knew what Strength did would have to know every host's
## combat maths.
##
## [b]Points are spent from the per-stat minimum[/b], so [member MKStatSchema.total_points] is the
## budget ABOVE the free starting spread. The alternative — charging for the floor too — makes "everyone
## starts at 8" an arithmetic problem for the schema author, and makes the readout's meaning depend on
## the schema.
##
## [b]Disabled, not clamped.[/b] A [code]+[/code] that would exceed the pool or the stat's ceiling is
## disabled rather than pressable-and-ignored: a button that visibly does nothing reads as a broken
## step, where a disabled one states the rule.
##
## [b]Disabled by default[/b] (D17): with no [MKStatSchema] supplied this step is DROPPED by the host
## entirely, which is what [method _mk_step_requires_stat_schema] tells it. Most flows are name plus
## archetype and should pay nothing for a feature they declined.

signal step_state_changed()

const PAYLOAD_KEY := "stats"

## Label column width, shared with the settings panel's rhythm so a host mixing the two screens gets one
## alignment rather than two.
##
## The label is given this as a MINIMUM and is deliberately NOT expand-filled: on a settings row the
## label and its control both expand, so the two share the width and the control column lands in the
## middle. Here the -/value/+ cluster does not expand, so an expanding label absorbed every spare pixel
## and shoved the buttons against the far edge — a stat name at x=0 with its counter a thousand pixels
## away is two rows, not one. Fixed column, cluster immediately beside it.
const LABEL_COLUMN_WIDTH := MKSettingsPanel.LABEL_COLUMN_WIDTH

var _host: MKCreationHost
var _def: MKCreationStepDef
var _schema: MKStatSchema
## Only the stats that passed [method MKStatDef.is_valid], in authored order.
var _stats: Array[MKStatDef] = []
## Current value per stat, same index as [member _stats]. Held as an array rather than keyed by id so a
## schema that repeats an id still renders two independent rows instead of two rows fighting over one
## entry — the payload write is the only place the duplicate collapses, and it says so.
var _values: Array[int] = []
var _value_labels: Array[Label] = []
var _minus_buttons: Array[Button] = []
var _plus_buttons: Array[Button] = []
var _remaining_label: Label
var _rows_column: VBoxContainer


func _ready() -> void:
	if Engine.is_editor_hint():
		return


## The D17 opt-out marker the host reads BEFORE binding: true means "drop me when no schema was
## supplied". Optional in the contract, so no other step has to implement it.
func _mk_step_requires_stat_schema() -> bool:
	return true


func _mk_step_owned_keys() -> Array[String]:
	return [PAYLOAD_KEY]


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	_host = host
	_def = def
	var raw: Variant = ctx.get("stat_schema", null)
	_schema = raw as MKStatSchema if raw != null else null
	_collect_stats()
	_build()
	# Restore a previous allocation when the player came back through Back. Values are validated against
	# the CURRENT schema on the way in rather than trusted: the payload may carry an allocation made
	# before a host reconfigured the flow, and an out-of-range restore would render a row the buttons
	# cannot bring back into legality.
	var payload_variant: Variant = ctx.get("payload", null)
	if payload_variant is Dictionary:
		var existing: Variant = (payload_variant as Dictionary).get(PAYLOAD_KEY, null)
		if existing is Dictionary:
			_restore(existing as Dictionary)
	_refresh()


func _mk_step_is_valid() -> bool:
	if _stats.is_empty():
		return false
	if _remaining() < 0:
		# Not reachable through the buttons, which disable first. Reachable through a restore of an
		# allocation made under a bigger pool, and an over-spend must not be walkable past.
		return false
	if _schema != null and _schema.require_full_spend:
		return _remaining() == 0
	return true


func _mk_step_commit(payload: Dictionary) -> void:
	var stats: Dictionary = {}
	for i in _stats.size():
		# String keys, not StringName: the payload round-trips through JSON in the shipped backend, and a
		# key whose type depends on whether the profile has been saved yet is a bug waiting on a load.
		# A repeated id collapses here, LAST write winning — said out loud rather than silently, because
		# the schema rendered two rows and the profile will carry one field.
		var key := String(_stats[i].id)
		if stats.has(key):
			MKLog.warn("%s: stat id '%s' appears more than once in the schema — the rows are independent but the payload carries ONE field, and the last row wins"
				% [MKLog.context(_schema, "stats"), key])
		stats[key] = _values[i]
	payload[PAYLOAD_KEY] = stats


func _collect_stats() -> void:
	_stats.clear()
	_values.clear()
	if _schema == null:
		# Reachable only if a host bound this scene outside MKCreationHost (which drops it instead). The
		# step renders its empty state and reports invalid rather than dividing a null budget.
		MKLog.warn("%s: point-buy step '%s' was bound with no MKStatSchema — it has nothing to allocate"
			% [MKLog.context(_def, "scene"), _def.id if _def != null else &"<unknown>"])
		return
	for stat in _schema.stats:
		if stat == null:
			continue
		if not stat.is_valid():
			MKLog.warn("%s: stat has no id, or a max_value below its min_value — the row is not rendered"
				% MKLog.context(stat))
			continue
		_stats.append(stat)
		_values.append(stat.min_value)


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_value_labels.clear()
	_minus_buttons.clear()
	_plus_buttons.clear()

	var column := VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(column)

	_remaining_label = Label.new()
	_remaining_label.name = "Remaining"
	MKTheme.set_variation(_remaining_label, MKTheme.HEADER)
	column.add_child(_remaining_label)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	_rows_column = VBoxContainer.new()
	_rows_column.name = "Rows"
	_rows_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_column)

	for i in _stats.size():
		_rows_column.add_child(_build_row(i))


## One stat: a labelled counter line, with the authored [member MKStatDef.effect_hint] beneath it.
##
## The hint is its own line rather than a tooltip because it is the only thing on screen that says what
## the number DOES, and a player deciding how to spend a pool should not have to hover each row to find
## out. [member MKStatDef.description] is the tooltip — the longer text that is fine to hide.
func _build_row(index: int) -> Control:
	var stat := _stats[index]

	var group := VBoxContainer.new()
	group.name = "Stat_" + String(stat.id)

	var row := HBoxContainer.new()
	row.name = "Row"
	group.add_child(row)

	var label := Label.new()
	label.name = "Label"
	label.text = stat.label if not stat.label.is_empty() else String(stat.id)
	label.custom_minimum_size = Vector2(LABEL_COLUMN_WIDTH, 0.0)
	MKTheme.set_variation(label, MKTheme.ROW_LABEL)
	row.add_child(label)

	# Focusable Buttons, not a SpinBox: D12 promises full gamepad navigation, and two discrete buttons
	# are what a d-pad drives well. They also make the pool rule visible — a disabled + IS the statement
	# that the points ran out.
	var minus := Button.new()
	minus.name = "Decrement"
	minus.text = "-"
	minus.focus_mode = Control.FOCUS_ALL
	minus.tooltip_text = "Lower %s" % label.text
	MKTheme.set_variation(minus, MKTheme.PANEL_BUTTON)
	minus.pressed.connect(func() -> void: _adjust(index, -1))
	row.add_child(minus)
	_minus_buttons.append(minus)

	var value := Label.new()
	value.name = "Value"
	value.custom_minimum_size = Vector2(48.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MKTheme.set_variation(value, MKTheme.ROW_LABEL)
	row.add_child(value)
	_value_labels.append(value)

	var plus := Button.new()
	plus.name = "Increment"
	plus.text = "+"
	plus.focus_mode = Control.FOCUS_ALL
	plus.tooltip_text = "Raise %s" % label.text
	MKTheme.set_variation(plus, MKTheme.PANEL_BUTTON)
	plus.pressed.connect(func() -> void: _adjust(index, 1))
	row.add_child(plus)
	_plus_buttons.append(plus)

	if not stat.description.is_empty():
		row.tooltip_text = stat.description
		label.tooltip_text = stat.description

	if not stat.effect_hint.is_empty():
		var hint := Label.new()
		hint.name = "EffectHint"
		hint.text = stat.effect_hint
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		MKTheme.set_variation(hint, MKTheme.ROW_LABEL)
		group.add_child(hint)

	return group


## Cost of one increment of [param index], never below 1.
##
## A zero or negative cost is meaningless — free points make the pool decorative, and a refunding stat
## is an infinite budget — so it is clamped and said at debug level rather than obeyed. Dividing by it
## is not the hazard (nothing divides); handing an author an unspendable pool silently is.
func _cost(index: int) -> int:
	var cost := _stats[index].cost_per_point
	if cost >= 1:
		return cost
	MKLog.debug("%s: stat '%s' has cost_per_point %d — treated as 1"
		% [MKLog.context(_stats[index], "cost_per_point"), _stats[index].id, cost])
	return 1


## Points spent above the baseline. See the class doc for why the floor is free.
func _spent() -> int:
	var total := 0
	for i in _stats.size():
		total += (_values[i] - _stats[i].min_value) * _cost(i)
	return total


func _remaining() -> int:
	var pool := _schema.total_points if _schema != null else 0
	return pool - _spent()


## The one mutation path, so every change goes through the same legality check the buttons display.
## Guarded even though the buttons are disabled: a keyboard activation can race a refresh.
func _adjust(index: int, delta: int) -> void:
	if index < 0 or index >= _stats.size():
		return
	var stat := _stats[index]
	var next_value := _values[index] + delta
	if next_value < stat.min_value or next_value > stat.max_value:
		return
	if delta > 0 and _cost(index) > _remaining():
		return
	_values[index] = next_value
	_refresh()
	step_state_changed.emit()


## Applies a previously committed allocation, honouring each stat's own min/max and dropping anything
## outside it. Out-of-range and unknown ids are dropped silently: a restore is not an authoring event,
## and the player has the buttons in front of them either way.
##
## [b]The POOL is not honoured here, only the per-stat ranges.[/b] A stored allocation whose values are
## each individually legal but together cost more than [member MKStatSchema.total_points] — a payload
## from a schema that has since shrunk its pool — is restored as-is, so the readout shows a NEGATIVE
## "points remaining" and [method _mk_step_is_valid]'s [code]_remaining() < 0[/code] check gates Next
## until the player spends their way back into budget. That is the intended shape rather than an
## oversight: silently clamping somebody's allocation to fit would discard choices without saying so,
## and the negative number names the problem in the same place as the buttons that fix it.
func _restore(stored: Dictionary) -> void:
	for i in _stats.size():
		var raw: Variant = stored.get(String(_stats[i].id), null)
		# typeof-gated: a payload can hold a JSON float, a string, or null, and int(null) is a script error
		# rather than a zero.
		if raw == null or not (typeof(raw) in [TYPE_INT, TYPE_FLOAT]):
			continue
		var value := int(raw)
		if value < _stats[i].min_value or value > _stats[i].max_value:
			continue
		_values[i] = value


## Redraws every value, the pool readout, and the enabled state of every button. One function for all
## three: they are three views of one number, and letting them refresh separately is how a readout ends
## up disagreeing with the buttons that produced it.
func _refresh() -> void:
	var remaining := _remaining()
	if _remaining_label != null and is_instance_valid(_remaining_label):
		_remaining_label.text = "Points remaining: %d" % remaining
		if _schema != null and _schema.require_full_spend and remaining > 0:
			# The gating reason, in place. The host disables Next; without this line nothing on screen
			# connects that to the number.
			_remaining_label.text += "  (spend them all to continue)"
	for i in _stats.size():
		if i < _value_labels.size() and is_instance_valid(_value_labels[i]):
			_value_labels[i].text = str(_values[i])
		if i < _minus_buttons.size() and is_instance_valid(_minus_buttons[i]):
			_minus_buttons[i].disabled = _values[i] <= _stats[i].min_value
		if i < _plus_buttons.size() and is_instance_valid(_plus_buttons[i]):
			_plus_buttons[i].disabled = _values[i] >= _stats[i].max_value or _cost(i) > remaining
