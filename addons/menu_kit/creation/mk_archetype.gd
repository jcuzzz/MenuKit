@tool
class_name MKArchetype
extends Resource
## One selectable starting identity — class, background, loadout, faction.
##
## The name is deliberately generic. MenuKit does not know whether a host's grid of cards is "choose a
## class" or "choose a starting ship", and nothing in this resource assumes an RPG: it carries display
## data plus an opaque [member payload_defaults] dictionary that the host alone interprets.
##
## [b]Seeding is the HOST's job, not the card's.[/b] [member payload_defaults] is merged into the
## creation payload by [MKCreationHost] when an archetype is chosen, because the host is the only thing
## that knows the merge ORDER (defaults first, step writes second) and the only thing that can see
## every step's owned keys to detect a collision.
##
## Inert: no node reference, no backend read. Safe to author in the inspector and load headlessly.

## Stable identifier. Written into the payload under [code]archetype[/code] (as a [String]) by the
## archetype step, and it is the value the host matches on when it loads the profile back.
@export var id: StringName = &""

## Card title.
@export var display_name: String = ""

## Card body text. Autowrapped by the step; length is a layout matter, not a validity one.
@export var description: String = ""

## Card icon. Optional — a schema with no art renders text-only cards rather than a gap.
@export var icon: Texture2D = null

## Optional 3D/2D preview this archetype shows in a host's preview pane.
##
## [b]Not consumed by the creation host or by any shipped step.[/b] It is authored here so the preview
## widget and the card grid agree on which resource owns the answer; a host embedding a preview
## viewport beside the flow reads this field itself.
@export var preview_scene: PackedScene = null

## Payload fields this archetype pre-fills — starting gold, a faction tag, a stat spread.
##
## Untyped [Variant] values on purpose: the payload is opaque end to end (see [MKProfileBackend]), so
## this dictionary carries whatever the host's own save format wants.
##
## [b]A default whose key is owned by a step is an authoring ERROR[/b], not a precedence puzzle. The
## host names the archetype and the key and refuses to seed it — see
## [method MKCreationHost.notify_archetype_chosen].
@export var payload_defaults: Dictionary = {}


## True when this archetype can be rendered as a card at all. Both fields are required: an id-less
## archetype writes nothing identifiable into the payload, and a nameless one is an unlabelled card the
## player is asked to choose between.
func is_valid() -> bool:
	return id != &"" and not display_name.is_empty()
