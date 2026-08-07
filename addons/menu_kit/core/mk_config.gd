@tool
class_name MKConfig
extends Resource
## Everything MenuKit needs to run, in one resource.
##
## The promise is "swap the whole integration by swapping one resource". Backends are [MKBackendSlot]
## entries rather than instances because they need scene-tree access and must not serialize runtime
## state; pure data — palette, pages, catalogs — is held directly.
##
## [b]Validation reports everything at once.[/b] [method validate] never stops at the first problem:
## a host wiring this up for the first time gets one list to work through instead of a fix-run-fix
## loop, and every message names the resource path and the field rather than saying "invalid
## setting". [MKRoot] runs it at [method Node._ready].

## Where the optional [code]MKSettingsService[/code] autoload lives once [code]plugin.gd[/code] has
## registered it, and the ONE place that name is written down.
##
## [b]Shared because a rename must break loudly, in one edit.[/b] Three runtime sites resolve this
## node — [code]MKRoot[/code] adopting the service's backend and brightness controller,
## [MKSettingsPanel] resolving its backend, and [code]plugin.gd[/code] registering the autoload. If
## they spelled it separately, changing one would fail silently: the lookups find nothing and fall
## back to their no-autoload paths, so the host ends up with a SECOND settings backend over the same
## JSON file and a SECOND brightness controller stacked over the first — the exact double-instance
## failure the service exists to prevent, with no diagnostic anywhere.
##
## It lives on [MKConfig] because this is the runtime class every user already reaches; the service
## script itself cannot host it (it deliberately has no [code]class_name[/code] — see its class doc),
## and [code]plugin.gd[/code] is an [EditorPlugin] absent from an exported game.
const SETTINGS_SERVICE_NAME := "MKSettingsService"

## Absolute node path to [constant SETTINGS_SERVICE_NAME], for [method Node.get_node_or_null].
## Derived rather than spelled again: an autoload is always a direct child of the scene-tree root.
const SETTINGS_SERVICE_PATH := "/root/" + SETTINGS_SERVICE_NAME

@export_group("Backends")
## Application actions — start game, return to menu, quit. Leaving it unassigned is valid config:
## it warns when something invokes it, never at boot, so a cold drop stays warning-free.
@export var menu_backend: MKBackendSlot

## The character/save roster.
@export var profile_backend: MKBackendSlot

## Setting values and their application to the engine. When the [code]MKSettingsService[/code]
## autoload is present, [MKRoot] adopts [b]its[/b] instance and ignores this slot's script — see
## [method MKRoot._resolve_settings_backend]. Naming a different script here than the service
## already built is a misconfiguration and is reported as one.
@export var settings_backend: MKBackendSlot

## Server discovery. [b]Ships empty[/b] in the default config: an unassigned network slot hides the
## server browser entirely, which is the correct first impression for a single-player game and keeps
## a cold drop warning-free.
@export var network_backend: MKBackendSlot

## What "pause" means to this game. Unassigned means menus never pause anything — safe, and exactly
## what a multiplayer host wants.
@export var pause_policy: MKBackendSlot

@export_group("Appearance")
## Source of truth for the generated [Theme]. [MKRoot] builds the Theme from this at runtime, so a
## cold drop is styled with no manual step; the editor bake is only a preview convenience.
##
## Assigning a different palette emits [signal Resource.changed], which is how a live [MKRoot] learns
## to regenerate — without it the root would stay subscribed to the palette it no longer displays.
@export var palette: MKPalette:
	set(value):
		if palette == value:
			return
		palette = value
		emit_changed()

@export var backdrop_catalog: MKBackdropCatalog

## Which backdrop to show. Empty falls back to the catalog's own default.
@export var backdrop_id: StringName = &""

@export_group("Navigation")
## The nav bar's tabs, in [member MKMenuPageDef.order]. A host adds a Credits or Mods page by
## appending here — no addon edit, no fork of the nav bar. That is the entire reason navigation is
## data rather than code.
@export var pages: Array[MKMenuPageDef] = []

## Page shown at boot. Empty means the first visible page in [member pages].
@export var initial_page: StringName = &""

@export_group("Character Creation")
## Archetypes the Archetype creation step offers. Data, not code: a host adds a class by appending
## here, exactly as it adds a nav page to [member pages].
##
## The shipped default config carries ONE neutral entry rather than shipping empty: an archetype step
## with nothing to pick is a dead end on the flow a cold drop is most likely to open, and a
## genre-flavoured placeholder would state a genre the host has not chosen.
@export var archetypes: Array[MKArchetype] = []

## The creation flow's steps, in order. [b]Empty means "not authored", never "no steps"[/b] —
## [MKCharacterCreate] falls back to its built-in Name → Archetype → Appearance order, because a
## creation page rendering nothing is indistinguishable from a broken one. Author this to reorder,
## drop, or add steps (the demo authors all four, which is what exercises the explicit path).
@export var creation_steps: Array[MKCreationStepDef] = []

## Point-buy stats for the Point Buy step, or null.
##
## [b]Null — the default — disables point-buy entirely.[/b] A game with no stat concept must not be
## handed a stat screen it has to work out how to remove, so the feature ships off and any point-buy
## step def is dropped when this is unset. The demo assigns a three-stat schema so the enabled path
## is visible out of the box.
@export var point_buy_schema: MKStatSchema = null

@export_group("Behaviour")
## Whether MenuKit saves and restores [member Input.mouse_mode] around menus. A Doom-like runs
## captured in gameplay, so a pause menu that does not release the cursor is unusable — MenuKit owns
## this by default rather than leaving every host to hand-roll a toggle that fights it. Turn it off
## if the host owns cursor state itself.
@export var manage_mouse_mode: bool = true

## Whether a brightness controller is created. Off leaves the setting a plain value the host
## consumes, which stays the documented floor.
@export var manage_brightness: bool = true

## Verbose logging. The [code]--mk-verbose[/code] command-line switch forces it on regardless.
@export var verbose: bool = false


## Collects every problem with this config. Empty means valid. Messages are ready to log verbatim
## and each names its resource and field.
##
## Slot [i]absence[/i] is never a problem — an unassigned slot is a supported configuration. What is
## reported: a slot whose script does not extend the base it was handed to, duplicate or empty page
## ids, an [member initial_page] naming nothing, a palette that fails its own validation, a
## [member backdrop_id] the catalog does not know, and the Character Creation group's equivalents
## (see [method _creation_problems]).
func validate() -> PackedStringArray:
	var problems := PackedStringArray()

	for reason in [
		_validate_slot(menu_backend, MKMenuBackend, "menu_backend"),
		_validate_slot(profile_backend, MKProfileBackend, "profile_backend"),
		_validate_slot(settings_backend, MKSettingsBackend, "settings_backend"),
		_validate_slot(network_backend, MKNetworkBackend, "network_backend"),
		_validate_slot(pause_policy, MKPausePolicy, "pause_policy"),
	]:
		if not reason.is_empty():
			problems.append(reason)

	var seen := {}
	for i in pages.size():
		var page := pages[i]
		if page == null:
			problems.append("%s: entry %d is null" % [MKLog.context(self, "pages"), i])
			continue
		if not page.is_valid():
			problems.append("%s: entry %d has an empty id" % [MKLog.context(self, "pages"), i])
			continue
		if seen.has(page.id):
			problems.append("%s: duplicate page id '%s' (entries %d and %d) — nav selection would be ambiguous"
				% [MKLog.context(self, "pages"), page.id, seen[page.id], i])
			continue
		seen[page.id] = i

	if not initial_page.is_empty() and not seen.has(initial_page):
		problems.append("%s: '%s' names no page in `pages`"
			% [MKLog.context(self, "initial_page"), initial_page])

	if palette != null:
		for p in palette.get_validation_problems():
			problems.append(p)

	if not backdrop_id.is_empty():
		if backdrop_catalog == null:
			problems.append("%s: '%s' is set but no backdrop_catalog is assigned"
				% [MKLog.context(self, "backdrop_id"), backdrop_id])
		elif not backdrop_catalog.has_backdrop(backdrop_id):
			problems.append("%s: catalog %s has no backdrop '%s'" % [
				MKLog.context(self, "backdrop_id"),
				MKLog.context(backdrop_catalog),
				backdrop_id,
			])

	for reason in _creation_problems():
		problems.append(reason)

	return problems


## The Character Creation group's half of [method validate], split out for readability. It RETURNS
## its findings rather than appending to a passed-in array: [PackedStringArray] is copy-on-write, so
## an out-parameter would be a value copy and every append would vanish. The caller folds these into
## the one list, so the "report everything at once" contract is unchanged.
func _creation_problems() -> PackedStringArray:
	var problems := PackedStringArray()

	var seen_archetypes := {}
	for i in archetypes.size():
		var arch := archetypes[i]
		if arch == null:
			problems.append("%s: entry %d is null" % [MKLog.context(self, "archetypes"), i])
			continue
		if not arch.is_valid():
			problems.append("%s: entry %d (%s) is invalid — an archetype needs at least an id and a display_name"
				% [MKLog.context(self, "archetypes"), i, MKLog.context(arch)])
			continue
		if seen_archetypes.has(arch.id):
			problems.append("%s: duplicate archetype id '%s' (entries %d and %d) — selection would be ambiguous"
				% [MKLog.context(self, "archetypes"), arch.id, seen_archetypes[arch.id], i])
			continue
		seen_archetypes[arch.id] = i

	var seen_steps := {}
	for i in creation_steps.size():
		var step := creation_steps[i]
		if step == null:
			problems.append("%s: entry %d is null" % [MKLog.context(self, "creation_steps"), i])
			continue
		if not step.is_valid():
			problems.append("%s: entry %d (%s) is invalid — a step needs at least an id"
				% [MKLog.context(self, "creation_steps"), i, MKLog.context(step)])
			continue
		if seen_steps.has(step.id):
			problems.append("%s: duplicate step id '%s' (entries %d and %d) — the flow would visit one twice"
				% [MKLog.context(self, "creation_steps"), step.id, seen_steps[step.id], i])
			continue
		seen_steps[step.id] = i
		# Reported separately from is_valid() rather than folded into it: a step def with an id and no
		# scene is well-formed data with nothing to show, and the fix ("assign the scene") is different
		# from the fix for a malformed def.
		if step.scene == null:
			problems.append("%s: step '%s' has no scene — the flow would show an empty page"
				% [MKLog.context(step, "scene"), step.id])

	# Null is the supported default (see the member's doc), so absence is never reported. Only an
	# ASSIGNED schema is held to these rules.
	if point_buy_schema == null:
		return problems
	if point_buy_schema.total_points <= 0:
		problems.append("%s: total_points is %d — a point-buy step with no points to spend is a dead screen"
			% [MKLog.context(point_buy_schema, "total_points"), point_buy_schema.total_points])
	if point_buy_schema.stats.is_empty():
		problems.append("%s: no stats — assign at least one MKStatDef or leave MKConfig.point_buy_schema null to disable point-buy"
			% MKLog.context(point_buy_schema, "stats"))
	var seen_stats := {}
	for i in point_buy_schema.stats.size():
		var stat := point_buy_schema.stats[i]
		if stat == null:
			problems.append("%s: entry %d is null" % [MKLog.context(point_buy_schema, "stats"), i])
			continue
		if stat.min_value > stat.max_value:
			problems.append("%s: stat '%s' has min_value %d above max_value %d — the row could hold no value"
				% [MKLog.context(point_buy_schema, "stats"), stat.id, stat.min_value, stat.max_value])
		if stat.cost_per_point < 1:
			problems.append("%s: stat '%s' has cost_per_point %d — a cost below 1 makes the pool infinite"
				% [MKLog.context(point_buy_schema, "stats"), stat.id, stat.cost_per_point])
		if seen_stats.has(stat.id):
			problems.append("%s: duplicate stat id '%s' (entries %d and %d) — the spend would be recorded against one key"
				% [MKLog.context(point_buy_schema, "stats"), stat.id, seen_stats[stat.id], i])
			continue
		seen_stats[stat.id] = i

	return problems


## The pages a nav bar should show, filtered and sorted the same way every caller needs them, so the
## ordering rule lives in one place rather than in each consumer.
func get_visible_pages() -> Array[MKMenuPageDef]:
	var out: Array[MKMenuPageDef] = []
	for page in pages:
		if page != null and page.is_valid() and page.visible:
			out.append(page)
	# Stabilised by original index. `sort_custom` is not a stable sort, so pages sharing an `order`
	# could come back permuted — and since this feeds both the nav bar's tab order AND the boot page
	# (`get_visible_pages()[0]`), a host giving two pages the same order could get a tab order that
	# does not match `pages` and a boot page that is not the first tab.
	var decorated: Array = []
	for i in out.size():
		decorated.append([out[i].order, i, out[i]])
	decorated.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	var sorted: Array[MKMenuPageDef] = []
	for entry in decorated:
		sorted.append(entry[2])
	return sorted


## One line for the diagnostics dump: what the creation flow actually loaded.
##
## "The archetype list is empty" and "point-buy is off" are the two facts every creation-flow bug
## report hinges on, and neither is visible from a screenshot — an empty archetype step and a step
## whose defs were dropped look identical. [code]MKRoot.dump_diagnostics[/code] appends this
## alongside its page count.
func creation_diagnostics() -> String:
	return "archetypes: %d  creation_steps: %d (empty = built-in order)  point_buy: %s" % [
		archetypes.size(),
		creation_steps.size(),
		"off" if point_buy_schema == null else "%d points over %d stats" % [
			point_buy_schema.total_points, point_buy_schema.stats.size()],
	]


func get_page(id: StringName) -> MKMenuPageDef:
	for page in pages:
		if page != null and page.id == id:
			return page
	return null


## Returns a ready-to-log reason, or an empty string when the slot is fine. Returning rather than
## appending keeps [PackedStringArray]'s copy-on-write semantics out of the picture — an
## out-parameter here would be a value copy and the appends would vanish.
func _validate_slot(slot: MKBackendSlot, base: Script, field: String) -> String:
	if slot == null or not slot.is_assigned():
		return ""
	var reason := slot.validate_against(base)
	if reason.is_empty():
		return ""
	return "%s -> %s" % [MKLog.context(self, field), reason]
