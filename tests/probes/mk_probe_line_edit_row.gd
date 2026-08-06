extends LineEdit
## Test probe: a [constant MKSettingDef.RowType.CUSTOM] scene root that honours the bind contract and
## is [b]itself a [LineEdit][/b].
##
## Entirely legal under the contract — the whole of it is "the root is a Control implementing
## [code]_mk_bind(backend, def)[/code]", and a one-field row whose root IS its widget is the smallest
## thing that satisfies it. But [code]MKSettingsPanel._build_custom[/code] registers that root in
## [code]_controls[/code], and [code]_sync_control[/code] dispatches by widget CLASS, so before the
## exclusion this root fell into the branch written for a TEXT row the panel had built and received an
## assignment of the RAW store value: [code]LineEdit.text = 7[/code] is a script error, and even a
## String landed as the panel overwriting a display it does not own.
##
## The text is set to a sentinel by [code]_mk_bind[/code] rather than read from the store, because the
## assertion is that NOTHING the panel does moves it. Reading the store would make a panel write of
## the same value indistinguishable from the row's own.
##
## Lives in [code]tests/[/code], never in the addon: the isolation gate (ship gate 1) is about what
## ships, and this is a probe.

## What [method _mk_bind] writes, and what must still be on screen after any external store write.
const SENTINEL := "row-owned"

var bound_def: MKSettingDef


func _mk_bind(_backend, def) -> void:
	bound_def = def
	text = SENTINEL
