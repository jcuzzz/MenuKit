@tool
class_name MKStatDef
extends Resource
## One point-buy stat row (plan §4.5, D17).
##
## [b]MenuKit never interprets a stat.[/b] It does not know that Strength raises melee damage, it does
## not compute a derived value, and it does not validate a combination — it renders a labelled counter
## with a pool, and hands the resulting numbers to the host verbatim through
## [method MKProfileBackend.create_profile]. That boundary is the same one [MKProfileBackend]'s opaque
## payload draws, and it is what keeps this a menu package rather than a character system: the moment
## the addon knew what "Strength" meant it would have to know every host's formula.
##
## The consequence, and it is deliberate: [member effect_hint] is AUTHORED TEXT. There is no
## expression language and no callback that computes "+3 melee damage" from the current value; a host
## that wants a live derived readout owns that widget itself (a [constant MKSettingDef.RowType.CUSTOM]
## row is the same escape hatch one layer down).
##
## This resource is inert: no node reference, no backend read, no application. Safe to author in the
## inspector, duplicate, and load headlessly.

## Stable identifier. This is the key written into the payload's [code]stats[/code] sub-dictionary
## (as a [String], since a payload crosses to JSON and back in the shipped backend), so renaming one
## renames the field the host reads.
@export var id: StringName = &""

## Human-readable row label. Separate from [member id] so a rename or a localisation never moves the
## persisted key — the same split [MKSettingDef] draws for the same reason.
@export var label: String = ""

## Longer explanation, shown as the row's tooltip. Optional.
@export var description: String = ""

@export_group("Range")
## Floor for this stat, and the value it starts at. The point-buy pool is spent from this baseline —
## reaching [member min_value] costs nothing, so a schema author sets the free starting spread here
## and pays only for what is above it.
@export var min_value: int = 0

## Ceiling for this stat. The [code]+[/code] button disables here even when points remain, because a
## per-stat cap is the usual way a schema stops one dumped stat from consuming the whole pool.
@export var max_value: int = 10

## Points consumed per single increment. One by default; a schema that makes a stat expensive raises
## it. Zero or negative is meaningless (an infinite stat, or one that refunds points forever) and the
## step clamps it to 1 with a debug line rather than dividing the pool by zero.
@export var cost_per_point: int = 1

@export_group("Presentation")
## Flavour text under the row — "Raises melee damage and carry weight". AUTHORED, never computed: see
## the class doc for why MenuKit cannot derive this and will not pretend to.
@export var effect_hint: String = ""


## True when this def can be built into a row at all. A def failing this is skipped with one named
## warning rather than rendering a counter that writes to an empty key.
##
## The range check is part of validity rather than something silently clamped: an inverted range
## ([member max_value] below [member min_value]) produces a row whose [code]+[/code] and [code]-[/code]
## are BOTH disabled at every value, which on screen is indistinguishable from a bug in the step.
func is_valid() -> bool:
	if id == &"":
		return false
	return max_value >= min_value
