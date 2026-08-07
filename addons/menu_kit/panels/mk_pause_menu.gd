@tool
class_name MKPauseMenu
extends Control
## The in-game pause page: Resume, Settings, Quit to Menu (plan §3.1, §5 row 6).
##
## [b]It is a page, not a shell.[/b] [method MKRoot.open_pause_menu] navigates the page host to it,
## so this panel never touches [member SceneTree.paused], the mouse mode, or the suspend counter —
## all three belong to [MKRoot] and its [MKPausePolicy] (plan §4.2a). Resume calls
## [method MKRoot.close_pause_menu] and nothing else, which is what keeps the policy edge, the
## cursor restore and the page state unwinding in one order in one place.
##
## [b]This script never sets its own [member Node.process_mode].[/b] The page host assigns
## [member MKRoot.host_content_process_mode] to every instantiated page, and an [MKRoot] that hosts
## the pause page is the one that sets that export to [constant Node.PROCESS_MODE_ALWAYS] — see the
## export's own doc for why a PAUSABLE control's buttons are input-dead under a tree pause. Writing
## a process mode here would silently defeat a host that deliberately configured a different one.
##
## [b]The whole UI is built in code[/b] (plan §1.2): the accompanying [code].tscn[/code] is the root
## node plus this script, so the scene cannot drift from the structure this script indexes into —
## the same rule [MKCharacterSelect] and [MKConfirmDialog] document.
##
## [b]Styling is type variations only[/b] — zero [code]add_theme_*_override[/code] calls (ship gate
## 1), so a palette swap re-skins this page like every other.

## The page id [method _on_settings_pressed] pushes. Named here rather than spelled at the call site
## for the reason [constant MKCharacterSelect.CREATE_PAGE_ID] is: a host repointing the settings page
## edits one constant, and both shipped configs (addon and demo) author a page under exactly this id.
const SETTINGS_PAGE_ID := &"settings"

## Width floor for the button column, so three short labels do not collapse into a thin strip. A
## layout rhythm, not a palette value — the distinction [constant
## MKCharacterSelect._CARD_COLUMN_WIDTH] draws.
const _COLUMN_WIDTH := 360.0

var _menu_backend: MKMenuBackend

var _resume_button: Button
var _settings_button: Button
var _quit_button: Button

## Whether the menu backend has already been named as missing, so Quit to Menu warns once per page
## rather than once per press.
var _warned_no_menu_backend := false


func _ready() -> void:
	# @tool guard: without it, opening this scene in the editor materialises the whole UI as unowned
	# children that get saved into whatever scene instanced it — the hazard MKWelcomePage documents.
	if Engine.is_editor_hint():
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_menu_backend = _find_menu_backend()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	# Centred rather than top-left: the pause page is read as an overlay over the frozen world, and
	# the shell's nav bar sits above it either way.
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.custom_minimum_size = Vector2(_COLUMN_WIDTH, 0.0)
	MKTheme.set_variation(frame, MKTheme.PANEL)
	margin.add_child(frame)

	# The inner MarginContainer insets the column from the panel edge using the theme's own margin
	# constants (MKThemeGenerator styles them from the palette's spacing), so the inset matches every
	# other panel rather than being a number that happens to agree today.
	var inner := MarginContainer.new()
	inner.name = "Inner"
	frame.add_child(inner)

	var column := VBoxContainer.new()
	column.name = "Column"
	inner.add_child(column)

	var heading := Label.new()
	heading.name = "Title"
	heading.text = "Paused"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MKTheme.set_variation(heading, MKTheme.HEADER)
	column.add_child(heading)

	_resume_button = Button.new()
	_resume_button.name = "Resume"
	_resume_button.text = "Resume"
	MKTheme.set_variation(_resume_button, MKTheme.PRIMARY_BUTTON)
	_resume_button.pressed.connect(_on_resume_pressed)
	column.add_child(_resume_button)

	_settings_button = Button.new()
	_settings_button.name = "Settings"
	_settings_button.text = "Settings"
	MKTheme.set_variation(_settings_button, MKTheme.PANEL_BUTTON)
	_settings_button.pressed.connect(_on_settings_pressed)
	column.add_child(_settings_button)

	_quit_button = Button.new()
	_quit_button.name = "QuitToMenu"
	_quit_button.text = "Quit to Menu"
	MKTheme.set_variation(_quit_button, MKTheme.PANEL_BUTTON)
	_quit_button.pressed.connect(_on_quit_pressed)
	column.add_child(_quit_button)

	# Built as a typed local rather than an inline literal, for the reason MKConfirmDialog._build
	# records: an untyped Array is refused at runtime by link_chain's Array[Control] parameter.
	# Vertical chain, wrapping, because the buttons are stacked in a VBoxContainer. Nothing here is
	# ever disabled, so — unlike MKCharacterSelect's footer — there is no ordering constraint between
	# a disabled-flag pass and this call.
	var buttons: Array[Control] = [_resume_button, _settings_button, _quit_button]
	MKFocus.link_chain(buttons)
	# No grab_focus here: MKRoot._focus_page_content runs deferred after every page change and focuses
	# the first focusable control of the new page, which is Resume by build order.


func _on_resume_pressed() -> void:
	var root := _find_ancestor_with("close_pause_menu")
	if root == null:
		MKLog.warn("MKPauseMenu: no MKRoot ancestor — Resume has nothing to close")
		return
	# close_pause_menu is the ONLY thing Resume does. It pops the modal stack, drops the suspension
	# (the policy's exit_menu and the mouse-mode restore ride the 1→0 edge) and emits
	# pause_menu_toggled(false). It deliberately does NOT navigate, and neither does this: what
	# happens to the shell after a resume is the host's to decide off that signal.
	root.call("close_pause_menu")


func _on_settings_pressed() -> void:
	var root := _find_ancestor_with("push_page")
	if root == null:
		MKLog.warn("MKPauseMenu: no MKRoot ancestor — Settings has nowhere to navigate to")
		return
	# push_page, not go_to_page: settings opened from pause is a SUB-panel, so ui_cancel returns here
	# rather than resuming the game out from under the player (MKRoot walks the back stack before it
	# considers the pause-resume rung). A missing page id is already handled — push_page refuses and
	# warns naming the config — so there is no pre-check here to keep in sync with it.
	root.call("push_page", SETTINGS_PAGE_ID)


func _on_quit_pressed() -> void:
	if _menu_backend == null:
		if not _warned_no_menu_backend:
			_warned_no_menu_backend = true
			MKLog.warn("MKPauseMenu: Quit to Menu pressed but no MKMenuBackend is reachable — assign MKConfig.menu_backend")
		return
	# No confirmation dialog: quit-to-menu is not quit-to-desktop, and the plan's §5 row 6 asks for
	# three buttons and no prompt. A host wanting one wraps the backend, which is where the question
	# "is there unsaved progress?" can actually be answered.
	#
	# Close FIRST, then quit. Two facts make that the order, and both contradict this comment's
	# previous claim that the backend frees everything mid-call:
	# - SceneTree.change_scene_to_file is DEFERRED. The shipped MKSceneMenuBackend returns with this
	#   page and the MKRoot above it still alive, and the swap happens at the end of the frame — so
	#   there is no mid-call free to be careful around, and the close below runs on a live shell.
	# - A backend need not change scene at all. A host whose to_main_menu re-uses the current scene (an
	#   in-place state machine, a fade) never triggers MKRoot._exit_tree, and leaning on teardown left
	#   that host with a paused world, a free cursor and a suspension counter nobody would unwind.
	# Closing first is therefore better in both configurations: with the shipped backend the closed
	# state is freed a frame later either way, and with a custom one it is the ONLY unwind.
	#
	# Duck-typed and null-tolerant for the same reason Resume's lookup is: a host may wrap the shell.
	# A missing ancestor is not worth a warning here — the quit still happens, which is the gesture the
	# player asked for.
	var root := _find_ancestor_with("close_pause_menu")
	if root != null:
		root.call("close_pause_menu")
	_menu_backend.to_main_menu()


# --- Ancestor lookups ---------------------------------------------------------

## The duck-typed parent walk MenuKit resolves shell services with, verbatim from
## [code]MKCharacterSelect._find_ancestor_with[/code]. Duck-typed rather than typed to [MKRoot]
## because a host may wrap the shell, or embed this panel under its own controller that forwards the
## call; a typed cast would refuse exactly that.
func _find_ancestor_with(method: String) -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method(method):
			return node
		node = node.get_parent()
	return null


## Kept separate from [method _find_ancestor_with] for the reason [MKCharacterSelect] records: an
## ancestor may ANSWER the method and still return null (a shell booted with an unassigned slot), and
## the walk must continue past it rather than stop at the first responder.
func _find_menu_backend() -> MKMenuBackend:
	var node := get_parent()
	while node != null:
		if node.has_method("get_menu_backend"):
			var backend: MKMenuBackend = node.call("get_menu_backend")
			if backend != null and is_instance_valid(backend):
				return backend
		node = node.get_parent()
	return null
