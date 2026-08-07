@tool
class_name MKServerBrowser
extends Control
## The server browser page: list, refresh, connect, cancel (plan §3.1, §5 row 7).
##
## [b]It is optional by construction.[/b] The shipped [code]default_config.tres[/code] leaves the
## network slot empty and authors no page for this scene, so a cold drop has no server browser at all
## — the first impression [MKNetworkBackend]'s own class doc argues for. The demo config assigns
## [MKStubNetworkBackend] to the slot and authors the page, which is the only reason the browser
## exists there. Nothing in this file decides that; a config does.
##
## [b]A null backend is not an error.[/b] Like [MKCharacterSelect] and [MKSettingsPanel], the page
## renders — here as one stated empty-state line — and says nothing at boot. The naming warn is
## deferred to the first press, because absence is a legitimate configured state and gate 2 counts
## boot warnings. Unlike [MKCharacterSelect], the actions are left ENABLED without a backend on
## purpose: a disabled button cannot be pressed, so disabling them would make the "name the missing
## slot on interaction" rule unreachable and the page would answer a press with nothing at all.
##
## [b]It renders the lifecycle enum, not the message text.[/b] Every
## [enum MKNetworkBackend.ConnectState] has a caption in [constant STATE_CAPTIONS], and the backend's
## [param message] is appended when it is non-empty — which is the split
## [signal MKNetworkBackend.connect_state_changed] was shaped for (its own doc: "so the panel can
## render each state without matching on message text"). Note what this means for the plan's
## error/timeout criteria: the abstract enum has no TIMEOUT member, and [MKStubNetworkBackend]
## reports its unreachable server as [code]FAILED[/code] with the message
## [code]"Connection timed out."[/code] — read from the stub, not assumed. Timeout is therefore a
## MESSAGE under the FAILED caption here, and a panel that rendered only the caption would show the
## two indistinguishably. That is why the message is appended rather than used as a fallback wherever
## there is one to append — every state that arrives on the signal. The ONE path with no message to
## append is the bind-time seed in [method _resolve_backend]: a panel re-entering the tree mid-connect
## reads the state back through a getter and there is no message accessor to read beside it, so that
## one render is caption-only by construction. Named there, with the trade.
##
## [b]The whole UI is built in code[/b] (plan §1.2): the accompanying [code].tscn[/code] is the root
## node plus this script, so the scene cannot drift from the structure this script indexes into —
## the same rule [MKCharacterSelect], [MKPauseMenu] and [MKConfirmDialog] document.
##
## [b]Styling is type variations only[/b] — zero [code]add_theme_*_override[/code] calls (ship gate
## 1), so a palette swap re-skins this page like every other.

## Emitted after the row list is (re)built, so tests and hosts can act on a real tree instead of
## guessing at a frame boundary. Mirrors [signal MKCharacterSelect.built] deliberately: both panels
## rebuild themselves from data that changes under them, and both were untestable without it.
signal built()

## Caption per lifecycle state, keyed by the enum's own integer value. A dictionary rather than a
## match statement so the set is enumerable: a state added to [MKNetworkBackend] with no caption here
## renders through [constant UNKNOWN_STATE_CAPTION] naming its number instead of silently reading as
## the previous state.
const STATE_CAPTIONS := {
	MKNetworkBackend.ConnectState.IDLE: "Not connected",
	MKNetworkBackend.ConnectState.CONNECTING: "Connecting…",
	MKNetworkBackend.ConnectState.CONNECTED: "Connected",
	MKNetworkBackend.ConnectState.FAILED: "Connection failed",
	MKNetworkBackend.ConnectState.CANCELLED: "Connection cancelled",
}

## Rendered for a state this panel has no caption for — see [constant STATE_CAPTIONS].
const UNKNOWN_STATE_CAPTION := "Connection state %d"

## Shown in place of the list when no [MKNetworkBackend] is reachable. A stated empty state, not an
## error: the slot is legitimately unassigned in the shipped default config.
const NO_BACKEND_TEXT := "No network backend is configured."

## Shown when a backend is present and its list is empty — a different fact from the line above, and
## the two must not collapse into one message a host cannot tell apart.
const NO_SERVERS_TEXT := "No servers found."

## Width floor for the row column, so a list of short names does not collapse into a thin strip. A
## layout rhythm, not a palette value — the same distinction [constant
## MKCharacterSelect._CARD_COLUMN_WIDTH] draws.
const _ROW_COLUMN_WIDTH := 560.0

var _network_backend: MKNetworkBackend

var _row_column: VBoxContainer
var _status_label: Label
var _footer: HBoxContainer
var _connect_button: Button
var _cancel_button: Button
var _refresh_button: Button

## The server entry currently selected, or an empty dictionary. Held whole rather than as an id
## because [method _on_connect_pressed] hands it to [method MKNetworkBackend.connect_to] VERBATIM —
## the contract is "one entry from list_servers back", and re-deriving it would be a second read of a
## list that refreshes underneath.
var _selected: Dictionary = {}
## Rows by server id, so a rebuild can restore the selection without re-deriving it from geometry.
var _rows: Dictionary = {}
## The last state reported by the backend. Drives which actions are live, and is seeded from the
## backend's own getter at bind time when it has one.
var _state: MKNetworkBackend.ConnectState = MKNetworkBackend.ConnectState.IDLE
## Whether the missing backend has already been named, so the page warns once per page rather than
## once per press.
var _warned_no_backend := false


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the whole UI as unowned
	# children that get saved into whatever scene instanced it — the hazard MKWelcomePage documents.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_resolve_backend()
	_refresh()


## Rebuilds the row list from the backend. Public because a host that mutated its server list through
## a route with no [signal MKNetworkBackend.servers_changed] emission still needs a way to redraw,
## and because the tests drive it directly.
func refresh() -> void:
	_refresh()


## The selected server entry, or an empty dictionary. Exposed so a host page embedding this panel can
## mirror the selection without reaching into private state.
func get_selected_server() -> Dictionary:
	return _selected


## The lifecycle state this panel is currently rendering.
func get_connect_state() -> MKNetworkBackend.ConnectState:
	return _state


func _build() -> void:
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	margin.add_child(column)

	var heading := Label.new()
	heading.name = "Title"
	heading.text = "Servers"
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Stated for the reason MKCharacterSelect states it: FOCUS_NONE is already ScrollContainer's
	# default, so this changes nothing today, but "the scroll must not be a focus stop" is a traversal
	# requirement and a default is not a decision anybody can read here.
	scroll.focus_mode = Control.FOCUS_NONE
	column.add_child(scroll)

	# The rows get their own MarginContainer inside the scroll so the column is inset from the panel
	# edge and from the scrollbar the same way every other page's rows are. The numbers are not spelled
	# here at all — MarginContainer's four margin constants come from the theme.
	var row_margin := MarginContainer.new()
	row_margin.name = "RowMargin"
	row_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(row_margin)

	_row_column = VBoxContainer.new()
	_row_column.name = "Rows"
	_row_column.custom_minimum_size = Vector2(_ROW_COLUMN_WIDTH, 0.0)
	_row_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_margin.add_child(_row_column)

	# The status line sits BELOW the list and ABOVE the buttons, i.e. next to the controls that change
	# it. Autowrap because a host's failure message is arbitrary text and a long one must not widen the
	# page past its column.
	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MKTheme.set_variation(_status_label, MKTheme.ROW_LABEL)
	column.add_child(_status_label)

	_footer = HBoxContainer.new()
	_footer.name = "Footer"
	_footer.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(_footer)

	_refresh_button = Button.new()
	_refresh_button.name = "Refresh"
	_refresh_button.text = "Refresh"
	MKTheme.set_variation(_refresh_button, MKTheme.PANEL_BUTTON)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_footer.add_child(_refresh_button)

	_connect_button = Button.new()
	_connect_button.name = "Connect"
	_connect_button.text = "Connect"
	MKTheme.set_variation(_connect_button, MKTheme.PRIMARY_BUTTON)
	_connect_button.pressed.connect(_on_connect_pressed)
	_footer.add_child(_connect_button)

	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = "Cancel"
	MKTheme.set_variation(_cancel_button, MKTheme.PANEL_BUTTON)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_footer.add_child(_cancel_button)

	_render_state(_state, "")


func _resolve_backend() -> void:
	_network_backend = _find_network_backend()
	if _network_backend == null:
		# No warn. Unlike MKCharacterSelect's missing profile backend, an unassigned network slot is
		# what the SHIPPED default config does, so a boot warning here would fire on every correct cold
		# drop and fail gate 2 by itself. The page states the absence on screen instead, and names the
		# slot on the first press.
		return
	# Subscribe rather than poll: the backend's contract is that the list announces its own changes, so
	# a refresh sweep, a host writing servers directly, and a late-arriving discovery result all redraw
	# through one path.
	if not _network_backend.servers_changed.is_connected(_on_servers_changed):
		_network_backend.servers_changed.connect(_on_servers_changed)
	if not _network_backend.connect_state_changed.is_connected(_on_connect_state_changed):
		_network_backend.connect_state_changed.connect(_on_connect_state_changed)
	# Seed from the backend's own getter when it offers one. Duck-typed because get_connect_state is
	# NOT on MKNetworkBackend — MKStubNetworkBackend adds it, documented there as being for "a panel
	# binding after a state change has already been emitted", which is exactly this page re-entering
	# the tree mid-connect. A backend without it starts the page on IDLE: not because IDLE is observed
	# truth, but because a panel that has observed nothing has nothing better to say.
	#
	# The seed carries NO message: there is no message accessor on MKNetworkBackend, so a page
	# re-entered mid-connect renders the CONNECTING caption alone and loses the "Connecting to
	# <server>…" half the live signal carries. Accepted rather than fixed — growing the backend's
	# abstract surface with a get_connect_message() every host would have to implement, for a display
	# nicety on one re-entry path, is the wrong trade before 0.1.0.
	if _network_backend.has_method("get_connect_state"):
		var seeded: Variant = _network_backend.call("get_connect_state")
		# typeof-gated and assigned as a bare int: an enum-typed member is int-backed, and `as` does not
		# accept an enum as its target type in GDScript.
		if typeof(seeded) == TYPE_INT:
			_state = int(seeded)
	# UNCONDITIONAL, and after the seed. _build() ran before any backend was resolved, so the status
	# line still carries NO_BACKEND_TEXT and the actions were settled against a null backend — for a
	# host backend that does not offer get_connect_state (the base class offers none; the stub adds
	# it), the seeded render used to be the only thing that corrected either, so the shipped host shape
	# reached the screen claiming no backend was configured while rendering that backend's rows.
	_render_state(_state, "")


func _on_servers_changed() -> void:
	_refresh()


func _on_connect_state_changed(state: MKNetworkBackend.ConnectState, message: String) -> void:
	_render_state(state, message)


## Writes the status line and re-settles the actions for [param state]. The single place the panel's
## notion of "where the connection is" changes, so the caption, the enable flags and the focus chain
## can never disagree about it.
func _render_state(state: MKNetworkBackend.ConnectState, message: String) -> void:
	_state = state
	if _status_label != null:
		_status_label.text = _state_text(state, message)
	_refresh_actions()
	_chain_focus()
	_recover_focus()


func _state_text(state: MKNetworkBackend.ConnectState, message: String) -> String:
	var caption: String = STATE_CAPTIONS.get(state, UNKNOWN_STATE_CAPTION % int(state))
	if _network_backend == null:
		# The lifecycle caption would be a lie with nothing to have a lifecycle: IDLE reads as "we asked
		# and are not connected", and there is nothing to ask.
		return NO_BACKEND_TEXT
	if message.is_empty():
		return caption
	# Both, always. The message is where MKStubNetworkBackend puts the DIFFERENCE between its failures
	# ("Connection timed out." vs "Unknown server." vs "Connection unavailable.") — all three are the
	# same FAILED caption, so dropping the message would render three distinct outcomes identically.
	return "%s — %s" % [caption, message]


func _refresh() -> void:
	if _row_column == null:
		return
	# Remember the id, not the dictionary: the entry that comes back from the backend after a refresh
	# is the authoritative one (the stub nudges every ping on a sweep), and re-selecting the stale copy
	# would hand connect_to a row the list no longer contains.
	var previous_id := _selected_id()
	_selected = {}
	_rows.clear()
	for child in _row_column.get_children():
		# remove_child before queue_free, for the reason MKRoot._show_page states: a queued node stays
		# in the tree until end of frame, so the old rows would still answer MKFocus's focusable scan and
		# the rebuilt chain would be wired through corpses.
		_row_column.remove_child(child)
		child.queue_free()

	var entries: Array[Dictionary] = []
	if _network_backend != null:
		entries = _network_backend.list_servers()

	if entries.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = NO_SERVERS_TEXT if _network_backend != null else NO_BACKEND_TEXT
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		MKTheme.set_variation(empty, MKTheme.ROW_LABEL)
		_row_column.add_child(empty)
	else:
		for entry in entries:
			var row := _make_row(entry)
			if row != null:
				_row_column.add_child(row)

	# ORDERING CONSTRAINT — selection and the enable flags BEFORE chaining, for the reason
	# MKCharacterSelect._refresh records: MKFocus.collect_focusables skips DISABLED buttons, so a chain
	# built while Connect is still disabled wires a footer ring that steps over it.
	if not previous_id.is_empty() and _rows.has(previous_id):
		_select(_rows[previous_id].get_meta(&"mk_server", {}))
	elif not entries.is_empty():
		# Default to the first row rather than to nothing: a Connect button disabled on arrival reads as
		# a broken page, and a server list always has a sensible default selection.
		_select(entries[0])
	else:
		_refresh_actions()
		_chain_focus()
	# The rows above were freed, so a player who was standing on one is now standing on nothing:
	# Godot releases focus when the holder leaves the tree and the rebuilt rows are different nodes.
	# Passed true because "the ring was on a row" is not answerable after the fact — the row it was on
	# no longer exists to be recognised.
	_recover_focus(true)
	built.emit()


## Builds one focusable row. A [Button] rather than a panel with a click handler because focus,
## keyboard activation and gamepad activation all come free from it — a hand-rolled row would have to
## re-implement all three to satisfy the keyboard-only traversal criterion.
func _make_row(entry: Dictionary) -> Button:
	var id := str(entry.get("id", ""))
	if id.is_empty():
		# MKNetworkBackend's contract requires an id, and connect_to REFUSES an entry without one (the
		# stub warns and reports FAILED). A row that could only ever fail is worse than no row, so name
		# the offender instead of rendering it.
		MKLog.warn("MKServerBrowser: a server entry has no 'id' and was skipped — check %s"
			% [_network_backend.get_script().resource_path if _network_backend != null \
				and _network_backend.get_script() != null else "the network backend"])
		return null
	var row := Button.new()
	row.name = "Server_%s" % id
	row.text = _row_text(entry)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MKTheme.set_variation(row, MKTheme.PANEL_BUTTON)
	row.set_meta(&"mk_server", entry)
	row.pressed.connect(_select.bind(entry))
	# Selection follows focus as well as clicks. Without this, arrowing down the list moves the
	# highlight but leaves Connect acting on whatever was clicked last — two disagreeing notions of
	# "the selected server" on the same screen.
	row.focus_entered.connect(_select.bind(entry))
	_rows[id] = row
	return row


## The label for one server entry. Only [code]id[/code] and [code]name[/code] are guaranteed by
## [method MKNetworkBackend.list_servers]; [code]players[/code], [code]max_players[/code],
## [code]ping[/code] and [code]map[/code] are rendered "when present" per that same doc, which is why
## every one of them is read defensively and type-gated rather than str()'d into the label. A host
## backend may hold anything under those keys, or nothing.
func _row_text(entry: Dictionary) -> String:
	var display_name := str(entry.get("name", ""))
	if display_name.is_empty():
		display_name = "(unnamed)"
	var parts := PackedStringArray([display_name])
	var map_name: Variant = entry.get("map", "")
	if (typeof(map_name) == TYPE_STRING or typeof(map_name) == TYPE_STRING_NAME) \
			and not str(map_name).is_empty():
		parts.append(str(map_name))
	# Population renders as "3/16" only when BOTH numbers are there; a lone player count is rendered
	# bare rather than against an invented capacity.
	var players: Variant = entry.get("players", null)
	var max_players: Variant = entry.get("max_players", null)
	if _is_number(players) and _is_number(max_players):
		parts.append("%d/%d players" % [int(players), int(max_players)])
	elif _is_number(players):
		parts.append("%d players" % int(players))
	var ping: Variant = entry.get("ping", null)
	if _is_number(ping):
		parts.append("%d ms" % int(ping))
	return " — ".join(parts)


## True for the two Variant types an authored or JSON-sourced number can arrive as. Bools are
## deliberately excluded even though [code]int(true)[/code] is legal: a backend answering true for
## [code]players[/code] has a bug, and rendering it as "1 players" hides it.
func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


func _select(entry: Dictionary) -> void:
	_selected = entry
	var id := str(entry.get("id", ""))
	for row_id in _rows:
		var row: Button = _rows[row_id]
		if row == null or not is_instance_valid(row):
			continue
		# A variation swap, never a theme override — the one sanctioned way to express dynamic state
		# (MKTheme's class doc), and what keeps the selected row re-skinnable.
		MKTheme.set_variation_if(row, row_id == id, MKTheme.PRIMARY_BUTTON, MKTheme.PANEL_BUTTON)
	_refresh_actions()
	_chain_focus()


func _selected_id() -> String:
	return str(_selected.get("id", ""))


## Settles the three footer buttons against the current state. Cancel is the CONNECTING-only
## affordance and Connect its complement, so the pair reads as one control that swaps roles rather
## than two buttons that can both look available mid-connect.
func _refresh_actions() -> void:
	var connecting := _state == MKNetworkBackend.ConnectState.CONNECTING
	if _connect_button != null:
		# Enabled with NO backend on purpose (class doc): the press is what produces the warn naming the
		# unassigned slot, and a disabled button cannot produce one. With a backend, a selection is
		# required — connect_to has nothing to be handed otherwise.
		_connect_button.disabled = connecting \
			or (_network_backend != null and _selected_id().is_empty())
	if _cancel_button != null:
		# MKNetworkBackend.cancel() is documented safe when idle, and the stub's is explicitly a no-op
		# off CONNECTING so a stray press cannot wipe a FAILED message the player has not read. Cancel is
		# still disabled off CONNECTING: "safe" is not the same as "an affordance", and a permanently
		# live Cancel on an idle page invites the press that does nothing.
		#
		# The `_network_backend != null` clause is the SAME carve-out Connect takes above, and for the
		# same reason: with no backend there is no lifecycle, CONNECTING is unreachable, and a Cancel
		# disabled forever could never produce the press that names the unassigned slot. So both buttons
		# stay live on a backendless page and both routes reach _require_backend's one warning.
		_cancel_button.disabled = not connecting and _network_backend != null
	if _refresh_button != null:
		# Refresh stays live throughout, including mid-connect: MKNetworkBackend.refresh() touches the
		# LIST, not the connection, and the stub's own sweep guard already refuses a second in-flight
		# sweep.
		_refresh_button.disabled = false


## Re-wires the row and footer chains over the tree as it now stands. Called after every rebuild AND
## after every enable-flag change, because MKFocus reads the live tree and skips disabled buttons —
## a chain wired while Cancel was disabled routes around a Cancel that is now the only live action.
func _chain_focus() -> void:
	if _row_column == null or _footer == null:
		return
	MKFocus.chain_container(_row_column)
	MKFocus.chain_container(_footer, false, true)
	MKFocus.link_containers(_row_column, _footer)


## Puts the focus ring back on a live control when this panel's own redraw took it away. The ONE
## recovery point, called after every enable-flag settle in [method _render_state] and after every row
## rebuild in [method _refresh] — the two gestures that destroy or disable the control the player was
## standing on:
##
## [br][br]- a REFRESH (or any [signal MKNetworkBackend.servers_changed]) frees every row, and a
## player standing on one is left with a null focus owner: keyboard and gamepad are dead until a mouse
## touches something, which on a gamepad is never.
## [br]- a state FLIP disables the button that caused it. Cancel is pressed while focused and
## CANCELLED disables it; Connect is pressed while focused and CONNECTING disables it. Godot lets a
## disabled control keep focus perfectly happily — nothing errors, the ring just sits there and eats
## every subsequent activation. [MKFocus]'s own doc calls a disabled button "never the answer" to
## where focus should go; [method _chain_focus] rewires the NEIGHBOURS around such a button and moves
## nothing, which is why re-chaining alone never fixed this.
##
## [br][br]It recovers only from focus this panel is responsible for: a null owner, a freed one, or a
## live one INSIDE this panel that is now disabled. Focus that is alive, enabled, or somewhere else
## entirely is left alone — a modal or a host panel may legitimately own it, and stealing it back
## would make this page the one that breaks THEM.
##
## [param rebuilding] states that the rows were just replaced, so a lost ring belongs on the selection
## rather than in the footer.
func _recover_focus(rebuilding := false) -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var prefer_row := rebuilding
	var owner_control := viewport.gui_get_focus_owner()
	if owner_control != null and is_instance_valid(owner_control):
		if not is_ancestor_of(owner_control):
			# Live focus outside this panel. Not ours to move.
			return
		var button := owner_control as BaseButton
		if button == null or not button.disabled:
			return
		# A row is never disabled today, so this only reads true if one ever is — the branch is the
		# rule ("go back to the list you were in"), not a prediction about which controls disable.
		prefer_row = prefer_row or (_row_column != null and _row_column.is_ancestor_of(owner_control))
	var target: Control = null
	if prefer_row:
		target = _recovery_row()
	if target == null:
		target = _live_footer_button()
	if target != null and target.is_visible_in_tree():
		target.grab_focus()


## The row a rebuild should hand the ring back to: the selected one, or the first that exists. Null
## when the list is empty, which is when the footer takes over.
func _recovery_row() -> Control:
	if _row_column == null:
		return null
	var selected_id := _selected_id()
	if not selected_id.is_empty() and _rows.has(selected_id):
		var row: Button = _rows[selected_id]
		if row != null and is_instance_valid(row) and not row.disabled:
			return row
	for child in _row_column.get_children():
		var button := child as Button
		if button != null and is_instance_valid(button) and not button.disabled:
			return button
	return null


## The footer button a lost ring lands on, in the order a player wants them: the primary action first,
## then the one that is always live, then the last resort. Null when the whole footer is disabled —
## which no state produces today, because Refresh never disables.
func _live_footer_button() -> Control:
	var ordered: Array[Button] = [_connect_button, _refresh_button, _cancel_button]
	for button in ordered:
		if button != null and is_instance_valid(button) and not button.disabled \
				and button.is_visible_in_tree():
			return button
	return null


func _on_refresh_pressed() -> void:
	if not _require_backend():
		return
	# refresh() is non-abstract and a no-op for a static list, so there is nothing to check here: the
	# redraw arrives (or does not) through servers_changed like every other list change.
	_network_backend.refresh()


func _on_connect_pressed() -> void:
	if not _require_backend():
		return
	if _selected_id().is_empty():
		return
	# The entry goes across VERBATIM — connect_to's contract is "one entry from list_servers", and the
	# stub refuses an id it does not know. Progress arrives on connect_state_changed; there is
	# deliberately no return value to read.
	_network_backend.connect_to(_selected)


func _on_cancel_pressed() -> void:
	if not _require_backend():
		return
	_network_backend.cancel()


## Gate every action goes through. Returns whether a backend is there, and names the unassigned slot
## ONCE per page on the first press that needed it — the "absence is a state, not a boot error"
## policy this panel shares with [MKCharacterSelect] and [MKPauseMenu].
func _require_backend() -> bool:
	if _network_backend != null:
		return true
	if not _warned_no_backend:
		_warned_no_backend = true
		MKLog.warn("MKServerBrowser: pressed with no MKNetworkBackend reachable — assign MKConfig.network_backend (the shipped default_config.tres leaves it empty on purpose)")
	return false


# --- Ancestor lookups ---------------------------------------------------------

## Kept as its own walk rather than a generic one for the reason [MKPauseMenu] and
## [MKCharacterSelect] both record: an ancestor may ANSWER [code]get_network_backend[/code] and still
## return null (a shell booted with an unassigned slot — the SHIPPED default here), and the walk must
## continue past it rather than stop at the first responder. Duck-typed rather than typed to [MKRoot]
## because a host may wrap the shell, or embed this panel under its own controller that forwards the
## call; a typed cast would refuse exactly that.
func _find_network_backend() -> MKNetworkBackend:
	var node := get_parent()
	while node != null:
		if node.has_method("get_network_backend"):
			var backend: MKNetworkBackend = node.call("get_network_backend")
			if backend != null and is_instance_valid(backend):
				return backend
		node = node.get_parent()
	return null
