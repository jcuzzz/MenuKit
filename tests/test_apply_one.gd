extends MKTest
## [method MKSettingsBackend.apply_one] — the instant-apply path a settings panel calls on every
## change (plan §4.3, D14).
##
## Its whole reason to exist is that a slider drag emits a write per pixel, so it must push exactly
## ONE value and dispatch to the same helpers [method MKSettingsBackend.apply_all] walks. Two
## opposite failures are covered:
##
## [br]- [b]Doing too much.[/b] A dispatch that fell through to apply_all would re-push every window,
##   bus and InputMap value on every slider frame — slow, and visible as window flicker on the display
##   rows. Asserted by proving an unrelated id leaves a reserved one unapplied.
## [br]- [b]Complaining about normal operation.[/b] Plain values (FOV, mouse sensitivity) are the
##   majority of ids and are the host's to consume, so an unrecognised id must be silent. A warning
##   there would make correct usage noisy and train hosts to ignore the log.
##
## [b]Headless boundary[/b] (plan §4.8). Window mode, resolution and vsync are [DisplayServer] calls
## that are inert under the headless driver, so "the window resized" is not assertable here and
## belongs to the phase criteria. What IS asserted is the guard that makes them inert: reaching a
## display id headless must produce no error AND no warning, including for a value the non-headless
## branch would have complained about — which pins the order of the guard rather than its absence.
## Audio and [member Engine.max_fps] are real headless, so those are asserted for effect.

const STORE_PATH := "user://test_apply_one.json"

var _warnings: Array[String] = []


func run_tests() -> void:
	_clean()
	await _test_plain_id_is_a_silent_no_op()
	await _test_dispatch_is_targeted()
	await _test_missing_bus_is_named()
	await _test_master_bus_applies()
	await _test_display_ids_are_inert_headless()
	_clean()


## A plain id must neither warn nor error. This is the majority case, not the exception.
func _test_plain_id_is_a_silent_no_op() -> void:
	var backend := _make_backend()
	backend.set_value(&"gameplay/fov", 90.0)
	backend.set_value(&"controls/mouse_sensitivity", 0.35)

	_watch()
	backend.apply_one(&"gameplay/fov")
	backend.apply_one(&"controls/mouse_sensitivity")
	backend.apply_one(&"never/stored/at/all")
	var warnings := _stop()

	check_eq(warnings.size(), 0,
		"an unrecognised id applies nothing and says nothing — the host consumes it off setting_changed. Saw: %s"
			% [warnings])
	check_eq(backend.get_value(&"gameplay/fov", 0.0), 90.0,
		"and the stored value is untouched by the attempt")

	backend.queue_free()
	await step_frame()


## Targeted, not a disguised apply_all: applying id A must not push id B.
##
## Engine.max_fps is the one reserved id that is real headless, which makes it the only honest probe
## for this in this suite.
func _test_dispatch_is_targeted() -> void:
	var backend := _make_backend()
	var restore := Engine.max_fps
	Engine.max_fps = 0

	backend.set_value(&"video/max_fps", 45)
	backend.apply_one(&"gameplay/fov")
	check_eq(Engine.max_fps, 0,
		"applying an unrelated id does NOT push video/max_fps — apply_one is not apply_all in disguise")

	backend.apply_one(&"video/max_fps")
	check_eq(Engine.max_fps, 45,
		"applying it directly does push it, through the same helper apply_all uses")

	# And the reverse direction: a value that was never stored must not be invented.
	Engine.max_fps = 0
	var empty := MKJsonSettingsBackend.new()
	empty._mk_configure({"file_path": "user://test_apply_one_empty.json"})
	get_root().add_child(empty)
	empty.apply_one(&"video/max_fps")
	check_eq(Engine.max_fps, 0,
		"an id with nothing stored applies nothing rather than pushing a zero at the engine")
	empty.queue_free()

	Engine.max_fps = restore
	backend.queue_free()
	await step_frame()


## A volume slider that moves nothing is otherwise diagnosed by reading source. The bus NAME is the
## part that has to be in the message — "a bus is missing" does not tell a host which one to add.
func _test_missing_bus_is_named() -> void:
	var backend := _make_backend()
	backend.set_value(&"audio/bus/Missing", 0.5)

	_watch()
	backend.apply_one(&"audio/bus/Missing")
	var warnings := _stop()

	check_eq(warnings.size(), 1, "a missing bus warns exactly once. Saw: %s" % [warnings])
	check_eq(_count_containing(warnings, "Missing"), 1,
		"and the message NAMES the bus, so the host knows which one to add")

	backend.queue_free()
	await step_frame()


## Audio is real under the headless driver, so this is asserted for effect rather than for logic.
func _test_master_bus_applies() -> void:
	var backend := _make_backend()
	var index := AudioServer.get_bus_index("Master")
	check(index >= 0, "an empty project always has a Master bus — the reason the shipped page is Master-only")
	if index < 0:
		backend.queue_free()
		return
	var restore_db := AudioServer.get_bus_volume_db(index)
	var restore_mute := AudioServer.is_bus_mute(index)

	_watch()
	backend.set_value(&"audio/bus/Master", 0.5)
	backend.apply_one(&"audio/bus/Master")
	check(is_equal_approx(AudioServer.get_bus_volume_db(index), linear_to_db(0.5)),
		"a linear 0..1 value reaches the bus as dB")
	check(not AudioServer.is_bus_mute(index), "and a non-zero volume leaves the bus unmuted")

	backend.set_value(&"audio/bus/Master", 0.0)
	backend.apply_one(&"audio/bus/Master")
	check(AudioServer.is_bus_mute(index),
		"zero MUTES explicitly rather than leaving the bus doing pointless work at -inf dB")

	backend.set_value(&"audio/bus/Master", 3.0)
	backend.apply_one(&"audio/bus/Master")
	check(is_equal_approx(AudioServer.get_bus_volume_db(index), linear_to_db(1.0)),
		"an out-of-range value is clamped to unity rather than blowing the mix out")
	var warnings := _stop()
	check_eq(warnings.size(), 0, "and an existing bus applies silently. Saw: %s" % [warnings])

	AudioServer.set_bus_volume_db(index, restore_db)
	AudioServer.set_bus_mute(index, restore_mute)
	backend.queue_free()
	await step_frame()


## Every display helper re-checks the headless guard ITSELF rather than trusting its caller: apply_all
## guards them as a group, but apply_one reaches each one individually, and a guard that exists at only
## one of two entry points is the shape of bug that passes every run with a window.
func _test_display_ids_are_inert_headless() -> void:
	var backend := _make_backend()
	check(backend.is_headless_display(),
		"this suite runs under the headless driver, which is what makes the assertions below meaningful")

	backend.set_value(&"video/window_mode", DisplayServer.WINDOW_MODE_FULLSCREEN)
	backend.set_value(&"video/vsync", DisplayServer.VSYNC_DISABLED)
	# Deliberately unusable: with a real display this value warns. Headless, the guard returns before
	# the check — so silence here proves the guard runs FIRST, which no "it did not crash" test can.
	backend.set_value(&"video/resolution", Vector2i(0, 0))

	_watch()
	backend.apply_one(&"video/window_mode")
	backend.apply_one(&"video/vsync")
	backend.apply_one(&"video/resolution")
	var warnings := _stop()

	check_eq(warnings.size(), 0,
		"display ids reach apply_one headless without error and without warning — the guard precedes the validation. Saw: %s"
			% [warnings])
	check_eq(backend.get_value(&"video/resolution", null), Vector2i(0, 0),
		"and the store is unchanged: apply_one pushes values, it never rewrites them")

	backend.queue_free()
	await step_frame()


# --- Fixtures -----------------------------------------------------------------

func _make_backend() -> MKJsonSettingsBackend:
	var backend := MKJsonSettingsBackend.new()
	backend._mk_configure({"file_path": STORE_PATH})
	get_root().add_child(backend)
	return backend


func _watch() -> void:
	_warnings = []
	MKLog.observer = func(level: MKLog.Level, message: String) -> void:
		if level == MKLog.Level.WARN:
			_warnings.append(message)


func _stop() -> Array[String]:
	MKLog.observer = Callable()
	return _warnings


func _count_containing(messages: Array[String], needle: String) -> int:
	var found := 0
	for message in messages:
		if message.contains(needle):
			found += 1
	return found


func _clean() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	for file in dir.get_files():
		if file.begins_with("test_apply_one"):
			dir.remove(file)
