@tool
class_name MKSettingsPageDef
extends Resource
## One tab of the settings panel: ordered rows plus the metadata the tab strip needs (D5).
##
## [MKSettingsPanel] takes an [code]Array[MKSettingsPageDef][/code] and builds every tab and every
## row at runtime, so a host adds, removes or reorders whole pages by editing its own array — no
## addon edit, no subclass, no scene fork.
##
## Inert data: no node references, no backend access. Authorable in the inspector and loadable
## headlessly.

## Stable identifier for the page. Not currently a navigation target the way [MKMenuPageDef.id] is,
## but it is what a diagnostic names when a page is malformed, and hosts key their own logic off it.
@export var id: StringName = &""

## Tab label.
@export var title: String = ""

## Optional tab icon. Null is normal and renders a text-only tab — the shipped pages carry no icon so
## the addon cold-drops into an empty project with no external texture.
@export var icon: Texture2D = null

## The rows, top to bottom. Order is array order — there is no sort key, because a settings page
## reads as a document and an author reordering rows expects to see exactly what they typed.
@export var rows: Array[MKSettingDef] = []


## True when the page can be shown as a tab at all. A page with no valid id is skipped with one named
## warning rather than producing an untitled tab nothing can reference.
func is_valid() -> bool:
	return id != &""
