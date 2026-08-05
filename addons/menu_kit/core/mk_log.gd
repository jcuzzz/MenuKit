@tool
class_name MKLog
extends RefCounted
## Leveled logging for MenuKit (plan §4.8).
##
## Rules this class exists to enforce:
## [br]- Every misconfiguration message names the offending resource path AND field — never a bare
##   "invalid setting". Use [method context] to build that prefix.
## [br]- Recoverable misconfiguration warns; only contract violations use [method error].
## [br]- Verbose output is opt-in: [code]MKConfig.verbose[/code] or the [code]--mk-verbose[/code]
##   command-line switch.
##
## This is a static-only utility. It deliberately holds no node/tree reference so it is callable
## from resources, [code]@tool[/code] scripts, and headless tests alike.

enum Level { ERROR, WARN, INFO, DEBUG }

const PREFIX := "[MenuKit]"

## Set by MKConfig / MKRoot at boot. `--mk-verbose` on the command line forces it true.
static var verbose := false

static var _cli_checked := false


## Formats a `resource path: field` context prefix. Pass an empty [param field] for resource-level
## problems. Accepts a Resource, a path String, or null.
static func context(res, field := "") -> String:
	var path := "<unknown>"
	if res is Resource:
		var r := res as Resource
		path = r.resource_path if not r.resource_path.is_empty() else "<unsaved %s>" % r.get_class()
	elif res is String:
		path = res
	if field.is_empty():
		return path
	return "%s.%s" % [path, field]


static func error(message: String) -> void:
	push_error("%s %s" % [PREFIX, message])
	printerr("%s ERROR: %s" % [PREFIX, message])


static func warn(message: String) -> void:
	push_warning("%s %s" % [PREFIX, message])
	print("%s WARN: %s" % [PREFIX, message])


static func info(message: String) -> void:
	print("%s %s" % [PREFIX, message])


static func debug(message: String) -> void:
	if is_verbose():
		print("%s DEBUG: %s" % [PREFIX, message])


static func is_verbose() -> bool:
	if not _cli_checked:
		_cli_checked = true
		if OS.get_cmdline_args().has("--mk-verbose") or OS.get_cmdline_user_args().has("--mk-verbose"):
			verbose = true
	return verbose
