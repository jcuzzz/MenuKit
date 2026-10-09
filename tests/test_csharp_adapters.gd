extends MKTest
## The five C# adapter backends, proven against a GDScript STAND-IN delegate.
##
## [b]Why a stand-in.[/b] This repo's gate has no .NET engine build, so no real C# node can be
## instantiated here. What a C# node PRESENTS to GDScript is a Node whose methods and signals are
## registered under their exact (PascalCase) names — and that shape is reproducible in GDScript
## exactly. [PascalStandIn] below is that shape: PascalCase methods, PascalCase signals,
## [code]MkConfigure[/code]. The real-C# proof runs out-of-repo and is recorded as
## human row 28 in docs/DEVELOPMENT.md §6a; everything a GDScript test CAN reach is reached
## here.
##
## [b]What each section pins.[/b]
## [br]1. [i]Slot validation[/i] — the wall the whole slice exists for: a C# class cannot extend a
##    GDScript base, and [method MKBackendSlot.validate_against] rightly refuses anything that does
##    not. Each adapter passes; a plain Node script fails (the live-check control, unpinned anywhere
##    else in the suite — [code]test_backend_ownership[/code] covers backend OWNERSHIP, never the
##    extends-check).
## [br]2. [i]Forwarding[/i] — arguments and returns cross verbatim under both spellings, with
##    snake_case winning when a delegate answers to both.
## [br]3. [i]Degradation[/i] — a missing delegate, a missing method and a wrong-typed return each
##    warn ONCE and leave the base's own answer standing. The once-ness is the assertion: a per-call
##    warning in a per-frame read site is a log flood, and a silent one is invisible misconfiguration.
## [br]4. [i]Configure[/i] — including the pending path, where params arrive before a late autoload
##    exists.
## [br]5. [i]Signals[/i] — all four bridged signals, arity and args intact.
## [br]6/7. [i]The real shell[/i] — an [MKRoot] over the demo config whose profile slot is the
##    adapter renders the stand-in's roster as cards, and whose network slot is the adapter seeds
##    the browser's caption. Isolation tests cannot catch a break in MKRoot's instantiate →
##    [code]_mk_configure[/code] → duck-typed-parent-walk chain, which is the only path a host uses.
##
## [b]Expected noise.[/b] Several tests provoke [method MKLog.warn] deliberately. Warnings are
## outside [code]check.ps1[/code]'s noise pattern, so [method expect_engine_error] must NOT be
## declared for them (an unmatched declaration fails the run by itself) — they are asserted through
## [member MKLog.observer], the seam that exists for exactly this.

const CONFIG_PATH := "res://demo/demo_config.tres"

## Messages seen by [member MKLog.observer] while a test has it installed.
var _log_lines: Array[String] = []


func run_tests() -> void:
	# --- 1. the wall
	_test_every_adapter_validates_against_its_base()
	_test_a_plain_node_script_fails_the_same_check()
	# --- 2. forwarding
	await _test_the_profile_adapter_forwards_its_whole_contract()
	await _test_the_menu_adapter_forwards_its_whole_contract()
	await _test_the_settings_adapter_forwards_its_whole_contract()
	await _test_the_network_adapter_forwards_its_whole_contract()
	await _test_the_pause_adapter_forwards_its_whole_contract()
	await _test_snake_case_wins_when_a_delegate_answers_to_both()
	_test_the_pascal_mapping_is_mechanical()
	# --- 3. degradation
	await _test_an_unreachable_delegate_warns_once_and_degrades_like_an_empty_slot()
	await _test_an_absolute_path_outside_root_degrades_instead_of_reaching_get_node()
	await _test_the_root_prefix_is_case_insensitive_and_optional()
	await _test_a_missing_method_warns_once_naming_both_spellings()
	await _test_a_wrong_typed_return_warns_once_and_keeps_the_base_default()
	await _test_one_fault_is_exactly_one_warning_line()
	await _test_omitted_optional_methods_fall_through_to_the_base()
	# --- 4. configure
	await _test_configure_reaches_the_delegate_minus_the_delegate_path()
	await _test_a_delegate_without_mk_configure_is_silently_fine()
	await _test_params_configured_before_the_delegate_exists_are_delivered_later()
	await _test_the_settings_boot_triad_replays_when_the_delegate_arrives_late()
	await _test_the_settings_adapter_refuses_to_save_a_store_it_never_loaded()
	await _test_a_loadless_delegate_never_receives_a_save()
	await _test_a_replaced_delegate_must_reload_before_it_may_save()
	await _test_the_pause_adapter_publishes_exit_tree()
	# --- 5. signals
	await _test_every_bridged_signal_re_emits_with_its_args()
	await _test_a_replaced_delegate_gets_its_signals_re_bridged()
	await _test_an_out_of_range_connect_state_lands_on_failed()
	# --- 6/7. the real shell
	await _test_the_characters_page_renders_the_stand_ins_roster()
	await _test_the_server_browser_seeds_idle_for_a_stateless_delegate()


# --- 1. Slot validation -------------------------------------------------------

## The one hard wall this slice exists to get over, stated as five facts. A C# node cannot extend
## these bases; the adapters can, and [method MKBackendSlot.validate_against] walks the whole base
## chain to say so.
func _test_every_adapter_validates_against_its_base() -> void:
	var pairs := [
		[MKCSharpMenuBackend, MKMenuBackend, "menu"],
		[MKCSharpProfileBackend, MKProfileBackend, "profile"],
		[MKCSharpSettingsBackend, MKSettingsBackend, "settings"],
		[MKCSharpNetworkBackend, MKNetworkBackend, "network"],
		[MKCSharpPausePolicy, MKPausePolicy, "pause"],
	]
	for pair in pairs:
		var slot := MKBackendSlot.new()
		slot.backend_script = pair[0]
		check_eq(slot.validate_against(pair[1]), "",
			"the %s adapter validates against its base — the wall the adapter layer exists to cross" % pair[2])


## The control. Without it the five assertions above hold against a validator that returns "" for
## everything, which is precisely the loosening this slice refused to do.
func _test_a_plain_node_script_fails_the_same_check() -> void:
	var slot := MKBackendSlot.new()
	slot.backend_script = NotABackend
	var reason := slot.validate_against(MKProfileBackend)
	check(not reason.is_empty(),
		"a plain Node script is REFUSED — the check is live, so the five passes above mean something")
	check(reason.contains("does not extend"),
		"and the refusal says what is wrong rather than failing at the first call")


# --- 2. Forwarding ------------------------------------------------------------

## Every method on [MKCSharpProfileBackend], args and returns verbatim. "Verbatim" is the assertion
## that matters: only the host knows what a profile dictionary means, and an adapter that reshaped
## one on the way through would make every C# host speak a MenuKit dialect of its own save format.
func _test_the_profile_adapter_forwards_its_whole_contract() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsProfile")
	var adapter := MKCSharpProfileBackend.new()
	_mount_adapter(adapter, "CsProfile")
	await step_frame()

	var roster := adapter.list_profiles()
	check_eq(roster.size(), 2, "list_profiles returns the delegate's rows")
	check_eq(roster[0], delegate.roster[0], "the first row crosses verbatim")

	var payload := {"name": "Zed", "archetype": "mage", "nested": {"deep": [1, 2]}}
	var created := adapter.create_profile(payload)
	check_eq(delegate.gameplay_calls(), ["ListProfiles", "CreateProfile"],
		"both calls reached the delegate under the PascalCase spelling, in order")
	check_eq(delegate.args_of("CreateProfile"), [payload],
		"with the payload byte-identical, nesting included — the WHOLE argument list, so a dropped argument fails here rather than out of bounds somewhere else")
	check_eq(created, {"id": "new", "name": "Zed"}, "and the delegate's return came back untouched")

	check_eq(adapter.delete_profile("abc"), true, "delete_profile returns the delegate's bool")
	check_eq(delegate.args_of("DeleteProfile"), ["abc"], "having handed it the id, and only the id")
	check_eq(adapter.load_profile("abc"), {"id": "abc", "loaded": true}, "load_profile returns its Dictionary")
	check_eq(adapter.is_name_available("Free"), true, "is_name_available forwards when the delegate offers it")
	check_eq(adapter.is_name_available("Alice"), false, "and its answer is the delegate's, not the base's scan")

	await _drop_all([adapter, delegate])


func _test_the_menu_adapter_forwards_its_whole_contract() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsMenu")
	var adapter := MKCSharpMenuBackend.new()
	_mount_adapter(adapter, "CsMenu")
	await step_frame()

	var profile := {"id": "p1", "name": "Alice", "level": 7}
	adapter.start_game(profile)
	adapter.to_main_menu()
	adapter.quit()
	adapter.open_url("https://example.invalid")

	check_eq(delegate.gameplay_calls(), ["StartGame", "ToMainMenu", "Quit", "OpenUrl"],
		"all four reach the delegate, under the PascalCase spelling, in order")
	check_eq(delegate.args_of("StartGame"), [profile], "start_game carries the profile verbatim")
	check_eq(delegate.args_of("OpenUrl"), ["https://example.invalid"],
		"and open_url the URL — the delegate's implementation REPLACES the base's OS.shell_open, which is the point of overriding it")

	await _drop_all([adapter, delegate])


func _test_the_settings_adapter_forwards_its_whole_contract() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsSettings")
	var adapter := MKCSharpSettingsBackend.new()
	_mount_adapter(adapter, "CsSettings")
	await step_frame()

	# The base declares a Variant return, so this is the one seam with NO coercion — a Dictionary
	# value must survive as a Dictionary, not be flattened by a well-meaning cast.
	delegate.store[&"display/mode"] = {"w": 1920, "h": 1080}
	check_eq(adapter.get_value(&"display/mode", null), {"w": 1920, "h": 1080},
		"get_value returns the delegate's Variant unchanged")
	check_eq(adapter.get_value(&"absent", 3.5), 3.5,
		"and an id the delegate has no entry for leaves the caller's default standing")

	adapter.set_value(&"audio/master", 0.25)
	check_eq(delegate.store[&"audio/master"], 0.25, "set_value wrote through to the delegate's store")
	var set_args := delegate.args_of("SetValue")
	check_eq(set_args, [&"audio/master", 0.25], "set_value forwarded both arguments verbatim")
	check_eq(typeof(set_args[0]) if set_args.size() > 0 else TYPE_NIL, TYPE_STRING_NAME,
		"with the id still a StringName across the boundary")

	# load() BEFORE save(), because the adapter refuses to save a store it never loaded — see
	# _test_the_settings_adapter_refuses_to_save_a_store_it_never_loaded for why that gate exists.
	adapter.load()
	adapter.save()
	adapter.apply_all()
	adapter.snapshot_input_defaults()
	adapter.apply_one(&"audio/master")
	check_eq(adapter.has_action_override(&"jump"), true, "has_action_override forwards and coerces to bool")
	check(delegate.calls.has("Save") and delegate.calls.has("Load") and delegate.calls.has("ApplyAll")
			and delegate.calls.has("SnapshotInputDefaults") and delegate.calls.has("ApplyOne"),
		"the store and engine-application methods all reached the delegate")

	await _drop_all([adapter, delegate])


func _test_the_network_adapter_forwards_its_whole_contract() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsNet")
	var adapter := MKCSharpNetworkBackend.new()
	_mount_adapter(adapter, "CsNet")
	await step_frame()

	var servers := adapter.list_servers()
	check_eq(servers.size(), 2, "list_servers narrows the delegate's untyped Array to Array[Dictionary]")
	check_eq(servers[1], {"id": "b", "name": "Beta"}, "with the rows verbatim")

	var entry := {"id": "a", "name": "Alpha", "port": 7777}
	adapter.connect_to(entry)
	check_eq(delegate.args_of("ConnectTo"), [entry], "connect_to hands the whole entry over, host fields included")
	adapter.cancel()
	adapter.refresh()
	check(delegate.calls.has("Cancel") and delegate.calls.has("Refresh"),
		"cancel and refresh reach the delegate")

	delegate.connect_state = MKNetworkBackend.ConnectState.CONNECTING
	check_eq(adapter.get_connect_state(), MKNetworkBackend.ConnectState.CONNECTING,
		"get_connect_state returns the delegate's enum value as an int")

	await _drop_all([adapter, delegate])


func _test_the_pause_adapter_forwards_its_whole_contract() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsPause")
	var adapter := MKCSharpPausePolicy.new()
	_mount_adapter(adapter, "CsPause")
	await step_frame()

	adapter.enter_menu(&"pause")
	adapter.exit_menu(&"pause")
	check_eq(delegate.gameplay_calls(), ["EnterMenu", "ExitMenu"], "both lifecycle calls reach the delegate")
	check_eq(delegate.args_of("EnterMenu"), [&"pause"], "with the reason still a StringName")
	delegate.can_pause = false
	check_eq(adapter.can_pause(), false, "can_pause is the delegate's answer when it offers one")

	await _drop_all([adapter, delegate])


## A delegate answering to BOTH spellings must resolve to the snake_case one. The ordering is
## invisible while only one spelling exists, and it is the documented rule — a host porting one
## method at a time would otherwise get whichever the implementation happened to check first.
func _test_snake_case_wins_when_a_delegate_answers_to_both() -> void:
	var delegate := BothSpellingsStandIn.new()
	_mount(delegate, "CsBoth")
	var adapter := MKCSharpProfileBackend.new()
	_mount_adapter(adapter, "CsBoth")
	await step_frame()

	var roster := adapter.list_profiles()
	check_eq(delegate.spellings, ["snake"],
		"the snake_case method was the one called — first spelling wins, exactly once")
	check_eq(roster.size(), 1, "and its answer is what came back")
	check_eq(String(roster[0].get("name", "")), "FromSnake", "specifically the snake_case one's rows")

	await _drop_all([adapter, delegate])


## The mapping rule itself, at the unit level, including the two cases a reader is most likely to
## get wrong by hand: the leading underscore is dropped, and the result is [code]Mk[/code] rather
## than [code]MK[/code] because the rule is mechanical rather than a table of special cases.
func _test_the_pascal_mapping_is_mechanical() -> void:
	var bridge := MKCSharpDelegate.new("probe")
	check_eq(bridge.to_pascal_case("list_profiles"), "ListProfiles", "list_profiles -> ListProfiles")
	check_eq(bridge.to_pascal_case("connect_state_changed"), "ConnectStateChanged",
		"connect_state_changed -> ConnectStateChanged")
	check_eq(bridge.to_pascal_case("quit"), "Quit", "a single segment is still capitalized")
	check_eq(bridge.to_pascal_case(MKCSharpDelegate.CONFIGURE_METHOD), MKCSharpDelegate.CONFIGURE_METHOD_PASCAL,
		"_mk_configure maps onto the published MkConfigure constant — the rule DERIVES the contract name, it is not a special case beside it")
	check_eq(MKCSharpDelegate.CONFIGURE_METHOD_PASCAL, "MkConfigure",
		"and that constant is the name the C# docs tell hosts to write")


# --- 3. Degradation -----------------------------------------------------------

## A delegate that never appears is a MISCONFIGURATION, not a crash: the adapter must answer like an
## unassigned slot and say so once. Once, because these are per-frame read sites — a warning per
## list_profiles would bury every other line in the log within a second.
func _test_an_unreachable_delegate_warns_once_and_degrades_like_an_empty_slot() -> void:
	var adapter := MKCSharpProfileBackend.new()
	_watch()
	adapter._mk_configure({"delegate_path": "/root/NoSuchNode"})
	check_eq(_lines("delegate '/root/NoSuchNode' is unavailable"), 1,
		"the unreachable delegate is named ONCE, with its path")
	check(_contains("MKCSharpProfileBackend"), "and the adapter that wanted it")

	check_eq(adapter.list_profiles(), [] as Array[Dictionary],
		"the adapter answers like an unassigned slot — an empty roster, not a crash at the first read")
	check_eq(adapter.create_profile({"name": "X"}), {}, "create degrades to an empty Dictionary")
	check_eq(adapter.delete_profile("x"), false, "delete degrades to false")
	check_eq(adapter.is_name_available("Anything"), true,
		"and is_name_available falls to the base's scan over an empty roster")
	check_eq(_lines("is unavailable"), 1,
		"after four more calls it is STILL one line — warn-once is per adapter, not per call")
	_stop()

	adapter.free()
	await step_frame()


## A typo'd absolute path is the SAME degrade as a missing node, and it must not reach
## [method Node.get_node]: an absolute NodePath resolved from outside an active scene tree pushes an
## engine ERROR — once at configure and TWICE per forwarded call, forever, in exactly the headless /
## pre-main-scene conditions an adapter is most likely to boot under. The path is parsed instead, so
## a leading segment that is not [code]root[/code] degrades quietly-but-visibly like any other
## unreachable delegate. What this test can assert is the warn; the absence of the engine ERROR is
## what the suite's own noise gate asserts, since an unexpected ERROR line fails the run.
func _test_an_absolute_path_outside_root_degrades_instead_of_reaching_get_node() -> void:
	var adapter := MKCSharpProfileBackend.new()
	_watch()
	adapter._mk_configure({"delegate_path": "/Main/Typo"})
	check_eq(_lines("delegate '/Main/Typo' is unavailable"), 1,
		"an absolute path that is not under /root is named ONCE as unavailable")
	check(_contains("must begin with '/root/'"),
		"and the warning says what is wrong with the path, which is the reader's next action")

	check_eq(adapter.list_profiles(), [] as Array[Dictionary],
		"the adapter degrades like an unassigned slot rather than crashing")
	adapter.create_profile({})
	adapter.delete_profile("x")
	check_eq(_lines("is unavailable"), 1,
		"and STILL one line after three forwarded calls — the per-call engine error this replaced was unbounded")
	_stop()

	adapter.free()
	await step_frame()


## Both accepted spellings of a reachable path, including the case-insensitive [code]/root/[/code]
## match. [code]/Root/Foo[/code] is a plausible thing for a host to write and names the same node;
## refusing it while silently ALSO refusing to say so was the shape of the bug this replaced.
func _test_the_root_prefix_is_case_insensitive_and_optional() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsCase")

	var upper := MKCSharpProfileBackend.new()
	_watch()
	upper._mk_configure({"delegate_path": "/Root/CsCase"})
	check_eq(upper.get_delegate(), delegate, "'/Root/CsCase' resolves — the /root/ segment is case-insensitive")

	var bare := MKCSharpProfileBackend.new()
	bare._mk_configure({"delegate_path": "CsCase"})
	check_eq(bare.get_delegate(), delegate, "and a bare root-relative path names the same node")
	check_eq(_log_lines.size(), 0, "neither spelling warned about anything")
	_stop()

	upper.free()
	bare.free()
	await _drop_all([delegate])


## The other half of the same rule, one level in: the delegate is THERE, it just does not implement
## the method. Both spellings are named because the reader's next action is to add one of them, and
## a message naming only the snake_case form sends a C# author looking for the wrong symbol.
func _test_a_missing_method_warns_once_naming_both_spellings() -> void:
	var delegate := StatelessStandIn.new()
	_mount(delegate, "CsLean")
	var adapter := MKCSharpSettingsBackend.new()
	_mount_adapter(adapter, "CsLean")
	await step_frame()

	_watch()
	check_eq(adapter.get_value(&"audio/master", 0.5), 0.5,
		"the base-shaped default stands: the caller's own default, which is what an empty store returns anyway")
	check_eq(_lines("neither 'get_value' nor 'GetValue'"), 1,
		"warned once, naming BOTH spellings so a C# author knows which symbol to add")
	adapter.get_value(&"audio/master", 0.5)
	adapter.get_value(&"display/mode", null)
	check_eq(_lines("neither 'get_value' nor 'GetValue'"), 1,
		"and three reads later it is still one line — warn-once is per METHOD, not per call")

	adapter.set_value(&"audio/master", 0.25)
	check_eq(_lines("neither 'set_value' nor 'SetValue'"), 1,
		"a DIFFERENT missing method gets its own line — warn-once must not silence the second fault")
	_stop()

	await _drop_all([adapter, delegate])


## The third degrade tier: the method EXISTS and answers the wrong type. This is the one a host hits
## while porting — a stringly-typed return, a nullable bool — and it must not propagate a garbage
## value into the panel that asked.
func _test_a_wrong_typed_return_warns_once_and_keeps_the_base_default() -> void:
	var delegate := WrongTypeStandIn.new()
	_mount(delegate, "CsWrong")
	var adapter := MKCSharpProfileBackend.new()
	_mount_adapter(adapter, "CsWrong")
	await step_frame()

	_watch()
	check_eq(adapter.delete_profile("a"), false,
		"a String where a bool was required leaves the base-shaped default standing")
	check_eq(_lines("returned String from 'delete_profile'"), 1,
		"warned once, naming the method, what came back, and what was required")
	adapter.delete_profile("b")
	check_eq(_lines("returned String from 'delete_profile'"), 1, "and not again on the next call")

	check_eq(adapter.list_profiles(), [] as Array[Dictionary],
		"a non-Array where Array[Dictionary] was required degrades to empty")
	check_eq(_lines("from 'list_profiles'"), 1,
		"and says so once, separately — a different method is a different fault")

	check_eq(adapter.create_profile({}), {}, "and a mistyped create degrades to an empty Dictionary")
	_stop()

	await _drop_all([adapter, delegate])


## [b]Warn TOTALS, not warn presence.[/b] Every degrade assertion above counts lines matching a
## needle, which cannot see an EXTRA line nobody looked for — and the extra line is the whole risk in
## a two-stage degrade path. A coerced call that never reached the delegate goes through the missing
## -method warn and then hands [code]null[/code] to a coercion that also wants to complain, so the
## suppression of that second complaint is load-bearing: without it one typo'd C# method name is
## reported as two unrelated faults, one of them naming a type the host never wrote.
##
## Neutering that suppression left the rest of this suite green, which is why the assertions here are
## totals over EVERY observed line rather than matches on a needle.
func _test_one_fault_is_exactly_one_warning_line() -> void:
	var lean := StatelessStandIn.new()
	_mount(lean, "CsOneFault")
	var missing := MKCSharpProfileBackend.new()
	_mount_adapter(missing, "CsOneFault")
	await step_frame()

	_watch()
	check_eq(missing.delete_profile("a"), false, "the base-shaped default stands")
	check_eq(_log_lines.size(), 1,
		"a missing method behind a bool coercion is EXACTLY one line in total — the Nil the degrade returned must not warn a second time about its type")
	check_eq(_lines("neither 'delete_profile' nor 'DeleteProfile'"), 1,
		"and it is the missing-method line, the one naming a symbol the host can go and add")
	_stop()

	var wrong := WrongTypeStandIn.new()
	_mount(wrong, "CsOneFaultWrong")
	var mistyped := MKCSharpProfileBackend.new()
	_mount_adapter(mistyped, "CsOneFaultWrong")
	await step_frame()

	_watch()
	check_eq(mistyped.delete_profile("a"), false, "the base-shaped default stands here too")
	check_eq(_log_lines.size(), 1,
		"and a delegate that DID answer, with the wrong type, is exactly one line in total as well")
	check_eq(_lines("returned String from 'delete_profile'"), 1,
		"the type line this time — a real non-Nil return is a fault worth naming")
	_stop()

	await _drop_all([missing, lean, mistyped, wrong])


## Non-abstract base defaults are the host's to override, NOT to be forced on. A delegate omitting
## one gets the base's answer with no warning at all: declining an optional hook is a correct
## configuration, and warning on it would train hosts to ignore this adapter's log lines.
func _test_omitted_optional_methods_fall_through_to_the_base() -> void:
	var delegate := StatelessStandIn.new()
	_mount(delegate, "CsOpt")
	var settings := MKCSharpSettingsBackend.new()
	_mount_adapter(settings, "CsOpt")
	var net := MKCSharpNetworkBackend.new()
	_mount_adapter(net, "CsOpt")
	var pause := MKCSharpPausePolicy.new()
	_mount_adapter(pause, "CsOpt")
	var profile := MKCSharpProfileBackend.new()
	_mount_adapter(profile, "CsOpt")
	await step_frame()

	_watch()
	check_eq(settings.get_action_events(&"jump"), [] as Array[InputEvent],
		"the input store degrades to the base's inert answer — 'Unbound' rows, never wrong bindings")
	check_eq(settings.has_action_override(&"jump"), false, "and no phantom override")
	settings.reset_all_actions_to_defaults()
	net.refresh()
	check_eq(pause.can_pause(), true, "the pause policy keeps the base's permissive default")
	check_eq(net.get_connect_state(), MKNetworkBackend.ConnectState.IDLE,
		"and the network adapter reports IDLE — see the browser test below for why that is the right default")
	check_eq(_lines("implements neither"), 0,
		"and NONE of it warned: an optional hook a host declined is correct configuration, not a fault")
	_stop()

	# is_name_available with no delegate method: the base scans list_profiles, and THAT call comes
	# straight back through this same adapter. The round trip is the assertion, and it DOES warn —
	# list_profiles is abstract, so a delegate missing it is a real fault, unlike the hooks above.
	check_eq(profile.is_name_available("Ghost"), true,
		"is_name_available falls to the base scan, which re-enters this adapter's own list_profiles")

	await _drop_all([settings, net, pause, profile, delegate])


# --- 4. Configure -------------------------------------------------------------

## [code]delegate_path[/code] is this adapter layer's OWN param and must not leak into the host's
## configure payload — a C# backend should see the same dictionary a GDScript one would.
func _test_configure_reaches_the_delegate_minus_the_delegate_path() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsCfg")
	var adapter := MKCSharpProfileBackend.new()
	var consumed := adapter._mk_configure({
		"delegate_path": "/root/CsCfg", "file_path": "user://x.json", "limit": 4,
	})
	check_eq(delegate.configured, {"file_path": "user://x.json", "limit": 4},
		"MkConfigure receives every param EXCEPT delegate_path, values intact")
	check_eq(consumed.size(), 3,
		"and all three keys are reported consumed — an unforwarded key would make MKRoot warn on correct config")

	adapter.free()
	await _drop_all([delegate])


## Optional means optional. A delegate with no configure hook and a slot with params is a legal
## combination, and it must be silent.
func _test_a_delegate_without_mk_configure_is_silently_fine() -> void:
	var delegate := StatelessStandIn.new()
	_mount(delegate, "CsNoCfg")
	var adapter := MKCSharpMenuBackend.new()
	_watch()
	adapter._mk_configure({"delegate_path": "/root/CsNoCfg", "game_scene": "res://x.tscn"})
	check_eq(_log_lines.size(), 0, "a delegate exposing no MkConfigure produces no output at all")
	_stop()
	adapter.free()
	await _drop_all([delegate])


## The pending path, and the reason it exists: a C# autoload can sit BELOW the adapter in autoload
## order, and MKRoot hands params over before it even adds the adapter to the tree. Params dropped
## because the delegate had not spawned yet would be lost silently, and the host's first symptom
## would be a backend running on defaults it never configured.
func _test_params_configured_before_the_delegate_exists_are_delivered_later() -> void:
	var adapter := MKCSharpProfileBackend.new()
	_watch()
	adapter._mk_configure({"delegate_path": "/root/CsLate", "file_path": "user://late.json"})
	check_eq(_lines("is unavailable"), 1, "precondition: at configure time the delegate does not exist yet")
	_stop()

	var delegate := PascalStandIn.new()
	_mount(delegate, "CsLate")
	check_eq(delegate.configured, null, "precondition: nothing was delivered while unresolved")

	# Any call re-attempts resolution; this is the first read a real host would make.
	adapter.list_profiles()
	check_eq(delegate.configured, {"file_path": "user://late.json"},
		"the held params are delivered on the resolve that finds the delegate — still minus delegate_path")

	adapter.list_profiles()
	check_eq(delegate.calls.count("MkConfigure"), 1,
		"and delivered exactly once, not on every later call")

	adapter.free()
	await _drop_all([delegate])


## [b]The autoload-order case, which is the one that eats a player's settings.[/b]
## [code]MKSettingsService[/code] makes its boot triad — snapshot_input_defaults, load, apply_all —
## synchronously in [method Node._ready]. A C# delegate autoload registered BELOW the service does
## not exist yet at that moment, so all three degrade; stock bindings are never snapshotted, the
## player's file is never read, and nothing is applied — permanently, because the service never calls
## them again. The adapter therefore holds the triad and replays it, IN ORDER, on the resolve that
## finds the delegate. Order is asserted, not just delivery: apply_all before load applies a store
## that was never read, and load before snapshot_input_defaults snapshots the user's own overrides as
## the "defaults" that Reset to Defaults restores.
func _test_the_settings_boot_triad_replays_when_the_delegate_arrives_late() -> void:
	var adapter := MKCSharpSettingsBackend.new()
	_watch()
	adapter._mk_configure({"delegate_path": "/root/CsBootLate", "file_path": "user://s.json"})
	# Exactly what the service does in _ready, against a delegate that does not exist yet.
	adapter.snapshot_input_defaults()
	adapter.load()
	adapter.apply_all()
	check_eq(_lines("is unavailable"), 1, "precondition: the whole triad forwarded into an absent delegate")
	_stop()

	var delegate := PascalStandIn.new()
	_mount(delegate, "CsBootLate")
	check_eq(delegate.calls, [], "precondition: nothing was delivered while unresolved")

	# Any later call re-attempts resolution. A settings panel READ is the realistic one — the host
	# never calls the triad again, so a replay that waited for a fourth boot call would never run.
	adapter.get_value(&"audio/master", 0.5)
	check_eq(delegate.gameplay_calls(),
		["SnapshotInputDefaults", "Load", "ApplyAll", "GetValue"],
		"the held triad is replayed in its original order on the resolve that found the delegate, before the call that triggered it completes")
	check_eq(delegate.calls[0], "MkConfigure",
		"and the configure params landed FIRST — a triad replayed onto an unconfigured delegate would read the wrong file")

	adapter.get_value(&"audio/master", 0.5)
	check_eq(delegate.calls.count("Load"), 1, "and replayed exactly once, not on every later call")

	adapter.free()
	await _drop_all([delegate])


## [b]The data-destroying half.[/b] When the triad above is lost, the delegate holds its C#-side
## defaults — and [code]MKSettingsService[/code] flushes a [method MKSettingsBackend.save] on exit.
## That save writes defaults over a file the player spent real time on, and the loss is silent and
## total. So the adapter refuses to save a store its load never reached, and says why.
func _test_the_settings_adapter_refuses_to_save_a_store_it_never_loaded() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsNoLoad")
	var adapter := MKCSharpSettingsBackend.new()
	_mount_adapter(adapter, "CsNoLoad")
	await step_frame()

	_watch()
	adapter.save()
	check_eq(delegate.calls.has("Save"), false,
		"a save before any load is REFUSED — this is the exit-tree flush that would overwrite the player's file")
	check_eq(_lines("refusing to save()"), 1, "and it says so, once, naming the reason")
	adapter.save()
	check_eq(_lines("refusing to save()"), 1, "still once — the refusal is a warn-once like every other degrade")
	_stop()

	adapter.load()
	adapter.save()
	check_eq(delegate.calls.has("Save"), true,
		"and once the load has actually reached the delegate, save forwards normally")

	await _drop_all([adapter, delegate])


## [b]The Load-less delegate stays refused FOREVER, and that is the contract.[/b] The adapter's class
## doc lists Load() in the required set; a Save-only C# store is out of contract, and the guard must
## treat "load was never delivered" identically whether the cause is autoload order or a delegate
## that simply has no Load — never overwriting a store that was never read is the point. This is
## also the pin round 2's surviving mutation demanded: a [method MKCSharpDelegate.was_delivered]
## that lies true would flow a Save through here and go red.
func _test_a_loadless_delegate_never_receives_a_save() -> void:
	var delegate := SaveOnlyStandIn.new()
	_mount(delegate, "CsSaveOnly")
	var adapter := MKCSharpSettingsBackend.new()
	_mount_adapter(adapter, "CsSaveOnly")
	await step_frame()

	_watch()
	adapter.load()
	check_eq(_lines("neither 'load' nor 'Load'"), 1,
		"the missing Load is named once, both spellings")
	adapter.save()
	check_eq(delegate.calls.has("Save"), false,
		"Save NEVER reaches a delegate whose store was never read — a Save-only store is out of contract")
	check_eq(_lines("refusing to save()"), 1, "and the refusal says why, once")
	adapter.save()
	check_eq(delegate.calls.has("Save"), false, "still refused — the guard is permanent for this delegate")
	_stop()

	await _drop_all([adapter, delegate])


## [b]A replaced delegate must earn save() again.[/b] A dev hot-reload swap mounts a NEW C# node at
## the same path; its store was never loaded even though the previous instance's was. The guard
## tracks the INSTANCE load reached, not a boolean — a save forwarded to the replacement would write
## its defaults over the player's file, the same destruction the never-loaded case refuses.
func _test_a_replaced_delegate_must_reload_before_it_may_save() -> void:
	var first := PascalStandIn.new()
	_mount(first, "CsSwap")
	var adapter := MKCSharpSettingsBackend.new()
	_mount_adapter(adapter, "CsSwap")
	await step_frame()

	adapter.load()
	adapter.save()
	check_eq(first.calls.has("Save"), true, "precondition: the loaded first instance saves normally")

	var second := PascalStandIn.new()
	await _drop_all([first])
	_mount(second, "CsSwap")
	adapter.get_value(&"audio/master", 0.5)
	check_eq(adapter.get_delegate(), second, "precondition: the adapter re-resolved to the replacement")

	_watch()
	adapter.save()
	check_eq(second.calls.has("Save"), false,
		"the replacement's store was never loaded — save is refused until ITS load lands")
	_stop()

	adapter.load()
	adapter.save()
	check_eq(second.calls.has("Save"), true, "and a fresh load re-arms save for the new instance")

	await _drop_all([adapter, second])


## The pause policy's teardown notification. The base's contract is that a policy undoes its own
## effects in [method Node._exit_tree] — but here the effects live in an autoload that never leaves
## the tree, so without this hop the delegate never learns the shell it froze the game for is gone,
## and the next game boots paused.
func _test_the_pause_adapter_publishes_exit_tree() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsExit")
	var adapter := MKCSharpPausePolicy.new()
	_mount_adapter(adapter, "CsExit")
	await step_frame()
	adapter.enter_menu(&"pause")
	check_eq(delegate.calls.has("MkExitTree"), false, "precondition: nothing has torn down yet")

	get_root().remove_child(adapter)
	adapter.free()
	check_eq(delegate.calls.has("MkExitTree"), true,
		"leaving the tree reaches the delegate, so an autoload policy can undo what it did")

	await _drop_all([delegate])


# --- 5. Signals ---------------------------------------------------------------

## All four bridged signals, each with the arity its base declares. Arity is stated per signal in
## the adapters rather than guessed, because a mismatched connection fails at EMIT time — meaning a
## generic bridge would look correct at wiring and break the first time a host's roster changed.
func _test_every_bridged_signal_re_emits_with_its_args() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsSig")
	var profile := MKCSharpProfileBackend.new()
	_mount_adapter(profile, "CsSig")
	var settings := MKCSharpSettingsBackend.new()
	_mount_adapter(settings, "CsSig")
	var net := MKCSharpNetworkBackend.new()
	_mount_adapter(net, "CsSig")
	await step_frame()

	var roster_hits := [0]
	profile.roster_changed.connect(func() -> void: roster_hits[0] += 1)
	delegate.RosterChanged.emit()
	check_eq(roster_hits[0], 1,
		"roster_changed re-emits through the adapter — this is what makes the select panel refresh after a C#-side mutation")

	var seen: Array = []
	settings.setting_changed.connect(func(id: StringName, value: Variant) -> void: seen.append([id, value]))
	# Emitted with a plain String id, which is what a C# signal declared with `string` sends.
	delegate.SettingChanged.emit("audio/master", 0.75)
	check_eq(seen.size(), 1, "setting_changed re-emits once")
	if seen.size() == 1:
		check_eq(typeof(seen[0][0]), TYPE_STRING_NAME, "with the id coerced to StringName, which the panels index by")
		check_eq(seen[0][0], &"audio/master", "and the id itself unchanged")
		check_eq(seen[0][1], 0.75, "and the value verbatim")

	var servers_hits := [0]
	net.servers_changed.connect(func() -> void: servers_hits[0] += 1)
	delegate.ServersChanged.emit()
	check_eq(servers_hits[0], 1, "servers_changed re-emits")

	var states: Array = []
	net.connect_state_changed.connect(func(s: int, m: String) -> void: states.append([s, m]))
	delegate.ConnectStateChanged.emit(MKNetworkBackend.ConnectState.CONNECTED, "Joined Alpha")
	check_eq(states.size(), 1, "connect_state_changed re-emits once")
	if states.size() == 1:
		check_eq(states[0][0], MKNetworkBackend.ConnectState.CONNECTED, "with the state intact")
		check_eq(states[0][1], "Joined Alpha", "and the message intact")

	await _drop_all([profile, settings, net, delegate])


## A delegate REPLACED at the same path — a hot-reloaded C# autoload, a scene reload, a test swapping
## its stand-in — is a different node instance, and the bridging done against the old one went with
## it. Silently: the adapter still resolves, still forwards calls, and simply never re-emits again,
## so the select panel stops refreshing after C#-side mutations with nothing in the log. Re-running
## the bridging on every resolution is the repair; the freed node's own connections need no cleanup
## because Godot drops them with it.
func _test_a_replaced_delegate_gets_its_signals_re_bridged() -> void:
	var first := PascalStandIn.new()
	_mount(first, "CsSwap")
	var adapter := MKCSharpProfileBackend.new()
	_mount_adapter(adapter, "CsSwap")
	await step_frame()

	var hits := [0]
	adapter.roster_changed.connect(func() -> void: hits[0] += 1)
	first.RosterChanged.emit()
	check_eq(hits[0], 1, "precondition: the first delegate's signal bridges")

	get_root().remove_child(first)
	first.free()
	var second := PascalStandIn.new()
	second.roster = [{"id": "9", "name": "Replacement"}]
	_mount(second, "CsSwap")

	# Any call re-attempts resolution, which is where the re-bridge has to happen.
	check_eq(adapter.list_profiles().size(), 1, "the adapter re-resolved onto the replacement")
	second.RosterChanged.emit()
	check_eq(hits[0], 2,
		"and its signal arrives — bridging follows the delegate INSTANCE, not the first one ever seen")

	await _drop_all([adapter, second])


## A state outside the enum must land on a TERMINAL one. The browser renders every enum member and
## nothing else, so a bogus value that fell through would leave the player on a spinner forever with
## no cancel path — worse than a wrong caption.
func _test_an_out_of_range_connect_state_lands_on_failed() -> void:
	var delegate := PascalStandIn.new()
	_mount(delegate, "CsBadState")
	var net := MKCSharpNetworkBackend.new()
	_mount_adapter(net, "CsBadState")
	await step_frame()

	var states: Array = []
	net.connect_state_changed.connect(func(s: int, m: String) -> void: states.append([s, m]))
	_watch()
	delegate.ConnectStateChanged.emit(99, "who knows")
	check_eq(states.size(), 1, "an out-of-range state still re-emits — swallowing it is the spinner-forever bug")
	if states.size() == 1:
		check_eq(states[0][0], MKNetworkBackend.ConnectState.FAILED, "coerced to FAILED, a terminal state")
		check_eq(states[0][1], "who knows",
			"keeping the delegate's own message, which is the only diagnostic the player gets")
	check_eq(_lines("connect_state_changed"), 1, "and the bad value is named in the log exactly once")
	_stop()

	await _drop_all([net, delegate])


# --- 6/7. Through the REAL shell ----------------------------------------------

## The end-to-end claim: adapters work through MKRoot's instantiate → validate → `_mk_configure` →
## add_child chain and the panel's duck-typed ancestor walk, not merely when a test calls them
## directly. The config is [method Resource.duplicate]d first — the shipped resource is cached
## across the sweep and re-pointing its slots would leak into every later test.
func _test_the_characters_page_renders_the_stand_ins_roster() -> void:
	var delegate := PascalStandIn.new()
	delegate.roster = [
		{"id": "1", "name": "Alice", "archetype": "scout"},
		{"id": "2", "name": "Bob"},
		{"id": "3", "name": "Cleo"},
	]
	_mount(delegate, "CsHost")
	var config := (ResourceLoader.load(CONFIG_PATH) as MKConfig).duplicate(true)
	var slot := MKBackendSlot.new()
	slot.backend_script = MKCSharpProfileBackend
	slot.params = {"delegate_path": "/root/CsHost"}
	config.profile_backend = slot
	check_eq(config.validate(), PackedStringArray(),
		"a config whose profile slot is the C# adapter VALIDATES — the whole point of the adapter extending the base")

	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	_watch()
	get_root().add_child(root)
	await step_frame()
	root.go_to_page(&"characters")
	await step_frame()
	await step_frame()
	check_eq(_lines("nothing consumed param"), 0,
		"MKRoot reports no leftover params: the adapter claims delegate_path on the delegate's behalf")
	_stop()

	var backend := root.get_profile_backend()
	check(backend is MKCSharpProfileBackend, "the shell instantiated the adapter from the slot")
	if backend is MKCSharpProfileBackend:
		check((backend as MKCSharpProfileBackend).get_delegate() == delegate,
			"and it resolved the stand-in from the slot param, through the real boot order")

	var panel := _find_typed(root, "MKCharacterSelect")
	check(panel != null, "the characters page built its panel")
	if panel != null:
		var cards := _cards(panel)
		check_eq(cards.size(), 3, "one card per stand-in roster entry — the C# roster is on screen")
		if cards.size() == 3:
			check_eq(cards[0].text, "Alice — scout",
				"rendered from the delegate's own fields, which is the proof the walk reached THIS backend")

	root.queue_free()
	await step_frame()
	await _drop_all([delegate])


## [b]The documented default, pinned deliberately.[/b] [MKServerBrowser] seeds its caption from a
## duck-typed [code]get_connect_state()[/code] — and [MKCSharpNetworkBackend] ALWAYS has that
## method, even when the delegate implements nothing of the kind, in which case it answers IDLE.
##
## That is the same state the panel starts on for a backend with no getter at all, so a delegate
## that does not track lifecycle state is exactly as well served through the adapter as a minimal
## GDScript backend is — no spinner, no false CONNECTED, rows rendered. Recorded here as the
## intended behaviour rather than an accident of the duck-typed seam: the alternative (hiding the
## method when the delegate lacks it) would need the adapter to answer `has_method` dynamically,
## which GDScript cannot do, and would buy nothing the IDLE answer does not already give.
func _test_the_server_browser_seeds_idle_for_a_stateless_delegate() -> void:
	var delegate := StatelessStandIn.new()
	_mount(delegate, "CsNetHost")
	var config := (ResourceLoader.load(CONFIG_PATH) as MKConfig).duplicate(true)
	var slot := MKBackendSlot.new()
	slot.backend_script = MKCSharpNetworkBackend
	slot.params = {"delegate_path": "/root/CsNetHost"}
	config.network_backend = slot

	var root := MKRoot.new()
	root.config = config
	root.size = Vector2(1920, 1080)
	get_root().add_child(root)
	await step_frame()
	root.go_to_page(&"servers")
	await step_frame()
	await step_frame()

	var panel := _find_typed(root, "MKServerBrowser")
	check(panel != null, "the servers page built its browser over the adapter")
	if panel != null:
		check_eq(panel.call("get_connect_state"), MKNetworkBackend.ConnectState.IDLE,
			"a delegate tracking no lifecycle state seeds IDLE — the documented default, identical to a backend with no getter")
		check_eq(_rows(panel).size(), 2,
			"and the delegate's rows are on screen regardless — the IDLE seed costs nothing")

	root.queue_free()
	await step_frame()
	await _drop_all([delegate])


# --- Fixtures -----------------------------------------------------------------

## The shape a C# node presents to GDScript: PascalCase methods, PascalCase signals, MkConfigure.
## NOT one method here is snake_case, which is what makes it a real test of the mapping rule.
class PascalStandIn extends Node:
	signal RosterChanged()
	signal SettingChanged(id, value)
	signal ServersChanged()
	signal ConnectStateChanged(state, message)

	## Method names in call order, and their argument arrays alongside — so a test can assert both
	## WHICH spelling resolved and WHAT crossed, from one recording.
	var calls: Array = []
	var args: Array = []
	var configured = null
	var roster: Array = [{"id": "1", "name": "Alice"}, {"id": "2", "name": "Bob"}]
	var servers: Array = [{"id": "a", "name": "Alpha"}, {"id": "b", "name": "Beta"}]
	var store := {}
	var connect_state := 0
	var can_pause := true

	func _record(what: String, a: Array = []) -> void:
		calls.append(what)
		args.append(a)

	## The call sequence with the configure hook filtered out. Every forwarding test asserts the
	## GAMEPLAY order, and MkConfigure always lands first because mounting configures first.
	func gameplay_calls() -> Array:
		return calls.filter(func(c: String) -> bool: return c != "MkConfigure")

	## The arguments the first call named [param what] arrived with. By name rather than by index so
	## an assertion does not silently start reading a different call when one is added above it.
	func args_of(what: String) -> Array:
		var index := calls.find(what)
		return args[index] if index >= 0 else []

	func MkConfigure(params: Dictionary) -> void:
		_record("MkConfigure", [params])
		configured = params

	func MkExitTree() -> void:
		_record("MkExitTree")

	# --- menu
	func StartGame(profile: Dictionary) -> void: _record("StartGame", [profile])
	func ToMainMenu() -> void: _record("ToMainMenu")
	func Quit() -> void: _record("Quit")
	func OpenUrl(url: String) -> void: _record("OpenUrl", [url])

	# --- profile
	func ListProfiles() -> Array:
		_record("ListProfiles")
		return roster

	func CreateProfile(payload: Dictionary) -> Dictionary:
		_record("CreateProfile", [payload])
		return {"id": "new", "name": payload.get("name", "")}

	func DeleteProfile(id: String) -> bool:
		_record("DeleteProfile", [id])
		return true

	func LoadProfile(id: String) -> Dictionary:
		_record("LoadProfile", [id])
		return {"id": id, "loaded": true}

	func IsNameAvailable(profile_name: String) -> bool:
		_record("IsNameAvailable", [profile_name])
		return profile_name != "Alice"

	# --- settings
	func GetValue(id, default_value):
		_record("GetValue", [id, default_value])
		return store.get(id, default_value)

	func SetValue(id, value) -> void:
		_record("SetValue", [id, value])
		store[id] = value

	func Save() -> void: _record("Save")
	func Load() -> void: _record("Load")
	func ApplyAll() -> void: _record("ApplyAll")
	func SnapshotInputDefaults() -> void: _record("SnapshotInputDefaults")
	func ApplyOne(id) -> void: _record("ApplyOne", [id])

	func HasActionOverride(action) -> bool:
		_record("HasActionOverride", [action])
		return true

	# --- network
	func ListServers() -> Array:
		_record("ListServers")
		return servers

	func ConnectTo(entry: Dictionary) -> void: _record("ConnectTo", [entry])
	func Cancel() -> void: _record("Cancel")
	func Refresh() -> void: _record("Refresh")

	func GetConnectState() -> int:
		_record("GetConnectState")
		return connect_state

	# --- pause
	func EnterMenu(reason) -> void: _record("EnterMenu", [reason])
	func ExitMenu(reason) -> void: _record("ExitMenu", [reason])

	func CanPause() -> bool:
		_record("CanPause")
		return can_pause


## Answers to BOTH spellings, so the resolution ORDER is observable. A host mid-port has exactly
## this shape for one method at a time.
class BothSpellingsStandIn extends Node:
	signal RosterChanged()

	var spellings: Array = []

	func list_profiles() -> Array:
		spellings.append("snake")
		return [{"id": "s", "name": "FromSnake"}]

	func ListProfiles() -> Array:
		spellings.append("pascal")
		return [{"id": "p", "name": "FromPascal"}]


## A delegate implementing the bare minimum: the abstract network contract and nothing optional. It
## is the "host who ported half of it" case, and every adapter must degrade over it without a crash.
class StatelessStandIn extends Node:
	func ListServers() -> Array:
		return [{"id": "a", "name": "Alpha"}, {"id": "b", "name": "Beta"}]

	func ConnectTo(_entry: Dictionary) -> void: pass
	func Cancel() -> void: pass


## Answers with the WRONG type — the shape a half-ported C# backend has when its return types have
## not been lined up with the Variant boundary yet.
class WrongTypeStandIn extends Node:
	func DeleteProfile(_id: String) -> String:
		return "yes"

	func ListProfiles() -> Dictionary:
		return {"not": "an array"}

	func CreateProfile(_payload: Dictionary) -> int:
		return 7


## The negative control for the slot check: a Node script that is not a backend at all.
class NotABackend extends Node:
	pass


## A Save-only settings store — out of the settings-adapter contract (no Load), which is precisely
## why it exists: the save-refusal guard must hold against it forever, not just against slow
## autoloads.
class SaveOnlyStandIn extends Node:
	var calls: Array = []

	func Save() -> void:
		calls.append("Save")

	func GetValue(_id: StringName, default_value: Variant) -> Variant:
		calls.append("GetValue")
		return default_value


# --- Harness ------------------------------------------------------------------

## Adds a stand-in under the exact node name a `delegate_path` param references. Absolute autoload
## paths are what a real host writes, and `/root/<name>` is reachable here without registering one.
func _mount(node: Node, node_name: String) -> void:
	node.name = node_name
	get_root().add_child(node)


## Builds an adapter the way MKRoot does: params BEFORE the tree, then add_child. Doing it in the
## other order would let `_ready`'s resolve mask a broken configure path.
func _mount_adapter(adapter: Node, delegate_name: String) -> void:
	adapter.call("_mk_configure", {"delegate_path": "/root/%s" % delegate_name})
	get_root().add_child(adapter)


func _drop_all(nodes: Array) -> void:
	for node in nodes:
		var n := node as Node
		if n != null and is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
	await step_frame()


func _watch() -> void:
	_log_lines = []
	MKLog.observer = func(_level: int, message: String) -> void:
		_log_lines.append(message)


func _stop() -> void:
	MKLog.observer = Callable()


func _lines(needle: String) -> int:
	var count := 0
	for line in _log_lines:
		if line.contains(needle):
			count += 1
	return count


func _contains(needle: String) -> bool:
	return _lines(needle) > 0


func _find_typed(root: Node, type_name: String) -> Node:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var script := node.get_script() as Script
		if script != null and script.get_global_name() == type_name:
			return node
		for child in node.get_children():
			stack.append(child)
	return null


func _cards(panel: Node) -> Array[Button]:
	var out: Array[Button] = []
	var column := panel.get("_card_column") as Node
	if column == null:
		return out
	for child in column.get_children():
		var button := child as Button
		if button != null:
			out.append(button)
	return out


func _rows(panel: Node) -> Array[Button]:
	var out: Array[Button] = []
	var column := panel.find_child("Rows", true, false)
	if column == null:
		return out
	for child in column.get_children():
		var button := child as Button
		if button != null:
			out.append(button)
	return out
