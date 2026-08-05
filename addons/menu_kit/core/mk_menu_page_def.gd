@tool
class_name MKMenuPageDef
extends Resource
## One navigable page in the menu — the unit a host appends to add its own page.
##
## The source menu this package was extracted from hardcoded its tab list as a [code]const[/code]
## in the nav bar, so "add a Credits page" meant forking the nav bar — which breaks the
## pin-a-tag upgrade story the whole versioning plan is built on (plan §4.7a, finding F5).
## Navigation is therefore DATA: [code]MKConfig.pages[/code] is an [code]Array[MKMenuPageDef][/code],
## [code]MKNavBar[/code] builds its tabs from it, and [code]MKRoot[/code] drives its page state
## machine off the same ids. A host appends, reorders, or hides entries with zero addon edits.
##
## This resource is inert data: it holds no node reference and performs no navigation itself, so it
## is safe to author in the inspector, duplicate, and load headlessly.

## Stable identifier for this page. It is the payload of [signal MKNavBar.page_selected] and the
## argument to [code]MKRoot.go_to_page()[/code], so a host's deep links are written against it —
## renaming one is a host-visible break, not a cosmetic edit.
@export var id: StringName = &""

## Human-readable tab label. Kept separate from [member id] so localization or a rename never
## changes the navigation contract.
@export var title: String = ""

## Optional tab icon. Null is normal and renders as a text-only tab — the shipped defaults carry no
## icon so the addon cold-drops into an empty project with no external texture (plan §3.1).
@export var icon: Texture2D = null

## The page content. [code]MKRoot[/code] instantiates it on first visit. Left null the page is a
## navigation target with nothing to show, which [code]MKRoot[/code] reports rather than crashing.
@export var scene: PackedScene = null

## False hides the tab without deleting the entry — the supported way for a host to switch a page
## off (e.g. multiplayer disabled in a build) while keeping the array shipped by the addon intact.
@export var visible: bool = true

## Sort key for tab order. [code]MKNavBar[/code] sorts ascending and preserves array order on ties,
## so a host can insert a page between two shipped ones without renumbering them.
@export var order: int = 0


## True when this def can actually be shown as a tab. Used by [MKNavBar] to skip junk entries with a
## single named warning instead of building an unlabelled, unroutable button.
func is_valid() -> bool:
	return id != &""
