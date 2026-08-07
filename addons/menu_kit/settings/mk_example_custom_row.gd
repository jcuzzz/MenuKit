@tool
class_name MKExampleCustomRow
extends HBoxContainer
## The shipped [constant MKSettingDef.RowType.CUSTOM] example — documentation by code.
##
## CUSTOM is the escape hatch for the closed row-type enum: when a host needs a control MenuKit does
## not ship (a colour picker, a segmented switch, a calibration widget), it authors a scene and points
## a [MKSettingDef] at it. This is the smallest complete implementation of that contract, and the
## shipped Gameplay page carries a live instance so the path is exercised, not merely described.
##
## [b]The whole contract is one method[/b], called by [MKSettingsPanel] immediately after
## instantiation:
## [codeblock]
## func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void
## [/codeblock]
## A root without it is skipped with a named warning — the panel will not put an unbound control on
## screen that silently discards every change.
##
## Four rules this example demonstrates, all of which a real custom row needs:
## [br]- [b]Read through the backend by [member MKSettingDef.id][/b], never from a field of your own.
##   The store is the truth; a cached copy drifts the moment anything else writes the same id.
## [br]- [b]Tolerate a null backend.[/b] The panel renders disabled rather than refusing to build when
##   a settings slot is unassigned, so [param backend] can legitimately be null.
## [br]- [b]Write with [method MKSettingsBackend.set_value] then
##   [method MKSettingsBackend.apply_one].[/b] Instant apply is the model (D14); apply_one is targeted
##   so a custom row cannot make every other setting re-apply.
## [br]- [b]Subscribe to [signal MKSettingsBackend.setting_changed] if you want to stay live.[/b]
##   [MKSettingsPanel] re-syncs the rows IT built; it cannot write a widget it has never seen, so a
##   CUSTOM row owns that end. Without this, a host writing the same id — a revert, a load, a "reset
##   to defaults" button — moves the store while this control keeps showing the old number.
##
## Styling uses theme type variations only — MenuKit ships zero [code]add_theme_*_override[/code]
## calls, and that rule binds host-facing examples as much as core panels.

var _backend: MKSettingsBackend
var _def: MKSettingDef
var _label: Label
var _spin: SpinBox
## True while this row is writing its own control FROM the store, so the resulting
## [signal Range.value_changed] is not mistaken for the user turning the dial and written straight
## back. The panel's own rows carry the identical guard.
var _syncing := false


## The bind contract. Called once, before this node is parented, so it may size itself from the value
## it reads.
func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void:
	_backend = backend
	_def = def
	_build()
	# Subscribing is the row's own job (see the class doc). No disconnect is written anywhere: Godot
	# drops connections whose receiver is freed, and this node is freed by the panel's rebuild.
	if _backend != null and not _backend.setting_changed.is_connected(_on_setting_changed):
		_backend.setting_changed.connect(_on_setting_changed)


## Follows external writes to this row's id. Guarded against ids that are not ours and against
## re-entering our own write.
func _on_setting_changed(id: StringName, _value: Variant) -> void:
	if _syncing or _def == null or id != _def.id:
		return
	if _spin == null or not is_instance_valid(_spin):
		return
	_syncing = true
	_spin.value = _read_number()
	_syncing = false


func _build() -> void:
	_label = Label.new()
	_label.text = _def.label if _def != null and not _def.label.is_empty() else "Custom row"
	_label.custom_minimum_size = Vector2(MKSettingsPanel.LABEL_COLUMN_WIDTH, 0.0)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MKTheme.set_variation(_label, MKTheme.ROW_LABEL)
	add_child(_label)

	_spin = SpinBox.new()
	_spin.min_value = _def.min_value if _def != null else 0.0
	_spin.max_value = _def.max_value if _def != null else 100.0
	_spin.step = _def.step if _def != null and _def.step > 0.0 else 1.0
	_spin.value = _read_number()
	# Null backend means "display only" — the panel already warned once for the whole page, so this
	# stays silent rather than repeating the same diagnosis per row.
	_spin.editable = _backend != null
	_spin.value_changed.connect(_on_value_changed)
	add_child(_spin)

	if _def != null and not _def.tooltip.is_empty():
		tooltip_text = _def.tooltip
		_spin.tooltip_text = _def.tooltip


func _read(fallback: Variant) -> Variant:
	if _backend == null or _def == null:
		return _def.default_value if _def != null and _def.default_value != null else fallback
	return _backend.get_value(_def.id, _def.default_value if _def.default_value != null else fallback)


## The store's value as a number the SpinBox can take. [code]float(null)[/code] is a script error, not
## a zero, and a store can legitimately hold a null — so the read is coerced in ONE place that both
## the build and the sync go through.
func _read_number() -> float:
	var raw: Variant = _read(0.0)
	return float(raw) if raw != null else 0.0


func _on_value_changed(value: float) -> void:
	if _syncing or _backend == null or _def == null:
		return
	_backend.set_value(_def.id, value)
	# Plain ids are no-ops in apply_one — the host consumes them — but it is called anyway: a custom
	# row must not need to know whether its id happens to be reserved.
	_backend.apply_one(_def.id)
