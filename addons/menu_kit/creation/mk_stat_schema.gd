@tool
class_name MKStatSchema
extends Resource
## The point-buy budget and the stats it is spent across (D17).
##
## [b]Point-buy is disabled by default[/b] (D17): a host that authors no schema gets no stat step, and
## that is not a misconfiguration. [MKCreationHost] DROPS a point-buy step from its flow when no schema
## was supplied, with a debug line rather than a warning.
##
## Like [MKStatDef], this resource knows nothing about what a stat MEANS. It is a budget and a list.

## Points available to spend above the per-stat [member MKStatDef.min_value] baseline.
##
## Spending is measured from that baseline: the free starting spread is authored as the minimums, and
## this is what the player distributes on top. The alternative — charging for every point including
## the floor — makes a schema author solve a subtraction to express "everyone starts at 8".
@export var total_points: int = 10

## The rows, in display order.
##
## A typed [Array] of [Resource] round-trips safely. The wipe-on-resave hazard applies to packed
## arrays specifically, and is documented on [member MKSettingDef.options].
@export var stats: Array[MKStatDef] = []

## When true, the step is INVALID until every point is spent, so Next stays disabled and the player
## cannot walk past a half-allocated character by accident.
##
## False means leftover points are allowed. Some hosts bank them for a level-up screen — MenuKit does
## not know or care which, it simply stops gating on the remainder.
@export var require_full_spend: bool = true


## True when this schema can produce a usable step. A schema with no stats renders a pool readout over
## an empty list, and one with a non-positive pool renders a step where every [code]+[/code] is
## disabled from the first frame — both read as broken, so the host drops the step and names the
## resource at WARN (an unusable schema is an authoring mistake, unlike the ABSENT schema that simply
## declines the feature).
##
## Non-positive, not merely negative: a zero pool produces the same dead step a negative one does.
func is_valid() -> bool:
	if total_points <= 0:
		return false
	for stat in stats:
		if stat != null and stat.is_valid():
			return true
	return false
