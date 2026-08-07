@tool
class_name MKVersion
extends RefCounted
## Single source of truth for the MenuKit version.
##
## Mirrored by hand into [code]plugin.cfg[/code] — the two must agree with the CHANGELOG entry and
## the release tag. Surfaced by [code]MKRoot.dump_diagnostics()[/code].

const VERSION := "0.1.0-dev"

## Minimum engine version this package is verified against.
const MIN_GODOT := "4.7"


static func version_string() -> String:
	var e := Engine.get_version_info()
	return "MenuKit %s (Godot %d.%d.%d)" % [VERSION, e.major, e.minor, e.patch]
