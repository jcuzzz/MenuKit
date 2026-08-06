@tool
class_name MKCreationStepDef
extends Resource
## One step of the character creation flow (plan §4.5).
##
## The flow is an ORDERED ARRAY of these, exactly as a settings page is an array of [MKSettingDef]:
## adding "choose a starting town" is authoring one resource plus one scene, never an addon edit. The
## host owns navigation, validation gating, the progress indicator and the shared payload; a step owns
## its own widgets and the payload keys it declares.
##
## [b]The step scene's ROOT implements a four-method duck-typed contract[/b], mirroring the
## [constant MKSettingDef.RowType.CUSTOM] row's [code]_mk_bind[/code] convention (finding M7 — the same
## reasoning: a scene that silently discards everything is worse than an absent step plus a named
## warning):
## [codeblock]
## signal step_state_changed()
## func _mk_step_bind(host: MKCreationHost, def: MKCreationStepDef, ctx: Dictionary) -> void
## func _mk_step_owned_keys() -> Array[String]
## func _mk_step_is_valid() -> bool
## func _mk_step_commit(payload: Dictionary) -> void
## [/codeblock]
## [method MKCreationHost.configure] documents each one, including the ordering rule that
## [code]_mk_step_owned_keys[/code] must answer BEFORE [code]_mk_step_bind[/code] has run.
##
## Inert: no node reference, no backend read. Safe to author in the inspector and load headlessly.

## Stable identifier. Used in every diagnostic the host prints about this step, and it is what a host
## matches on if it wants to find a step in its own configured array.
@export var id: StringName = &""

## Header shown above the step's content, e.g. "Name your character". Falls back to the id when empty,
## so a title-less step still reads as something rather than as a blank bar.
@export var title: String = ""

## The step UI. Its root must honour the contract in the class doc; a root that does not is skipped
## with a warning naming this def.
@export var scene: PackedScene = null

## A required step cannot be skipped, whatever [member skippable] says.
##
## Both flags exist because they answer different questions: this one is about the FLOW ("the payload
## is incomplete without it"), and [member skippable] is about the CONTROL ("offer a Skip button").
## Required wins by HIDING the Skip control ([code]skippable and not required[/code], in
## [method MKCreationHost._refresh_buttons]) rather than by rendering one that refuses to work: the
## player is never offered a gesture that does nothing. It is not reported anywhere, because the
## combination is a legitimate authoring state — a step toggled back to required keeps its skippable
## flag for when it is toggled again, and warning about that would fire on every well-formed flow that
## ever changed its mind.
@export var required: bool = true

## Shows a Skip control while this step is current — and only when [member required] is false.
##
## Skipping advances WITHOUT calling [code]_mk_step_commit[/code], so the step's owned keys keep
## whatever the payload already held (an archetype default, or an earlier visit's commit reached
## through Back). It does not erase them: a Skip that quietly deleted a value the player had already
## chosen is a data-loss gesture wearing a navigation label.
@export var skippable: bool = false


## True when this def is identifiable. The id alone, deliberately: a missing [member scene] is a
## separate failure with a separate message ("has no scene"), and folding it in here would collapse two
## distinct authoring mistakes into one indistinguishable "invalid step" line — the exact thing
## [MKLog]'s naming rule exists to prevent. The host checks both, in that order.
func is_valid() -> bool:
	return id != &""
