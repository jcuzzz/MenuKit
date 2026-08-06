@tool
class_name MKCharacterSelect
extends Control
## The character roster page: pick, play, delete, or go make a new one (plan §3.1, §4.4).
##
## [b]It reads profiles as opaque dictionaries and nothing more.[/b] [MKProfileBackend]'s contract
## guarantees an [code]id[/code] and a [code]name[/code]; every other field belongs to the host. This
## panel displays one optional extra — [code]archetype[/code], because the creation flow it pairs with
## produces it and a roster of identically-shaped names is hard to read — and it reads even that
## defensively, type-gated, because a host's payload may hold anything under that key or nothing at
## all. Interpreting more would make MenuKit a character system rather than a menu package.
##
## [b]A null backend is not an error.[/b] Like [MKSettingsPanel], the page renders with its actions
## disabled and warns ONCE, rather than refusing to build: a page that vanishes when a slot is
## unassigned is indistinguishable from a crashed page, and the host's actual mistake goes unnamed.
##
## [b]The whole UI is built in code[/b] (plan §1.2's runtime-generation half): the accompanying
## [code].tscn[/code] is the root node plus this script, so the scene can never drift from the
## structure the script indexes into — the same rule [MKConfirmDialog] documents.
##
## [b]Styling is type variations only[/b] — zero [code]add_theme_*_override[/code] calls (ship gate 1),
## so a palette swap re-skins this page like every other.

## Emitted after the card list is (re)built, so tests and hosts can act on a real tree instead of
## guessing at a frame boundary. Mirrors [signal MKSettingsPanel.built] deliberately: both panels
## rebuild themselves from data that can change under them, and both were untestable without it.
signal built()

## The page id [method _on_new_pressed] navigates to. Named here rather than spelled at the call site
## because a host repointing the creation flow at its own page edits one constant, and because the
## shipped configs author a page under exactly this id.
const CREATE_PAGE_ID := &"character_create"

## Width floor for the card column, so a roster of short names does not collapse into a thin strip.
## A layout rhythm, not a palette value — the same distinction [constant
## MKSettingsPanel.LABEL_COLUMN_WIDTH] draws.
const _CARD_COLUMN_WIDTH := 520.0

var _profile_backend: MKProfileBackend
var _menu_backend: MKMenuBackend

var _card_column: VBoxContainer
var _footer: HBoxContainer
var _play_button: Button
var _delete_button: Button
var _new_button: Button

## The roster entry currently selected, or an empty dictionary. Held as the whole dictionary rather
## than just an id because [method _on_play_pressed] hands the entry to the menu backend VERBATIM —
## re-looking it up by id would be a second read of a roster that may have changed underneath.
var _selected: Dictionary = {}
## Cards by profile id, so a rebuild can restore the selection without re-deriving it from geometry.
var _cards: Dictionary = {}
## Whether the menu backend has already been named as missing, so Play warns once per page rather
## than once per press.
var _warned_no_menu_backend := false


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the whole UI as unowned
	# children that get saved into whatever scene instanced it — the hazard MKWelcomePage documents.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_resolve_backends()
	_refresh()


## Rebuilds the card list from the backend. Public because a host that mutated the roster through a
## route with no [signal MKProfileBackend.roster_changed] emission still needs a way to redraw, and
## because the tests drive it directly.
func refresh() -> void:
	_refresh()


## The selected roster entry, or an empty dictionary. Exposed so a host page embedding this panel can
## mirror the selection (a portrait preview beside the list) without reaching into private state.
func get_selected_profile() -> Dictionary:
	return _selected


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
	heading.text = "Characters"
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The scroll container itself must not be a focus stop: it sits between the footer chain and the
	# cards, and a focusable-but-empty container is where gamepad traversal appears to hang.
	scroll.focus_mode = Control.FOCUS_NONE
	column.add_child(scroll)

	# The cards get their own MarginContainer inside the scroll, so the column is inset from the panel
	# edge and from the scrollbar the same way the settings panel's rows are inset inside THEIR scroll.
	# The numbers are not spelled here at all — MarginContainer's four margin constants come from the
	# theme (MKThemeGenerator._style_panels sets them from the palette's spacing_lg), which is what
	# makes this the same inset as every other page rather than a number that happens to match today.
	var card_margin := MarginContainer.new()
	card_margin.name = "CardMargin"
	card_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(card_margin)

	_card_column = VBoxContainer.new()
	_card_column.name = "Cards"
	_card_column.custom_minimum_size = Vector2(_CARD_COLUMN_WIDTH, 0.0)
	_card_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_margin.add_child(_card_column)

	_footer = HBoxContainer.new()
	_footer.name = "Footer"
	_footer.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(_footer)

	_play_button = Button.new()
	_play_button.name = "Play"
	_play_button.text = "Play"
	MKTheme.set_variation(_play_button, MKTheme.PRIMARY_BUTTON)
	_play_button.pressed.connect(_on_play_pressed)
	_footer.add_child(_play_button)

	_delete_button = Button.new()
	_delete_button.name = "Delete"
	_delete_button.text = "Delete"
	MKTheme.set_variation(_delete_button, MKTheme.DANGER_BUTTON)
	_delete_button.pressed.connect(_on_delete_pressed)
	_footer.add_child(_delete_button)

	_new_button = Button.new()
	_new_button.name = "NewCharacter"
	_new_button.text = "New Character"
	MKTheme.set_variation(_new_button, MKTheme.PANEL_BUTTON)
	_new_button.pressed.connect(_on_new_pressed)
	_footer.add_child(_new_button)

	# Built as a typed local rather than an inline literal, for the reason MKConfirmDialog._build
	# records: an untyped Array is refused at runtime by link_chain's Array[Control] parameter.
	var footer_row: Array[Control] = [_play_button, _delete_button, _new_button]
	MKFocus.link_chain(footer_row, false, true)


func _resolve_backends() -> void:
	_profile_backend = _find_profile_backend()
	_menu_backend = _find_menu_backend()
	if _profile_backend == null:
		# ONE warning for the page, naming the slot rather than the symptom. House policy: the panel
		# still renders, with every action disabled — see the class doc.
		MKLog.warn("MKCharacterSelect: no MKProfileBackend is reachable — the roster renders empty and Play/Delete/New are disabled. Assign MKConfig.profile_backend.")
		return
	# Subscribe rather than poll: the backend's contract is that the roster announces its own changes,
	# so deletion here, creation from the creation page, and a host writing profiles directly all
	# redraw through one path.
	if not _profile_backend.roster_changed.is_connected(_on_roster_changed):
		_profile_backend.roster_changed.connect(_on_roster_changed)


func _on_roster_changed() -> void:
	_refresh()


func _refresh() -> void:
	if _card_column == null:
		return
	# Remember the id, not the dictionary: the entry that comes back from the backend after a change
	# is the authoritative one, and re-selecting the stale copy would keep a deleted or renamed
	# profile alive in this panel's hand.
	var previous_id := _selected_id()
	_selected = {}
	_cards.clear()
	for child in _card_column.get_children():
		# remove_child before queue_free, for the reason MKRoot._show_page states: a queued node stays
		# in the tree until end of frame, so the old cards would still answer MKFocus's focusable scan
		# and the rebuilt chain would be wired through corpses.
		_card_column.remove_child(child)
		child.queue_free()

	var entries: Array[Dictionary] = []
	if _profile_backend != null:
		entries = _profile_backend.list_profiles()

	if entries.is_empty():
		# Never a dead end (plan §4.4): an empty roster still offers the one action that can change it,
		# and that action takes focus, so a gamepad-only user is not stranded on a page of nothing.
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "No characters yet." if _profile_backend != null \
			else "No profile backend is assigned."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		MKTheme.set_variation(empty, MKTheme.ROW_LABEL)
		_card_column.add_child(empty)
	else:
		for entry in entries:
			var card := _make_card(entry)
			if card != null:
				_card_column.add_child(card)

	# ORDERING CONSTRAINT — selection BEFORE chaining, and it is not a preference.
	# MKFocus.collect_focusables skips DISABLED buttons, and Play/Delete are disabled until something
	# is selected (_selected was cleared at the top of this rebuild). Chaining first therefore wires a
	# footer ring over New Character alone, and the two buttons _select then enables are left holding
	# whatever neighbours an earlier pass happened to leave on them — reachable today only because
	# _build's one-time link_chain wired the footer once, which is an accident rather than a rule.
	# Selecting first settles every disabled flag, so the chain below is built over the footer as the
	# player will actually see it.
	if not previous_id.is_empty() and _cards.has(previous_id):
		_select(_cards[previous_id].get_meta(&"mk_profile", {}))
	elif not entries.is_empty():
		# Default to the first card rather than to nothing: Play/Delete disabled on arrival reads as a
		# broken page, and a roster always has a sensible default selection.
		_select(entries[0])
	else:
		_update_actions()

	# Chain AFTER the column is populated and after the disabled flags are settled — MKFocus reads the
	# live tree, so a chain built before the cards exist wires nothing.
	MKFocus.chain_container(_card_column)
	MKFocus.chain_container(_footer, false, true)
	MKFocus.link_containers(_card_column, _footer)

	if entries.is_empty() and _new_button != null and not _new_button.disabled:
		_new_button.grab_focus.call_deferred()
	built.emit()


## Builds one focusable card. A [Button] rather than a panel with a click handler because focus,
## keyboard activation and gamepad activation all come free from it — a hand-rolled card would have to
## re-implement all three to satisfy the keyboard-only traversal criterion.
func _make_card(entry: Dictionary) -> Button:
	var id := str(entry.get("id", ""))
	if id.is_empty():
		# The backend contract requires an id, and a card without one cannot be selected, played or
		# deleted. Name the offender rather than rendering a card that does nothing when pressed.
		MKLog.warn("MKCharacterSelect: a roster entry has no 'id' and was skipped — check %s"
			% [_profile_backend.get_script().resource_path if _profile_backend != null \
				and _profile_backend.get_script() != null else "the profile backend"])
		return null
	var card := Button.new()
	card.name = "Card_%s" % id
	card.text = _card_text(entry)
	card.alignment = HORIZONTAL_ALIGNMENT_LEFT
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MKTheme.set_variation(card, MKTheme.PANEL_BUTTON)
	card.set_meta(&"mk_profile", entry)
	card.pressed.connect(_select.bind(entry))
	# Selection follows focus as well as clicks. Without this, arrowing down the list moves the
	# highlight but leaves Play acting on whatever was clicked last — two disagreeing notions of "the
	# selected character" on the same screen.
	card.focus_entered.connect(_select.bind(entry))
	_cards[id] = card
	return card


## The label for one roster entry. [code]archetype[/code] is read defensively and type-gated: it is an
## optional field of an OPAQUE host dictionary, so it may be absent, or hold a resource, a number, or
## a nested dictionary that [method String.str] would render as noise across the whole card.
func _card_text(entry: Dictionary) -> String:
	var display_name := str(entry.get("name", ""))
	if display_name.is_empty():
		display_name = "(unnamed)"
	var archetype: Variant = entry.get("archetype", "")
	if typeof(archetype) == TYPE_STRING or typeof(archetype) == TYPE_STRING_NAME:
		var text := str(archetype)
		if not text.is_empty():
			return "%s — %s" % [display_name, text]
	return display_name


func _select(entry: Dictionary) -> void:
	_selected = entry
	var id := str(entry.get("id", ""))
	for card_id in _cards:
		var card: Button = _cards[card_id]
		if card == null or not is_instance_valid(card):
			continue
		# A variation swap, never a theme override — the one sanctioned way to express dynamic state
		# (MKTheme's class doc), and what keeps the selected card re-skinnable.
		MKTheme.set_variation_if(card, card_id == id, MKTheme.PRIMARY_BUTTON, MKTheme.PANEL_BUTTON)
	_update_actions()


func _selected_id() -> String:
	return str(_selected.get("id", ""))


func _update_actions() -> void:
	var has_backend := _profile_backend != null
	var has_selection := has_backend and not _selected_id().is_empty()
	if _play_button != null:
		_play_button.disabled = not has_selection
	if _delete_button != null:
		_delete_button.disabled = not has_selection
	if _new_button != null:
		# New Character stays live without a selection — it is the action that CREATES one — but not
		# without a backend, which has nowhere to store the result.
		_new_button.disabled = not has_backend


func _on_play_pressed() -> void:
	if _selected_id().is_empty():
		return
	if _menu_backend == null:
		if not _warned_no_menu_backend:
			_warned_no_menu_backend = true
			MKLog.warn("MKCharacterSelect: Play pressed but no MKMenuBackend is reachable — assign MKConfig.menu_backend")
		return
	# The entry goes across VERBATIM. start_game(profile) already exists on the backend contract, and
	# the shipped default ignoring the dictionary is fine: only the host knows what a profile means.
	_menu_backend.start_game(_selected)


func _on_delete_pressed() -> void:
	if _profile_backend == null or _selected_id().is_empty():
		return
	var layer := _find_modal_layer()
	if layer == null:
		# Refuse rather than delete unconfirmed. A destructive action whose confirmation could not be
		# shown must not silently become an unconfirmed one.
		MKLog.warn("MKCharacterSelect: no MKModalLayer is reachable — deletion needs a confirmation and was refused")
		return
	var id := _selected_id()
	var display_name := str(_selected.get("name", id))
	var dialog := MKConfirmDialog.open(layer, "Delete Character",
		"Delete '%s'? This cannot be undone." % display_name, "Delete", "Cancel", true)
	if dialog == null:
		return
	# The dialog frees itself when it is popped (MKConfirmDialog.open's contract), so nothing here owns
	# cleanup. The id is captured rather than re-read at confirm time: the selection can move while the
	# dialog is open, and deleting whatever is selected THEN is not what the prompt named.
	dialog.confirmed.connect(func() -> void:
		# On success there is no manual refresh: delete_profile emits roster_changed, and routing the
		# redraw through that one subscription keeps this panel correct for host-side deletions too.
		if _profile_backend.delete_profile(id):
			return
		# FALSE means the id was not there — the row this panel is still showing describes a profile
		# that has already gone somewhere else (a second client, a host-side write, a stale card left
		# by a backend that changed without announcing it). It is a query result, not a
		# misconfiguration, so it is a debug line rather than a warning; but a panel that did nothing
		# at all here would leave the vanished character on screen and answer the next Delete the same
		# way. Say so to the log, and RESYNC from the backend so the screen agrees with it.
		MKLog.debug("MKCharacterSelect: delete_profile('%s') reported no such profile — the roster moved under this page; refreshing from the backend" % id)
		_refresh()
	)


func _on_new_pressed() -> void:
	var root := _find_ancestor_with("push_page")
	if root == null:
		MKLog.warn("MKCharacterSelect: no MKRoot ancestor — 'New Character' has nowhere to navigate to")
		return
	# push_page, not go_to_page: the creation flow is a SUB-panel of this one, so Escape and the
	# creation page's own cancel return here rather than to the boot page (the §4.4 back-stack ladder).
	# The symmetric pop_page lives in MKCharacterCreate.
	root.call("push_page", CREATE_PAGE_ID)


# --- Ancestor lookups ---------------------------------------------------------

## The duck-typed parent walk MenuKit resolves shell services with, verbatim from
## [code]MKSettingsPanel._find_modal_layer[/code]. Duck-typed rather than typed to [MKRoot] because a
## host may wrap the shell, or embed this panel under its own controller that forwards the call; a
## typed cast would refuse exactly that.
func _find_ancestor_with(method: String) -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method(method):
			return node
		node = node.get_parent()
	return null


func _find_modal_layer() -> MKModalLayer:
	var node := get_parent()
	while node != null:
		if node.has_method("get_modal_layer"):
			var layer: MKModalLayer = node.call("get_modal_layer")
			if layer != null and is_instance_valid(layer):
				return layer
		node = node.get_parent()
	return null


## Kept separate from [method _find_ancestor_with] for the same reason [method _find_modal_layer] is:
## an ancestor may ANSWER the method and still return null (a shell booted with an unassigned slot),
## and the walk must continue past it rather than stop at the first responder.
func _find_profile_backend() -> MKProfileBackend:
	var node := get_parent()
	while node != null:
		if node.has_method("get_profile_backend"):
			var backend: MKProfileBackend = node.call("get_profile_backend")
			if backend != null and is_instance_valid(backend):
				return backend
		node = node.get_parent()
	return null


func _find_menu_backend() -> MKMenuBackend:
	var node := get_parent()
	while node != null:
		if node.has_method("get_menu_backend"):
			var backend: MKMenuBackend = node.call("get_menu_backend")
			if backend != null and is_instance_valid(backend):
				return backend
		node = node.get_parent()
	return null
