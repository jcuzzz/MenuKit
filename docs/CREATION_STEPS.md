# Character creation steps

`MKCreationHost` runs an ordered list of steps over **one shared payload `Dictionary`**. It owns
Back / Next / Skip / Confirm, the validation gate, the progress indicator and the refusal gate — and
it emits its result rather than navigating anywhere itself.

The payload is opaque: MenuKit assembles it and hands it to `MKProfileBackend.create_profile()`
verbatim. **MenuKit never interprets a field.**

---

## 1. `MKCreationStepDef`

```gdscript
class_name MKCreationStepDef extends Resource

@export var id: StringName = &""
@export var title: String = ""
@export var scene: PackedScene = null      # its ROOT implements the step contract
@export var required: bool = true
@export var skippable: bool = false

func is_valid() -> bool
```

Steps are configured on `MKConfig.creation_steps: Array[MKCreationStepDef]`. **Array order is flow
order** — reorder the array and the flow follows, with no code change.

**Empty `creation_steps` means "not authored", never "no steps".** `MKCharacterCreate` then falls
back to its built-in **Name → Archetype → Appearance** order. (Authoring those same three in the
shipped default config would be a second copy of that order to keep in sync, for no gain. The demo
authors all four, including point-buy.)

Shipped steps, all under `res://addons/menu_kit/creation/steps/`:

| Scene | Owns payload key |
|---|---|
| `mk_step_name.tscn` | `name` |
| `mk_step_archetype.tscn` | `archetype` |
| `mk_step_appearance.tscn` | *(none — placeholder)* |
| `mk_step_pointbuy.tscn` | `stats` |

---

## 2. The step contract

**Four methods on the scene ROOT, plus one signal.** An optional fifth marks a step as
point-buy-shaped.

```gdscript
signal step_state_changed()

func _mk_step_owned_keys() -> Array[String]
func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void
func _mk_step_is_valid() -> bool
func _mk_step_commit(payload: Dictionary) -> void

func _mk_step_requires_stat_schema() -> bool     # optional; absent means "does not need one"
```

- **`_mk_step_owned_keys()`** is called **BEFORE** the bind and must therefore be a **static
  declaration**, not a function of the context. Ownership is disjoint by *declaration* — nothing
  audits what `_mk_step_commit` actually writes; the shipped steps honour theirs.
- **`_mk_step_bind`** receives the host, its own def, and the context (§3).
- **`step_state_changed`** is what you emit when validity may have changed; the host re-polls
  `_mk_step_is_valid()` and re-gates Next.
- **`_mk_step_commit(payload)`** writes your owned keys. It runs on **Next and on Confirm** — never
  on Skip, and never on Back. Back deliberately leaves a visited step's committed keys in place;
  returning forward recommits over them.

A def whose scene root does not implement the contract is dropped with a named warning. A flow with
no usable step renders the shell and says so, rather than showing an empty rectangle.

### A minimal step

```gdscript
extends VBoxContainer

const PAYLOAD_KEY := "backstory"

signal step_state_changed()

var _host: MKCreationHost
var _def: MKCreationStepDef
var _edit: TextEdit


func _mk_step_owned_keys() -> Array[String]:
	return [PAYLOAD_KEY]


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	_host = host
	_def = def
	_edit = %Backstory
	# ctx.payload is a DEEP COPY — safe to read, and writes to it go nowhere.
	_edit.text = String((ctx.get("payload", {}) as Dictionary).get(PAYLOAD_KEY, ""))
	_edit.text_changed.connect(func() -> void: step_state_changed.emit())


func _mk_step_is_valid() -> bool:
	return _edit != null and _edit.text.strip_edges().length() >= 10


func _mk_step_commit(payload: Dictionary) -> void:
	payload[PAYLOAD_KEY] = _edit.text.strip_edges()
```

---

## 3. The bind context

`ctx` is a `Dictionary` carrying:

| Key | Type | Notes |
|---|---|---|
| `archetypes` | `Array[MKArchetype]` | From `MKConfig.archetypes` |
| `profile_backend` | `MKProfileBackend` | **May be null** |
| `stat_schema` | `MKStatSchema` | **May be null** (point-buy disabled) |
| `payload` | `Dictionary` | A **DEEP COPY** |

The payload copy is deep on purpose: a step can only write through `_mk_step_commit`, so there is one
write path and no step can reach the live dictionary — not even through a nested sub-dictionary.

Steps bind **eagerly**, before any choice exists. If your step needs to read state another step
commits later (the shipped appearance step re-resolves the chosen archetype's preview scene), do it
on `visibility_changed` — there is no `step_changed` signal on the host.

---

## 4. `MKCreationHost`

```gdscript
class_name MKCreationHost extends Control

signal creation_confirmed(profile: Dictionary)
signal creation_cancelled()
signal built()

const REFUSAL_MESSAGE := "Could not create the character. Adjust it and try again, or cancel."
const NO_BACKEND_MESSAGE := "No profile backend is assigned, so nothing can be saved."

func configure(steps: Array[MKCreationStepDef], archetypes: Array[MKArchetype],
		profile_backend: MKProfileBackend, stat_schema: MKStatSchema) -> void
func get_payload() -> Dictionary        # a DEEP read-only copy
func current_step_index() -> int
func get_step_count() -> int
func get_message() -> String
func is_built() -> bool
func notify_archetype_chosen(archetype: MKArchetype) -> void
```

**`configure()` is the ONE entry point.** There is no incremental `add_step`. The host emits
`creation_confirmed` / `creation_cancelled` and navigates nowhere itself — `MKCharacterCreate` is
what turns those into a `pop_page()`.

A null profile backend produces **one** warning for the whole flow (not one per step) and builds with
navigation disabled.

### The three passes of `configure()`

The order is load-bearing:

1. **Claim** — collect every enabled step's `_mk_step_owned_keys()`.
2. **Validate archetype defaults** against those claims.
3. **Bind** — call `_mk_step_bind` on each step.

Binding runs last because it is **not inert**: the archetype step auto-selects and seeds at bind
time. Interleaving made the ownership validation order-dependent.

### Payload ownership

**Two enabled steps claiming one payload key is an error, not a precedence question.** The host logs
an error naming both defs and the key, and **drops the later step**.

### Archetype defaults, and merge order

`MKArchetype.payload_defaults` is **seeded first; step commits overwrite** — and that is enforced by
**exclusion**, so the overwrite never actually happens: an archetype default whose key a step owns is
**refused at `configure` with an error naming both sides**. Fix it in the data, not at runtime.

Changing the archetype clears exactly the previous choice's seeded keys and nothing else.

```gdscript
class_name MKArchetype extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D = null
@export var preview_scene: PackedScene = null    # consumed only by a preview widget
@export var payload_defaults: Dictionary = {}

func is_valid() -> bool
```

The shipped `default_config.tres` carries **one** inline archetype, "Traveler" — deliberately
genre-neutral, so the Archetype step is never an empty dead end on a fresh install. The moment
`MKConfig.archetypes` is authored, that entry is gone. (The demo authors three under
`res://demo/demo_archetypes/`.)

### The refusal gate

When `create_profile` returns `{}`, the host **closes both doors into confirm** — the Confirm button
and a last-step Skip — and shows `REFUSAL_MESSAGE`, which **names no cause**: a taken name, a full
roster, and a read-only store all answer with the same empty dictionary, so claiming a cause would be
a guess.

Any **forward movement** lifts the refusal: a commit, or a non-last Skip. On a flow whose refused
step has no earlier step (index 0), the step **announcing a state change** lifts it — that is the
only fresh-attempt signal that shape can produce. It announces rather than proves; the signal cannot
tell an edit from a re-affirmation, and either is a distinct gesture.

---

## 5. Point-buy

**Disabled by default (D17).** With no `MKConfig.point_buy_schema`, any point-buy step def is dropped
with a debug line — a game with no stat concept must not be handed a stat screen it then has to work
out how to remove. An **invalid** schema (no valid stat, or a non-positive `total_points`) drops the
step with a **warning naming the resource**.

```gdscript
class_name MKStatSchema extends Resource

@export var total_points: int = 10
@export var stats: Array[MKStatDef] = []
@export var require_full_spend: bool = true

func is_valid() -> bool


class_name MKStatDef extends Resource

@export var id: StringName = &""
@export var label: String = ""
@export var description: String = ""
@export var min_value: int = 0
@export var max_value: int = 10
@export var cost_per_point: int = 1
@export var effect_hint: String = ""

func is_valid() -> bool
```

The step writes `{"stats": {id: value}}` into the payload.

Boundaries — read these as the contract:

- **Points are spent from each stat's `min_value`**, so `total_points` is the budget **above** the
  free starting spread, not the sum of the final values.
- **`cost_per_point` below 1 is clamped to 1.** A free point is not a point.
- **`require_full_spend` gates Next** until the pool is empty.
- **`effect_hint` is AUTHORED text.** There is no expression language, and **MenuKit never derives a
  stat's meaning or its effect** — it owns allocation, validation and confirm-gating, and nothing
  else. What "Might 7" does is entirely your game's business.
- Known limitation: a **restore** honours per-stat ranges but not the **pool**. An over-pool restored
  payload renders a negative remaining and the validity gate holds (so it cannot be confirmed), but
  it is not clamped.

---

## 6. Replacing the appearance step

`MKStepAppearance` is a deliberate **placeholder**: it owns no payload keys and commits nothing. It
hosts an `MKPreviewViewport` showing the chosen archetype's `preview_scene`, and an archetype with no
preview scene leaves the viewport empty by design.

Replacing it is one edit — point the step def's `scene` at your own scene implementing the same
four-method contract. No addon edit, no subclass required.

---

## 7. Worked extension — a step with live derived-stat previews

The motivating case for extending rather than replacing a shipped step: point-buy that also shows
what the allocation *does* — "Might 7 → 140 HP, 22 carry" — where the derivation is your game's, not
MenuKit's.

The shape: subclass the shipped point-buy step, let it keep owning allocation and validity, and hook
`step_state_changed` to refresh a panel of your own.

```gdscript
extends MKStepPointbuy
## Point-buy plus a live derived-stat readout. MenuKit owns the allocation; the derivation is ours.

var _derived: VBoxContainer


func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void:
	# Let the base build the allocator, claim its key, and seed from the payload first.
	super(host, def, ctx)

	_derived = VBoxContainer.new()
	add_child(_derived)

	# The base emits this whenever an allocation changes; it is also what re-gates Next.
	if not step_state_changed.is_connected(_refresh_derived):
		step_state_changed.connect(_refresh_derived)
	_refresh_derived()


func _refresh_derived() -> void:
	for child in _derived.get_children():
		child.queue_free()

	# Read the CURRENT allocation the same way a commit would produce it.
	var scratch := {}
	_mk_step_commit(scratch)
	var stats: Dictionary = scratch.get("stats", {})

	for line in MyStatMath.describe(stats):     # host-side derivation; MenuKit never does this
		var label := Label.new()
		label.text = line
		MKTheme.set_variation(label, MKTheme.ROW_LABEL)
		_derived.add_child(label)
```

Then point a `MKCreationStepDef.scene` at a scene whose root carries that script. Two things to keep
in mind:

- **Do not widen `_mk_step_owned_keys()`** unless you really own the extra key — a second step
  claiming it is a hard error that drops one of the two steps.
- Calling `_mk_step_commit(scratch)` against a throwaway dictionary is the honest way to read the
  live allocation: `ctx.payload` was a snapshot at bind time, and `MKCreationHost.get_payload()`
  reflects only what has been *committed*.

> Both samples in this document are illustrative and have not been compiled against your project.
> Smoke them once when you wire them.
