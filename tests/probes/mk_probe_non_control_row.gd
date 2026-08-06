extends Node
## Test probe: a [constant MKSettingDef.RowType.CUSTOM] scene root that DOES implement the bind
## contract but is not a [Control].
##
## [MKSettingsPanel._build_custom] checks the Control-ness BEFORE calling [code]_mk_bind[/code], and
## that order is the contract being pinned: bind is where a row reads the store, wires signals and may
## register itself with the host, so running it on an instance the panel is about to free leaves those
## side effects behind with nothing on screen to show for them. Asserting "the row was skipped" alone
## passes with the checks in either order — the panel skips it either way — so the probe RECORDS
## whether it was bound.
##
## Lives in [code]tests/[/code], never in the addon: it is a counter-example, and the isolation gate
## (ship gate 1) is about what ships.
##
## The counter is [code]static[/code] so a test can read it off the SCRIPT without a surviving
## instance — the panel frees this node during the build, which is the whole point.
static var bind_calls := 0


func _mk_bind(_backend, _def) -> void:
	bind_calls += 1
