@tool
class_name MKCharacterCreate
extends Control
## The page that hosts the character creation flow.
##
## [b]It is deliberately thin.[/b] All flow behaviour — step order, validation, Back/Next, the
## assembled payload — lives in [MKCreationHost]. This page exists only to be something
## [member MKConfig.pages] can name: it resolves the config and the profile backend off the shell,
## configures ONE host, and translates the host's two outcome signals into navigation. Flow logic here
## would fork it from the host that hosts embed directly.
##
## [b]Steps default to a built-in order.[/b] A host that authors nothing still gets Name → Archetype →
## Appearance, because a creation page that renders no steps when [member MKConfig.creation_steps] is
## empty is indistinguishable from a broken one. Point-buy is NOT in that default (D17): a game with
## no stat concept must not be handed a stat screen.
##
## [b]It is a sub-panel.[/b] [MKCharacterSelect] arrives here with [method MKRoot.push_page], so both
## outcomes leave with [method MKRoot.pop_page] and the user lands back on the roster — with Escape
## doing the same thing through [MKRoot]'s own cancel handling.

## Built-in step scenes, in the default order. Ids and titles are set here rather than in the scenes
## so the default flow is described in ONE readable place, and so a host copying this order into its
## own [member MKConfig.creation_steps] can see exactly what it is replacing.
##
## Loaded at runtime rather than [code]preload[/code]ed, so a distribution that trimmed the creation
## module fails with a warning naming the missing file and drops that one step, instead of taking the
## whole default order down with it.
const DEFAULT_STEPS := [
	{"id": &"name", "title": "Name",
		"scene": "res://addons/menu_kit/creation/steps/mk_step_name.tscn"},
	{"id": &"archetype", "title": "Archetype",
		"scene": "res://addons/menu_kit/creation/steps/mk_step_archetype.tscn"},
	{"id": &"appearance", "title": "Appearance",
		"scene": "res://addons/menu_kit/creation/steps/mk_step_appearance.tscn"},
]

var _host: MKCreationHost


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the host as an unowned
	# child that gets saved into whatever scene instanced it — the hazard MKWelcomePage documents.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_host = MKCreationHost.new()
	_host.name = "CreationHost"
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	_host.creation_confirmed.connect(_on_creation_confirmed)
	_host.creation_cancelled.connect(_on_creation_cancelled)

	var config := _find_config()
	var steps := _resolve_steps(config)
	# Declared as a typed local and then filled, not built by an inline conditional: an untyped []
	# literal is refused at runtime by configure's Array[MKArchetype] parameter.
	var archetypes: Array[MKArchetype] = []
	if config != null:
		archetypes = config.archetypes
	var schema: MKStatSchema = config.point_buy_schema if config != null else null
	# A null schema is the SUPPORTED default, not a fault: the host drops any point-buy step and says
	# so at debug level (D17). Nothing warns here for the same reason.
	_host.configure(steps, archetypes, _find_profile_backend(), schema)


## The host's live [MKCreationHost], or null before [method Node._ready]. Exposed so a test — or a
## host wrapping this page — can reach the flow without re-deriving the child's name.
func get_creation_host() -> MKCreationHost:
	return _host


## Authored steps when there are any, otherwise the built-in order. Empty means "I did not author
## this", never "I want no steps": a zero-step creation flow can produce no profile, so treating an
## empty array as an instruction would make the default configuration a dead page.
func _resolve_steps(config: MKConfig) -> Array[MKCreationStepDef]:
	if config != null and not config.creation_steps.is_empty():
		# BORROWED, not copied: this is the config resource's own live array, and the only caller hands it
		# straight to MKCreationHost.configure, which reads it and appends the survivors to its own arrays
		# without writing back. Anything that starts mutating the resolved array must duplicate() it here
		# first, or it silently edits the author's .tres.
		return config.creation_steps
	var out: Array[MKCreationStepDef] = []
	for entry in DEFAULT_STEPS:
		var path := String(entry["scene"])
		if not ResourceLoader.exists(path):
			MKLog.warn("MKCharacterCreate: built-in step scene '%s' is missing — the '%s' step is dropped"
				% [path, entry["id"]])
			continue
		var def := MKCreationStepDef.new()
		def.id = entry["id"]
		def.title = String(entry["title"])
		def.scene = ResourceLoader.load(path) as PackedScene
		out.append(def)
	return out


func _on_creation_confirmed(_profile: Dictionary) -> void:
	# The host already persisted through the profile backend, and the roster panel redraws off
	# roster_changed — so this page's only job on success is to leave.
	_leave()


func _on_creation_cancelled() -> void:
	_leave()


## pop_page, symmetric with the push_page MKCharacterSelect arrived by (see that class's
## [code]_on_new_pressed[/code]): the creation flow is a sub-panel, so both of its exits return to
## whatever pushed it rather than jumping laterally to a page this class would have to name.
func _leave() -> void:
	var root := _find_ancestor_with("pop_page")
	if root == null:
		MKLog.warn("MKCharacterCreate: no MKRoot ancestor — the creation flow finished with nowhere to return to")
		return
	root.call("pop_page")


# --- Ancestor lookups ---------------------------------------------------------

## The duck-typed parent walk MenuKit resolves shell services with. Duck-typed rather than cast to
## [MKRoot] because a host may wrap the shell or forward these calls from its own controller, and a
## typed cast would refuse exactly that.
func _find_ancestor_with(method: String) -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method(method):
			return node
		node = node.get_parent()
	return null


## [MKRoot] exposes its config as the exported PROPERTY [code]config[/code] and ships no
## [code]get_config()[/code] accessor, so this reads the property duck-typed — [method Object.get]
## returns null on an ancestor that has no such property, which is exactly the "keep walking" answer
## the loop needs. If a future [MKRoot] adds a real accessor this should prefer it.
func _find_config() -> MKConfig:
	var node := get_parent()
	while node != null:
		var value: Variant = node.get("config")
		var config := value as MKConfig
		if config != null:
			return config
		node = node.get_parent()
	MKLog.warn("MKCharacterCreate: no MKConfig is reachable — falling back to the built-in step order with no archetypes")
	return null


func _find_profile_backend() -> MKProfileBackend:
	var node := get_parent()
	while node != null:
		if node.has_method("get_profile_backend"):
			var backend: MKProfileBackend = node.call("get_profile_backend")
			if backend != null and is_instance_valid(backend):
				return backend
		node = node.get_parent()
	# The host renders and validates fine without one; it simply cannot persist. Named here rather
	# than left to fail silently at Confirm.
	MKLog.warn("MKCharacterCreate: no MKProfileBackend is reachable — a created character cannot be saved. Assign MKConfig.profile_backend.")
	return null
