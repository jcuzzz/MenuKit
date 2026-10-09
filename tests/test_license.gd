extends MKTest
## D21's machine-checkable half: the root LICENSE and the addon's own copy exist, state MIT, and are
## identical. The copy is hand-mirrored so a copied `addons/menu_kit/` carries its terms; a drifted or
## missing copy would ship the addon under no stated license.

const ROOT_LICENSE := "res://LICENSE"
const ADDON_LICENSE := "res://addons/menu_kit/LICENSE.md"


func run_tests() -> void:
	check(FileAccess.file_exists(ROOT_LICENSE), "the root LICENSE ships (%s)" % ROOT_LICENSE)
	check(FileAccess.file_exists(ADDON_LICENSE), "the addon carries its own copy (%s)" % ADDON_LICENSE)
	var root_text := FileAccess.get_file_as_string(ROOT_LICENSE)
	var addon_text := FileAccess.get_file_as_string(ADDON_LICENSE)
	check(root_text.begins_with("MIT License"), "the root LICENSE states MIT")
	check_eq(addon_text, root_text, "the addon copy is identical to the root LICENSE")
