@tool
class_name MKConfirmDialog
extends Control
## A generic 2–3 button confirm modal pushed onto an [MKModalLayer].
##
## Phase 1 needs it for the root quit-confirm; Phase 5 reuses it for character deletion and Phase 4
## for rebind conflicts, so it carries NO roster or settings vocabulary — title, body and button
## texts are arguments. That genericity is the point: a second, near-identical dialog script would
## be exactly the parallel-code duplication the plan's upgrade story cannot afford.
##
## It is not an [AcceptDialog]/[ConfirmationDialog]. Those are OS-ish [Window]s with their own
## theming path and their own focus behaviour, neither of which can be driven by [MKTheme] type
## variations or trapped by [MKModalLayer]. This is a plain [Control] so it stacks, dims, and
## restyles like every other MenuKit panel.
##
## The whole UI is built in code (plan §1.2's runtime-generation half): the accompanying
## [code].tscn[/code] is the root node plus this script, so the scene can never drift from the
## structure the script indexes into.

## The user chose the confirm action. Emitted before the dialog is popped, so a handler can inspect
## the still-live instance.
signal confirmed()

## The user chose cancel — button, [code]ui_cancel[/code], or the third "discard" button when one is
## configured and it is treated as a decline.
signal cancelled()

## The optional third button was chosen. Left unconnected for the common 2-button case.
signal alternate()

const _MARGIN := 24
const _MIN_WIDTH := 420.0

var _layer: MKModalLayer
var _title_label: Label
var _body_label: Label
var _confirm_button: Button
var _cancel_button: Button
var _alt_button: Button
var _destructive := false
## True only for dialogs built by [method open]. See [method _on_popped].
var _owns_self := false


## Builds a dialog, pushes it onto [param layer] and returns the instance so the caller can connect
## [signal confirmed]/[signal cancelled] in the same expression that opened it.
## [param destructive] styles the confirm button with [constant MKTheme.DANGER_BUTTON] — a delete
## and a quit must not look like an OK.
## [param alt_text] adds the third button; empty means a 2-button dialog.
## A dialog opened this way frees itself when it is popped (see [method _on_popped]), so callers
## never own cleanup. Building one with [method Object.new] and pushing it yourself keeps ownership
## with you.
static func open(layer: MKModalLayer, title: String, body: String, confirm_text := "Confirm",
		cancel_text := "Cancel", destructive := false, alt_text := "") -> MKConfirmDialog:
	var dialog := MKConfirmDialog.new()
	dialog.name = "MKConfirmDialog"
	dialog._destructive = destructive
	dialog._configure(title, body, confirm_text, cancel_text, alt_text)
	if layer != null and is_instance_valid(layer):
		dialog._layer = layer
		dialog._owns_self = true
		layer.push_modal(dialog)
	else:
		MKLog.warn("MKConfirmDialog.open: no MKModalLayer given — dialog is unparented")
	return dialog


func _ready() -> void:
	# Anchors AND offsets. set_anchors_preset moves the anchors but leaves the rect at whatever size
	# the node was constructed with, so the dialog stayed a small box pinned to the top-left and the
	# CenterContainer below had nothing to centre within. Centring here is pure container work —
	# never an add_theme_*_override (ship gate 1).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# STOP so a click on the dialog body never reaches the scrim or anything behind it.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	# Grab focus on the default button so the dialog is usable keyboard/gamepad-only from Phase 1;
	# MKModalLayer.push_modal traps focus, this decides WHICH control starts with it.
	if _confirm_button != null:
		_confirm_button.grab_focus()
	if _owns_self and _layer != null and is_instance_valid(_layer):
		_layer.modal_popped.connect(_on_popped)


## [method MKModalLayer.pop_modal] deliberately does not free what it pops, so a host can cache and
## reuse a dialog. That leaves [method open] — whose result nobody is required to hold — leaking one
## node per invocation, which the Phase 1 test caught as leaked ObjectDB instances at exit. A dialog
## that constructed itself owns itself, so it frees itself on pop.
##
## The signal carries the popped control, so a dialog stacked under another one ignores that pop and
## only reacts to its own.
func _on_popped(control: Control) -> void:
	if control != self or not _owns_self:
		return
	if _layer != null and is_instance_valid(_layer) and _layer.modal_popped.is_connected(_on_popped):
		_layer.modal_popped.disconnect(_on_popped)
	queue_free()


func _configure(title: String, body: String, confirm_text: String, cancel_text: String,
		alt_text: String) -> void:
	set_meta(&"mk_title", title)
	set_meta(&"mk_body", body)
	set_meta(&"mk_confirm", confirm_text)
	set_meta(&"mk_cancel", cancel_text)
	set_meta(&"mk_alt", alt_text)


func _build() -> void:
	if _title_label != null:
		return
	var centre := CenterContainer.new()
	centre.name = "Centre"
	# Offsets too, for the same reason as the root above: a CenterContainer centres within its own
	# rect, so a zero-sized one centres nothing and the frame lands at the origin.
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	# The authored floor the dialog is designed around. A CenterContainer sizes its child to the
	# child's minimum, so this is what actually decides the dialog's width — not a stretch ratio.
	frame.custom_minimum_size = Vector2(_MIN_WIDTH, 0.0)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# MKPanel is what draws the dialog's background and border. Without it the body sat directly on
	# the scrim — the visible half of the theme-propagation defect this class doc's layer counterpart
	# describes.
	MKTheme.set_variation(frame, MKTheme.PANEL)
	centre.add_child(frame)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	# Constants on a MarginContainer are layout, and Godot exposes no non-override path for them;
	# the generated Theme sets them for MKPanel, so this container only carries the box.
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	margin.add_child(column)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.text = String(get_meta(&"mk_title", ""))
	MKTheme.set_variation(_title_label, MKTheme.HEADER)
	column.add_child(_title_label)

	_body_label = Label.new()
	_body_label.name = "Body"
	_body_label.text = String(get_meta(&"mk_body", ""))
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.custom_minimum_size = Vector2(_MIN_WIDTH - _MARGIN * 2, 0.0)
	MKTheme.set_variation(_body_label, MKTheme.ROW_LABEL)
	column.add_child(_body_label)

	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(buttons)

	_confirm_button = Button.new()
	_confirm_button.name = "Confirm"
	_confirm_button.text = String(get_meta(&"mk_confirm", "Confirm"))
	MKTheme.set_variation(_confirm_button,
		MKTheme.DANGER_BUTTON if _destructive else MKTheme.PRIMARY_BUTTON)
	_confirm_button.pressed.connect(_on_confirm)
	buttons.add_child(_confirm_button)

	var alt_text := String(get_meta(&"mk_alt", ""))
	if not alt_text.is_empty():
		_alt_button = Button.new()
		_alt_button.name = "Alternate"
		_alt_button.text = alt_text
		MKTheme.set_variation(_alt_button, MKTheme.PANEL_BUTTON)
		_alt_button.pressed.connect(_on_alternate)
		buttons.add_child(_alt_button)

	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = String(get_meta(&"mk_cancel", "Cancel"))
	MKTheme.set_variation(_cancel_button, MKTheme.PANEL_BUTTON)
	_cancel_button.pressed.connect(_on_cancel)
	buttons.add_child(_cancel_button)

	# Built explicitly rather than via Array.filter — filter returns an untyped Array, which
	# link_chain's Array[Control] parameter refuses at runtime.
	var row: Array[Control] = [_confirm_button]
	if _alt_button != null:
		row.append(_alt_button)
	row.append(_cancel_button)
	MKFocus.link_chain(row, false, true)


## Returns the confirm button so a caller can retitle or disable it after opening (a countdown
## dialog rewrites its label every second). Never null once the dialog is in the tree.
func get_confirm_button() -> Button:
	return _confirm_button


## Returns the cancel button. Exposed for the same reason as [method get_confirm_button], and
## because the rebind row's abort rule hit-tests the Cancel rect (plan §4.4).
func get_cancel_button() -> Button:
	return _cancel_button


## Replaces the body text after opening — a conflict dialog learns which action collided only after
## the scan finishes, and rebuilding the dialog for that would drop focus.
func set_body(text: String) -> void:
	set_meta(&"mk_body", text)
	if _body_label != null:
		_body_label.text = text


## Cancel-gesture hook honoured by [method MKModalLayer.handle_cancel]. Returning false means "I did
## not consume it", which is what makes the layer pop this dialog — the dialog reports the decline
## and lets the stack own the removal, so there is exactly one place that pops.
func handle_cancel() -> bool:
	cancelled.emit()
	return false


func _on_confirm() -> void:
	confirmed.emit()
	_close()


func _on_cancel() -> void:
	cancelled.emit()
	_close()


func _on_alternate() -> void:
	alternate.emit()
	_close()


## Removes the dialog from the stack. Freeing is deliberately NOT done here: ownership is decided in
## exactly one place, [method _on_popped], which frees only what [method open] built. A second
## unconditional free here would also destroy a dialog a host constructed and intends to reuse,
## contradicting the ownership split this class documents.
func _close() -> void:
	if _layer != null and is_instance_valid(_layer) and _layer.top() == self:
		_layer.pop_modal()
	elif get_parent() != null:
		get_parent().remove_child(self)
		if _owns_self:
			queue_free()
