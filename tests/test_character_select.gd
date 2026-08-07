extends MKTest
## The character roster page, end to end through a REAL shell (plan §3.1, §4.4), plus the Character
## Creation group's half of [method MKConfig.validate].
##
## [b]Everything below runs inside an MKRoot built from the demo config.[/b] The panel's whole job is
## to be wired to things it does not own — a profile backend two ancestors up, a menu backend beside
## it, a modal layer for its confirmation, and a page stack it pushes the creation flow onto — and
## every one of those is resolved by a duck-typed parent walk. A test that instantiated the panel
## alone and handed it backends directly would assert the panel's internals while leaving the wiring
## (the part that actually breaks) uncovered. The config is [method Resource.duplicate]d first: the
## shipped resource is cached across the sweep, so re-pointing its backend slots at this suite's file
## would leak into every later test.
##
## [b]Activations are real[/b]: focus plus a pushed [code]ui_accept[/code], and a pushed
## [code]ui_cancel[/code] for the back ladder — the mouse route to a button's [signal
## BaseButton.pressed] is dead under the dummy display driver (verified in test_rebind), so a click
## would prove nothing about a button a keyboard player can reach.
##
## [b]Headless boundary.[/b] Card text, roster contents, focus ownership, page ids and modal depth are
## all real headless. Card LAYOUT — whether a long name wraps or the column is wide enough — is a
## human pass on a real display.

const PROFILES_PATH := "user://test_character_select_profiles.json"
const CONFIG_PATH := "res://demo/demo_config.tres"


func run_tests() -> void:
	_clean()
	await _test_the_roster_renders_one_card_per_entry()
	await _test_play_hands_the_selected_entry_over_verbatim()
	await _test_delete_is_confirmed_before_it_happens()
	await _test_a_destructive_dialog_opens_on_cancel()
	await _test_deleting_the_last_entry_leaves_a_reachable_empty_state()
	await _test_navigating_to_an_empty_roster_never_focuses_a_disabled_button()
	await _test_new_character_pushes_and_every_exit_pops_back()
	await _test_the_page_is_drivable_by_keyboard_alone()
	await _test_the_selection_survives_a_roster_rebuild()
	await _test_the_footer_chain_is_built_over_the_buttons_the_rebuild_ends_with()
	await _test_a_missing_profile_backend_warns_once_and_disables_the_actions()
	await _test_a_delete_the_backend_refuses_says_so_and_resyncs()
	await _test_creation_steps_are_reordered_by_config_alone()
	_test_config_validation_reports_every_creation_fault()
	_clean()


## One card per roster entry, and the optional [code]archetype[/code] field read TYPE-GATED: it is an
## optional key of an OPAQUE host dictionary, so it may hold a number, a resource or a nested
## dictionary, and [code]str()[/code]ing one of those across the card is the failure this gate
## prevents. The numeric case also ties the store's int envelope to a real read site.
func _test_the_roster_renders_one_card_per_entry() -> void:
	_seed([
		{"name": "Alice", "archetype": "scout"},
		{"name": "Bob"},
		{"name": "Numeric", "archetype": 7},
	])
	var root := await _make_root()
	var panel := _panel(root)
	check(panel != null, "the characters page built an MKCharacterSelect")
	if panel == null:
		await _drop(root)
		return

	check_eq(_cards(panel).size(), 3, "one card per roster entry")
	check_eq(_card_text(panel, "Alice"), "Alice — scout",
		"a String archetype is shown beside the name — a roster of identically-shaped names is hard to read")
	check_eq(_card_text(panel, "Bob"), "Bob",
		"an entry with no archetype renders the bare name rather than a trailing separator")
	check_eq(_card_text(panel, "Numeric"), "Numeric",
		"and a NON-string archetype is ignored rather than stringified across the card")
	check_eq(_card_text(panel, "Numeric").length(), 7, "specifically: nothing was appended at all")

	check_eq(str(panel.get_selected_profile().get("name", "")), "Alice",
		"the first card is selected on arrival — Play and Delete disabled on a populated roster reads as a broken page")
	check(not _button(panel, "Play").disabled, "so Play is live")
	check(not _button(panel, "Delete").disabled, "and Delete")

	await _drop(root)


## The entry crosses to [method MKMenuBackend.start_game] VERBATIM — only the host knows what a
## profile means, and a panel that reshaped it on the way out would make every host unpack a MenuKit
## dialect of its own save format.
func _test_play_hands_the_selected_entry_over_verbatim() -> void:
	_seed([{"name": "Alice", "archetype": "scout", "level": 7}, {"name": "Bob"}])
	var root := await _make_root()
	var panel := _panel(root)
	var menu := root.get_menu_backend() as SpyMenu
	check(menu != null, "the spy menu backend was instantiated from the slot")
	if panel == null or menu == null:
		await _drop(root)
		return

	await _activate(_card(panel, "Bob"))
	check_eq(str(panel.get_selected_profile().get("name", "")), "Bob",
		"activating a card selects it")
	await _activate(_button(panel, "Play"))

	check_eq(menu.started.size(), 1, "Play reached the menu backend exactly once")
	if menu.started.size() == 1:
		var expected := _roster(root)[1]
		check_eq(menu.started[0], expected,
			"with the selected entry byte-identical to what the roster holds — no filtering, no renaming")
		check_eq(typeof((menu.started[0] as Dictionary).get("id")), TYPE_STRING,
			"including the backend-assigned id the host needs to load it again")

	await _drop(root)


## A destructive action gets a confirmation, and Cancel really cancels. Both outcomes are asserted
## from the same dialog, because a confirm-only test passes against a dialog whose Cancel deletes too.
func _test_delete_is_confirmed_before_it_happens() -> void:
	_seed([{"name": "Alice"}, {"name": "Bob"}])
	var root := await _make_root()
	var panel := _panel(root)
	var layer := root.get_modal_layer()
	if panel == null:
		await _drop(root)
		return

	await _activate(_button(panel, "Delete"))
	check_eq(layer.depth(), 1, "Delete raises a confirmation rather than deleting")
	var dialog := layer.top() as MKConfirmDialog
	check(dialog != null, "and it is an MKConfirmDialog on the shell's own modal layer")
	if dialog == null:
		await _drop(root)
		return

	await _activate(dialog.get_cancel_button())
	check_eq(layer.depth(), 0, "Cancel closes it")
	check_eq(_roster(root).size(), 2, "and the roster is untouched — an unconfirmed delete deletes nothing")
	check_eq(_cards(panel).size(), 2, "with both cards still on screen")

	await _activate(_button(panel, "Delete"))
	var second := layer.top() as MKConfirmDialog
	check(second != null, "a second Delete raises the dialog again")
	if second != null:
		await _activate(second.get_confirm_button())
	check_eq(layer.depth(), 0, "confirming closes the dialog")
	check_eq(_roster(root).size(), 1, "the profile is gone from the backend")
	check_eq(_cards(panel).size(), 1,
		"and its card dropped off the page — through roster_changed, so a host-side deletion redraws the same way")
	check_eq(_card_text(panel, "Bob"), "Bob", "leaving the other entry")

	await _drop(root)


## [b]A destructive dialog must not open with the destructive button under the ring.[/b] The delete
## confirmation and the root's quit-confirm are both one already-travelling accept away from doing
## the thing they exist to ask about, and Phase 6 recorded that as a real defect rather than a taste.
##
## The assertion is on the VIEWPORT's focus owner, not on the dialog's own intent: [method
## MKFocus.trap] re-grabs during the push, after the dialog's [method Node._ready] has run, so a
## dialog that only set its own preference would test green and ship the old behaviour. The
## non-destructive half is asserted from the SAME fixture, because "Cancel is focused" passes just as
## well against a dialog that always focuses Cancel — which would break the conflict modal's Replace
## and the demo's OK dialog.
func _test_a_destructive_dialog_opens_on_cancel() -> void:
	_seed([{"name": "Alice"}])
	var root := await _make_root()
	var layer := root.get_modal_layer()

	var destructive := MKConfirmDialog.open(layer, "Delete Character", "Delete 'Alice'?",
		"Delete", "Cancel", true)
	await step_frame()
	check(destructive != null, "the destructive dialog opened")
	if destructive != null:
		check_eq(get_root().gui_get_focus_owner(), destructive.get_cancel_button(),
			"and the ring starts on CANCEL — an accept that was already travelling must not delete (got %s)"
				% get_root().gui_get_focus_owner())
		check(get_root().gui_get_focus_owner() != destructive.get_confirm_button(),
			"never on the destructive button, which is what the trap's tree-order rule is arranged to produce")
		layer.pop_modal()
		await step_frame()

	var safe := MKConfirmDialog.open(layer, "Binding Conflict", "Space is already bound.",
		"Replace", "Cancel", false)
	await step_frame()
	check(safe != null, "a non-destructive dialog opened on the same layer")
	if safe != null:
		check_eq(get_root().gui_get_focus_owner(), safe.get_confirm_button(),
			"and it still opens on CONFIRM — the flip is scoped to destructive dialogs, not applied to all of them (got %s)"
				% get_root().gui_get_focus_owner())
		layer.pop_modal()
		await step_frame()

	await _drop(root)


## An empty roster is never a dead end (§4.4): the one action that can change it is offered AND takes
## focus, or a gamepad-only user is stranded on a page of nothing.
func _test_deleting_the_last_entry_leaves_a_reachable_empty_state() -> void:
	_seed([{"name": "Solo"}])
	var root := await _make_root()
	var panel := _panel(root)
	var layer := root.get_modal_layer()
	if panel == null:
		await _drop(root)
		return

	await _activate(_button(panel, "Delete"))
	var dialog := layer.top() as MKConfirmDialog
	if dialog != null:
		await _activate(dialog.get_confirm_button())
	await step_frame()
	await step_frame()

	check_eq(_roster(root).size(), 0, "the last profile is gone")
	var empty := panel._card_column.get_node_or_null("Empty") as Label
	check(empty != null, "an empty-state label replaced the cards")
	if empty != null:
		check_eq(empty.text, "No characters yet.",
			"stating the roster is empty, not that a backend is missing — those are different problems")
	check(_button(panel, "Play").disabled, "Play is disabled with nothing selected")
	check(_button(panel, "Delete").disabled, "and Delete")
	check(not _button(panel, "NewCharacter").disabled,
		"but New Character stays live — it is the action that creates one")
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "NewCharacter"),
		"and it TAKES focus, so the page is not a dead end for a gamepad-only player")

	await _drop(root)


## [b]The same empty state, reached by NAVIGATION instead of by deletion — which is a different code
## path and used to land somewhere else entirely.[/b] The panel grabs New Character for itself, but
## MKRoot ALSO focuses the new page's first focusable control on every page change (deferred, so it
## runs last and wins), and MKFocus's collector did not filter disabled buttons: Play sits first in
## the footer's tree order and is disabled with nothing selected, so arriving at an empty roster left
## the ring on a button that swallows every press. A gamepad-only player's first action on a fresh
## install was into silence, with the one live action two controls away.
##
## Asserted through a REAL go_to_page rather than by calling the panel's refresh, because the deferred
## shell-side focus is exactly the half that overrode the panel — and asserted on the button's
## `disabled` flag too, so the case cannot be satisfied by a future footer whose first control merely
## happens to be enabled.
func _test_navigating_to_an_empty_roster_never_focuses_a_disabled_button() -> void:
	_clean()
	var root := await _make_root()
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return
	check_eq(_cards(panel).size(), 0, "precondition: the roster is empty")
	check(_button(panel, "Play").disabled, "precondition: Play is disabled with nothing to select")

	# The shell's focus is deferred, and it is the LAST writer — settle past it rather than reading a
	# frame in which only the panel's own grab has landed.
	await step_frame()
	await step_frame()

	var owner := get_root().gui_get_focus_owner()
	check_eq(owner, _button(panel, "NewCharacter"),
		"focus lands on New Character — the only action an empty roster offers (got %s)" % owner)
	var owner_button := owner as BaseButton
	check(owner_button != null and not owner_button.disabled,
		"and whatever holds focus is ENABLED: Godot lets a disabled control hold focus perfectly happily, which is why this is asserted rather than assumed")

	await _drop(root)


## The §4.4 back ladder, in both directions: the creation flow is a SUB-panel, so it is entered with
## push_page and every exit from it — Escape, the flow's own Cancel, and a completed creation — returns
## to the roster rather than to the boot page.
func _test_new_character_pushes_and_every_exit_pops_back() -> void:
	_seed([{"name": "Alice"}])
	var root := await _make_root()
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return

	await _activate(_button(panel, "NewCharacter"))
	check_eq(root.get_page_id(), MKCharacterSelect.CREATE_PAGE_ID, "New Character navigates to the creation page")
	check_eq(root.get_back_depth(), 1,
		"by PUSHING it — a lateral move would clear the stack and strand the player on the boot page")

	# Escape, through the real unhandled-input ladder.
	check(_cancel(root), "Escape is consumed by the shell")
	await step_frame()
	check_eq(root.get_page_id(), &"characters", "and pops back to the roster")
	check_eq(root.get_back_depth(), 0, "unwinding the stack")

	# The roster page is rebuilt by every navigation (MKRoot frees the old page node), so the panel is
	# re-resolved rather than cached across a pop — holding the old one is a freed-object read.
	panel = _panel(root)
	# The flow's own Cancel button — the gesture a mouse/gamepad player actually uses.
	await _activate(_button(panel, "NewCharacter"))
	var host := _creation_host(root)
	check(host != null, "the creation page hosts an MKCreationHost")
	if host != null:
		await _activate(host._cancel_button)
		check_eq(root.get_page_id(), &"characters", "Cancel leaves the flow the same way Escape does")
		check_eq(root.get_back_depth(), 0, "with the stack unwound")

	# The success exit. Emitted rather than walked: what the flow does with a payload is
	# test_creation_host.gd's subject, and the DELTA here is that the page treats confirmation as an
	# exit at all — a page that only left on Cancel would strand the player on a finished flow.
	panel = _panel(root)
	await _activate(_button(panel, "NewCharacter"))
	var confirm_host := _creation_host(root)
	if confirm_host != null:
		confirm_host.creation_confirmed.emit({"id": "p_x", "name": "New"})
		await step_frame()
		check_eq(root.get_page_id(), &"characters",
			"a confirmed creation pops back to the roster too")
		check_eq(root.get_back_depth(), 0, "and unwinds")

	await _drop(root)


## D12: the whole page is drivable without a mouse, which means the card column and the footer are
## LINKED — a chain that only walks within each group leaves a keyboard player able to reach the cards
## or the buttons but never both.
func _test_the_page_is_drivable_by_keyboard_alone() -> void:
	_seed([{"name": "Alice"}, {"name": "Bob"}])
	var root := await _make_root()
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return

	var first := _card(panel, "Alice")
	first.grab_focus()
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), first, "precondition: focus starts on the first card")

	_nav(&"ui_down")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _card(panel, "Bob"),
		"a real ui_down walks down the card list")
	check_eq(str(panel.get_selected_profile().get("name", "")), "Bob",
		"and selection FOLLOWS focus — otherwise Play acts on whatever was clicked last, which is two disagreeing notions of 'selected' on one screen")

	_nav(&"ui_down")
	await step_frame()
	check(_is_footer_button(panel, get_root().gui_get_focus_owner()),
		"walking off the last card reaches the footer (got %s)" % get_root().gui_get_focus_owner())
	# Which footer button, specifically — and ORDERING-BLIND, which is what this block is and is not.
	# The roster here is seeded before the page is built, so Play and Delete have never been disabled
	# and the chain would come out the same under any _refresh order. These assertions are therefore
	# plain traversal coverage of the first-build footer shape (the ring exists, it walks across every
	# action, and it walks back), not a guard on the chain-vs-disabled-flags ordering. The guard for
	# that is _test_the_footer_chain_is_built_over_the_buttons_the_rebuild_ends_with, which reaches the
	# footer from an EMPTY roster — the only state in which the two orders differ.
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "Play"),
		"landing on the FIRST footer button, not skipping the two actions that were disabled a moment earlier in the rebuild (got %s)"
			% get_root().gui_get_focus_owner())
	_nav(&"ui_right")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "Delete"),
		"and the footer's own ring walks across every action, built over the buttons as the player sees them")
	_nav(&"ui_right")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "NewCharacter"),
		"to the last one")
	_nav(&"ui_left")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "Delete"),
		"and back — a ring wired over a one-button footer would have pointed New Character at itself in both directions")

	# Back to the footer's entry control for the return leg — the cross-container link is wired on the
	# edge pair, so the walk back into the list starts where the walk out arrived.
	_button(panel, "Play").grab_focus()
	await step_frame()
	_nav(&"ui_up")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _card(panel, "Bob"),
		"and ui_up walks back INTO the list — a one-way link is a trap in the other direction")

	await _drop(root)


## A rebuild replaces every card object, so the selection has to be restored BY ID. Restoring the held
## dictionary instead would keep a stale (or deleted) profile alive in the panel's hand.
func _test_the_selection_survives_a_roster_rebuild() -> void:
	_seed([{"name": "Alice"}, {"name": "Bob"}])
	var root := await _make_root()
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return

	await _activate(_card(panel, "Bob"))
	var selected_id := str(panel.get_selected_profile().get("id", ""))
	check(not selected_id.is_empty(), "precondition: a card is selected")
	var card_before := _card(panel, "Bob")

	# A creation through the backend, which is the real route a host or the creation page takes.
	root.get_profile_backend().create_profile({"name": "Zed"})
	await step_frame()
	await step_frame()

	check_eq(_cards(panel).size(), 3, "the roster_changed subscription rebuilt the list")
	check(_card(panel, "Bob") != card_before, "with brand-new card objects")
	check_eq(str(panel.get_selected_profile().get("id", "")), selected_id,
		"and the selection is restored by ID across the rebuild")
	check_eq(str(panel.get_selected_profile().get("name", "")), "Bob", "onto the same character")

	await _drop(root)


## [b]The rebuild that goes EMPTY → POPULATED, which is the one where the footer's chain and the
## footer's disabled flags disagree.[/b]
##
## [method MKCharacterSelect._refresh] clears the selection first, so Play and Delete carry the
## previous state's flags until the selection is restored — and coming from an empty roster that state
## is DISABLED. [method MKFocus.collect_focusables] skips disabled buttons, so a footer chained before
## that restore is a ring over New Character alone, and the cross-container link from the card list
## lands on New with the two live actions bypassed entirely. On the page's FIRST build the buttons
## have never been disabled yet, which is why every existing traversal assertion passes either way:
## this case is the one that arrives at the footer from the empty state.
##
## Driven through a real create_profile so the redraw rides [signal MKProfileBackend.roster_changed],
## the same route a creation flow or a host-side write takes.
func _test_the_footer_chain_is_built_over_the_buttons_the_rebuild_ends_with() -> void:
	_clean()
	var root := await _make_root()
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return
	check(_button(panel, "Play").disabled,
		"precondition: the page starts empty, so Play and Delete are disabled")

	root.get_profile_backend().create_profile({"name": "Alice"})
	await step_frame()
	await step_frame()
	check_eq(_cards(panel).size(), 1, "precondition: the roster_changed rebuild drew the new card")
	check(not _button(panel, "Play").disabled,
		"precondition: and the restored selection re-enabled Play")

	var card := _card(panel, "Alice")
	card.grab_focus()
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), card, "precondition: focus is on the card")

	_nav(&"ui_down")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "Play"),
		"walking off the list reaches Play — the footer was chained over the buttons the rebuild ENDS with, not the ones it started with (got %s)"
			% get_root().gui_get_focus_owner())
	_nav(&"ui_right")
	await step_frame()
	check_eq(get_root().gui_get_focus_owner(), _button(panel, "Delete"),
		"and Delete is on the ring too, rather than reachable only through neighbours some earlier pass left behind")

	await _drop(root)


## House policy, matching [MKSettingsPanel]: a page that vanished when a slot is unassigned is
## indistinguishable from a crashed page, and the host's real mistake goes unnamed. So it renders,
## disabled, and warns ONCE naming the slot to assign.
func _test_a_missing_profile_backend_warns_once_and_disables_the_actions() -> void:
	var host := Control.new()
	host.name = "BareHost"
	get_root().add_child(host)

	_watch_warnings()
	var panel := (ResourceLoader.load("res://addons/menu_kit/panels/mk_character_select.tscn")
		as PackedScene).instantiate() as MKCharacterSelect
	host.add_child(panel)
	await step_frame()
	await step_frame()
	var warnings := _stop_watching()

	check_eq(_count_containing(warnings, "no MKProfileBackend is reachable"), 1,
		"ONE warning for the page, naming the slot rather than the symptom")
	check(_contains(warnings, "MKConfig.profile_backend"),
		"and telling the host which field to assign")
	check_eq(_cards(panel).size(), 0, "no cards are rendered")
	var empty := panel._card_column.get_node_or_null("Empty") as Label
	check(empty != null, "but the page still renders an empty state")
	if empty != null:
		check_eq(empty.text, "No profile backend is assigned.",
			"which says the BACKEND is missing — distinct from an empty roster, because the fixes differ")
	check(_button(panel, "Play").disabled, "Play is disabled")
	check(_button(panel, "Delete").disabled, "Delete is disabled")
	check(_button(panel, "NewCharacter").disabled,
		"and New Character too — unlike an empty roster, there is nowhere to store the result")

	host.queue_free()
	await step_frame()
	await step_frame()


## [method MKProfileBackend.delete_profile] returns a BOOL, and a false is news: the row on screen
## describes a profile the backend does not have. The panel's success path deliberately owns no
## refresh (the redraw rides [signal MKProfileBackend.roster_changed]), and a backend that deleted
## nothing emits nothing — so without reading the return value the panel silently kept showing a
## character that is not there and would answer the next Delete identically.
##
## Both halves are asserted: the panel says so to the log (DEBUG — a stale id is a query result, not a
## misconfiguration), and it RESYNCS, which is observable as the card column having been rebuilt.
func _test_a_delete_the_backend_refuses_says_so_and_resyncs() -> void:
	var root := await _make_root(RefusingBackend)
	var panel := _panel(root)
	var layer := root.get_modal_layer()
	if panel == null:
		await _drop(root)
		return

	check_eq(_cards(panel).size(), 1, "precondition: the refusing backend lists one card")
	var card_before := _card(panel, "Ghost")

	_watch_debug()
	await _activate(_button(panel, "Delete"))
	var dialog := layer.top() as MKConfirmDialog
	check(dialog != null, "precondition: Delete raised its confirmation")
	if dialog != null:
		await _activate(dialog.get_confirm_button())
	var messages := _stop_watching()

	check_eq(_count_containing(messages, "reported no such profile"), 1,
		"the refusal is stated once — a panel that noticed nothing has no line to find when the row will not go away")
	check(_contains(messages, "p_ghost"),
		"naming the id it asked for, which is the only thing that identifies which row disagreed")
	check_eq(_cards(panel).size(), 1, "the row is still listed, because the backend still lists it")
	check(_card(panel, "Ghost") != card_before,
		"but the column was REBUILT from the backend rather than left as it was — the panel resynced instead of doing nothing")

	await _drop(root)


## [method MKConfig.validate]'s Character Creation half. Every rule is asserted to fire ONCE and to
## name its own offender, and they are stacked in one config on purpose: the contract is a single pass
## that reports everything, so an integrator gets one list to work through rather than a fix-run-fix
## loop.
func _test_config_validation_reports_every_creation_fault() -> void:
	var config := MKConfig.new()
	config.archetypes = [null, _archetype(&""), _archetype(&"dup"), _archetype(&"dup")]
	config.creation_steps = [null, _step(&""), _step(&"dup"), _step(&"dup"), _step(&"no_scene", false)]
	var schema := MKStatSchema.new()
	schema.total_points = 0
	schema.stats = [null, _stat(&"inverted", 5, 1, 1), _stat(&"free", 0, 5, 0),
		_stat(&"dup", 0, 5, 1), _stat(&"dup", 0, 5, 1)]
	config.point_buy_schema = schema

	var problems := config.validate()
	var joined := "\n".join(problems)

	check_eq(_lines_containing(problems, "archetypes: entry 0 is null"), 1, "a null archetype entry is named")
	check_eq(_lines_containing(problems, "an archetype needs at least an id and a display_name"), 1,
		"an unusable archetype is named with the fix")
	check_eq(_lines_containing(problems, "duplicate archetype id 'dup'"), 1,
		"a duplicate archetype id is named once, not once per copy")
	check_eq(_lines_containing(problems, "creation_steps: entry 0 is null"), 1, "a null step entry is named")
	check_eq(_lines_containing(problems, "a step needs at least an id"), 1, "an id-less step is named")
	check_eq(_lines_containing(problems, "duplicate step id 'dup'"), 1, "a duplicate step id is named")
	check_eq(_lines_containing(problems, "has no scene"), 1,
		"a step with no scene is reported SEPARATELY from a malformed one — the two have different fixes")
	check_eq(_lines_containing(problems, "total_points is 0"), 1,
		"a pool with nothing to spend is named")
	check_eq(_lines_containing(problems, "stats: entry 0 is null"), 1, "a null stat entry is named")
	check_eq(_lines_containing(problems, "min_value 5 above max_value 1"), 1,
		"an inverted stat range is named")
	check_eq(_lines_containing(problems, "cost_per_point 0"), 1,
		"a cost below 1 is named — it makes the pool infinite")
	check_eq(_lines_containing(problems, "duplicate stat id 'dup'"), 1, "a duplicate stat id is named")
	check(problems.size() >= 12,
		"and every one of them is reported in the SAME pass (got %d)" % problems.size())
	check(joined.contains("archetypes") and joined.contains("creation_steps") and joined.contains("stats"),
		"each message names its own field, not just a description")

	# The empty-stats rule needs its own schema: it cannot coexist with the per-stat rules above.
	var empty_schema := MKStatSchema.new()
	empty_schema.total_points = 5
	var empty_config := MKConfig.new()
	empty_config.point_buy_schema = empty_schema
	check_eq(_lines_containing(empty_config.validate(), "no stats"), 1,
		"an assigned schema with no stats is named, with 'leave it null to disable' as the alternative")

	# D17's default: point-buy OFF is the supported configuration, so absence reports nothing at all.
	var clean := MKConfig.new()
	check_eq(clean.validate(), PackedStringArray(),
		"a config with no archetypes, no steps and NO schema reports nothing — declining an optional feature is not a fault")


## [b]Phase 5 exit criterion: "reorder the steps via config and the flow follows".[/b] It was verified
## by hand and had no suite coverage at all, which for a criterion about CONFIG driving the flow is the
## easiest thing to break silently — [method MKCharacterCreate._resolve_steps] could start ignoring
## [member MKConfig.creation_steps] entirely and every other test in this repo would stay green.
##
## Driven through the REAL creation page rather than by calling [method MKCreationHost.configure]: the
## criterion is not "the host walks the array it was handed" (test_creation_host.gd owns that) but "the
## array a host AUTHORS is the one that reaches it", and the resolve-and-configure seam between the two
## is the only part that can fail this. So the config is authored, the shell boots it, New Character
## pushes the real page, and the order is read off the flow that resulted.
##
## Both halves are asserted, because they are two branches of one method: an authored order is used
## verbatim, and an EMPTY one falls back to the built-in Name → Archetype → Appearance rather than
## rendering a stepless page.
func _test_creation_steps_are_reordered_by_config_alone() -> void:
	_seed([{"name": "Alice"}])
	# Deliberately the exact REVERSE of the built-in order, so a fallback that ignored the config would
	# produce the mirror image rather than something that happens to overlap.
	var authored: Array[MKCreationStepDef] = []
	authored.append(_creation_step(&"appearance", "Appearance", "mk_step_appearance"))
	authored.append(_creation_step(&"archetype", "Archetype", "mk_step_archetype"))
	authored.append(_creation_step(&"name", "Name", "mk_step_name"))

	var root := await _make_root(null, authored)
	var panel := _panel(root)
	if panel == null:
		await _drop(root)
		return
	await _activate(_button(panel, "NewCharacter"))
	var host := _creation_host(root)
	check(host != null, "the creation page built a host from the authored config")
	if host != null:
		check_eq(_step_ids(host), PackedStringArray(["appearance", "archetype", "name"]),
			"the flow walks the authored order, not the built-in one")
		check_eq(host.current_step_index(), 0, "and opens on its first step")
		check_eq(host._title_label.text, "Appearance",
			"which is the authored first step, on screen — the player-visible half of the same claim")
	await _drop(root)

	# The unauthored case. Empty means "I did not author this", never "I want no steps": a zero-step
	# flow can create nothing, so an empty array must produce the built-in order rather than a dead page.
	_seed([{"name": "Alice"}])
	var empty: Array[MKCreationStepDef] = []
	var default_root := await _make_root(null, empty)
	var default_panel := _panel(default_root)
	if default_panel == null:
		await _drop(default_root)
		return
	await _activate(_button(default_panel, "NewCharacter"))
	var default_host := _creation_host(default_root)
	check(default_host != null, "an unauthored config still builds a flow")
	if default_host != null:
		check_eq(_step_ids(default_host), PackedStringArray(["name", "archetype", "appearance"]),
			"in the built-in order — and point-buy is NOT in it, since a game with no stat concept must not be handed a stat screen (D17)")
		check_eq(default_host._title_label.text, "Name", "opening on Name")
	await _drop(default_root)


## The ids of the steps a host actually built, in flow order. Read off [code]_steps[/code] rather than
## walked with Next: walking needs each step to answer valid, and the name step deliberately does not
## until something is typed into it — which would make an ORDER assertion depend on the validation
## rules of whichever steps the order happens to put first.
func _step_ids(host: MKCreationHost) -> PackedStringArray:
	var out := PackedStringArray()
	for def in host._steps:
		out.append(String(def.id))
	return out


func _creation_step(id: StringName, title: String, scene_stem: String) -> MKCreationStepDef:
	var def := MKCreationStepDef.new()
	def.id = id
	def.title = title
	def.scene = ResourceLoader.load("res://addons/menu_kit/creation/steps/%s.tscn" % scene_stem)
	check(def.scene != null, "the '%s' step scene loaded" % scene_stem)
	return def


# --- Fixtures -----------------------------------------------------------------

## Writes the roster through the REAL backend on this suite's own file, before the shell boots. Seeding
## by hand-writing JSON would test the file format instead of the panel, and seeding through the shell
## would need the panel to work before it could be measured.
func _seed(entries: Array) -> void:
	_clean()
	var backend := MKJsonProfileBackend.new()
	backend._mk_configure({"file_path": PROFILES_PATH})
	get_root().add_child(backend)
	for entry in entries:
		var created := backend.create_profile(entry)
		check(not created.is_empty(), "seeded '%s'" % entry.get("name", "?"))
	get_root().remove_child(backend)
	backend.free()


## A real shell on the demo config, with its profile slot re-pointed at this suite's file and its menu
## slot at a spy. Duplicated first — the shipped config is a cached resource and mutating it would
## leak into every later test in the sweep.
## [param profile_script] swaps the shipped JSON backend for a stub in the ONE case that needs a
## backend behaviour the real one cannot be talked into (a delete that refuses). It still arrives
## through the slot, so the panel resolves it by the same duck-typed walk as always.
## [param creation_steps] replaces the demo config's authored order when it is non-null (an EMPTY
## array is a meaningful value — it is how the unauthored case is reached, and it is why the parameter
## is nullable rather than defaulted to []).
func _make_root(profile_script: Script = null, creation_steps: Variant = null) -> MKRoot:
	var config := (ResourceLoader.load(CONFIG_PATH) as MKConfig).duplicate(true)
	if creation_steps != null:
		config.creation_steps.assign(creation_steps as Array)
	var profile_slot := MKBackendSlot.new()
	profile_slot.backend_script = profile_script if profile_script != null else MKJsonProfileBackend
	if profile_script == null:
		profile_slot.params = {"file_path": PROFILES_PATH}
	config.profile_backend = profile_slot
	var menu_slot := MKBackendSlot.new()
	menu_slot.backend_script = SpyMenu
	config.menu_backend = menu_slot
	check_eq(config.validate(), PackedStringArray(),
		"the re-pointed config still validates — a slot carrying an MKMenuBackend subclass is legal")

	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()
	root.go_to_page(&"characters")
	await step_frame()
	await step_frame()
	return root


func _drop(root: Node) -> void:
	if root != null and is_instance_valid(root):
		root.queue_free()
	await step_frame()
	await step_frame()
	_clean()


func _archetype(id: StringName) -> MKArchetype:
	var arch := MKArchetype.new()
	arch.id = id
	# An id-less archetype is left nameless too, so the "needs at least an id and a display_name"
	# message is what fires rather than a duplicate-of-empty-id line.
	arch.display_name = "" if id == &"" else String(id).capitalize()
	return arch


func _step(id: StringName, with_scene := true) -> MKCreationStepDef:
	var def := MKCreationStepDef.new()
	def.id = id
	if with_scene:
		def.scene = ResourceLoader.load("res://addons/menu_kit/creation/steps/mk_step_appearance.tscn")
	return def


func _stat(id: StringName, min_value: int, max_value: int, cost: int) -> MKStatDef:
	var stat := MKStatDef.new()
	stat.id = id
	stat.min_value = min_value
	stat.max_value = max_value
	stat.cost_per_point = cost
	return stat


# --- Lookups ------------------------------------------------------------------

func _panel(root: Node) -> MKCharacterSelect:
	for node in _descendants(root):
		if node is MKCharacterSelect:
			return node
	return null


func _creation_host(root: Node) -> MKCreationHost:
	for node in _descendants(root):
		if node is MKCharacterCreate:
			return (node as MKCharacterCreate).get_creation_host()
	return null


func _roster(root: MKRoot) -> Array[Dictionary]:
	return root.get_profile_backend().list_profiles()


## The card Buttons currently on screen, excluding the empty-state Label.
func _cards(panel: MKCharacterSelect) -> Array[Button]:
	var out: Array[Button] = []
	for child in panel._card_column.get_children():
		var button := child as Button
		if button != null:
			out.append(button)
	return out


func _card(panel: MKCharacterSelect, display_name: String) -> Button:
	for card in _cards(panel):
		if card.text.begins_with(display_name):
			return card
	return null


func _card_text(panel: MKCharacterSelect, display_name: String) -> String:
	var card := _card(panel, display_name)
	return card.text if card != null else "<no card for %s>" % display_name


func _button(panel: MKCharacterSelect, node_name: String) -> Button:
	return panel._footer.get_node_or_null(node_name) as Button


func _is_footer_button(panel: MKCharacterSelect, node: Node) -> bool:
	return node != null and node.get_parent() == panel._footer


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			out.append(child)
			stack.push_back(child)
	return out


func _lines_containing(problems: PackedStringArray, needle: String) -> int:
	var found := 0
	for problem in problems:
		if problem.contains(needle):
			found += 1
	return found


# --- Input drivers ------------------------------------------------------------

## Focus the control and push a REAL ui_accept press/release, so the engine's own BaseButton
## activation runs — including the disabled check the null-backend assertions rely on.
func _activate(button: Button) -> void:
	if button == null or not is_instance_valid(button):
		fail("tried to activate a button that does not exist")
		return
	button.grab_focus()
	await step_frame()
	get_root().push_input(_key(KEY_ENTER, true), true)
	get_root().push_input(_key(KEY_ENTER, false), true)
	await step_frame()
	await step_frame()


## A real ui_cancel through the viewport's unhandled-input path, returning whether it was consumed —
## the same driver test_navigation uses, so the ladder is exercised through the engine's own dispatch
## order rather than by calling the handler.
func _cancel(root: MKRoot) -> bool:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	root.get_viewport().push_input(event)
	return root.get_viewport().is_input_handled()


## Focus navigation, pushed as the action the engine's own GUI traversal reads.
func _nav(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	get_root().push_input(event)


func _key(code: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.pressed = pressed
	return event


## Lists one profile and refuses every delete — the shape a roster takes when the entry went away
## through a route this panel never saw. The real JSON backend cannot be made to do this: it returns
## false only for an id that is not in its roster, and an id not in the roster has no card to press
## Delete on.
class RefusingBackend extends MKProfileBackend:
	func list_profiles() -> Array[Dictionary]:
		return [{"id": "p_ghost", "name": "Ghost"}] as Array[Dictionary]

	func create_profile(_payload: Dictionary) -> Dictionary:
		return {}

	func delete_profile(_id: String) -> bool:
		return false

	func load_profile(_id: String) -> Dictionary:
		return {}


## Records what Play handed over. A Node backend instantiated by MKRoot from the slot, exactly as a
## host's own would be — the panel resolves it by the same duck-typed walk either way.
class SpyMenu extends MKMenuBackend:
	var started: Array[Dictionary] = []

	func start_game(profile: Dictionary) -> void:
		started.append(profile.duplicate(true))

	func to_main_menu() -> void:
		pass

	func quit() -> void:
		pass


# --- Observation --------------------------------------------------------------

var _warnings: Array[String] = []


func _watch_warnings() -> void:
	_warnings = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_warnings.append(message)


## The DEBUG channel, kept separate from the warning watcher above: the refused-delete line is
## specified as a debug line ("a stale id is a query result, not a misconfiguration"), and a watcher
## that collected every level could not tell the two apart.
func _watch_debug() -> void:
	_warnings = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.DEBUG:
			_warnings.append(message)


func _stop_watching() -> Array[String]:
	MKLog.observer = Callable()
	return _warnings


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found


func _contains(messages: Array[String], needle: String) -> bool:
	return _count_containing(messages, needle) > 0


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := PROFILES_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)
