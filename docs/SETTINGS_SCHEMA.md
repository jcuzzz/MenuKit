# Settings schema

The settings panel builds itself from resources. Adding a row is authoring one `.tres`
sub-resource — never an addon edit.

```
MKSettingsPanel.pages : Array[MKSettingsPageDef]
                          └─ rows : Array[MKSettingDef]      # array order IS display order
```

There is no sort key. A page's tab is its `title`; a row's position is where you put it.

---

## 1. `MKSettingsPageDef`

```gdscript
class_name MKSettingsPageDef extends Resource

@export var id: StringName = &""
@export var title: String = ""
@export var icon: Texture2D = null
@export var rows: Array[MKSettingDef] = []

func is_valid() -> bool
```

The addon ships four minimal default pages under `res://addons/menu_kit/settings/defaults/`
(`video_page.tres`, `audio_page.tres`, `gameplay_page.tres`, `controls_page.tres`). They are
deliberately thin — a **Master-only** audio page and a controls page with **no KEYBIND rows** —
because an empty project has one audio bus and only `ui_*` actions, and a row naming a missing bus or
an absent action warns by design. The richer pages are yours to author; the demo's are under
`res://demo/demo_pages/`.

---

## 2. `MKSettingDef`

```gdscript
class_name MKSettingDef extends Resource

@export var id: StringName = &""            # the store key
@export var label: String = ""
@export var type: RowType = RowType.TOGGLE
@export var default_value: Variant = null

@export_group("Slider")
@export var min_value: float = 0.0
@export var max_value: float = 1.0
@export var step: float = 0.01

@export_group("Enum")
@export var options: Array[String] = []
@export var option_values: Array = []

@export_group("Behaviour")
@export var tooltip: String = ""
@export var action_name: StringName = &""
@export var requires_confirm: bool = false
@export var visible_condition_id: StringName = &""
@export var custom_scene: PackedScene = null

func is_valid() -> bool
```

`id` and `label` are separate on purpose: localisation or a rename never changes the persisted key or
your read contract.

### Row types

**The `RowType` enum is CLOSED and its values are a persisted contract.** Inserting a value renumbers
every enum already written into an existing `.tres`, which is a **Breaking** change. Reserve, never
insert.

| Value | Renders as | Fields it uses |
|---|---|---|
| `HEADER` | A section title. Label only — no control, no value, no backend traffic. | `label` |
| `TOGGLE` | `CheckBox` | `default_value` (bool) |
| `SLIDER` | `HSlider` + live value readout | `min_value`, `max_value`, `step`, `default_value` |
| `ENUM` | `OptionButton` | `options`, `option_values`, `default_value` |
| `KEYBIND` | `MKRebindRow` | `action_name` (see §4) |
| `TEXT` | `LineEdit`, committing on submit and on focus loss | `default_value` |
| `CUSTOM` | Your scene | `custom_scene` (see §5) |

For an `ENUM` row, `options` are the labels and `option_values` are the stored values, positionally
paired.

### Behaviour fields

**`visible_condition_id`** makes a row visible only while another setting's value is truthy, live off
`setting_changed`. While the controlling setting is unset it falls back to *that row's own*
`default_value`, so a default-true controller and its dependent row agree on a fresh install.

**`tooltip`** is shown on the row and its control.

---

## 3. Reserved ids, and the shared-id rule

The shipped `MKJsonSettingsBackend` **applies these to the engine**:

| id | Effect |
|---|---|
| `video/window_mode` | `DisplayServer.window_set_mode` |
| `video/resolution` | `DisplayServer.window_set_size` (windowed only) |
| `video/vsync` | vsync mode |
| `video/max_fps` | `Engine.max_fps` |
| `audio/bus/<BusName>` | bus volume |

And the **panel itself** gives three ids behaviour of its own: `video/window_mode` (drives the
resolution row's enablement), `video/resolution`, and `video/brightness` (the calibration swatch).

**Every other id is a plain value you consume off `setting_changed`.** That is normal operation, never
a warning — FOV, mouse sensitivity, subtitles and the rest are the majority of ids and are yours.

**A row naming a missing audio bus or an absent InputMap action warns by design.** That warning is
the feature; it is why the addon's own shipped pages are minimal.

### Shared id ⇒ shared type and range

If two page sets (say the addon defaults and your own) both carry a row with the same persisted `id`,
they must agree on the **type and the range**. Only `default_value` may differ. For an `ENUM` row the
candidate list *is* the range — adding a flavour to one page set and not the other means the store
holds a value the other page cannot display. If you need a different value space, use a **distinct
id**, not a distinct type.

### Resolution rows

The resolution row is a curated `Vector2i` list on the def, filtered to what fits the current screen,
with the **native size always added**. Authored `options` labels are used **positionally** when
present (a formatted `Vector2i` is the fallback); authoring slips in either direction — surplus
labels, duplicate sizes — are debug-logged naming the def.

The row is **DISABLED outside windowed mode** (`window_set_size` is a no-op in fullscreen and
borderless) and the tooltip says so. **The WINDOW, not the store, is the source of truth** for which
mode is current wherever a real display exists; the stored mode is consulted only headless.
Enablement re-checks on build, on the setting edge, and on `visibility_changed` — a mode change while
the page sits open and untouched is a stated gap.

---

## 4. KEYBIND rows

A KEYBIND row is **CUSTOM-shaped to the panel**: it is registered for duplicate-id and visibility
handling, and excluded outright from the panel's value sync, value display, and the D14 confirm
machinery. **Its state lives in the input store, keyed by action — not the value store keyed by id.**

Consequently **`requires_confirm` on a KEYBIND def is IGNORED** (with a debug line): the confirm
machinery operates on the value store, and a binding is not in it.

### Capture priority — a host-facing invariant

While a row is listening it reads input in `_input` and marks **every event class it inspects**
handled via `set_input_as_handled()`. That is what stops a capture keystroke from also closing the
menu, activating the focused button, or reaching gameplay: `MKRoot` reads `ui_cancel` in
`_unhandled_input`, which runs strictly *after* `_input` and after GUI dispatch.

Two consequences follow by construction:

- The row never uses `_unhandled_input`.
- **GUI dispatch does not run for consumed events**, so the row's own Cancel button is reached by a
  manual rect hit-test rather than a click.

**If you install your own global `_input` handler, respect that ordering.**

### Abort is decided per device

Never through the `ui_cancel` *action* — testing the action would swallow the pad's B before the
reserved check could explain it.

| Gesture | Result |
|---|---|
| Keyboard physical **Escape** | Aborts capture (and does **not** pop the page) |
| Gamepad **B** | No special case: it reaches the record path, is refused as a reserved event, and that refusal ends listening — one gesture, both jobs |
| Mouse press **inside the Cancel rect** | Aborts |
| Mouse press **anywhere else** | Is RECORDED |
| Listen timeout (default 10s) | Aborts |

Escape is unbindable as a result of the mechanism, with no blacklist anywhere.

### Capture semantics

**A capture REPLACES the row's whole event list (single-slot).** The multi-event stock binding is not
lost — it lives in the boot snapshot, and the row's Reset restores all of it. Fresh events are built
with **`device = -1`** (all devices) and cleared modifier flags (modifier *keys* themselves stay
bindable); captured joypad motion normalises to ±1.0.

### Reserved events

`MKSettingsPanel.extra_reserved_events: Array[InputEvent]` is your hook for widening the
never-bindable set (a game whose menu also opens on Start). The **derived** part is the boot-default
**non-keyboard** `ui_cancel` bindings only; keyboard Escape is deliberately absent because the row's
own abort already makes it unreachable.

> A host that wants pad-B refused must have a pad-B binding on `ui_cancel` in its own
> `project.godot`, or widen `extra_reserved_events`. Without either, the derived list is empty and the
> guard is inert. The demo's `project.godot` restates `ui_cancel` with a pad-B binding for exactly
> this reason.

### Cross-row consistency

The panel — not the row — owns one-capture-at-a-time and the refresh relay: a conflict resolved with
*Replace* rewrites an action some **other** row displays, and rows cannot see each other. The conflict
modal is `MKConfirmDialog` verbatim (`Replace` / `Keep both` / `Cancel` mapped to
confirm/alternate/cancel), and listening ends **before** the dialog opens, or the dialog's own
keyboard would be consumed by the row.

---

## 5. CUSTOM rows

`RowType.CUSTOM` is the escape hatch for the closed enum. Point `custom_scene` at a scene whose
**root** implements:

```gdscript
func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void
```

A root without it is **skipped with a named warning** — the panel will not put an unbound control on
screen that silently discards every change. `_mk_bind` is called once, immediately after
instantiation and **before the node is parented**, so a row may size itself from the value it reads.

### CUSTOM rows are NEVER auto-synced

The panel's external-write sync covers built-in row types only. A CUSTOM root owns its backend
relationship end to end. (A CUSTOM root may legally *be* a `LineEdit`/`CheckBox`/`HSlider`;
auto-syncing it would assign uncoerced Variants — a script error.)

Four rules, all demonstrated by the shipped reference
`res://addons/menu_kit/settings/mk_example_custom_row.tscn` (`MKExampleCustomRow`), which the
Gameplay page carries as a **live instance** so the path is exercised, not merely described:

1. **Read through the backend by `def.id`**, never from a field of your own. The store is the truth;
   a cached copy drifts the moment anything else writes the same id.
2. **Tolerate a null backend.** The panel renders disabled rather than refusing to build when the
   settings slot is unassigned, so `backend` can legitimately be null.
3. **Write with `set_value` then `apply_one`.** Instant apply is the model (D14), and `apply_one` is
   targeted so a custom row cannot make every other setting re-apply. Call it even for a plain id —
   a custom row must not need to know whether its id happens to be reserved.
4. **Subscribe to `setting_changed` if you want to stay live.** The panel re-syncs the rows *it*
   built; it cannot write a widget it has never seen.

```gdscript
class_name MyColorRow
extends HBoxContainer

var _backend: MKSettingsBackend
var _def: MKSettingDef
var _picker: ColorPickerButton
var _syncing := false


func _mk_bind(backend: MKSettingsBackend, def: MKSettingDef) -> void:
	_backend = backend
	_def = def
	_build()
	if _backend != null and not _backend.setting_changed.is_connected(_on_setting_changed):
		_backend.setting_changed.connect(_on_setting_changed)


func _on_setting_changed(id: StringName, _value: Variant) -> void:
	if _syncing or _def == null or id != _def.id:
		return
	_syncing = true
	_picker.color = _read()
	_syncing = false


func _build() -> void:
	var label := Label.new()
	label.text = _def.label
	label.custom_minimum_size = Vector2(MKSettingsPanel.LABEL_COLUMN_WIDTH, 0.0)
	MKTheme.set_variation(label, MKTheme.ROW_LABEL)   # variations only — never a theme override
	add_child(label)

	_picker = ColorPickerButton.new()
	_picker.color = _read()
	_picker.disabled = _backend == null               # tolerate a null backend
	_picker.color_changed.connect(_on_color_changed)
	add_child(_picker)


func _read() -> Color:
	if _backend == null or _def == null:
		return Color.WHITE
	var raw: Variant = _backend.get_value(_def.id, _def.default_value)
	return raw if raw is Color else Color.WHITE


func _on_color_changed(value: Color) -> void:
	if _syncing or _backend == null or _def == null:
		return
	_backend.set_value(_def.id, value)
	_backend.apply_one(_def.id)
```

> Note: this example stores a `Color`. The shipped `MKJsonSettingsBackend` envelopes only `Vector2i`,
> so a `Color` round-trips through JSON as an array-ish value — persist it as a hex `String` or four
> floats if you use that backend, or handle the type in your own.

Styling uses theme type variations only. MenuKit ships zero `add_theme_*_override` calls, and that
rule binds host-facing examples as hard as core panels.

---

## 6. `requires_confirm` — the D14 flow

`requires_confirm` **applies, then asks.** A display change that leaves the user unable to see the
screen also leaves them unable to click Undo, so the change goes live immediately and a countdown
dialog (`MKRevertCountdown`, default 10s) asks to keep it.

Rules:

- **One live countdown per setting id**, keeping the **FIRST unconfirmed value**. A→B→C with neither
  confirmed lapses back to **A**. Different ids stay independent.
- **Unconfirmed means not kept.** A live countdown whose dialog or panel leaves the tree resolves as
  **REVERTED**.
- The countdown runs `PROCESS_MODE_ALWAYS` and accumulates in `_process` rather than on a `Timer`, so
  it still counts down when the settings page was opened from the pause menu under a tree pause.
- Shipped rows using it: `video/window_mode` and `video/resolution`.
- On a KEYBIND def it is **ignored** (§4).

---

## 7. Persisted formats

Both shipped stores are JSON under `user://`, both written atomically where possible, and **neither
ever deletes a file it could not read**.

### Settings store — `user://menukit_settings.json`

```json
{
	"version": 1,
	"values": {
		"video/window_mode": 0,
		"video/resolution": { "__mk_type": "Vector2i", "v": [1920, 1080] },
		"audio/bus/Master": 0.8,
		"gameplay/fov": 90
	},
	"input": {
		"move_forward": [
			{ "type": "key", "physical_keycode": 87, "keycode": 87,
			  "alt": false, "shift": false, "ctrl": false, "meta": false, "device": -1 }
		]
	}
}
```

- `version` is `FORMAT_VERSION` (`1`).
- `values` holds every stored setting. **Only `Vector2i` is enveloped** here — this backend's format
  predates the int envelope and every application site coerces with an explicit `int(...)`, so
  enveloping ints would change bytes for no behavioural gain. The known cost: a plain JSON number
  reads back as a `float`, which is why every application site coerces.
- `input` maps an action name to its **override** event list. Absent action = no override.

**Event dictionary shapes.** Four types are carriable; anything else warns and is skipped:

| `type` | Fields |
|---|---|
| `"key"` | `physical_keycode`, `keycode`, `alt`, `shift`, `ctrl`, `meta`, `device` |
| `"mouse_button"` | `button_index`, `device` |
| `"joypad_button"` | `button_index`, `device` |
| `"joypad_motion"` | `axis`, `axis_value`, `device` |

**The `device` field, and why absent means `-1`.** `-1` means ALL devices — both what
`project.godot` authors for stock bindings and the correct meaning for a local rebind. It must be
written explicitly, because `InputEvent`'s per-class `device` default is **not** -1
(`InputEventJoypadButton` 0, `InputEventKey` 16, `InputEventMouseButton` 32); round-tripping without
it would silently narrow a pad binding to controller 0. A store written before the field existed
therefore reads back as an all-devices binding.

Bindings are stored by **physical keycode** so they stay under the same finger on an AZERTY layout;
the label is mapped back through the active layout for display. A prompt reads the live `InputMap`
(the post-override truth an actual press is matched against); a settings row asks the **store**. The
two agree once apply has run, and only the store survives a restart.

**Corruption policy.** An unparseable or wrong-shaped store is renamed aside to
`<name>.corrupt-<n>.json` and defaults boot with **one warning**. Nothing is deleted.

### Profile store — `user://menukit_profiles.json`

```json
{
	"version": 1,
	"next_id": 3,
	"profiles": [
		{ "id": "p_000001", "name": "Alice", "archetype": "vanguard",
		  "stats": { "might": { "__mk_type": "int", "v": 6 } } }
	]
}
```

- `version` is `SCHEMA_VERSION` (`1`); `next_id` backs the monotonic id counter.
- Ids are minted `p_000001` and **never reissued after a delete**.
- **This backend envelopes ints as well as `Vector2i`**, because a profile payload is opaque *host*
  data it cannot coerce at the read site — the only alternative to int fidelity would be a silent
  lossy conversion of your data.
- **Names are stored TRIMMED** — the value the uniqueness rule was checked against. Storing raw would
  make the rule bypassable by whitespace: `"  Alice  "` would persist untrimmed, a later create of
  `"Alice"` would find no collision, and the roster would hold two rows that render identically.
- `id` is a reserved key: a payload carrying it is warned about and the backend's value wins.

**The `__mk_type` discriminator refusal.** A creation payload may not spell `__mk_type` at any
depth. `create_profile` scans recursively and **refuses** such a payload with a warning naming the
path — accepting it would write a file whose load quarantines the whole roster, taking every other
profile with it.

**The newer-store read-only latch.** A store whose `version` is **greater** than this build's
`SCHEMA_VERSION` is a downgraded install, not corruption. The file is left exactly where it is,
byte-identical, the roster boots empty, and the backend latches **read-only**: `create_profile`
returns `{}` and `delete_profile` returns `false`, with one warning naming both versions. A settings
value is an annoyance to lose; a roster is not — the two shipped backends deliberately take
different positions here. **The latch follows the FILE**: replace it with a readable store and writes
resume.

Other quarantine triggers (whole file aside, roster boots empty, nothing deleted): invalid JSON, a
non-object root, `version < 1`, a missing or non-array `profiles`, an entry that is not an object,
an entry missing `id` or `name`, a duplicate id. An **unreadable** (locked) file is not treated as
corrupt: the roster boots empty and the file is left alone.

### Versioning rule

Any change to a persisted JSON key, an envelope tag spelling, or a `RowType` enum value is
**Breaking** and says so in the CHANGELOG — those are the surfaces your game code and your users'
existing files are written against. Adding an envelope tag is additive.
