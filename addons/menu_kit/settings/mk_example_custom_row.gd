@tool
class_name MKExampleCustomRow
extends HBoxContainer
## The shipped [constant MKSettingDef.RowType.CUSTOM] example — documentation by code (plan §3.1,
## §4.3).
##
## [constant MKSettingDef.RowType.CUSTOM] is the escape hatch for the closed row-type enum: when a
## host needs a control MenuKit does not ship (a colour picker, a three-way segmented switch, a
## calibration widget), it authors a scene and points a [MKSettingDef] at it. This is the smallest
## complete implementation of that contract, and the Gameplay page carries a live instance of it so
## the path is exercised by the shipped defaults rather than only described in a document.
##
## [b]The whole contract is one method[/b], called by [MKSettingsPanel] immediately after
## instantiation:
## [codeblock]
## func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void
## [/codeblock]
## A root without it is skipped with a named warning — the panel will not put an unbound control on
## screen that silently discards every change.
##
## Three rules this example demonstrates, all of which a real custom row needs:
## [br]- [b]Read through the backend by [member MKSettingDef.id][/b], never from a field of your own.
##   The store is the truth; a cached copy drifts the moment anything else writes the same id.
## [br]- [b]Tolerate a null backend.[/b] The panel renders disabled rather than refusing to build when
##   a settings slot is unassigned, so [param backend] can legitimately be null.
## [br]- [b]Write with [method MKSettingsBackend.set_value] then
##   [method MKSettingsBackend.apply_one].[/b] Instant apply is the model (D14); apply_one is targeted
##   so a custom row cannot make every other setting re-apply.
##
## Styling uses theme type variations only — MenuKit ships zero [code]add_theme_*_override[/code]
## calls (plan §1.2, ship gate 1), and that rule binds host-facing examples as much as core panels,
## because an example is the thing people copy.

var _backend: MKSettingsBackend
var _def: MKSettingDef
var _label: Label
var _spin: SpinBox


## The bind contract. Called once, before this node is parented, so it may size itself from the value
## it reads.
func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void:
	_backend = backend
	_def = def
	_build()


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
	_spin.value = float(_read(0.0))
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


func _on_value_changed(value: float) -> void:
	if _backend == null or _def == null:
		return
	_backend.set_value(_def.id, value)
	# Plain ids are no-ops in apply_one — the host consumes them (plan §4.3). Calling it anyway is
	# deliberate: a custom row must not need to know whether its id happens to be reserved, and the
	# copy-paste target for the next host's row should carry the complete gesture.
	_backend.apply_one(_def.id)
