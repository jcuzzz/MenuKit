extends MKTest
## The Phase 6 pause shell: the shipped [MKPauseMenu] page over a real [MKRoot] (plan §5 row 6).
##
## [b]Every mechanism here is exercised against the SHIPPED assets at least once[/b] —
## [code]mk_pause_menu.tscn[/code] is the page in every fixture, and the button/ladder tests run on
## [code]default_config.tres[/code] (duplicated only where a slot has to be swapped), so a page id or
## a slot that drifts in the shipped resource fails here rather than in a host's project. The demo
## game scene has its own suite ([code]test_demo_game.gd[/code]); this one is the addon half.
##
## [b]Gestures, not widget pokes.[/b] Buttons are activated by focusing them and pushing a real
## [code]ui_accept[/code] press/release through the viewport (the [code]test_character_select[/code]
## idiom), and every Escape is a pushed [code]ui_cancel[/code] through
## [method Node._unhandled_input] — the precedence ladder is the thing under test, and calling
## [method MKRoot.close_pause_menu] directly would prove nothing about it.
##
## What is deliberately NOT re-asserted here: the policy edge calls, the [code]can_pause[/code] false
## branch and the teardown unwind on a synthetic root ([code]test_pause_policy.gd[/code]), and the
## [method MKRoot._modal_should_suspend] mouse-mode matrix ([code]test_navigation.gd[/code]). The new
## angle on suspension below is the [i]policy[/i] edge under a modal-over-pause, which neither covers.

const SERVICE_NAME := "MKSettingsService"
const SERVICE_SCRIPT := preload("res://addons/menu_kit/core/mk_settings_service.gd")
const SHIPPED_CONFIG := "res://addons/menu_kit/default_config.tres"
const PAUSE_PAGE_SCENE := "res://addons/menu_kit/panels/mk_pause_menu.tscn"
const STORE_PATH := "user://test_pause_menu.json"
const BACKDROP_CATALOG := "res://addons/menu_kit/themes/default_backdrop_catalog.tres"

## Messages seen by [member MKLog.observer] while a test has it installed.
var _log_lines: Array[String] = []


func run_tests() -> void:
	_clean()
	await _test_one_settings_backend_serves_both_shells()
	await _test_countdown_from_pause_reverts_while_the_tree_is_paused()
	await _test_a_preview_under_a_paused_page_does_not_animate()
	await _test_the_pause_page_is_input_live_only_because_the_host_says_ALWAYS()
	await _test_a_modal_over_pause_never_reaches_the_policy_exit_edge()
	await _test_resume_button_closes_the_menu()
	await _test_settings_from_pause_pushes_and_escape_walks_back()
	await _test_quit_to_menu_calls_the_backend()
	await _test_quit_to_menu_without_a_backend_warns_once()
	await _test_a_second_open_is_refused()
	await _test_open_without_a_pause_page_refuses_without_touching_anything()
	await _test_open_with_a_sceneless_pause_page_refuses_before_suspending()
	await _test_the_nav_bar_is_hidden_while_the_pause_menu_is_open()
	await _test_escape_on_a_foreign_page_recovers_to_the_pause_page()
	await _test_close_pause_menu_clears_a_stacked_modal()
	await _test_show_backdrop_gates_the_backdrop_layer()
	await _test_a_hidden_shell_consumes_nothing()
	await _test_a_lost_recovery_target_resumes_rather_than_freezing()
	await _test_a_hidden_shell_does_not_focus_an_invisible_nav_tab()
	await _test_diagnostics_carry_the_pause_page_id_and_it_clears_on_close()
	await _test_close_clears_the_back_stack_left_by_a_pause_sub_panel()
	await _test_close_restores_the_nav_bar_the_host_had_hidden()
	await _test_quit_to_menu_unwinds_the_pause_before_the_backend_runs()
	await _test_hiding_the_shell_closes_the_pause_menu()
	await _test_showing_a_hidden_shell_does_not_close_an_open_pause_menu()
	await _test_hiding_an_ancestor_closes_the_pause_menu()
	await _test_quit_to_menu_walks_past_a_null_answering_ancestor()
	_clean()


# --- One store ----------------------------------------------------------------

## Row 6's first clause: "Settings opened from pause writes the same store as the main menu — ONE
## backend instance".
##
## The shipped adoption path is the subject, so the fixture mounts a real [code]MKSettingsService[/code]
## at the path [MKRoot] resolves and then builds TWO shells over it — a main-menu shell and the
## in-game pause shell, which is literally the Phase 6 configuration (a second [MKRoot] parked inside
## the game scene). Identity is asserted first because it is the mechanism; the write-through is
## asserted second because identity alone would still pass against a shell that reloaded the file
## behind the other's back if the two were ever decoupled.
func _test_one_settings_backend_serves_both_shells() -> void:
	var parked := _park_autoload()
	var service := _install_service(MKJsonSettingsBackend)
	await step_frame()
	var owned: MKSettingsBackend = service.get_settings_backend()
	check(owned != null, "the service built the one backend")

	var menu_shell := _make_root(MKTreePausePolicy)
	var pause_shell := _make_root(MKTreePausePolicy)
	await step_frame()

	check(menu_shell.get_settings_backend() == owned,
		"the main-menu shell adopted the service's instance")
	check(pause_shell.get_settings_backend() == owned,
		"and so did the in-game pause shell — one store, or the D14 countdown snapshots one handle while the panel writes the other")
	check(menu_shell.get_settings_backend() == pause_shell.get_settings_backend(),
		"the two shells hold the IDENTICAL instance, which is the §4.2 clause row 6 names")

	# The write-through, in the direction row 6 states it: a value set from the PAUSE shell is visible
	# to the main-menu shell with no reload call anywhere. Reading it back off the pause handle would
	# be vacuous under a shared instance and equally vacuous under two.
	pause_shell.get_settings_backend().set_value(&"probe/from_pause", 7)
	check_eq(menu_shell.get_settings_backend().get_value(&"probe/from_pause", 0), 7,
		"a value written from the pause shell is read by the main-menu shell without a reload")

	menu_shell.free()
	pause_shell.free()
	await step_frame()
	check(is_instance_valid(owned),
		"and freeing both shells destroys nothing — the backend belongs to the service")
	_remove_service(service)
	_restore_autoload(parked)
	await step_frame()


# --- The countdown under a real pause -----------------------------------------

## Row 6's PROCESS_MODE_ALWAYS clause: a [code]requires_confirm[/code] change made FROM PAUSE runs its
## countdown to timeout and reverts.
##
## The tree is genuinely paused by the shipped [MKTreePausePolicy] for the whole of it, asserted on
## every frame of the wait rather than once at each end — a policy that resumed mid-wait and re-paused
## would otherwise pass, and "the countdown ticked" would be evidence of nothing.
##
## The countdown is restarted at a short duration once it is up. [constant
## MKSettingsPanel.REVERT_SECONDS] is ten seconds of WALL CLOCK under a frame-driven accumulator, and
## the duration is not the property under test: the property is that [method Node._process] runs at
## all while [member SceneTree.paused] is true. The restart goes through the dialog's own public
## [method MKRevertCountdown.start], so the panel's connections, the timeout emission and the revert
## handler are all the shipped ones.
func _test_countdown_from_pause_reverts_while_the_tree_is_paused() -> void:
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": STORE_PATH})
	backend.process_mode = Node.PROCESS_MODE_ALWAYS
	get_root().add_child(backend)
	backend.set_value(MKSettingsPanel.ID_WINDOW_MODE, 0)

	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	var panel := _make_confirm_panel(backend)
	root.add_child(panel)
	await step_frame()

	check(root.open_pause_menu(), "the shipped pause page opened")
	check(get_root().get_tree().paused, "and MKTreePausePolicy really paused the tree")

	var option := _first_option(panel)
	check(option != null, "the panel built the requires_confirm ENUM row")
	if option == null:
		await _drop(root, panel, backend)
		return
	option.select(1)
	option.item_selected.emit(1)
	var countdown := root.get_modal_layer().top() as MKRevertCountdown
	check(countdown != null, "changing it from the pause menu raised the countdown")
	if countdown == null:
		await _drop(root, panel, backend)
		return
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 3,
		"and the new value is live in the store while the decision is pending")

	countdown.start(0.15)
	var before := countdown.get_time_left()
	var lowest := before
	var stayed_paused := true
	# The dialog is FREED the moment the panel's revert handler resolves it, so validity is checked
	# before every read: a typed call against a freed instance is itself an engine error, and the gate
	# fails on those. The loop is bounded so a countdown that never ticks fails the assertions below
	# rather than hanging the sweep.
	for i in 600:
		if not is_instance_valid(countdown) or not countdown.is_running():
			break
		lowest = minf(lowest, countdown.get_time_left())
		await step_frame()
		if not get_root().get_tree().paused:
			stayed_paused = false
	check(stayed_paused, "the tree was paused on EVERY frame of the wait, not merely at both ends")
	check(not is_instance_valid(countdown) or not countdown.is_running(),
		"the countdown reached timeout under pause")
	check(lowest < before, "having actually ticked down rather than been reset")
	check_eq(int(backend.get_value(MKSettingsPanel.ID_WINDOW_MODE, -1)), 0,
		"and the unconfirmed change REVERTED — this is the whole of §4.2a's process-mode rule, observable")
	check_eq(option.selected, 0, "the row that raised it went back with the store")
	check(get_root().get_tree().paused, "the world is still paused: a revert is not a resume")
	check_eq(root.get_modal_layer().depth(), 0, "and the dialog left the stack")

	await _drop(root, panel, backend)
	check(not get_root().get_tree().paused, "teardown left the world running")


# --- Host content does not animate under pause --------------------------------

## Row 6's "a host preview scene does not animate during pause", with [MKPreviewViewport] as the
## concrete subject.
##
## [b]The pinned process mode is the point.[/b] The preview inherits, so an [MKRoot] page forces it
## PAUSABLE and it freezes — and "the preview freezes when I open the pause menu" reads like a bug
## report, which is exactly how somebody deletes this exit criterion by "fixing" it. The first
## assertion is the tripwire on that; the rest measures the consequence rather than trusting it.
func _test_a_preview_under_a_paused_page_does_not_animate() -> void:
	var preview := MKPreviewViewport.new()
	check_eq(preview.process_mode, Node.PROCESS_MODE_INHERIT,
		"MKPreviewViewport sets NO process mode of its own — it inherits, which is what makes a paused page freeze it (deliberate: see its class doc before 'fixing' this)")
	check(preview.auto_rotate, "and its idle turntable is on by default, so a frozen one is observable")

	# A PAUSABLE branch is what MKRoot._show_page gives host content; the preview is mounted under one
	# here rather than under a page so the assertion is about the preview, not about page plumbing (the
	# page half is the next test).
	var branch := Control.new()
	branch.process_mode = Node.PROCESS_MODE_PAUSABLE
	get_root().add_child(branch)
	branch.add_child(preview)
	await step_frame()
	var pivot := preview.find_child(MKPreviewViewport.PIVOT_NAME, true, false) as Node3D
	check(pivot != null, "the preview built its content pivot, which is where the turntable's yaw lands")

	get_root().get_tree().paused = true
	check(not preview.can_process(),
		"under pause the preview cannot process — a PAUSABLE node inside a paused tree is what the §4.2a rule buys")
	var yaw_paused := pivot.rotation.y if pivot != null else 0.0
	for i in 5:
		await step_frame()
	check_eq(pivot.rotation.y if pivot != null else 0.0, yaw_paused,
		"and its yaw does not move across five paused frames — the preview is not animating during pause")

	get_root().get_tree().paused = false
	await step_frame()
	await step_frame()
	check(pivot != null and pivot.rotation.y != yaw_paused,
		"while an UNPAUSED preview does turn — otherwise the assertion above would hold against a preview that never spins at all")

	branch.free()
	await step_frame()


## The other half of the same rule, at the page seam and on the SHIPPED pause page: host content is
## PAUSABLE by default and therefore input-dead under a tree pause, and a shell hosting the pause menu
## is the one that opts out. [member MKRoot.host_content_process_mode]'s own doc makes exactly this
## claim; without an assertion, a default flipped back to PAUSABLE would ship a Resume button that
## does nothing under the only policy that needs it.
func _test_the_pause_page_is_input_live_only_because_the_host_says_ALWAYS() -> void:
	var pausable := _make_root(MKTreePausePolicy, Node.PROCESS_MODE_PAUSABLE)
	await step_frame()
	check(pausable.open_pause_menu(), "a shell left at the default host process mode still OPENS the page")
	await step_frame()
	var dead := _find_pause_button(pausable, "Resume")
	check(dead != null, "the shipped page built its Resume button either way")
	check(dead != null and not dead.can_process(),
		"but under a tree pause a PAUSABLE page is input-dead — Godot dispatches no GUI input to it, so Resume would not respond")
	pausable.close_pause_menu()
	pausable.free()
	await step_frame()

	var live := _make_root(MKTreePausePolicy)
	await step_frame()
	check(live.open_pause_menu(), "the pause-hosting shell opens it too")
	await step_frame()
	var alive := _find_pause_button(live, "Resume")
	check(alive != null and alive.can_process(),
		"and with host_content_process_mode = ALWAYS the same button is live under the same pause — the export is what the demo scene sets")
	live.close_pause_menu()
	live.free()
	await step_frame()


# --- Suspension edges ---------------------------------------------------------

## A modal over the pause menu pushes 1→2 and its dismissal returns to 1 WITHOUT crossing the 1→0
## edge. [code]test_pause_policy[/code] asserts the depth and that the world stays paused; neither
## can tell "the policy was never told" from "the policy was told and happened to do nothing", because
## MKTreePausePolicy's exit_menu is idempotent against its own flag. The counting spy below can, and
## the failure it guards is the one row 6 names: capture restored underneath a still-open menu.
func _test_a_modal_over_pause_never_reaches_the_policy_exit_edge() -> void:
	CountingSpy.reset()
	var root := _make_root(CountingSpy)
	await step_frame()

	check(root.open_pause_menu(), "the pause menu opened")
	check_eq(CountingSpy.enters, 1, "the 0→1 edge told the policy exactly once")
	check_eq(CountingSpy.reasons, ["pause"], "naming the reason it was given")

	MKConfirmDialog.open(root.get_modal_layer(), "T", "B")
	await step_frame()
	check_eq(root.get_suspend_depth(), 2, "a modal over pause pushes 1→2")
	check_eq(CountingSpy.enters, 1, "and does NOT re-enter the policy — edges are 0→1 only")

	root.get_modal_layer().pop_modal()
	await step_frame()
	check_eq(root.get_suspend_depth(), 1, "dismissing it returns to 1")
	check_eq(CountingSpy.exits, 0,
		"without ever reaching the 1→0 edge — this is what stops mouse capture being restored underneath a still-open pause menu")

	root.close_pause_menu()
	check_eq(root.get_suspend_depth(), 0, "closing the menu reaches zero")
	check_eq(CountingSpy.exits, 1, "and only THERE does the policy hear exit_menu, exactly once")

	root.free()
	await step_frame()


## Counts every edge, and pauses for real, so "the policy was not told" is distinguishable from "the
## policy was told and did nothing". Its own _exit_tree teardown is the §4.2a contract every custom
## policy owes; without it this spy would leave the harness's tree paused for the next test.
class CountingSpy extends MKPausePolicy:
	static var enters := 0
	static var exits := 0
	static var reasons: Array[String] = []
	var _paused_by_us := false

	static func reset() -> void:
		enters = 0
		exits = 0
		reasons = []

	func enter_menu(reason: StringName) -> void:
		enters += 1
		reasons.append(String(reason))
		if not get_tree().paused:
			get_tree().paused = true
			_paused_by_us = true

	func exit_menu(_reason: StringName) -> void:
		exits += 1
		if _paused_by_us:
			get_tree().paused = false
			_paused_by_us = false

	func _exit_tree() -> void:
		if _paused_by_us and get_tree() != null:
			get_tree().paused = false
			_paused_by_us = false


# --- The page's own buttons ---------------------------------------------------

## Resume, through the button, under a real tree pause: focus plus a pushed ui_accept, so the engine's
## own BaseButton activation runs. A [code]pressed.emit()[/code] here would pass against a page whose
## button is unreachable — which is precisely the failure mode the PAUSABLE half of the previous test
## describes.
func _test_resume_button_closes_the_menu() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "opened")
	await step_frame()
	check(get_root().get_tree().paused, "the world is paused before the press")

	var resume := _find_pause_button(root, "Resume")
	check(resume != null, "the shipped page exposes a Resume button")
	if resume != null:
		check(resume.has_focus() or MKFocus.focus_first(root) != null,
			"and the page focuses something on entry, or a gamepad could never reach it")
		await _activate(resume)

	check(not root.is_pause_menu_open(), "Resume closed the pause menu")
	check_eq(root.get_suspend_depth(), 0, "the suspension unwound")
	check(not get_root().get_tree().paused, "and the world is running again")

	root.free()
	await step_frame()


## Settings-from-pause is a PUSH, and Escape walks the stack before it considers the resume rung —
## the ladder order §4.2a/§4.7a states, driven end to end on the SHIPPED default config so the page
## ids ("pause", "settings") are the shipped ones rather than fixture spellings.
##
## [b]The fixture arrives at the pause menu with a NON-EMPTY back stack[/b], because that is the only
## state in which [method MKRoot.open_pause_menu]'s clear() means anything: a player who walked into a
## sub-panel from the main menu and then started a game (or, in the shipped in-game shape, any host
## that pushed before showing the shell) leaves a return address behind. An earlier revision of this
## test opened on a freshly booted shell, where the stack was already empty — the depth assertion
## below stayed green with the clear() deleted, which is a caption asserting nothing.
func _test_settings_from_pause_pushes_and_escape_walks_back() -> void:
	var root := _make_shipped_root()
	await step_frame()
	root.push_page(MKPauseMenu.SETTINGS_PAGE_ID)
	await step_frame()
	check_eq(root.get_back_depth(), 1, "precondition: the shell has a return address before the pause opens")

	check(root.open_pause_menu(), "the shipped config's pause page opened")
	await step_frame()
	check_eq(root.get_page_id(), &"pause", "and it is the page showing")
	check_eq(root.get_back_depth(), 0,
		"and the stale return address is GONE — open_pause_menu clears the stack, so Escape at the pause page is the resume rung and not a walk back into a page from before the game started")

	var settings := _find_pause_button(root, "Settings")
	check(settings != null, "the page exposes a Settings button")
	if settings != null:
		await _activate(settings)
	check_eq(root.get_page_id(), MKPauseMenu.SETTINGS_PAGE_ID,
		"Settings pushed the shipped settings page")
	check_eq(root.get_back_depth(), 1, "as a SUB-panel, so there is somewhere to come back to")
	check(root.is_pause_menu_open(), "and the pause menu is still open behind it")
	check(get_root().get_tree().paused, "with the world still paused")

	check(_cancel(root), "Escape over the settings page is consumed")
	check_eq(root.get_page_id(), &"pause",
		"and returns to the PAUSE page rather than resuming the game out from under the player")
	check(root.is_pause_menu_open(), "the menu is still open")
	check(get_root().get_tree().paused, "and the world is still paused")

	check(_cancel(root), "Escape at the pause page is consumed too")
	check(not root.is_pause_menu_open(),
		"and THERE it resumes — the Phase 6 rung, the symmetry a player expects from the key that opened the menu")
	check(not get_root().get_tree().paused, "the world runs again")
	check_eq(root.get_modal_layer().depth(), 0,
		"and no quit-confirm appeared: the ladder stopped at the pause rung instead of falling through to the root gesture")

	root.free()
	await step_frame()


## Quit to Menu calls [method MKMenuBackend.to_main_menu] exactly once, and raises no confirm dialog.
## The close that now precedes the backend call is the NEXT test's subject; here it is asserted only
## as the state the page leaves behind, so this test keeps measuring the backend contract.
func _test_quit_to_menu_calls_the_backend() -> void:
	QuitSpy.reset()
	var config := _shipped_config()
	var slot := MKBackendSlot.new()
	slot.backend_script = QuitSpy
	config.menu_backend = slot
	var root := _make_root_with(config)
	await step_frame()
	check(root.open_pause_menu(), "opened")
	await step_frame()

	var quit := _find_pause_button(root, "QuitToMenu")
	check(quit != null, "the page exposes a Quit to Menu button")
	if quit != null:
		await _activate(quit)
	check_eq(QuitSpy.to_menu, 1, "pressing it called to_main_menu exactly once")
	check_eq(QuitSpy.quits, 0, "and never quit the application — quit-to-menu is not quit-to-desktop")
	check_eq(root.get_modal_layer().depth(), 0, "with no confirmation dialog in the way")
	check(not root.is_pause_menu_open(),
		"and the page unwound the pause on its way out — change_scene_to_file is deferred, so leaning on teardown was never safe and is impossible for a backend that swaps no scene")

	root.free()
	await step_frame()
	check(not get_root().get_tree().paused,
		"and that teardown is what leaves the world running, exactly as a real quit-to-menu does")


## A shell booted with no menu backend must NAME the problem and do so once per page, not once per
## press: a warning per press buries the first one under the player's second attempt. Observed through
## [member MKLog.observer], which exists because this contract is stated as a COUNT.
func _test_quit_to_menu_without_a_backend_warns_once() -> void:
	var config := _shipped_config()
	config.menu_backend = null
	var root := _make_root_with(config)
	await step_frame()
	check(root.open_pause_menu(), "opened")
	await step_frame()
	check(root.get_menu_backend() == null, "precondition: the shell really has no menu backend")

	var quit := _find_pause_button(root, "QuitToMenu")
	_watch_log()
	if quit != null:
		await _activate(quit)
		await _activate(quit)
	_unwatch_log()
	check_eq(_log_lines.filter(func(l: String) -> bool: return l.contains("no MKMenuBackend")).size(), 1,
		"two presses warn ONCE, and the message names MKMenuBackend so the reader knows which slot to assign")
	check(root.is_pause_menu_open(), "and the menu stays open — a dead button is not a resume")

	root.free()
	await step_frame()


# --- Refusals -----------------------------------------------------------------

## A second open is refused and changes nothing. The demo forwards every ESC press, and under
## MKNoPausePolicy its own handler is still receiving input while the menu is up, so this guard is
## what stops a repeated gesture from stacking suspensions the first close cannot unwind.
func _test_a_second_open_is_refused() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "the first open succeeds")
	check_eq(root.get_suspend_depth(), 1, "raising one suspension")
	check(not root.open_pause_menu(), "the second is refused")
	check_eq(root.get_suspend_depth(), 1,
		"and raised NO second suspension — otherwise one close would leave the world paused with no menu on screen")
	root.close_pause_menu()
	check(not get_root().get_tree().paused, "so a single close resumes the world")
	root.free()
	await step_frame()


## A config with no "pause" page must leave nothing behind. Since the pre-check moved ahead of the
## suspension there is nothing to unwind — the assertions below say so in both directions: depth zero
## AND the policy never told anything at all. There is no post-[code]_show_page[/code] unwind left to
## measure: the pre-check owns refusal, and a show that fails anyway (foreign code between the
## pre-check and the lookup — the two windows the call site names) is contained by the ESC recovery
## rung, which [code]_test_a_lost_recovery_target_resumes_rather_than_freezing[/code] drives.
## Suspending the world to display nothing is strictly worse than not pausing.
func _test_open_without_a_pause_page_refuses_without_touching_anything() -> void:
	CountingSpy.reset()
	var config := MKConfig.new()
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	var slot := MKBackendSlot.new()
	slot.backend_script = CountingSpy
	config.pause_policy = slot
	var page := MKMenuPageDef.new()
	page.id = &"only"
	page.title = "Only"
	page.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(page)
	config.initial_page = &"only"
	# No expect_engine_error here: the refusal is a WARNING (a recoverable misconfiguration, per
	# MKLog's own rule), and the gate's noise pattern deliberately excludes WARNING — declaring it
	# would be an unmatched declaration, which the gate fails on in the other direction.
	var root := _make_root_with(config)
	await step_frame()

	check(not root.open_pause_menu(), "open_pause_menu REFUSES when the page id is not in the config")
	check(not root.is_pause_menu_open(), "and reports itself closed")
	check_eq(root.get_suspend_depth(), 0, "leaving no suspension standing")
	check_eq(CountingSpy.enters, 0,
		"and the policy was never entered at all — the refusal is decided BEFORE the world is suspended, not unwound after")
	check_eq(CountingSpy.exits, CountingSpy.enters,
		"so its edges stay paired — a refused open must not leave an enter without its exit")
	check(not get_root().get_tree().paused, "so the world is not left paused behind a page nobody can see")
	check_eq(root.get_page_id(), &"only", "and the shell is still on the page it was on")

	root.free()
	await step_frame()


## A pause page that EXISTS but carries no scene. [method MKRoot._show_page] returns true for it
## (it warns and empties the page host), so a refusal written against that return value alone never
## fired: the world went to sleep and the cursor went free behind a blank page with a nav bar. The
## pre-check is what makes the refusal doc true, and this is the state it was false in.
func _test_open_with_a_sceneless_pause_page_refuses_before_suspending() -> void:
	CountingSpy.reset()
	var root := _make_root(CountingSpy)
	# The fixture's own pause page, scene stripped. Everything else — id, visibility, the policy — is
	# the shape the successful tests use, so the ONLY difference is the null scene.
	root.config.get_page(&"pause").scene = null
	await step_frame()

	check(not root.open_pause_menu(),
		"open_pause_menu refuses a pause page with no scene — _show_page would have returned true and only warned")
	check(not root.is_pause_menu_open(), "and reports itself closed")
	check_eq(root.get_suspend_depth(), 0, "with no suspension raised")
	check_eq(CountingSpy.enters, 0, "the policy never heard enter_menu")
	check(not get_root().get_tree().paused,
		"and the world is NOT paused — freezing it behind an empty page host is the failure this refuses")
	check_eq(root.get_page_id(), &"only", "the shell is still on the page it was on")

	root.free()
	await step_frame()


## While the pause menu is open the shell is a PAUSE shell, and the nav bar is not part of it.
##
## A tab press is a lateral [method MKRoot.go_to_page]: it clears the back stack and leaves the pause
## flag set, so Escape then hit the resume rung and un-paused the game under a full settings page —
## measured before this fix. And the shipped tabs reach Start Game and character deletion, which are
## not pause gestures at all. Hiding the bar removes the gesture rather than filtering it, so there is
## no allow-list to keep in sync with a host's page set.
func _test_the_nav_bar_is_hidden_while_the_pause_menu_is_open() -> void:
	var root := _make_shipped_root()
	await step_frame()
	var nav := _find_nav_bar(root)
	check(nav != null, "the shell built a nav bar")
	if nav == null:
		root.free()
		await step_frame()
		return
	check(nav.visible, "which is visible on the main-menu shell")
	check(nav.get_tab_count() > 0, "with tabs on it, or hiding it would prove nothing")

	check(root.open_pause_menu(), "the pause menu opened")
	await step_frame()
	check(not nav.visible,
		"and the nav bar is HIDDEN — no tab press can clear the back stack out from under the pause rung, and Start Game is not reachable from a pause screen")

	root.close_pause_menu()
	await step_frame()
	check(nav.visible, "closing the menu restores it — the shell is a main-menu shell again")

	root.free()
	await step_frame()


## The pause rung is page-aware. A host that navigates the shell programmatically while paused (the
## one route left once the nav bar is hidden) leaves the pause flag true on a foreign page with an
## empty back stack — and the flag-only rung answered Escape there by RESUMING the game under that
## page. The recovery navigates back to the pause page instead; only the second Escape resumes.
func _test_escape_on_a_foreign_page_recovers_to_the_pause_page() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "paused, on the pause page")
	await step_frame()

	root.go_to_page(&"only")
	await step_frame()
	check_eq(root.get_page_id(), &"only", "the host navigated the shell somewhere else while paused")
	check_eq(root.get_back_depth(), 0, "leaving nothing on the back stack — go_to_page is lateral")
	check(root.is_pause_menu_open(), "with the pause menu still open behind it")

	check(_cancel(root), "Escape there is consumed")
	check(root.is_pause_menu_open(),
		"and does NOT resume — a running game under a full-screen menu page is the state this rung used to produce")
	check(get_root().get_tree().paused, "the world is still paused")
	check_eq(root.get_page_id(), &"pause", "the shell recovered to the PAUSE page")
	check_eq(root.get_modal_layer().depth(), 0,
		"and no quit-confirm appeared — the other wrong answer to this gesture")

	check(_cancel(root), "the next Escape is consumed too")
	check(not root.is_pause_menu_open(), "and THERE it resumes, one rung later than before")
	check(not get_root().get_tree().paused, "the world runs again")

	root.free()
	await step_frame()


## [method MKRoot.close_pause_menu] pops the modal stack, and the host-driven close is the route that
## proves it: Resume is pressed on a page that a stacked modal has covered, so the only caller that
## can reach this state is the host (or the ladder, which routes through the modal first). Deleting
## the pop_all() left a measured triple — world frozen, shell hidden by the host, modal stranded on a
## layer nobody can reach — and every existing assertion stayed green.
func _test_close_pause_menu_clears_a_stacked_modal() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "paused, with the menu open")
	await step_frame()

	MKConfirmDialog.open(root.get_modal_layer(), "Are you sure", "Body")
	await step_frame()
	check_eq(root.get_modal_layer().depth(), 1, "a confirm dialog is stacked over the pause page")
	check_eq(root.get_suspend_depth(), 2, "holding a suspension of its own")

	root.close_pause_menu()
	await step_frame()
	check_eq(root.get_modal_layer().depth(), 0,
		"a host-driven close empties the modal stack — a modal left over a hidden shell is unreachable and unrecoverable")
	check_eq(root.get_suspend_depth(), 0,
		"and the depth reaches zero, because the stranded modal's own suspension went with it")
	check(not get_root().get_tree().paused,
		"so the world is running — a stranded modal counting a suspension is a permanently paused game")

	root.free()
	await step_frame()


## [member MKRoot.show_backdrop] is behaviour, not documentation. Both shells get the SAME catalog, so
## the only variable is the flag; both build the Backdrop child, so the assertion is about what it
## displays rather than about the layout forking. The in-game shell turns it off because an opaque
## backdrop hides the very world the pause menu is supposed to sit on top of — demo_game.tscn pins the
## export, and nothing measured what the export did.
func _test_show_backdrop_gates_the_backdrop_layer() -> void:
	var on := _make_root(MKTreePausePolicy, Node.PROCESS_MODE_ALWAYS, true)
	var off := _make_root(MKTreePausePolicy, Node.PROCESS_MODE_ALWAYS, false)
	await step_frame()
	var on_layer := _find_backdrop(on)
	var off_layer := _find_backdrop(off)
	check(on_layer != null and off_layer != null,
		"both shells build a Backdrop child — the shell layout does not fork on the flag")
	check(on.config.backdrop_catalog != null and off.config.backdrop_catalog != null,
		"precondition: both configs carry the same catalog, so the flag is the only difference")
	check(on_layer != null and on_layer.get_active_def() != null,
		"show_backdrop = true applies a def from the catalog")
	check(off_layer != null and off_layer.get_active_def() == null,
		"show_backdrop = false displays NOTHING — MKBackdrop treats that as a supported state, and the paused world showing through is what says 'pause' rather than 'scene change'")

	on.free()
	off.free()
	await step_frame()


## A shell that is not visible consumes nothing. This is the in-game configuration's load-bearing
## rule: the demo parks a hidden [MKRoot] in the game scene, and a hidden shell that swallowed
## ui_cancel would eat the very gesture the host's ESC handler needs to open it — and, with both
## stacks empty, answer it with a quit-confirm dialog nobody can see.
func _test_a_hidden_shell_consumes_nothing() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	root.visible = false
	await step_frame()

	check(not _cancel(root), "a hidden shell does NOT consume ui_cancel")
	check_eq(root.get_modal_layer().depth(), 0,
		"and raises no quit-confirm — an invisible dialog holding a suspension is unrecoverable")
	check(not root.is_pause_menu_open(), "and opens nothing")
	check_eq(root.get_suspend_depth(), 0, "leaving the counter alone")

	# Visible again, the SAME gesture is answered — so the assertion above measures the visibility
	# rule and not a viewport that was ignoring pushed events all along.
	root.visible = true
	await step_frame()
	check(_cancel(root), "the same gesture IS consumed once the shell is shown")
	check_eq(root.get_modal_layer().depth(), 1, "raising the root quit-confirm, both stacks being empty")
	root.get_modal_layer().pop_all()
	await step_frame()

	root.free()
	await step_frame()


## The recovery rung's own failure case. The rung answers Escape on a foreign page by navigating BACK
## to the recorded pause page — but that page can be gone by then: a host that removes the def, or
## swaps the config, while the menu is open. The rung then discarded a false return and did nothing,
## which is the one unrecoverable answer available: the press is consumed (the ladder always consumes
## ui_cancel), so EVERY later Escape lands in the same branch and does the same nothing, with the
## world suspended and the cursor free forever.
##
## Resuming is the decision: a running game with a warning in the log beats a frozen one with no exit.
func _test_a_lost_recovery_target_resumes_rather_than_freezing() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "paused, on the pause page")
	await step_frame()
	root.go_to_page(&"only")
	await step_frame()
	check_eq(root.get_page_id(), &"only", "the host navigated the shell off the pause page while paused")

	# The fixture builds a config of its own per shell, so removing the def mutates nothing shared.
	# This is the state a host reaches by editing config.pages or repointing the resource mid-pause.
	var doomed := root.config.get_page(&"pause")
	check(doomed != null, "precondition: the pause page def exists before it is removed")
	root.config.pages.erase(doomed)
	check(root.config.get_page(&"pause") == null, "and it is gone from the config the shell holds")

	check(_cancel(root), "Escape is consumed, as every ladder press is")
	check(not root.is_pause_menu_open(),
		"and with no page left to recover to, the rung RESUMES rather than consuming the gesture forever")
	check_eq(root.get_suspend_depth(), 0, "the suspension unwound")
	check(not get_root().get_tree().paused,
		"the world is running again — the alternative is a permanently paused game whose every Escape is swallowed by a branch that cannot act")
	check_eq(root.get_back_depth(), 0, "with nothing left on the back stack")

	root.free()
	await step_frame()


## The focus fallback measures the TREE, not the local flag.
##
## The in-game configuration parks this shell hidden inside the game scene, and a hidden ANCESTOR
## leaves the nav bar's own [member CanvasItem.visible] true — so the flag-only guard passed and the
## deferred focus pass landed on a nav tab nobody could see (probed: MKNavTab_welcome held focus on a
## shell booted with visible = false). The first input a player made then activated an invisible tab.
##
## Both halves are asserted, because the second is what makes the first non-vacuous: the bar really is
## flag-visible, and really is not visible in the tree.
func _test_a_hidden_shell_does_not_focus_an_invisible_nav_tab() -> void:
	var root := MKRoot.new()
	root.config = _shipped_config()
	root.host_content_process_mode = Node.PROCESS_MODE_ALWAYS
	root.show_backdrop = false
	# Hidden BEFORE it enters the tree, so the whole boot — including the deferred focus pass — runs in
	# the state the demo game scene boots its shell in.
	root.visible = false
	get_root().add_child(root)
	await step_frame()
	await step_frame()

	var nav := _find_nav_bar(root)
	check(nav != null, "the shell built a nav bar")
	if nav != null:
		check(nav.visible,
			"whose own visible flag is TRUE — the ancestor is what hides it, which is why the flag-only guard passed")
		check(not nav.is_visible_in_tree(), "while the tree-wide answer is false")
	var owner := root.get_viewport().gui_get_focus_owner()
	check(owner == null or not String(owner.name).begins_with("MKNavTab"),
		"and nothing focused a nav tab: focus on a control nobody can see hands the player's next input to an invisible Start Game")

	root.free()
	await step_frame()


## [code]_pause_page_id[/code] must be empty whenever the pause menu is closed — an invariant its own
## field doc states and nothing could observe, because the member is private and no accessor exposes
## it. Putting it on the diagnostics pause line answers both needs at once: a bug report can now
## distinguish "paused, on the pause page" from "paused, navigated elsewhere", and this test can read
## the invariant through the shipped surface rather than through a seam added for it.
func _test_diagnostics_carry_the_pause_page_id_and_it_clears_on_close() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "opened")
	await step_frame()
	check_eq(_diagnostic_pause_page_id(root), "pause",
		"the dump names the page open_pause_menu navigated to")
	check(root.dump_diagnostics().contains("pause_menu_open: true"), "alongside the flag it qualifies")

	root.close_pause_menu()
	await step_frame()
	check_eq(_diagnostic_pause_page_id(root), "",
		"and the close CLEARS it — a stale id would make the ladder's recovery rung navigate to a page nobody asked for the next time the flag went true")
	check(root.dump_diagnostics().contains("pause_menu_open: false"), "with the flag down")

	# A SECOND registered page id, so the field is measured rather than pattern-matched. With only the
	# default id ever opened, a dump that FABRICATED the value — printing "pause" whenever the flag is
	# true — carried the same string as the real field and every assertion above stayed green. The
	# fixture's other page is a legitimate pause target: it is registered and it has a scene, which is
	# all open_pause_menu's pre-check asks for.
	check(root.open_pause_menu(&"only"), "the shell opens the pause menu under a non-default page id")
	await step_frame()
	check_eq(_diagnostic_pause_page_id(root), "only",
		"and the dump names THAT id — the field is read from the state, not reconstructed from the flag")
	root.close_pause_menu()
	await step_frame()

	root.free()
	await step_frame()


## Closing clears the back stack, and the asymmetry it fixes is a real gesture: pause, open a
## sub-panel from the pause page, resume from the host (Resume, the ladder, or a quit). The return
## address to the pause page survived the close, so the player's NEXT Escape — meant as "pause the
## game" — popped the stack instead and drew the pause page over a running world, with the resume rung
## unreachable because the flag was false.
func _test_close_clears_the_back_stack_left_by_a_pause_sub_panel() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "paused, on the pause page")
	await step_frame()
	root.push_page(&"only")
	await step_frame()
	check_eq(root.get_back_depth(), 1, "precondition: a pause sub-navigation left a return address")

	root.close_pause_menu()
	await step_frame()
	check_eq(root.get_back_depth(), 0,
		"the close clears it — a return address into a shell that is about to be hidden is not worth keeping")
	check(not root.is_pause_menu_open(), "and the menu is closed")

	check(_cancel(root), "the next Escape is consumed")
	check(root.get_page_id() != &"pause",
		"and does NOT land on the pause page: with the stale address gone there is nothing to pop, so the gesture reaches the root rung instead of drawing a pause panel over a running game")
	check(not get_root().get_tree().paused, "and the world is still running")
	root.get_modal_layer().pop_all()
	await step_frame()

	root.free()
	await step_frame()


## The nav bar is RESTORED, not asserted true. A host is entitled to run the shell with the bar
## hidden — a single-page shell, or its own chrome — and an unconditional [code]visible = true[/code]
## on close made the pause gesture a way to summon a strip the host had deliberately hidden, which no
## host gesture could then put back (nothing else writes that node).
func _test_close_restores_the_nav_bar_the_host_had_hidden() -> void:
	var root := _make_shipped_root()
	await step_frame()
	var nav := _find_nav_bar(root)
	check(nav != null, "the shell built a nav bar")
	if nav == null:
		root.free()
		await step_frame()
		return
	nav.visible = false
	check(root.open_pause_menu(), "the pause menu opened over a shell whose host had hidden the bar")
	await step_frame()
	check(not nav.visible, "the bar is hidden while paused, as it is for every open")

	root.close_pause_menu()
	await step_frame()
	check(not nav.visible,
		"and STILL hidden after the close — the close restores what open found, rather than showing a strip the host hid")

	root.free()
	await step_frame()


## Quit to Menu unwinds the pause before the backend runs.
##
## The page used to hand the whole unwind to teardown on the argument that
## [method SceneTree.change_scene_to_file] frees everything mid-call. It does not: the scene change is
## DEFERRED, so the call returns with the shell alive. And a backend need not change scene at all — an
## in-place state machine, a fade — in which case nothing is ever torn down and the world stays paused
## with a free cursor and a suspension counter nobody will unwind. The spy below is exactly that
## backend: it records the call and changes no scene.
##
## [b]"Before" is asserted at the call, not after it.[/b] Every end-state assertion below is equally
## true of the reverse order — press, call the backend, then close — because by the time the press
## returns both have happened either way. So the spy captures [member SceneTree.paused] and the
## shell's counters INSIDE [code]to_main_menu[/code]; swapping the two lines in
## [code]MKPauseMenu._on_quit_pressed[/code] turns those three assertions red and leaves the rest
## green, which is the exact shape of the hole this closes.
func _test_quit_to_menu_unwinds_the_pause_before_the_backend_runs() -> void:
	QuitSpy.reset()
	var config := _shipped_config()
	var slot := MKBackendSlot.new()
	slot.backend_script = QuitSpy
	config.menu_backend = slot
	var root := _make_root_with(config)
	QuitSpy.shell_probe = func() -> Dictionary:
		return {
			"pause_menu_open": root.is_pause_menu_open(),
			"suspend_depth": root.get_suspend_depth(),
		}
	await step_frame()
	var nav := _find_nav_bar(root)
	check(root.open_pause_menu(), "opened")
	await step_frame()
	check(get_root().get_tree().paused, "with the world paused")

	var quit := _find_pause_button(root, "QuitToMenu")
	check(quit != null, "the page exposes a Quit to Menu button")
	if quit != null:
		await _activate(quit)

	check_eq(QuitSpy.to_menu, 1, "the backend was still called exactly once")
	check(not QuitSpy.paused_at_call,
		"and the world was ALREADY running when to_main_menu ran — not merely running by the time the press returned")
	check(not QuitSpy.pause_open_at_call,
		"with the pause menu already reported closed at that instant")
	check_eq(QuitSpy.suspend_depth_at_call, 0,
		"and the suspension already unwound — a backend that changes no scene inherits a clean shell, which is the whole claim")
	check(not root.is_pause_menu_open(), "and the pause menu closed itself first")
	check_eq(root.get_suspend_depth(), 0, "the suspension unwound")
	check(not get_root().get_tree().paused,
		"so a backend that changes NO scene leaves a running world rather than a permanently frozen one")
	check(nav == null or nav.visible, "with the shell's chrome restored")

	root.free()
	QuitSpy.shell_probe = Callable()
	await step_frame()


## Hiding the shell IS closing the pause menu. The documented in-game gesture is
## [code]visible = open[/code] on a shell parked in the game scene, and a host that hides it directly —
## a cutscene, a death screen, its own menu key — otherwise stranded the suspension: world paused,
## cursor free, counter at one, and no surface on screen to unwind it from.
##
## No feedback loop is possible in either direction, which the demo's own handler is the proof of: it
## hides in RESPONSE to a close, by which time the flag is already false and the notification is a
## no-op, and it shows BEFORE an open, when the flag is false as well.
func _test_hiding_the_shell_closes_the_pause_menu() -> void:
	var root := _make_root(MKTreePausePolicy)
	await step_frame()
	check(root.open_pause_menu(), "the pause menu opened on a visible shell")
	await step_frame()
	check(get_root().get_tree().paused, "and the world is paused")

	var toggles: Array[bool] = []
	root.pause_menu_toggled.connect(func(open: bool) -> void: toggles.append(open))
	root.hide()
	await step_frame()

	check(not root.is_pause_menu_open(), "hiding the shell closed the pause menu")
	check_eq(root.get_suspend_depth(), 0, "dropping the suspension it was holding")
	check(not get_root().get_tree().paused,
		"and resuming the world — otherwise a host that hides its shell freezes the game with nothing on screen to unfreeze it")
	check_eq(toggles, [false] as Array[bool],
		"the host hears exactly one toggle(false), so its own `visible = open` handler re-hides an already hidden shell and stops there — no loop")

	root.free()
	await step_frame()


## The other DIRECTION of the same notification, which is what makes the close conditional rather
## than a close-on-any-visibility-change.
##
## Only the hidden branch was ever driven, so
## [code]if _pause_menu_open and not is_visible_in_tree()[/code] mutated to
## [code]if _pause_menu_open[/code] passed the whole suite. The host it breaks is the reverse-ordered
## one: a shell that is hidden when the pause gesture arrives, opened, and shown afterwards. That is
## not an exotic shape — [MKRoot] itself opens fine while hidden (the pre-check reads the config, not
## the screen), and the demo's own ordering comment says the show-before-open order is the HOST's
## choice for its own focus reason, i.e. the other order is a host's to make. Under the mutant the
## show closes the menu instantly: world resumed, cursor recaptured, a panel on screen with the game
## running behind it.
##
## The ordering that matters is that the SHOW comes after the open. Entering the tree fires a
## visibility notification of its own, with [method CanvasItem.is_visible_in_tree] already true
## (probed), and the hide below fires another — but both land while [code]_pause_menu_open[/code] is
## still false, where every reading of the guard is a no-op. The first notification that can tell the
## two readings apart is the one this test drives.
func _test_showing_a_hidden_shell_does_not_close_an_open_pause_menu() -> void:
	var root := _make_root(MKTreePausePolicy)
	root.visible = false
	await step_frame()
	check(not root.is_visible_in_tree(), "precondition: the shell is in the tree and hidden")

	var toggles: Array[bool] = []
	root.pause_menu_toggled.connect(func(open: bool) -> void: toggles.append(open))
	check(root.open_pause_menu(), "the pause menu opens on a HIDDEN shell — the pre-check reads the config, not the screen")
	await step_frame()
	check(get_root().get_tree().paused, "and the world is paused")

	root.visible = true
	await step_frame()
	check(root.is_visible_in_tree(), "the host then shows the shell, which fires the same notification the hide does")
	check(root.is_pause_menu_open(),
		"and the menu is STILL open — the close is conditional on becoming invisible, not on the notification arriving")
	check_eq(root.get_suspend_depth(), 1, "holding its suspension")
	check(get_root().get_tree().paused,
		"with the world still paused — a close here hands the player a running game under a full-screen pause panel")
	check_eq(toggles, [true] as Array[bool],
		"and the host heard exactly one toggle, the OPEN — no toggle(false) chased it")

	root.close_pause_menu()
	root.free()
	await step_frame()


## A host controller that ANSWERS get_menu_backend above a shell whose own slot is unassigned.
class BackendProvider extends Control:
	var backend: MKMenuBackend

	func get_menu_backend() -> MKMenuBackend:
		return backend


## Pins the continue-past-null half of [code]MKPauseMenu._find_menu_backend[/code]'s walk — the
## property its comment cites [MKCharacterSelect] for, which round 4 proved undefended here: a
## first-responder walk (stop at whoever ANSWERS the method) passed the whole suite. The shape it
## breaks is the documented one: a shell booted with an unassigned menu slot, wrapped by a host
## controller that provides the backend — the walk must pass the null-answering MKRoot and reach
## the provider, or Quit to Menu warns "no backend" with a backend two levels up.
##
## The button is driven by its own pressed signal rather than a focus + ui_accept gesture: the
## activation path is not the property here (the quit tests own it), the LOOKUP is, and a synthetic
## press exercises exactly the handler the lookup lives in.
func _test_quit_to_menu_walks_past_a_null_answering_ancestor() -> void:
	QuitSpy.reset()
	var provider := BackendProvider.new()
	provider.name = "HostBackendProvider"
	get_root().add_child(provider)
	var spy := QuitSpy.new()
	provider.backend = spy
	provider.add_child(spy)
	var root := _make_root(MKTreePausePolicy, Node.PROCESS_MODE_ALWAYS, false, provider)
	await step_frame()
	check(root.get_menu_backend() == null,
		"precondition: the shell itself answers get_menu_backend with null — the walk must not stop here")
	check(root.open_pause_menu(), "the pause menu opened")
	await step_frame()

	var page := _find_typed(root, "MKPauseMenu") as Control
	check(page != null, "the shipped pause page is up")
	if page != null:
		var quit_button := page.find_child("QuitToMenu", true, false) as Button
		check(quit_button != null, "and carries its Quit to Menu button")
		if quit_button != null:
			quit_button.pressed.emit()
			await step_frame()
	check_eq(QuitSpy.to_menu, 1,
		"Quit reached the provider ABOVE the null-answering shell — the walk continued past the first responder")

	provider.free()
	await step_frame()


## The ANCESTOR-hide direction, and the reason the guard reads is_visible_in_tree() and not the
## local flag.
##
## Round 4's surviving mutant: `not is_visible_in_tree()` → `not visible` passed the whole suite,
## because both existing direction tests drive visibility on the SHELL itself, where the two reads
## agree. They disagree exactly when a host hides a PARENT of the shell — a UI layer, a cutscene
## container — which never touches the shell's own flag. Under the mutant that gesture strands the
## suspension: world paused, cursor free, no surface on screen, the precise failure the hide-close
## exists to prevent. The distinction is the same one _unhandled_input and _focus_page_content
## already draw; this pins it on the third site.
func _test_hiding_an_ancestor_closes_the_pause_menu() -> void:
	var layer := Control.new()
	layer.name = "HostUiLayer"
	get_root().add_child(layer)
	var root := _make_root(MKTreePausePolicy, Node.PROCESS_MODE_ALWAYS, false, layer)
	await step_frame()
	check(root.open_pause_menu(), "the pause menu opened under a host UI layer")
	await step_frame()
	check(get_root().get_tree().paused, "and the world is paused")

	var toggles: Array[bool] = []
	root.pause_menu_toggled.connect(func(open: bool) -> void: toggles.append(open))
	layer.hide()
	await step_frame()

	check(root.visible, "the shell's OWN flag never moved — only the tree visibility did")
	check(not root.is_visible_in_tree(), "while the shell is genuinely off screen")
	check(not root.is_pause_menu_open(), "and the ancestor hide closed the pause menu")
	check_eq(root.get_suspend_depth(), 0, "dropping the suspension")
	check(not get_root().get_tree().paused, "and resuming the world")
	check_eq(toggles, [false] as Array[bool], "with exactly one toggle(false) for the host")

	layer.free()
	await step_frame()


# --- Fixtures -----------------------------------------------------------------

## A lean shell carrying the SHIPPED pause page under the given policy. [param page_mode] defaults to
## ALWAYS because that is what an MKRoot hosting the pause menu sets (demo_game.tscn sets it in the
## scene); the PAUSABLE case is a test of its own.
##
## The backdrop CATALOG is always assigned and [param backdrop] gates only the shell's own flag, so
## the show_backdrop test measures the flag rather than a missing catalog. Default off: an opaque
## backdrop over the fixture is the in-game shape every other test here wants.
func _make_root(policy_script: Script,
		page_mode: Node.ProcessMode = Node.PROCESS_MODE_ALWAYS,
		backdrop := false,
		parent: Node = null) -> MKRoot:
	var config := MKConfig.new()
	config.palette = load("res://addons/menu_kit/themes/default_palette.tres")
	var slot := MKBackendSlot.new()
	slot.backend_script = policy_script
	config.pause_policy = slot
	var home := MKMenuPageDef.new()
	home.id = &"only"
	home.title = "Only"
	home.scene = load("res://addons/menu_kit/panels/mk_welcome_page.tscn")
	config.pages.append(home)
	var pause := MKMenuPageDef.new()
	pause.id = &"pause"
	pause.title = "Paused"
	pause.visible = false
	pause.scene = load(PAUSE_PAGE_SCENE)
	config.pages.append(pause)
	config.initial_page = &"only"
	config.backdrop_catalog = load(BACKDROP_CATALOG)
	var root := MKRoot.new()
	root.config = config
	root.host_content_process_mode = page_mode
	root.show_backdrop = backdrop
	(parent if parent != null else get_root()).add_child(root)
	return root


## The shipped default config, in the in-game shape (no backdrop, ALWAYS page content).
func _make_shipped_root() -> MKRoot:
	return _make_root_with(_shipped_config())


func _make_root_with(config: MKConfig) -> MKRoot:
	var root := MKRoot.new()
	root.config = config
	root.host_content_process_mode = Node.PROCESS_MODE_ALWAYS
	root.show_backdrop = false
	get_root().add_child(root)
	return root


## A SHALLOW duplicate of the shipped default config, so a slot swap does not mutate the resource
## every other test (and every host) loads — [method Resource.load] returns the same cached instance.
## Shallow is deliberate: the page and archetype arrays are read here, never written.
func _shipped_config() -> MKConfig:
	var config := (load(SHIPPED_CONFIG) as MKConfig).duplicate(false) as MKConfig
	check(config != null, "the shipped default config loads")
	return config


## One requires_confirm ENUM row on a real [MKSettingsPanel] — the same shape test_revert_countdown
## builds, because the row type is not the subject here; the pause it runs under is.
func _make_confirm_panel(backend: MKSettingsBackend) -> MKSettingsPanel:
	var def := MKSettingDef.new()
	def.id = MKSettingsPanel.ID_WINDOW_MODE
	def.label = "Window Mode"
	def.type = MKSettingDef.RowType.ENUM
	def.default_value = 0
	def.options = ["Windowed", "Fullscreen"] as Array[String]
	def.option_values = [0, 3]
	def.requires_confirm = true
	var page := MKSettingsPageDef.new()
	page.id = &"video"
	page.title = "Video"
	page.rows = [def] as Array[MKSettingDef]
	var panel := MKSettingsPanel.new()
	panel.pages = [page] as Array[MKSettingsPageDef]
	panel.bind_backend(backend)
	return panel


func _drop(root: MKRoot, panel: Node, backend: Node) -> void:
	if is_instance_valid(panel):
		panel.queue_free()
	if is_instance_valid(root):
		root.queue_free()
	if is_instance_valid(backend):
		backend.queue_free()
	await step_frame()
	await step_frame()


## The pause page's buttons, by the stable names [MKPauseMenu] builds them under. Indexed by name
## rather than by order so a layout change does not silently retarget an assertion.
func _find_pause_button(root: MKRoot, button_name: String) -> Button:
	return root.find_child(button_name, true, false) as Button


## The shell's own chrome nodes, found by TYPE rather than by the name [MKRoot._build_shell] assigns:
## a rename there is a refactor, and a test that fails on one is reporting the wrong thing.
func _find_nav_bar(root: MKRoot) -> MKNavBar:
	return _find_typed(root, "MKNavBar") as MKNavBar


func _find_backdrop(root: MKRoot) -> MKBackdrop:
	return _find_typed(root, "MKBackdrop") as MKBackdrop


func _find_typed(node: Node, class_id: String) -> Node:
	for child in node.get_children():
		if child.is_class(class_id) or (child.get_script() != null \
				and (child.get_script() as Script).get_global_name() == class_id):
			return child
		var found := _find_typed(child, class_id)
		if found != null:
			return found
	return null


## The [code]pause_page_id[/code] token out of [method MKRoot.dump_diagnostics], read positionally
## between its own label and the next field's. Parsed rather than substring-matched because the value
## under test is the EMPTY one, and "contains an empty string" is true of every string.
func _diagnostic_pause_page_id(root: MKRoot) -> String:
	const LABEL := "pause_page_id: "
	const NEXT := "  mouse_mode:"
	var dump := root.dump_diagnostics()
	var start := dump.find(LABEL)
	if start < 0:
		fail("dump_diagnostics carries no pause_page_id field")
		return "<missing>"
	start += LABEL.length()
	var end := dump.find(NEXT, start)
	if end < 0:
		fail("the pause_page_id field is not followed by mouse_mode on the same line")
		return "<missing>"
	return dump.substr(start, end - start)


func _first_option(node: Node) -> OptionButton:
	for child in node.get_children():
		var button := child as OptionButton
		if button != null:
			return button
		var found := _first_option(child)
		if found != null:
			return found
	return null


# --- Input drivers ------------------------------------------------------------

## Focus plus a REAL ui_accept press/release through the viewport, so the engine's own BaseButton
## activation runs — including the GUI dispatch that a PAUSABLE page would not receive.
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


## A real ui_cancel through the viewport's unhandled-input path, returning whether it was consumed —
## the test_navigation driver, so the ladder runs in the engine's own dispatch order.
func _cancel(root: MKRoot) -> bool:
	var event := InputEventAction.new()
	event.action = &"ui_cancel"
	event.pressed = true
	root.get_viewport().push_input(event)
	return root.get_viewport().is_input_handled()


# --- Service plumbing ---------------------------------------------------------

## Mounted under the exact node name MKRoot resolves; registering a real autoload needs an editor.
## Loaded by path because the service script deliberately carries no class_name.
func _install_service(backend_script: Script) -> Node:
	var service: Node = SERVICE_SCRIPT.new()
	service.name = SERVICE_NAME
	var slot := MKBackendSlot.new()
	slot.backend_script = backend_script
	service.override_backend_slot = slot
	get_root().add_child(service)
	return service


func _remove_service(service: Node) -> void:
	if is_instance_valid(service):
		get_root().remove_child(service)
		service.free()


## The project registers the real service autoload, so a test mounting its own under the same name
## must park it — Godot would otherwise rename the duplicate and every resolve would silently keep
## finding the autoload.
func _park_autoload() -> Node:
	var service := get_root().get_node_or_null(SERVICE_NAME)
	if service == null:
		return null
	get_root().remove_child(service)
	return service


func _restore_autoload(service: Node) -> void:
	if service != null and is_instance_valid(service):
		get_root().add_child(service)


# --- Log observation ----------------------------------------------------------

func _watch_log() -> void:
	_log_lines = []
	MKLog.observer = func(_level: int, message: String) -> void:
		_log_lines.append(message)


func _unwatch_log() -> void:
	MKLog.observer = Callable()


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var stem := STORE_PATH.get_file().get_basename()
	for file in dir.get_files():
		if file.begins_with(stem):
			dir.remove(file)


## Records the two application-level actions the pause page can reach, so "Quit to Menu called
## to_main_menu" is distinguishable from "it called quit" — and records the world state AT THE MOMENT
## [method to_main_menu] ran, which is the only way to assert the word "before".
##
## Counts alone cannot: after the press, the page has both closed the menu and called the backend, so
## the same final state (unpaused, depth 0) is produced by either order. This spy is a real backend
## node parented into the shell, so [method Node.get_tree] answers the same tree the policy pauses;
## the shell's own counters arrive through [member shell_probe], because a backend has no typed handle
## on the root above it.
##
## The reset sentinels are the FAILING values (paused, open, depth unknown), so a spy that never
## captured anything fails the assertions rather than passing them by default.
class QuitSpy extends MKMenuBackend:
	static var to_menu := 0
	static var quits := 0
	static var paused_at_call := true
	static var pause_open_at_call := true
	static var suspend_depth_at_call := -1
	## Set by the test to a `func() -> Dictionary` reading the live shell. Left empty by the tests that
	## only count calls.
	static var shell_probe := Callable()

	static func reset() -> void:
		to_menu = 0
		quits = 0
		paused_at_call = true
		pause_open_at_call = true
		suspend_depth_at_call = -1
		shell_probe = Callable()

	func start_game(_profile: Dictionary) -> void:
		pass

	func to_main_menu() -> void:
		to_menu += 1
		var tree := get_tree()
		paused_at_call = tree == null or tree.paused
		if shell_probe.is_valid():
			var state: Dictionary = shell_probe.call()
			pause_open_at_call = bool(state.get("pause_menu_open", true))
			suspend_depth_at_call = int(state.get("suspend_depth", -1))

	func quit() -> void:
		quits += 1
