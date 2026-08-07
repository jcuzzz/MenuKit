@tool
class_name MKConfirmDialog
extends Control
## A generic 2–3 button confirm modal pushed onto an [MKModalLayer].
##
## The root quit-confirm, character deletion and rebind conflicts all use it, so it carries NO roster
## or settings vocabulary — title, body and button texts are arguments. That genericity is the point: a
## second, near-identical dialog script would be pure duplication.
##
## It is not an [AcceptDialog]/[ConfirmationDialog]. Those are OS-ish [Window]s with their own theming
## path and focus behaviour, neither of which can be driven by [MKTheme] type variations or trapped by
## [MKModalLayer]. This is a plain [Control] so it stacks, dims, and restyles like every other MenuKit
## panel.
##
## The whole UI is built in code: the accompanying [code].tscn[/code] is the root node plus this
## script, so the scene can never drift from the structure the script indexes into.
##
## [b]Default focus follows [method open]'s [param destructive] flag, and it is decided by BUTTON
## ORDER.[/b] A non-destructive dialog opens with Confirm focused; a destructive one opens with Cancel
## focused, so an [code]ui_accept[/code] that was already travelling when "Quit to desktop?" or
## "Delete character?" appeared cannot commit the destructive action.
##
## Four routes decide where focus lands, and only one is this script's own [method _ready] grab:
## [method MKFocus.trap] re-grabs during [method MKModalLayer.push_modal] (after [method _ready] has
## run), and both [code]MKModalLayer._restore_focus[/code] (a modal stacked ABOVE this one popping)
## and its focus-pullback re-grab later still. All of them take the FIRST focusable in tree order, so
## the decision is single-sourced AS tree order: [method _build] puts the default button first among
## the dialog's buttons, and [method get_default_focus_button] names the same rule for the one explicit
## grab. A dialog that only agreed with itself in [method _ready] would be overridden by the next trap.
##
## The visible consequence for a destructive dialog is the button row reading Cancel → (alternate) →
## Confirm rather than the other way round, which also puts the red button furthest from the one the
## ring starts on. Escape/cancel semantics are unchanged in both shapes.

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
## and a quit must not look like an OK — and moves the default focus (and the confirm button itself)
## to the far side of the row, so the dialog opens on Cancel. See the class doc.
## [param alt_text] adds the third button; empty means a 2-button dialog.
## A dialog opened this way frees itself when it is popped (see [method _on_popped]), so callers
## never own cleanup. Building one with [method Object.new] and pushing it yourself keeps ownership
## with you.
## Returns [code]null[/code] when [param layer] is null — there is nowhere to show a dialog, so the
## instance is disposed of rather than handed back unparented.
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
		# Returning the orphan would leak one Control per call, on the error path of the very method whose
		# contract promises callers never own cleanup. Nothing can be done with an unparented dialog, so
		# dispose of it and return null.
		MKLog.error("MKConfirmDialog.open: no MKModalLayer given — nothing to show the dialog on")
		dialog.free()
		return null
	return dialog


func _ready() -> void:
	# @tool guard: opening this scene in the editor would otherwise materialise the whole dialog as
	# unowned children and save them into whatever instanced it — the hazard MKWelcomePage documents.
	if Engine.is_editor_hint():
		return
	# Anchors AND offsets: set_anchors_preset moves the anchors but leaves the rect at whatever size the
	# node was constructed with, so the dialog would stay a small box pinned to the top-left with the
	# CenterContainer below having nothing to centre within.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# STOP so a click on the dialog body never reaches the scrim or anything behind it.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	# The dialog must be usable keyboard/gamepad-only from the frame it appears, including when nobody
	# pushed it onto an MKModalLayer (a host parenting it itself gets no trap). _build has already put the
	# same button first in tree order, so this grab and every later trap/restore/pullback agree.
	var default_button := get_default_focus_button()
	if default_button != null:
		default_button.grab_focus()
	if _owns_self and _layer != null and is_instance_valid(_layer):
		_layer.modal_popped.connect(_on_popped)


## Called by [method MKModalLayer.clear_for_teardown]. Teardown emits no
## [signal MKModalLayer.modal_popped], so a dialog that frees itself on that signal would otherwise
## leak once the layer also unparents it. Only self-built dialogs dispose here; one a host constructed
## and pushed is handed back untouched.
##
## The ownership split: [method MKModalLayer.pop_modal] deliberately does not free what it pops, so a
## host can cache and reuse a dialog — which leaves [method open], whose result nobody is required to
## hold, owning its own instance.
func _mk_layer_teardown() -> void:
	if _owns_self:
		queue_free()


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
	# MKPanel is what draws the dialog's background and border; without it the body sits directly on the
	# scrim.
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

	var alt_text := String(get_meta(&"mk_alt", ""))
	if not alt_text.is_empty():
		_alt_button = Button.new()
		_alt_button.name = "Alternate"
		_alt_button.text = alt_text
		MKTheme.set_variation(_alt_button, MKTheme.PANEL_BUTTON)
		_alt_button.pressed.connect(_on_alternate)

	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = String(get_meta(&"mk_cancel", "Cancel"))
	MKTheme.set_variation(_cancel_button, MKTheme.PANEL_BUTTON)
	_cancel_button.pressed.connect(_on_cancel)

	# ORDER IS THE FOCUS DECISION, not a layout preference: every focus route into this dialog takes the
	# first focusable in tree order (class doc), and an HBoxContainer's child order is also what the
	# player sees left-to-right. Destructive therefore parents Cancel first — the default-focus rule and
	# the visual row are one fact, so neither can change without the other following.
	# Built as a typed local rather than an inline literal: an untyped Array is refused at runtime by
	# link_chain's Array[Control] parameter.
	var row: Array[Control] = [get_default_focus_button()]
	if _alt_button != null:
		row.append(_alt_button)
	row.append(_confirm_button if _destructive else _cancel_button)
	for control in row:
		buttons.add_child(control)
	MKFocus.link_chain(row, false, true)


## The button this dialog opens with focused: Cancel when it is destructive, Confirm otherwise.
##
## The ONE place that rule is written. [method _build] parents this button first so tree order carries
## the same decision to [method MKFocus.trap] and to [code]MKModalLayer[/code]'s focus restoration and
## pullback — all of which take the first focusable and none of which can be told about a preference.
##
## Null only before [method _build] has run (i.e. before the dialog entered the tree). A destructive
## dialog whose Cancel button a host later DISABLES loses the guarantee at the trap seam rather than
## here: [method MKFocus.collect_focusables] skips disabled buttons, so the ring would start on
## Confirm. No shipped path disables Cancel.
func get_default_focus_button() -> Button:
	return _cancel_button if _destructive and _cancel_button != null else _confirm_button


## Returns the confirm button so a caller can retitle or disable it after opening (a countdown
## dialog rewrites its label every second). Never null once the dialog is in the tree.
func get_confirm_button() -> Button:
	return _confirm_button


## Returns the cancel button. Exposed for the same reason as [method get_confirm_button], and
## because the rebind row's abort rule hit-tests the Cancel rect.
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
## exactly one place, [method _on_popped], which frees only what [method open] built. An unconditional
## free here would also destroy a dialog a host constructed and intends to reuse.
func _close() -> void:
	# Always ask the layer to do the removal, even when this dialog is not on top. Reparenting
	# ourselves out from under it would leave a stale entry in its stack, and from then on the layer
	# reports non-empty forever: the scrim stays up over nothing and MKRoot swallows every cancel.
	if _layer != null and is_instance_valid(_layer) and _layer.remove_modal(self):
		return
	if get_parent() != null:
		get_parent().remove_child(self)
	if _owns_self:
		queue_free()
