@tool
class_name MKVersion
extends RefCounted
## Single source of truth for the MenuKit version.
##
## Mirrored by hand into [code]plugin.cfg[/code] — the two must agree with the CHANGELOG entry and
## the release tag (ship gate 10). The mirror is enforced by [code]tests/test_version_agreement.gd[/code],
## because a hand-mirrored constant drifts silently. Surfaced by [code]MKRoot.dump_diagnostics()[/code].

const VERSION := "0.2.0"

## Minimum engine version this package is verified against.
const MIN_GODOT := "4.7"


static func version_string() -> String:
	var e := Engine.get_version_info()
	return "MenuKit %s (Godot %d.%d.%d)" % [VERSION, e.major, e.minor, e.patch]
