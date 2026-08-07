@tool
class_name MKProbeCreationStep
extends Control
## A scriptable creation step, for the flow tests.
##
## [MKCreationHost] is a flow engine over a duck-typed step contract, and every rule worth asserting
## about it — ownership collisions, merge order, skip semantics, the schema-requirement drop — is a
## statement about an ARBITRARY set of steps, not about the three the addon happens to ship. No pair
## of shipped steps collides, so those rules are unreachable through them.
##
## So this probe declares its owned keys, its validity and its commit values from exported data, and
## the tests build a [PackedScene] per case with [method PackedScene.pack]. It is a real
## [code]res://[/code] script rather than an inner class so the packed scene carries a resolvable
## script reference.
##
## The counters are STATIC because the interesting cases are about instances that are never bound
## (a step dropped for a duplicate key is freed before its bind would have run), and an instance that
## does not exist cannot be interrogated.

signal step_state_changed()

## Payload keys this step claims. Empty is a supported shape — the appearance placeholder is exactly
## that — and is what makes the "claiming nothing never collides" case reachable.
@export var owned_keys: Array[String] = []

## Written into the payload verbatim on commit. Values keep their GDScript type, which is how the int
## that ends up in [method MKProfileBackend.create_profile] is an int at every hop.
@export var commit_values: Dictionary = {}

## What [code]_mk_step_is_valid[/code] answers. Mutable at runtime through [method set_valid], so a
## test can invalidate a live step the way a player emptying a field does.
@export var valid := true

## The schema-requirement marker's answer. The METHOD is always present (a test cannot
## conditionally define one);
## false is the ordinary "this step does not need a schema" reply, so the drop is driven by the
## value, exactly as a host step would.
@export var requires_schema := false

static var binds := 0
static var commits := 0
## Step ids in bind order, so "the later step never bound" is assertable rather than inferred from a
## count that a differently-ordered drop would also satisfy.
static var bound_ids: Array[String] = []

## The context payload this instance was handed at bind, for the restore-through-Back assertions.
var seen_payload: Dictionary = {}


static func reset() -> void:
	binds = 0
	commits = 0
	bound_ids = []


func _mk_step_requires_stat_schema() -> bool:
	return requires_schema


func _mk_step_owned_keys() -> Array[String]:
	return owned_keys


func _mk_step_bind(_host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	binds += 1
	bound_ids.append(String(def.id) if def != null else "<null>")
	var payload: Variant = ctx.get("payload", null)
	seen_payload = (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _mk_step_is_valid() -> bool:
	return valid


func _mk_step_commit(payload: Dictionary) -> void:
	commits += 1
	for key in commit_values.keys():
		payload[String(key)] = commit_values[key]


## Flips validity and announces it, like a real step's input handler does — the host re-polls on the
## signal, so setting the flag alone would leave Next gated on a stale answer.
func set_valid(value: bool) -> void:
	valid = value
	step_state_changed.emit()
