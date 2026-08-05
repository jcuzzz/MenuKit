class_name MKTest
extends SceneTree
## Base for every MenuKit headless test (plan §4.8).
##
## Subclasses override [method run_tests] and call the assertion helpers; exit code is 0 only when
## every assertion passed and at least one ran. The "at least one" clause is deliberate: a test file
## that silently executes nothing would otherwise report green and count toward ship gate 8, which
## is worse than having no test at all.
##
## [b]Headless-safety is a hard boundary here.[/b] [code]DisplayServer[/code] window calls, audio bus
## application, and the brightness overlay are stubbed or inert under [code]--headless[/code], so
## assertions about engine-visible effects do not belong in this suite — they are phase exit criteria
## or ship gates instead. What belongs here: value round-trips, schema construction, conflict
## detection, payload and counter logic.

var _passed := 0
var _failed: Array[String] = []
var _suite := ""


func _initialize() -> void:
	_suite = (get_script() as Script).resource_path.get_file()
	call_deferred("_go")


func _go() -> void:
	await run_tests()
	await _teardown()
	_report()


## Frees whatever the test left parented to the root and lets one frame drain the queue.
##
## Without this, a test that adds an [MKRoot] and quits reports green while the engine prints
## leaked-RID and leaked-ObjectDB errors at exit. Those messages are indistinguishable from a real
## node leak in the product, so a suite that produces them routinely trains everyone to ignore the
## one signal that would catch a genuine one.
func _teardown() -> void:
	for child in get_root().get_children():
		child.queue_free()
	await process_frame
	await process_frame


## Override with the test body. May await; the harness waits for it before reporting.
func run_tests() -> void:
	fail("run_tests() not overridden")


## Declares that this test deliberately provokes an engine or MenuKit error containing
## [param substring], so the gate does not count it as a defect.
##
## [code]check.ps1[/code] fails any test whose output carries a script error, an [code]ERROR:[/code]
## line, or leaked nodes — that gate is what caught a freed-object cast four review rounds missed.
## But some tests must trigger a real error to prove it is reported: the settings-backend mismatch
## rule, a backend not extending its base. Without a way to say so, the only options are to weaken
## the gate for everyone or to leave those contracts untested, and both are worse.
##
## Declare the NARROWEST substring that identifies the specific error. A broad one ("ERROR")
## re-opens the hole this mechanism exists to keep shut.
func expect_engine_error(substring: String) -> void:
	print("MKTEST_EXPECT_NOISE: %s" % substring)


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
	else:
		fail(what)


func check_eq(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		_passed += 1
	else:
		fail("%s (expected %s, got %s)" % [what, expected, actual])


func fail(what: String) -> void:
	_failed.append(what)


## Advances one frame. Needed wherever behaviour depends on deferred calls, `_ready`, or signals
## emitted a frame after a tree mutation.
func step_frame() -> void:
	await process_frame


func _report() -> void:
	for f in _failed:
		printerr("[FAIL] %s: %s" % [_suite, f])
	if _passed == 0 and _failed.is_empty():
		printerr("[FAIL] %s: no assertions ran" % _suite)
		print("TEST %s: 0 passed, 0 failed, EMPTY" % _suite)
		quit(1)
		return
	print("TEST %s: %d passed, %d failed" % [_suite, _passed, _failed.size()])
	quit(0 if _failed.is_empty() else 1)
