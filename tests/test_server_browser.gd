extends MKTest
## The Phase 7 server browser: absence under the shipped config, presence under the demo's, and the
## whole connect lifecycle rendered from the SHIPPED [MKStubNetworkBackend] (plan §5 row 7).
##
## [b]Shipped assets, not lookalikes.[/b] Every shell here boots a duplicate of a shipped [MKConfig]
## — [code]addons/menu_kit/default_config.tres[/code] for the absence half, [code]demo/demo_config.tres[/code]
## for everything else — and the only field ever replaced is the demo's network SLOT, whose
## [code]connect_delay[/code]/[code]refresh_delay[/code] params are retimed so a lifecycle that takes
## 1.2 seconds on a player's screen resolves inside a headless sweep. The backend script, the page
## def, the panel scene and the row data are the ones a host gets.
##
## [b]Gestures where the driver can reach.[/b] Rows are selected by FOCUSING them (the panel selects
## on [signal Control.focus_entered], so that is a real gesture) and the footer buttons are activated
## by focus plus a pushed [code]ui_accept[/code] — the [code]test_pause_menu[/code] idiom. A pushed
## mouse click never reaches GUI dispatch headless (§4), so no test here pretends to click. The two
## paths a gesture cannot reach at all — an entry with an unknown id, which no row carries — are
## driven at the BACKEND and asserted at the PANEL, which is the seam under test in those cases
## anyway.
##
## [b]Expected noise.[/b] Two tests provoke [method MKLog.warn] on purpose (the unknown-id refusal,
## the missing-slot naming). Warnings are deliberately outside [code]check.ps1[/code]'s noise pattern,
## so declaring them through [method expect_engine_error] would be an UNMATCHED declaration and fail
## the run by itself. They are asserted through [member MKLog.observer] instead, which is what that
## seam exists for.

const SHIPPED_CONFIG := "res://addons/menu_kit/default_config.tres"
const DEMO_CONFIG := "res://demo/demo_config.tres"
const BROWSER_SCENE := "res://addons/menu_kit/panels/mk_server_browser.tscn"
const SERVERS_PAGE := &"servers"

## Long enough that no headless sweep can outrun it, so a test asserting the CONNECTING state is
## measuring the panel and not a race it happened to win.
const HELD_DELAY := 30.0
## Short enough to resolve within the bounded frame loops below.
const QUICK_DELAY := 0.05

## Messages seen by [member MKLog.observer] while a test has it installed.
var _log_lines: Array[String] = []


func run_tests() -> void:
	await _test_the_shipped_config_has_no_server_browser_anywhere()
	await _test_the_demo_config_authors_the_page_and_the_rows_are_the_backend_s()
	await _test_connecting_resolves_to_connected()
	await _test_the_connecting_state_owns_the_footer()
	await _test_cancel_from_connecting_and_the_focus_it_leaves_behind()
	await _test_the_unreachable_server_fails_with_its_timeout_message()
	await _test_an_unknown_id_fails_synchronously_and_the_panel_says_which()
	await _test_refresh_rebuilds_the_rows_and_keeps_the_selection()
	await _test_no_backend_renders_the_empty_state_and_warns_once()
	await _test_the_page_focuses_something_on_entry()
	await _test_the_backend_walk_passes_a_null_answering_shell()
	await _test_the_connecting_flip_moves_the_ring_off_the_button_it_disabled()
	await _test_a_rebuild_hands_the_ring_back_to_the_selected_row()
	await _test_a_minimal_backend_gets_its_state_and_its_rows_on_screen()
	await _test_re_entering_mid_connect_seeds_the_connecting_state()
	await _test_an_out_of_enum_state_renders_its_number()
	await _test_a_nameless_entry_renders_the_unnamed_fallback()
	await _test_an_id_less_entry_is_skipped_and_named_once()
	await _test_the_backendless_page_leaves_cancel_live_too()
	await _test_the_demo_nav_is_exactly_five_pages_in_order()


# --- Absence ------------------------------------------------------------------

## Row 7's first clause, in both the directions it can be broken: the shipped config must not NAME
## this scene, and a shell booted from it must never INSTANTIATE the panel.
##
## The second half is not implied by the first — a host controller, a stray default, or a page def
## added later would produce a browser on screen with the config's own page list still innocent — so
## every page in the shipped config is actually visited and the whole shell tree scanned after each.
## The network slot's emptiness is asserted at the resource AND at the booted shell, because the
## panel resolves the backend by walking ancestors: "the slot is null" and "the walk answers null"
## are different facts and only the second one hides the browser.
func _test_the_shipped_config_has_no_server_browser_anywhere() -> void:
	var shipped := load(SHIPPED_CONFIG) as MKConfig
	check(shipped != null, "the shipped default config loads")
	if shipped == null:
		return
	check(shipped.network_backend == null or not shipped.network_backend.is_assigned(),
		"its network slot ships EMPTY — the §3.1 cold-drop first impression")

	var naming: Array[String] = []
	for page in shipped.pages:
		if page.scene != null and page.scene.resource_path == BROWSER_SCENE:
			naming.append(String(page.id))
	check_eq(naming, [] as Array[String],
		"and NO page def in it names mk_server_browser.tscn — the panel is optional by config, not by a runtime check")
	check(shipped.pages.size() > 0, "precondition: the config authors pages at all, so the sweep above looked at something")

	var config := shipped.duplicate(false) as MKConfig
	var root := _make_shell(config)
	await step_frame()
	check(root.get_network_backend() == null,
		"a shell booted from it resolves NO network backend, which is what a browser page would have found")
	var visited := 0
	for page in config.pages:
		root.go_to_page(page.id)
		await step_frame()
		await step_frame()
		visited += 1
		if _find_typed(root, "MKServerBrowser") != null:
			fail("page '%s' of the shipped config put an MKServerBrowser on screen" % page.id)
			break
	check(visited == config.pages.size(),
		"every page of the shipped config was visited and none of them was a server browser (%d pages)" % visited)

	root.free()
	await step_frame()


# --- Presence -----------------------------------------------------------------

## Row 7's second clause: present under the demo config, and the list it shows is the BACKEND's.
##
## Row text is asserted by content rather than by an exact format string: the panel's own doc says the
## optional keys render "when present", so pinning the punctuation would break on a layout tweak while
## missing the thing that matters — that the name and the ping of every entry reached the screen.
func _test_the_demo_config_authors_the_page_and_the_rows_are_the_backend_s() -> void:
	var demo := load(DEMO_CONFIG) as MKConfig
	check(demo != null, "the demo config loads")
	if demo == null:
		return
	var def := demo.get_page(SERVERS_PAGE)
	check(def != null, "it authors a 'servers' page")
	check(def != null and def.scene != null and def.scene.resource_path == BROWSER_SCENE,
		"whose scene is the shipped mk_server_browser.tscn")
	check(def != null and def.visible, "and it is a visible nav tab, not a hidden sub-page")

	var root := _make_shell(_demo_config())
	var panel := await _open_browser(root)
	check(panel != null, "go_to_page('servers') instantiated MKServerBrowser")
	if panel == null:
		root.free()
		await step_frame()
		return

	var backend := root.get_network_backend()
	check(backend != null, "the demo's stub slot produced a network backend the panel could find")
	var entries := backend.list_servers()
	check_eq(entries.size(), 3, "the shipped stub offers three servers")
	var rows := _rows(panel)
	check_eq(rows.size(), entries.size(),
		"and the panel built exactly one row per entry — no empty-state label standing in for a list it has")
	for entry in entries:
		var row := _row(panel, String(entry["id"]))
		check(row != null, "there is a row for '%s'" % entry["id"])
		if row == null:
			continue
		check(row.text.contains(String(entry["name"])),
			"row '%s' renders its name" % entry["id"])
		check(row.text.contains("%d ms" % int(entry["ping"])),
			"and its ping (%d ms), which is the field a refresh moves" % int(entry["ping"]))

	check_eq(String(panel.get_selected_server().get("id", "")), String(entries[0]["id"]),
		"the first row is selected on arrival — a Connect button disabled on a freshly opened list reads as a broken page")
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.IDLE,
		"and nothing has been connected yet")
	check_eq(_status(panel), MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.IDLE],
		"so the status line carries the IDLE caption alone — the stub emits no message with it")

	root.free()
	await step_frame()


# --- The lifecycle ------------------------------------------------------------

## CONNECTING → CONNECTED, driven through the footer button by a real keyboard activation, and
## asserted on the STATUS LINE rather than only on the panel's state getter: the caption and the
## message are two independent halves of one contract (the stub distinguishes its three failures by
## message alone), and a panel that dropped either would still report the right enum.
##
## The emission SEQUENCE is recorded off the backend as well, because "the panel ends on CONNECTED"
## is equally true of a stub that skipped CONNECTING entirely — which would make the Cancel button
## and the whole connecting state unreachable in the product.
func _test_connecting_resolves_to_connected() -> void:
	var root := _make_shell(_demo_config(QUICK_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	var backend := root.get_network_backend()
	var seen: Array[int] = []
	backend.connect_state_changed.connect(func(state: int, _m: String) -> void: seen.append(state))

	await _select_row(panel, "mk_stub_local")
	check_eq(String(panel.get_selected_server().get("id", "")), "mk_stub_local",
		"focusing a row selects it — selection follows focus, or a gamepad player connects to whatever was clicked last")
	await _activate(_button(panel, "Connect"))

	var resolved := await _await_state(panel, MKNetworkBackend.ConnectState.CONNECTED)
	check(resolved, "the connect resolved to CONNECTED within the frame budget")
	check_eq(seen, [MKNetworkBackend.ConnectState.CONNECTING, MKNetworkBackend.ConnectState.CONNECTED] as Array[int],
		"through CONNECTING first — a stub that jumped straight to CONNECTED would make the Cancel affordance unreachable in the product")
	var status := _status(panel)
	check(status.contains(MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.CONNECTED]),
		"the status line carries the CONNECTED caption")
	check(status.contains("Connected to Local Test Server."),
		"AND the backend's message, which is where the stub puts everything the caption cannot say")
	check(not _button(panel, "Connect").disabled, "Connect is live again once the attempt is over")
	check(_button(panel, "Cancel").disabled, "and Cancel is not — there is nothing in flight to abort")

	root.free()
	await step_frame()


## The CONNECTING state itself: what it says, and which of the three footer buttons it leaves live.
## Driven on a shell whose connect delay outlives the whole sweep, so the assertions below cannot be
## a race the test happened to win.
func _test_the_connecting_state_owns_the_footer() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	check(not _button(panel, "Connect").disabled, "Connect is live with a selection and nothing in flight")
	check(_button(panel, "Cancel").disabled,
		"while Cancel is DISABLED outside CONNECTING — cancel() is documented safe when idle, but 'safe' is not an affordance")

	await _select_row(panel, "mk_stub_ranked")
	await _activate(_button(panel, "Connect"))
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING,
		"a keyboard activation of Connect really started the attempt — this is the row-7 gesture, not a pressed.emit()")
	var status := _status(panel)
	check(status.contains(MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.CONNECTING]),
		"the status line carries the CONNECTING caption")
	check(status.contains("Ranked Deathmatch"),
		"and the message names the server being reached, so two attempts in a row are distinguishable")
	check(_button(panel, "Connect").disabled,
		"Connect is disabled mid-flight — a second press would supersede the attempt the player is watching")
	check(not _button(panel, "Cancel").disabled, "Cancel is the live affordance instead")
	check(not _button(panel, "Refresh").disabled,
		"and Refresh stays live throughout: refresh() touches the LIST, not the connection")

	root.free()
	await step_frame()


## Cancel, through the button, from CONNECTING — and the focus question the flip raises.
##
## [b]The focus half is the point.[/b] Cancel is FOCUSED when it is pressed (that is what the gesture
## is), and the CANCELLED state it produces disables it. Godot lets a disabled Control keep focus and
## [method MKServerBrowser._chain_focus] rewires neighbours without moving the ring, so this gesture
## used to end with the player's next Enter landing on a button that does nothing —
## [method MKServerBrowser._recover_focus] is what moves it, and Connect (live again, and the retry
## the player wants) is where it goes.
func _test_cancel_from_connecting_and_the_focus_it_leaves_behind() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	await _select_row(panel, "mk_stub_local")
	await _activate(_button(panel, "Connect"))
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING, "an attempt is in flight")

	await _activate(_button(panel, "Cancel"))
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.CANCELLED,
		"activating Cancel cancelled it — CANCELLED, not FAILED: the player's own decision is not an error")
	var status := _status(panel)
	check(status.contains(MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.CANCELLED]),
		"the status line carries the CANCELLED caption")
	check(status.contains("Connection cancelled."), "and the stub's message alongside it")
	check(_button(panel, "Cancel").disabled, "Cancel disables itself again — there is nothing left to abort")
	check(not _button(panel, "Connect").disabled, "and Connect comes back, so the player can retry")

	var owner_control := root.get_viewport().gui_get_focus_owner()
	check(owner_control != null,
		"focus is not lost to null when the focused Cancel greys out")
	check(owner_control != _button(panel, "Cancel"),
		"and it does NOT stay on the disabled Cancel — a ring on a button that swallows every activation is the dead end MKFocus documents")
	check(owner_control == _button(panel, "Connect"),
		"it lands on Connect: the live primary action, which is also the retry this state invites")

	root.free()
	await step_frame()


## The plan's "timeout" criterion, read from the stub rather than assumed: the abstract enum has no
## TIMEOUT member, so the unreachable server reports FAILED with "Connection timed out." — a MESSAGE
## under a shared caption. This is precisely why the panel appends the message always instead of using
## it as a fallback, and the assertion pins both halves: a panel rendering only the caption would show
## a timeout and a rejected id identically.
func _test_the_unreachable_server_fails_with_its_timeout_message() -> void:
	var root := _make_shell(_demo_config(QUICK_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	await _select_row(panel, String(MKStubNetworkBackend.FAILING_SERVER_ID))
	check_eq(String(panel.get_selected_server().get("id", "")), String(MKStubNetworkBackend.FAILING_SERVER_ID),
		"the unreachable server is selected")
	await _activate(_button(panel, "Connect"))
	var resolved := await _await_state(panel, MKNetworkBackend.ConnectState.FAILED)
	check(resolved, "it resolves to FAILED")
	var status := _status(panel)
	check(status.contains(MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.FAILED]),
		"under the FAILED caption")
	check(status.contains("Connection timed out."),
		"carrying the TIMEOUT message — the only thing that distinguishes this outcome from the other two FAILED ones")
	check(not _button(panel, "Connect").disabled, "and Connect is live again for a retry")
	check(_button(panel, "Cancel").disabled, "with Cancel back down")

	root.free()
	await step_frame()


## The synchronous refusal. No row carries an unknown id — the panel hands entries back verbatim — so
## this is driven at the backend and asserted at the PANEL, which is exactly the seam under test: a
## state emitted before any timer exists must still reach the status line.
##
## The stub warns on the way through; that warning is the noise this test declares by OBSERVING it
## rather than by expect_engine_error, which the gate would leave unmatched (§4).
func _test_an_unknown_id_fails_synchronously_and_the_panel_says_which() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	var backend := root.get_network_backend()

	_watch_log()
	backend.connect_to({"id": &"mk_not_a_server"})
	_unwatch_log()
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.FAILED,
		"an unknown id fails immediately — no timer, no CONNECTING state to sit in")
	var status := _status(panel)
	check(status.contains(MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.FAILED]),
		"the panel rendered the FAILED caption from a state emitted before it could have polled anything")
	check(status.contains("Unknown server."),
		"with the message that tells it apart from a timeout — the two share a caption")
	check_eq(_log_lines.filter(func(l: String) -> bool: return l.contains("unknown server id")).size(), 1,
		"and the backend named the offending id once")

	# The other synchronous refusal, for the same reason: an entry with no id at all.
	backend.connect_to({})
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.FAILED, "an id-less entry fails too")
	check(_status(panel).contains("Invalid server entry."),
		"with its own third message under the same caption")

	root.free()
	await step_frame()


# --- Refresh ------------------------------------------------------------------

## Refresh: the sweep rebuilds the rows from the backend's own (deterministically nudged) numbers, and
## the SELECTION survives it.
##
## The ping arithmetic is asserted against the stub's stated formula rather than merely "changed", so
## a rebuild that re-rendered the stale list would fail here instead of passing on a coincidence. The
## selection clause is what the panel's [code]previous_id[/code] restore exists for: losing it would
## disable Connect under a player who had already chosen, one press before they were going to use it.
func _test_refresh_rebuilds_the_rows_and_keeps_the_selection() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY, QUICK_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	var backend := root.get_network_backend()
	await _select_row(panel, "mk_stub_ranked")
	var before := backend.list_servers()
	var before_ping := int(_find_entry(before, "mk_stub_ranked")["ping"])
	check_eq(before_ping, 48, "precondition: the shipped stub's ranked server starts at 48 ms")

	var builds: Array[int] = [0]
	panel.built.connect(func() -> void: builds[0] += 1)
	await _activate(_button(panel, "Refresh"))
	var rebuilt := await _await_signalled(builds)
	check(rebuilt, "the sweep emitted servers_changed and the panel rebuilt from it")

	var expected := 8 + ((before_ping + 7) % 200)
	var after := backend.list_servers()
	check_eq(int(_find_entry(after, "mk_stub_ranked")["ping"]), expected,
		"the stub nudged the ping by its stated deterministic formula (%d → %d)" % [before_ping, expected])
	var row := _row(panel, "mk_stub_ranked")
	check(row != null and row.text.contains("%d ms" % expected),
		"and the REBUILT row renders the new number — a redraw that kept the stale label would pass every count-based assertion")
	check(row != null and not row.text.contains("%d ms" % before_ping),
		"with the old one gone")
	check_eq(_rows(panel).size(), after.size(), "the row count still matches the list")

	check_eq(String(panel.get_selected_server().get("id", "")), "mk_stub_ranked",
		"the SELECTION survived the rebuild — the panel restores it by id, not by holding the stale dictionary")
	check_eq(int(panel.get_selected_server().get("ping", -1)), expected,
		"and it is the FRESH entry that is now selected, not the copy the backend has moved on from")
	check(not _button(panel, "Connect").disabled,
		"so Connect is still live: a refresh must not disarm a player who had already chosen")

	root.free()
	await step_frame()


# --- No backend ---------------------------------------------------------------

## The backendless page: the shipped empty state, silence at boot, and ONE warning per page however
## many times it is pressed.
##
## All three clauses are counts, which is what [member MKLog.observer] exists for. The boot clause is
## the one gate 2 cares about — a page that warned on arrival would fire on every correct cold drop of
## a config that simply has no network — and the once-per-page clause is what keeps the first warning
## readable when a player presses twice.
func _test_no_backend_renders_the_empty_state_and_warns_once() -> void:
	var config := _demo_config()
	# The demo's page def stays; only the SLOT is emptied. That is the configuration a host reaches by
	# authoring the page and forgetting the backend, and it is the only one in which the panel's empty
	# state is visible at all.
	config.network_backend = null

	_watch_log()
	var root := _make_shell(config)
	var panel := await _open_browser(root)
	var boot_lines := _log_lines.filter(func(l: String) -> bool: return l.contains("MKServerBrowser"))
	_unwatch_log()
	check(panel != null, "the page still builds with an empty network slot — absence is a state, not an error")
	if panel == null:
		root.free()
		await step_frame()
		return
	check(root.get_network_backend() == null, "precondition: the shell really resolved no backend")
	check_eq(boot_lines, [] as Array[String],
		"and boot says NOTHING about it — a warning here fires on every correct cold drop and fails ship gate 2 by itself")

	check_eq(_status(panel), MKServerBrowser.NO_BACKEND_TEXT,
		"the status line states the absence instead of a lifecycle caption it has nothing to have a lifecycle for")
	check_eq(_rows(panel).size(), 0, "no rows")
	var empty := panel.find_child("Empty", true, false) as Label
	check(empty != null and empty.text == MKServerBrowser.NO_BACKEND_TEXT,
		"and the list area carries the no-backend line, not the different 'No servers found.' one a real-but-empty backend earns")
	check(MKServerBrowser.NO_BACKEND_TEXT != MKServerBrowser.NO_SERVERS_TEXT,
		"which are two distinguishable facts, deliberately")

	check(not _button(panel, "Connect").disabled,
		"Connect is left ENABLED without a backend on purpose: a disabled button cannot produce the warning that names the missing slot")

	_watch_log()
	await _activate(_button(panel, "Connect"))
	await _activate(_button(panel, "Connect"))
	var pressed_lines := _log_lines.filter(func(l: String) -> bool: return l.contains("MKServerBrowser"))
	_unwatch_log()
	check_eq(pressed_lines.size(), 1,
		"two presses warn ONCE per page — the second burying the first is how the naming stops being read")
	check(pressed_lines.size() == 1 and pressed_lines[0].contains("network_backend"),
		"and the one warning names the slot to assign")

	root.free()
	await step_frame()


## Cancel's own backendless carve-out, which is the same one Connect takes and was defended by
## nothing: with no backend there is no lifecycle, CONNECTING is unreachable, and the
## `and _network_backend != null` clause is what keeps Cancel out of the permanently-disabled state
## that clause's absence would produce. A disabled button cannot be pressed, and the press is the
## whole naming mechanism — so a Cancel disabled here is a second dead control on a page whose only
## job in this configuration is to say which slot is empty.
func _test_the_backendless_page_leaves_cancel_live_too() -> void:
	var config := _demo_config()
	config.network_backend = null
	var root := _make_shell(config)
	var panel := await _open_browser(root)
	check(panel != null, "the page built with an empty network slot")
	if panel == null:
		root.free()
		await step_frame()
		return
	check(not _button(panel, "Cancel").disabled,
		"Cancel is LIVE without a backend — the carve-out Connect's comment names, applied symmetrically")
	check(not _button(panel, "Connect").disabled, "as is Connect, for the same reason")

	_watch_log()
	await _activate(_button(panel, "Cancel"))
	var lines := _log_lines.filter(func(l: String) -> bool: return l.contains("MKServerBrowser"))
	_unwatch_log()
	check_eq(lines.size(), 1,
		"and pressing it reaches the naming warn — which a disabled Cancel could never have produced")
	check(lines.size() == 1 and lines[0].contains("network_backend"), "naming the slot to assign")

	root.free()
	await step_frame()


# --- Focus --------------------------------------------------------------------

## The gamepad entry point: arriving at the page focuses something INSIDE it. A page that focuses
## nothing is a dead end for gate 4's controller-only walk, and the shell's fallback (a nav tab) is
## not the same thing — it would leave the player's first press on the tab strip they just used.
func _test_the_page_focuses_something_on_entry() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	var owner_control := root.get_viewport().gui_get_focus_owner()
	check(owner_control != null, "arriving at the page focused something")
	check(owner_control != null and panel.is_ancestor_of(owner_control),
		"and it is inside the BROWSER, not the nav bar the shell falls back to")
	var button := owner_control as BaseButton
	check(button == null or not button.disabled,
		"and it is not a disabled control — a ring on a button that swallows every activation is the dead end MKFocus documents")

	root.free()
	await step_frame()


# --- The ancestor walk --------------------------------------------------------

## A host controller that ANSWERS get_network_backend above a shell whose own slot is unassigned —
## the shape [method MKServerBrowser._find_network_backend]'s comment names as its reason for
## continuing past the first responder.
class BackendProvider extends Control:
	var backend: MKNetworkBackend

	func get_network_backend() -> MKNetworkBackend:
		return backend


## Pins the continue-past-null half of the walk, which every other test here leaves undefended: in a
## plain demo shell the FIRST responder is the MKRoot and it answers non-null, so a mutant that
## stopped at the first responder passes all of them. The shape it breaks is the documented one — a
## shell booted with an unassigned network slot (the SHIPPED default) wrapped by a host that provides
## the backend — where stopping early renders the no-backend empty state over a perfectly good server
## list two levels up. This is round 4 of Phase 6's finding, on this panel's copy of the walk.
func _test_the_backend_walk_passes_a_null_answering_shell() -> void:
	var provider := BackendProvider.new()
	provider.name = "HostNetworkProvider"
	get_root().add_child(provider)
	var stub := MKStubNetworkBackend.new()
	stub._mk_configure({MKStubNetworkBackend.PARAM_CONNECT_DELAY: HELD_DELAY})
	provider.backend = stub
	provider.add_child(stub)

	var config := _demo_config()
	config.network_backend = null
	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	provider.add_child(root)
	var panel := await _open_browser(root)
	check(panel != null, "the page built under a host provider")
	if panel != null:
		check(root.get_network_backend() == null,
			"precondition: the shell itself answers get_network_backend with NULL — the walk must not stop here")
		check_eq(_rows(panel).size(), stub.list_servers().size(),
			"and the panel found the provider's backend ABOVE it: the rows are the host's list, not the empty state a first-responder walk would render")
		check(_status(panel) != MKServerBrowser.NO_BACKEND_TEXT,
			"with no 'no backend' line, which is what stopping early would have said with a backend two levels up")

	provider.free()
	await step_frame()


# --- Focus recovery -----------------------------------------------------------

## The other half of the flip family the Cancel test covers: Connect is focused when it is pressed,
## and CONNECTING disables it. Same mechanism, opposite button — and the recovery target differs,
## because Connect (the first choice) is exactly the button that just went down.
##
## Refresh, not Cancel, is where the ring lands: [method MKServerBrowser._live_footer_button] takes
## the primary action first and the always-live one second. Cancel IS the semantically interesting
## button mid-flight; the fixed order is what makes the target predictable across all five states
## instead of state-by-state, and Cancel is one arrow key away.
func _test_the_connecting_flip_moves_the_ring_off_the_button_it_disabled() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	await _select_row(panel, "mk_stub_local")
	await _activate(_button(panel, "Connect"))
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING, "an attempt is in flight")
	check(_button(panel, "Connect").disabled, "precondition: the press disabled the button it came from")

	var owner_control := root.get_viewport().gui_get_focus_owner()
	check(owner_control != _button(panel, "Connect"),
		"the ring did not stay on the Connect the flip disabled — the next Enter would have gone nowhere")
	check(owner_control == _button(panel, "Refresh"),
		"it moved to Refresh, the live footer button the recovery order reaches first here")

	root.free()
	await step_frame()


## The third shape: a rebuild frees the row the ring was standing on. Driven through the BACKEND's
## refresh rather than the Refresh button, because pressing the button moves focus into the footer
## first and would test the wrong loss — this is the servers_changed route a host discovery result takes,
## with the player still standing in the list.
func _test_a_rebuild_hands_the_ring_back_to_the_selected_row() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY, QUICK_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	var backend := root.get_network_backend()
	await _select_row(panel, "mk_stub_ranked")
	check(root.get_viewport().gui_get_focus_owner() == _row(panel, "mk_stub_ranked"),
		"precondition: the player is standing on a row, which is what a rebuild is about to free")

	var builds: Array[int] = [0]
	panel.built.connect(func() -> void: builds[0] += 1)
	backend.refresh()
	var rebuilt := await _await_signalled(builds)
	check(rebuilt, "the sweep rebuilt the list under the player")

	var owner_control := root.get_viewport().gui_get_focus_owner()
	check(owner_control != null,
		"and focus is not left on the freed row's null — keyboard and gamepad die there, and a gamepad has no mouse to recover with")
	check(owner_control == _row(panel, "mk_stub_ranked"),
		"it is the REBUILT row for the same selection, so the player is standing where they were")

	root.free()
	await step_frame()


# --- A backend with nothing but the abstract surface --------------------------

## A host backend that implements [MKNetworkBackend] and nothing more — no [code]get_connect_state[/code],
## which is a STUB-only addition, and no message accessor (there is none to add). This is the shape a
## host ships, and the shape every other test here misses by driving the stub.
class MinimalBackend extends MKNetworkBackend:
	var servers: Array[Dictionary] = []

	func list_servers() -> Array[Dictionary]:
		return servers

	func connect_to(_entry: Dictionary) -> void:
		connect_state_changed.emit(ConnectState.CONNECTING, "")

	func cancel() -> void:
		connect_state_changed.emit(ConnectState.CANCELLED, "")

	## Emits whatever it is handed, so the panel's unknown-state caption has a way to be reached: no
	## shipped state can produce it, and the caption exists precisely for a state MenuKit did not write.
	func emit_state(state: int) -> void:
		connect_state_changed.emit(state, "")


## Row 7 for the backend a host actually writes: the panel must show that backend's IDLE state, not
## the "no network backend is configured" line it renders before one is resolved.
##
## The panel builds its UI before [method MKServerBrowser._resolve_backend] runs, so the status line
## starts on NO_BACKEND_TEXT by construction. Under the stub that is corrected by the duck-typed seed;
## under a backend without [code]get_connect_state[/code] — the base class offers none — nothing
## corrected it, and the page rendered the host's three servers under a line saying it had no backend.
func _test_a_minimal_backend_gets_its_state_and_its_rows_on_screen() -> void:
	var backend := MinimalBackend.new()
	backend.servers = [
		{"id": "host_one", "name": "Host One"},
		{"id": "host_two", "name": "Host Two"},
	]
	check(not backend.has_method("get_connect_state"),
		"precondition: the minimal backend offers NO get_connect_state — the seed cannot be what corrects the line")
	var mounted := await _mount_under_provider(backend)
	var panel := mounted[1] as MKServerBrowser
	check(panel != null, "the page built over a minimal backend")
	if panel != null:
		check_eq(_status(panel), MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.IDLE],
			"the status line carries the IDLE caption — not the no-backend line it was built with")
		check(_status(panel) != MKServerBrowser.NO_BACKEND_TEXT,
			"which is the lie a host would have shipped: 'no network backend' printed above that backend's own list")
		check_eq(_rows(panel).size(), 2, "and both of its servers are rows")
	(mounted[0] as Node).free()
	await step_frame()


## The out-of-enum caption, reached the only way it can be: a backend emitting a state MenuKit never
## defined. The panel names the number rather than falling through to the previous caption, so a host
## extending the lifecycle sees an honest "I do not know this" instead of a stale "Connected".
func _test_an_out_of_enum_state_renders_its_number() -> void:
	var backend := MinimalBackend.new()
	backend.servers = [{"id": "host_one", "name": "Host One"}]
	var mounted := await _mount_under_provider(backend)
	var panel := mounted[1] as MKServerBrowser
	if panel != null:
		backend.emit_state(99)
		await step_frame()
		check_eq(_status(panel), MKServerBrowser.UNKNOWN_STATE_CAPTION % 99,
			"an unmapped state renders as its number, not as whatever the panel said last")
		check(_status(panel) != MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.IDLE],
			"and specifically not as IDLE, which is what a get()-with-a-default onto the previous caption would have shown")
	(mounted[0] as Node).free()
	await step_frame()


## [method MKNetworkBackend.list_servers] guarantees an [code]id[/code] and a [code]name[/code]; a
## host backend is a host's code and can break either. The name is recoverable — the row renders with
## a stated placeholder rather than an empty button the player cannot tell from a rendering bug.
func _test_a_nameless_entry_renders_the_unnamed_fallback() -> void:
	var backend := MinimalBackend.new()
	backend.servers = [{"id": "host_one", "ping": 40}]
	var mounted := await _mount_under_provider(backend)
	var panel := mounted[1] as MKServerBrowser
	if panel != null:
		var row := _row(panel, "host_one")
		check(row != null, "the entry still becomes a row — a missing name is not a reason to hide a joinable server")
		check(row != null and row.text.contains("(unnamed)"),
			"labelled with the stated fallback, not an empty string that reads as a broken row")
		check(row != null and row.text.contains("40 ms"),
			"and the rest of the entry still renders around it")
	(mounted[0] as Node).free()
	await step_frame()


## The id, unlike the name, is not recoverable: [method MKNetworkBackend.connect_to] refuses an entry
## without one, so the row could only ever fail. It is skipped and the backend NAMED — once, and only
## for the offending entry.
func _test_an_id_less_entry_is_skipped_and_named_once() -> void:
	var backend := MinimalBackend.new()
	backend.servers = [
		{"id": "host_one", "name": "Host One"},
		{"name": "Ghost"},
	]
	_watch_log()
	var mounted := await _mount_under_provider(backend)
	var lines := _log_lines.filter(func(l: String) -> bool: return l.contains("MKServerBrowser") and l.contains("no 'id'"))
	_unwatch_log()
	var panel := mounted[1] as MKServerBrowser
	if panel != null:
		check_eq(_rows(panel).size(), 1,
			"the id-less entry produced NO row — a row whose only possible outcome is a refused connect is worse than no row")
		check(_row(panel, "host_one") != null, "and the valid entry beside it still built")
		check_eq(lines.size(), 1, "with exactly one warning, for the one bad entry")
	(mounted[0] as Node).free()
	await step_frame()


# --- The mid-flight re-entry --------------------------------------------------

## The bind-time seed, on its own rather than through the M1 coupling: a page LEFT mid-connect and
## returned to is a fresh panel instance that has observed no signal, and without the seed it would
## claim IDLE over a connection still in flight — with a live Connect offering to start a second one.
##
## The caption is asserted ALONE, deliberately. The seed reads the state back through
## [code]get_connect_state[/code] and there is no message accessor to read beside it, so the
## "Connecting to <server>…" half the live signal carries is lost on this path. That is the documented
## trade, and this assertion is what makes a future message accessor visible instead of silent.
func _test_re_entering_mid_connect_seeds_the_connecting_state() -> void:
	var root := _make_shell(_demo_config(HELD_DELAY))
	var panel := await _open_browser(root)
	if panel == null:
		root.free()
		await step_frame()
		return
	await _select_row(panel, "mk_stub_ranked")
	await _activate(_button(panel, "Connect"))
	check_eq(panel.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING, "an attempt is in flight")

	root.go_to_page(&"settings")
	await step_frame()
	await step_frame()
	var returned := await _open_browser(root)
	check(returned != null and returned != panel,
		"precondition: coming back built a FRESH panel, which has observed no state change of its own")
	if returned != null:
		check_eq(returned.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING,
			"it seeded CONNECTING from the backend's own getter rather than claiming IDLE over a live attempt")
		check_eq(_status(returned), MKServerBrowser.STATE_CAPTIONS[MKNetworkBackend.ConnectState.CONNECTING],
			"the caption ALONE — the seed has no message accessor to read, an accepted loss on this one path")
		check(_button(returned, "Connect").disabled,
			"and the footer agrees with it: Connect is down, so the page cannot start a second attempt over the first")
		check(not _button(returned, "Cancel").disabled, "with Cancel live, which is the only sane action here")

	root.free()
	await step_frame()


# --- Navigation ---------------------------------------------------------------

## Row 7 adds a nav tab, which is a change to a number [code]test_navigation[/code] asserts. Pinning
## the IDS and their ORDER here says what that number means: a count alone stays green if the Servers
## page displaced a page it was never meant to replace.
func _test_the_demo_nav_is_exactly_five_pages_in_order() -> void:
	var demo := load(DEMO_CONFIG) as MKConfig
	if demo == null:
		return
	var ids: Array[StringName] = []
	for page in demo.get_visible_pages():
		ids.append(page.id)
	check_eq(ids, [&"play", &"characters", &"settings", &"servers", &"credits"] as Array[StringName],
		"the demo's visible tabs are exactly these five, in this order — and the hidden sub/create/pause pages are still not among them")


# --- Fixtures -----------------------------------------------------------------

## A SHALLOW duplicate of the shipped demo config with its network slot retimed.
##
## Shallow for the reason [code]test_pause_menu._shipped_config[/code] gives: [method load] hands back
## the cached instance every other suite (and every host) sees, so a slot swap on the original would
## leak across the sweep. The pages, archetypes and other slots are READ here, never written — the one
## field assigned is a fresh [MKBackendSlot] of this test's own.
##
## The slot points at the SHIPPED [MKStubNetworkBackend]; only its two documented timing params move,
## because 1.2 seconds of connect delay per attempt is a player-facing number and not the contract.
func _demo_config(connect_delay := QUICK_DELAY, refresh_delay := QUICK_DELAY) -> MKConfig:
	var config := (load(DEMO_CONFIG) as MKConfig).duplicate(false) as MKConfig
	check(config != null, "the demo config loads")
	var slot := MKBackendSlot.new()
	slot.backend_script = MKStubNetworkBackend
	slot.params = {
		MKStubNetworkBackend.PARAM_CONNECT_DELAY: connect_delay,
		MKStubNetworkBackend.PARAM_REFRESH_DELAY: refresh_delay,
	}
	config.network_backend = slot
	return config


## Boots a shell whose OWN network slot is empty under a host provider answering with [param backend],
## and opens the browser. The [code]BackendProvider[/code] shape is reused rather than a second
## mounting idiom because it is the only way to give the panel a backend that is not the demo slot's
## stub. Returns [code][provider, panel][/code]; freeing the provider frees the whole fixture.
func _mount_under_provider(backend: MKNetworkBackend) -> Array:
	var provider := BackendProvider.new()
	provider.name = "MinimalHostProvider"
	get_root().add_child(provider)
	provider.backend = backend
	provider.add_child(backend)

	var config := _demo_config()
	config.network_backend = null
	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	provider.add_child(root)
	var panel := await _open_browser(root)
	return [provider, panel]


func _make_shell(config: MKConfig) -> MKRoot:
	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	return root


## Navigates to the servers page and returns the panel, after the deferred focus pass has run.
func _open_browser(root: MKRoot) -> MKServerBrowser:
	root.go_to_page(SERVERS_PAGE)
	await step_frame()
	await step_frame()
	return _find_typed(root, "MKServerBrowser") as MKServerBrowser


func _rows(panel: MKServerBrowser) -> Array[Button]:
	var out: Array[Button] = []
	var column := panel.find_child("Rows", true, false)
	if column == null:
		return out
	for child in column.get_children():
		var button := child as Button
		if button != null:
			out.append(button)
	return out


func _row(panel: MKServerBrowser, id: String) -> Button:
	return panel.find_child("Server_%s" % id, true, false) as Button


func _button(panel: MKServerBrowser, button_name: String) -> Button:
	return panel.find_child(button_name, true, false) as Button


func _status(panel: MKServerBrowser) -> String:
	var label := panel.find_child("Status", true, false) as Label
	if label == null:
		fail("the panel has no Status label")
		return "<missing>"
	return label.text


func _find_entry(entries: Array[Dictionary], id: String) -> Dictionary:
	for entry in entries:
		if String(entry.get("id", "")) == id:
			return entry
	fail("no entry '%s' in the backend's list" % id)
	return {}


# --- Drivers ------------------------------------------------------------------

## Selects a row the way a player on a gamepad does: by focusing it. The panel selects on
## [signal Control.focus_entered], so this exercises the selection path a pushed mouse click could
## never reach headless (§4).
func _select_row(panel: MKServerBrowser, id: String) -> void:
	var row := _row(panel, id)
	if row == null:
		fail("tried to select a row '%s' that does not exist" % id)
		return
	row.grab_focus()
	await step_frame()


## Focus plus a REAL ui_accept press/release through the viewport, so the engine's own BaseButton
## activation runs — the test_pause_menu idiom, and the only button gesture reachable headless.
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


func _key(code: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.pressed = pressed
	return event


## Waits for the panel to report [param state], bounded. A [SceneTreeTimer] needs real frames to
## elapse, and a wall-clock sleep would give it none — so this drives frames and gives up rather than
## hanging the sweep on a state that never arrives.
func _await_state(panel: MKServerBrowser, state: int, max_frames := 2000) -> bool:
	for i in max_frames:
		if panel.get_connect_state() == state:
			return true
		await step_frame()
	return panel.get_connect_state() == state


## Waits for a one-element counter Array to move. An Array rather than a local int because a GDScript
## lambda captures locals BY VALUE (§4) — a counter incremented inside a connected closure is a copy
## the caller's later read never sees, which reads as a permanently-zero assertion.
func _await_signalled(counter: Array[int], max_frames := 2000) -> bool:
	for i in max_frames:
		if counter[0] > 0:
			return true
		await step_frame()
	return counter[0] > 0


func _find_typed(node: Node, class_id: String) -> Node:
	for child in node.get_children():
		if child.is_class(class_id) or (child.get_script() != null \
				and (child.get_script() as Script).get_global_name() == class_id):
			return child
		var found := _find_typed(child, class_id)
		if found != null:
			return found
	return null


# --- Log observation ----------------------------------------------------------

func _watch_log() -> void:
	_log_lines = []
	MKLog.observer = func(_level: int, message: String) -> void:
		_log_lines.append(message)


func _unwatch_log() -> void:
	MKLog.observer = Callable()
