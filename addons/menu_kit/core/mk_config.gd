@tool
class_name MKConfig
extends Resource
## Everything MenuKit needs to run, in one resource (plan §3, §4.1).
##
## The promise is "swap the whole integration by swapping one resource". Backends are [MKBackendSlot]
## entries rather than instances because they need scene-tree access and must not serialize runtime
## state; pure data — palette, pages, catalogs — is held directly.
##
## [b]Validation reports everything at once.[/b] [method validate] never stops at the first problem:
## a host wiring this up for the first time gets one list to work through instead of a fix-run-fix
## loop, and every message names the resource path and the field rather than saying "invalid
## setting". [MKRoot] runs it at [method Node._ready].

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
## server browser entirely, which is the correct first impression for a single-player game and is
## what lets the shipped defaults pass the zero-warning cold-drop gate.
@export var network_backend: MKBackendSlot

## What "pause" means to this game. Unassigned means menus never pause anything — safe, and exactly
## what a multiplayer host wants.
@export var pause_policy: MKBackendSlot

@export_group("Appearance")
## Source of truth for the generated [Theme]. [MKRoot] builds the Theme from this at runtime, so a
## cold drop is styled with no manual step; the editor bake is only a preview convenience.
##
## Assigning a different palette emits [signal Resource.changed], which is how a live [MKRoot] learns
## to regenerate. Without that, swapping the palette — the headline re-skin gesture — changed nothing
## at runtime: the root stayed subscribed to the palette it no longer displayed, and only edits to
## the [i]old[/i] palette had any effect.
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

@export_group("Behaviour")
## Whether MenuKit saves and restores [member Input.mouse_mode] around menus. A Doom-like runs
## captured in gameplay, so a pause menu that does not release the cursor is unusable — MenuKit owns
## this by default rather than leaving every host to hand-roll a toggle that fights it. Turn it off
## if the host owns cursor state itself.
@export var manage_mouse_mode: bool = true

## Whether a brightness controller is created (Phase 3). Off leaves the setting a plain value the
## host consumes, which stays the documented floor.
@export var manage_brightness: bool = true

## Verbose logging. The [code]--mk-verbose[/code] command-line switch forces it on regardless.
@export var verbose: bool = false


## Collects every problem with this config. Empty means valid. Messages are ready to log verbatim
## and each names its resource and field, because "invalid setting" in a bug report costs a
## round-trip that a path and a field name do not.
##
## Slot [i]absence[/i] is never a problem — an unassigned slot is a supported configuration. What is
## reported: a slot whose script does not extend the base it was handed to, duplicate or empty page
## ids, an [member initial_page] naming nothing, a palette that fails its own validation, and a
## [member backdrop_id] the catalog does not know.
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
