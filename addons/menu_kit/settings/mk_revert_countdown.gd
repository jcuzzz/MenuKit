@tool
class_name MKRevertCountdown
extends Control
## The D14 confirm-or-revert dialog: "Keep these settings?" with a live countdown, Keep, and Revert.
##
## Window mode and resolution rows carry [code]requires_confirm[/code] because they can make the game
## unreachable — a resolution the monitor cannot display, or a fullscreen mode on a broken output,
## leaves a player with no way to click anything. The countdown is the recovery path: apply the
## change, and if nothing is confirmed within the timeout, put it back.
##
## [b]The countdown is accumulated in [method _process], not run on a [Timer].[/b] A [SceneTreeTimer]
## or a [Timer] under a tree pause policy would never tick when this dialog is opened from the pause
## menu — the exact place a player changes display settings — and the dialog would hang forever with
## no failing write to reveal it. This is also why the [MKRoot] subtree is
## [constant Node.PROCESS_MODE_ALWAYS].
##
## [b]Ownership.[/b] It is built and pushed by the settings panel, which is also the thing that knows
## how to revert. It never pops or frees itself: it emits exactly one of [signal kept] /
## [signal reverted] and the panel does the removal, so there is one place that owns the pair of
## "undo the change" and "take it off the stack". This mirrors [MKConfirmDialog], whose own free path
## is limited to dialogs its static [code]open[/code] constructed.
##
## Built entirely in code and styled with [MKTheme] type variations only — MenuKit ships zero
## [code]add_theme_*_override[/code] calls.

## The user chose to keep the new settings, by button. Emitted at most once.
signal kept()

## The settings must be put back — the user pressed Revert, pressed [code]ui_cancel[/code], or the
## countdown reached zero. Emitted at most once, and never after [signal kept].
signal reverted()

const _MARGIN := 24
const _MIN_WIDTH := 420.0

## Used when [method start] is given a non-positive duration. A zero-second countdown would revert on
## the first frame and read as "the dialog flickered and my setting was refused".
const DEFAULT_DURATION := 10.0

var _title_label: Label
var _body_label: Label
var _keep_button: Button
var _revert_button: Button

var _remaining := 0.0
var _running := false
## The whole-seconds value currently shown, so the label is rewritten once a second rather than every
## frame. -1 forces the first paint.
var _shown_seconds := -1
## Emit-exactly-once latch. Both buttons, the cancel gesture and the timeout funnel through
## [method _finish]; without this, a Revert click on the frame the timer expires emits
## [signal reverted] twice and the panel reverts a revert.
var _emitted := false


func _init() -> void:
	# Explicit rather than inherited: a host (or a test) that pushes this onto a layer outside the
	# MKRoot subtree must still get a ticking countdown. A frozen confirm-or-revert dialog is
	# unrecoverable by construction.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## Starts (or restarts) the countdown. Safe to call before or after the dialog enters the tree, so a
## caller may construct, start, and push in any order.
func start(duration: float) -> void:
	if duration <= 0.0 or not is_finite(duration):
		MKLog.warn("MKRevertCountdown.start: invalid duration '%s' — using %s seconds"
			% [duration, DEFAULT_DURATION])
		duration = DEFAULT_DURATION
	_remaining = duration
	_running = true
	_emitted = false
	_shown_seconds = -1
	set_process(true)
	_refresh_label()


## Seconds left, or 0 once the countdown has resolved. For tests and diagnostics.
func get_time_left() -> float:
	return maxf(_remaining, 0.0)


## True until one of [signal kept] / [signal reverted] has been emitted.
func is_running() -> bool:
	return _running


func _ready() -> void:
	# @tool guard: opening this in the editor would otherwise materialise the whole dialog as unowned
	# children and save them into whatever instanced it.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# STOP so a click on the dialog body never reaches the scrim or anything behind it.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_refresh_label()
	# Keep starts focused: it is the non-destructive choice, and doing nothing already reverts, so a
	# player mashing the accept button keeps what they just chose.
	if _keep_button != null:
		_keep_button.grab_focus()


func _process(delta: float) -> void:
	if not _running:
		return
	_remaining -= delta
	if _remaining <= 0.0:
		_remaining = 0.0
		_refresh_label()
		_finish(false)
		return
	_refresh_label()


## Cancel-gesture hook honoured by [method MKModalLayer.handle_cancel]. Escape means revert: the
## whole point of the dialog is that the safe outcome is the one requiring no working input, and a
## player whose screen just went black is pressing Escape, not reading buttons.
##
## [b]Returns whether THIS call resolved the dialog[/b], and both halves are load-bearing:
## [br]- [b]A live dialog returns true — consumed — and the layer must not pop anything.[/b] Emitting
##   [signal reverted] resolves this dialog synchronously: the settings panel's handler puts the value
##   back and calls [method MKModalLayer.remove_modal] on it before this method returns. Reporting
##   "not consumed" makes [method MKModalLayer.handle_cancel] pop AGAIN, destroying whatever modal was
##   underneath.
## [br]- [b]An already-resolved dialog returns false.[/b] Returning true unconditionally leaves a
##   resolved dialog on the stack — owner gone, nothing left to remove it — consuming EVERY Escape
##   from then on: an unclosable scrim over nothing. False routes the gesture to
##   [method MKModalLayer.handle_cancel]'s pop, which clears the stale entry and self-heals the stack.
func handle_cancel() -> bool:
	return _finish(false)


## Called by [method MKModalLayer.clear_for_teardown]. Teardown emits no
## [signal MKModalLayer.modal_popped], and the panel that owns this dialog is destroyed in the same
## teardown, so nobody is left to free it — an unparented countdown leaks one Control per
## quit-while-open. This dialog is never host-supplied (the settings panel is its only constructor),
## so disposing here cannot destroy something a host intended to reuse.
func _mk_layer_teardown() -> void:
	_running = false
	set_process(false)
	queue_free()


## Resolves the dialog WITHOUT emitting either signal, and stops it ticking.
##
## For the one caller that has already performed the resolution itself:
## [MKSettingsPanel._resolve_orphaned_countdown], which reverts the value directly from its own
## bookkeeping when the panel dies with this dialog still stacked. Emitting there would reach handlers
## whose panel is gone.
##
## [b]This is what makes the ownerless frame safe.[/b] That path cannot dispose of a stacked dialog
## synchronously — a pop mid-teardown is the hazard [method MKModalLayer.clear_for_teardown] exists to
## prevent — so it marks the dialog and schedules [method MKModalLayer.reap_modal] deferred. Between
## the mark and that flush this dialog is on a live stack with no owner, and all three things it could
## do in that window are switched off here:
## [br]- [b]It stops ticking.[/b] This node is [constant Node.PROCESS_MODE_ALWAYS], so neither a
##   paused tree nor a dead owner stops [method Node._process]: without the [code]_running[/code] flag
##   it keeps counting down and repaints its label every frame.
## [br]- [b]It cannot lapse.[/b] The [code]_emitted[/code] latch is the same one [method _finish]
##   throws, so a timeout cannot fire [signal reverted] into a dropped connection — and cannot revert
##   a revert the panel has already performed.
## [br]- [b]It declines a cancel gesture instead of eating it.[/b] A later [method handle_cancel]
##   returns false, which routes the Escape to [method MKModalLayer.handle_cancel]'s own pop: the stale
##   entry is cleared and the stack self-heals. Returning true would swallow every cancel until the
##   reap arrived.
func mark_resolved() -> void:
	_emitted = true
	_running = false
	set_process(false)


## The one place that resolves the dialog. [param keep] chooses which signal fires.
##
## Returns whether THIS call performed the resolution — false when the latch had already been thrown.
## [method handle_cancel] reports that value straight to the modal layer, which is how a stale stacked
## dialog stops swallowing cancel gestures.
func _finish(keep: bool) -> bool:
	if _emitted:
		return false
	_emitted = true
	_running = false
	set_process(false)
	if keep:
		kept.emit()
	else:
		reverted.emit()
	return true


func _on_keep() -> void:
	_finish(true)


func _on_revert() -> void:
	_finish(false)


func _refresh_label() -> void:
	if _body_label == null:
		return
	# ceilf, not floorf: showing "0" for a whole second before anything happens reads as a hung dialog.
	var seconds := int(ceilf(_remaining))
	if seconds == _shown_seconds:
		return
	_shown_seconds = seconds
	_body_label.text = "Reverting in %d second%s if you do nothing." \
		% [seconds, "" if seconds == 1 else "s"]


func _build() -> void:
	if _title_label != null:
		return
	var centre := CenterContainer.new()
	centre.name = "Centre"
	# Anchors AND offsets: a CenterContainer centres within its own rect, so a zero-sized one centres
	# nothing and the frame lands at the origin.
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.custom_minimum_size = Vector2(_MIN_WIDTH, 0.0)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# MKPanel is what draws the background and border; without it the body sits directly on the scrim.
	MKTheme.set_variation(frame, MKTheme.PANEL)
	centre.add_child(frame)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	margin.add_child(column)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.text = "Keep these settings?"
	MKTheme.set_variation(_title_label, MKTheme.HEADER)
	column.add_child(_title_label)

	_body_label = Label.new()
	_body_label.name = "Countdown"
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.custom_minimum_size = Vector2(_MIN_WIDTH - _MARGIN * 2, 0.0)
	MKTheme.set_variation(_body_label, MKTheme.ROW_LABEL)
	column.add_child(_body_label)

	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(buttons)

	_keep_button = Button.new()
	_keep_button.name = "Keep"
	_keep_button.text = "Keep"
	MKTheme.set_variation(_keep_button, MKTheme.PRIMARY_BUTTON)
	_keep_button.pressed.connect(_on_keep)
	buttons.add_child(_keep_button)

	_revert_button = Button.new()
	_revert_button.name = "Revert"
	# DANGER, not PANEL_BUTTON: reverting throws the player's change away, so it must not read as the
	# neutral option.
	_revert_button.text = "Revert"
	MKTheme.set_variation(_revert_button, MKTheme.DANGER_BUTTON)
	_revert_button.pressed.connect(_on_revert)
	buttons.add_child(_revert_button)

	# Built explicitly rather than via Array.filter — filter returns an untyped Array, which
	# link_chain's Array[Control] parameter refuses at runtime.
	var row: Array[Control] = [_keep_button, _revert_button]
	MKFocus.link_chain(row, false, true)


## Returns the Keep button so a caller can retitle or disable it after opening.
func get_keep_button() -> Button:
	return _keep_button


## Returns the Revert button, for the same reason as [method get_keep_button].
func get_revert_button() -> Button:
	return _revert_button
