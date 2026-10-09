# MenuKit API reference

Every public class, signature and signal a host writes code against. Signatures are as shipped in
`0.2.0`.

Anything below is a **public surface** under the versioning rule: a change to a backend method
signature, an exported `Resource` field, a `Theme` type-variation name, or a persisted JSON key is
**Breaking** and says so in the CHANGELOG.

Contents: [MKRoot](#mkroot) · [Backends](#backends) · [MKSettingsService](#mksettingsservice) ·
[MKConfig / MKBackendSlot / MKMenuPageDef](#mkconfig) ·
[MKBackdropCatalog / MKBackdropDef / MKBackdrop](#mkbackdropcatalog--mkbackdropdef--mkbackdrop) ·
[MKInputGlyphs](#mkinputglyphs) ·
[MKFocus](#mkfocus) · [MKPreviewViewport](#mkpreviewviewport) ·
[MKModalLayer / MKConfirmDialog](#mkmodallayer) · [MKLog](#mklog) · [MKJsonCodec](#mkjsoncodec) ·
[MKVersion](#mkversion)

---

## MKRoot

`class_name MKRoot extends Control` — the shell. Instance
`res://addons/menu_kit/core/mk_root.tscn`, not a bare node.

**Per-scene instance, not a persistent singleton.** Counters are per-instance and reset naturally on
a scene change. The whole subtree runs `PROCESS_MODE_ALWAYS`, unconditionally.

### Exports

| Export | Type | Default | Notes |
|---|---|---|---|
| `config` | `MKConfig` | `null` | Resolved from the `menu_kit/config_path` project setting when left null. **Assigning it at runtime does nothing.** |
| `host_content_process_mode` | `Node.ProcessMode` | `PROCESS_MODE_PAUSABLE` | Applied to instantiated page content. A pause-hosting shell sets `PROCESS_MODE_ALWAYS`. |
| `show_backdrop` | `bool` | `true` | Off for an in-game pause shell. |
| `hover_sfx` / `click_sfx` / `back_sfx` / `error_sfx` | `AudioStream` | `null` | Optional; no audio ships (licensing). All four play through one internal player. |

### Signals

```gdscript
signal page_changed(id: StringName)
signal pause_menu_toggled(open: bool)
```

`pause_menu_toggled` is the camera gate. Under a no-pause policy the world keeps running while the
cursor is freed, so mouselook keeps consuming relative motion unless you act on this.

### Navigation

```gdscript
func go_to_page(id: StringName) -> void      # lateral move; CLEARS the back stack
func push_page(id: StringName) -> void       # pushes onto the back stack
func pop_page() -> bool                      # returns false when the stack was empty
func get_page_id() -> StringName
func get_back_depth() -> int
func request_quit_confirm() -> void          # the root rung of the cancel ladder
```

### Backdrop character

```gdscript
func set_backdrop_character(scene: PackedScene) -> void  # stands scene in the scene backdrop's mount
```

Pages are wired automatically: a shown page with a `selection_changed(entry: Dictionary)` signal
(duck-typed — `MKCharacterSelect`, or a host's own roster page) has it connected to the shell, which
resolves `entry.archetype` through `MKConfig.archetypes` and mounts that archetype's
`preview_scene`. See the MKBackdrop section.

### Pause

```gdscript
func open_pause_menu(page_id: StringName = &"pause") -> bool
func close_pause_menu() -> void
func is_pause_menu_open() -> bool
func get_suspend_depth() -> int
```

`open_pause_menu` **pre-checks** (page def null, or its scene null) before touching any state and
returns `false` having changed nothing. `close_pause_menu` clears the back stack — no return
addresses into a hidden shell — and restores the nav bar's visibility **as it was found**, so a host
running navless is not handed a strip it hid on purpose.

### Service accessors

```gdscript
func get_modal_layer() -> MKModalLayer
func get_menu_backend() -> MKMenuBackend
func get_profile_backend() -> MKProfileBackend
func get_settings_backend() -> MKSettingsBackend
func get_brightness_controller() -> MKBrightnessController
func get_network_backend() -> MKNetworkBackend
func get_pause_policy() -> MKPausePolicy
func dump_diagnostics() -> String
```

Shipped panels call `push_page`, `pop_page`, `close_pause_menu`, `get_modal_layer`,
`get_profile_backend`, `get_menu_backend`, `get_network_backend` and read `config` **duck-typed**, by
walking up the tree — so a host controller that forwards those names can host a panel without an
`MKRoot` above it.

`dump_diagnostics()` returns version, active backend scripts, the resolved `user://` path of any
backend exposing `get_file_path()`, page/step/archetype counts and current setting values.

---

## Backends

Five host extension points. Each is a **Node** subclassed from an abstract base; you point an
`MKBackendSlot` at the script and `MKRoot` instantiates it as a child, calling `_mk_configure` first.

Every base carries the same optional hook:

```gdscript
func _mk_configure(params: Dictionary) -> Array[String]   # return the keys you consumed
```

Keys nothing claims are warned about by name.

### MKMenuBackend

`@abstract class_name MKMenuBackend extends Node` — what Play / Quit to Menu / Quit actually do.

```gdscript
@abstract func start_game(profile: Dictionary) -> void
@abstract func to_main_menu() -> void
@abstract func quit() -> void

func open_url(url: String) -> void            # non-abstract; default opens the OS browser
```

**Shipped default — `MKSceneMenuBackend`.** Changes scene. Names no scene of its own; both targets
arrive as slot params: `game_scene`, `menu_scene` (constants `PARAM_GAME_SCENE`,
`PARAM_MENU_SCENE`). Unassigned params are valid config — they warn when Play is clicked, never at
boot.

### MKProfileBackend

`@abstract class_name MKProfileBackend extends Node` — the character/save roster. Profiles are opaque
`Dictionary`s; MenuKit never interprets a payload.

```gdscript
signal roster_changed()

@abstract func list_profiles() -> Array[Dictionary]
@abstract func create_profile(payload: Dictionary) -> Dictionary   # {} == refused
@abstract func delete_profile(id: String) -> bool
@abstract func load_profile(id: String) -> Dictionary

func is_name_available(profile_name: String) -> bool               # default scans list_profiles()
```

Every entry must carry at least `id` and `name`. `MKCharacterSelect` additionally displays
`archetype` when present (type-gated).

**Shipped default — `MKJsonProfileBackend`.** Params: `file_path` (String), `max_profiles`
(int, 0 = unlimited). Additional public methods: `get_file_path() -> String`, `reload() -> void`.
Constants: `SCHEMA_VERSION = 1`, `DEFAULT_FILE_PATH = "user://menukit_profiles.json"`,
`RESERVED_KEYS = ["id"]`. See [SETTINGS_SCHEMA.md](SETTINGS_SCHEMA.md) for the store format, the
`__mk_type` refusal, trimmed names, and the newer-store read-only latch.

### MKSettingsBackend

`@abstract class_name MKSettingsBackend extends Node` — setting values **plus** their application to
the engine. Storage and application live together deliberately: a host swapping to cloud-synced
settings should not also have to reimplement "what window mode 2 does".

**Exactly one instance per project.**

```gdscript
signal setting_changed(id: StringName, value: Variant)

@abstract func get_value(id: StringName, default_value: Variant) -> Variant
@abstract func set_value(id: StringName, value: Variant) -> void
@abstract func save() -> void
@abstract func load() -> void
@abstract func apply_all() -> void
@abstract func snapshot_input_defaults() -> void

func apply_one(_id: StringName) -> void              # no-op by default
func apply_action(_action: StringName) -> void       # base delegates to apply_all()

# The input store — six non-abstract methods, inert by default
func get_action_events(_action: StringName) -> Array[InputEvent]          # []
func set_action_events(_action: StringName, _events: Array) -> void       # no-op
func get_default_action_events(_action: StringName) -> Array[InputEvent]  # []
func reset_action_to_default(_action: StringName) -> void                 # no-op
func reset_all_actions_to_defaults() -> void                              # no-op
func has_action_override(_action: StringName) -> bool                     # false
```

**Store-only backends are legitimate.** The inert answers are chosen so a rebind row over such a
backend degrades *visibly* (every row reads "Unbound", every Reset stays disabled) rather than
wrongly. But **implement the six input-store methods together** — the read side without the write
side produces rows that capture and never display.

`apply_one` exists so a slider drag does not re-push every window mode, bus volume and InputMap
binding per tick. Implementations must treat an unrecognised id as **normal operation and stay
silent** — plain values like FOV and mouse sensitivity are the majority of ids and are the host's to
consume off `setting_changed`.

`apply_action` matters because a rebind cannot wait for the next `apply_all`. The base delegation is
correct but broad; override it with a targeted implementation.

**Shipped default — `MKJsonSettingsBackend`.** Param: `file_path` (String). Extra public methods:
`get_file_path() -> String`, `is_headless_display() -> bool`. Constants: `FORMAT_VERSION = 1`,
`DEFAULT_FILE_PATH = "user://menukit_settings.json"`, and the reserved ids `ID_WINDOW_MODE`,
`ID_RESOLUTION`, `ID_VSYNC`, `ID_MAX_FPS`, plus `BUS_VOLUME_PREFIX = "audio/bus/"`.

### MKNetworkBackend

`@abstract class_name MKNetworkBackend extends Node` — optional; an unassigned slot hides the server
browser entirely.

```gdscript
enum ConnectState { IDLE, CONNECTING, CONNECTED, FAILED, CANCELLED }

signal servers_changed()
signal connect_state_changed(state: ConnectState, message: String)

@abstract func list_servers() -> Array[Dictionary]
@abstract func connect_to(entry: Dictionary) -> void
@abstract func cancel() -> void

func refresh() -> void                                # non-abstract; default is a no-op
```

Connection progress is reported through `connect_state_changed` **only**, never a return value, so
the panel stays responsive and cancellable. **The enum has no TIMEOUT member**: a timeout is `FAILED`
plus a message, which is why the browser renders both.

**Shipped reference — `MKStubNetworkBackend`.** Ships as a reference implementation, not a live
default (`default_config.tres` leaves the network slot empty; the demo points at it). Params:
`connect_delay`, `refresh_delay`. Extra method: `get_connect_state() -> ConnectState`. Its delays run
on `SceneTreeTimer`s so they keep ticking under a tree pause.

### MKPausePolicy

`@abstract class_name MKPausePolicy extends Node` — what "the menu is up" does to the world.

```gdscript
@abstract func enter_menu(reason: StringName) -> void
@abstract func exit_menu(reason: StringName) -> void

func can_pause() -> bool                              # non-abstract; default true
```

`MKRoot` owns the single suspend counter and calls `enter_menu` only on the 0→1 edge, `exit_menu`
only on the 1→0 edge. **Policies must not count depth.** `can_pause() == false` is never a veto on
opening the menu — the menu opens, the world keeps running, `enter_menu` is skipped.

**Teardown contract: whatever a policy changes on engage it must undo in its own `_exit_tree()`**,
not in `MKRoot`'s. `NOTIFICATION_EXIT_TREE` propagates children first, so by the time
`MKRoot._exit_tree()` runs, the policy is out of the tree and `get_tree()` is null.

**Shipped defaults.** `MKTreePausePolicy` sets `SceneTree.paused`. `MKNoPausePolicy` is the
multiplayer answer: `can_pause()` returns false and both edges are inert — and it hands you a
responsibility (gate camera input on `MKRoot.pause_menu_toggled`).

### C# adapter backends

`addons/menu_kit/backends/interop/` — five backends that extend the bases and forward to a
host-supplied node, because **a C# class cannot extend a GDScript one**. Full worked example in
[INTEGRATION.md §10](INTEGRATION.md#10-c-hosts).

```gdscript
MKCSharpMenuBackend      extends MKMenuBackend
MKCSharpProfileBackend   extends MKProfileBackend
MKCSharpSettingsBackend  extends MKSettingsBackend
MKCSharpNetworkBackend   extends MKNetworkBackend
MKCSharpPausePolicy      extends MKPausePolicy
```

Each takes one param, `delegate_path` (`/root/Foo`, case-insensitive on the `/root/` segment, or the
equivalent root-relative `Foo`; any other absolute path degrades rather than reaching `get_node`),
forwards every remaining param to the
delegate's configure hook, overrides its base's whole public contract, and exposes
`get_delegate() -> Node` for diagnostics. `MKCSharpNetworkBackend` additionally answers
`get_connect_state()`, the browser's duck-typed re-entry seed.

**`MKCSharpDelegate`** (`RefCounted`) is the shared bridge the five forward through:

```gdscript
const PARAM_DELEGATE_PATH   := "delegate_path"
const CONFIGURE_METHOD      := "_mk_configure"
const CONFIGURE_METHOD_PASCAL := "MkConfigure"

func configure(params: Dictionary) -> Array[String]
func supports(method: String) -> bool          # warns once when the delegate answers neither spelling
func supports_quiet(method: String) -> bool    # same lookup, no warning — for optional hooks
func forward(method: String, args: Array = []) -> Variant
func was_delivered() -> bool                   # did the LAST forward reach the delegate, or degrade?
func bridge(signal_name: String, sink: Callable) -> void
func ensure_resolved() -> bool
func get_delegate() -> Node                    # the resolved node, or null
func get_delegate_path() -> String             # the configured delegate_path, verbatim
var on_resolved: Callable                      # fired once per resolution, after held params go over
func to_pascal_case(method: String) -> String
func to_bool / to_dictionary / to_dictionary_array / to_event_array / to_enum
```

The delegate contract, in five rules:

1. **Names.** snake_case first, then PascalCase (leading underscores stripped, `_` split, each
   segment's first character upper-cased). `_mk_configure` → `MkConfigure`. Signals resolve the same
   way and re-emit through the adapter with their arguments intact — `roster_changed` (0),
   `setting_changed` (2), `servers_changed` (0), `connect_state_changed` (2).
2. **Resolution is lazy and retried** while unresolved (a C# autoload may sit below the adapter in
   autoload order), off `Engine.get_main_loop()` rather than the adapter's own tree position, so
   `_mk_configure` — which runs before `MKRoot` adds the adapter as a child — still reaches the
   delegate.
3. **Params are claimed optimistically.** `delegate_path` is consumed by the adapter; every other key
   is reported consumed and forwarded, because a delegate that is not resolvable *yet* would
   otherwise make correct config warn. Unknown-key detection for those keys is the delegate's.
4. **Degradation warns once and answers the base default** — for an unreachable delegate, for a
   method under neither spelling, and for a return of the wrong type. One fault is exactly one line:
   a call that degraded returns `null`, and the coercions do not warn a second time about that.
   Never an error, never a throw.
5. **Signal bridging follows the delegate INSTANCE.** It re-runs on every resolution, so a delegate
   replaced at the same path keeps re-emitting; `bridge()` after resolution connects immediately.

`MKCSharpSettingsBackend` adds one behaviour of its own: it holds `snapshot_input_defaults`, `load`
and `apply_all` while the delegate is unresolved and replays them in order on the resolution that
finds it, and refuses `save()` until `load()` has actually reached the CURRENT delegate instance —
per-instance, so a delegate replaced at the same path must load again before it may save, and a
delegate that implements no `Load()` is refused permanently (warned by name). See
[INTEGRATION.md §10](INTEGRATION.md#10-c-hosts) for the autoload-order rule this backstops.

`MKCSharpPausePolicy` adds `MkExitTree()`: an optional delegate hook called from the adapter's
`_exit_tree()`, because the base's teardown contract cannot be honoured by an autoload that never
leaves the tree.

---

## MKSettingsService

The optional autoload (`/root/MKSettingsService`, registered by the plugin). **No `class_name`** — a
script registered as an autoload must not also declare one.

```gdscript
func get_settings_backend() -> MKSettingsBackend
func get_brightness_controller() -> MKBrightnessController
func get_config() -> MKConfig

var override_backend_slot: MKBackendSlot     # testing seam: supply a slot without a config
```

At `_ready` it sets `PROCESS_MODE_ALWAYS` (it lives outside the `MKRoot` subtree and inherits
nothing), resolves its slot, then calls `snapshot_input_defaults()` → `load()` → `apply_all()`, then
boots brightness. At `_exit_tree` it calls `save()` — **that flush is what makes settings survive a
relaunch.**

`get_settings_backend()` and `get_brightness_controller()` are the **method names** `MKRoot` resolves
by; a host substituting its own service-shaped node must answer both.

### MKBrightnessController

`class_name MKBrightnessController extends CanvasLayer`. Godot has no global or OS gamma control, so
brightness cannot be "applied by a backend" — a live node is required.

```gdscript
enum Mode { OVERLAY, ENVIRONMENT }

const SETTING_ID := &"video/brightness"
const MIN_BRIGHTNESS := 0.4
const MAX_BRIGHTNESS := 2.5

@export var mode: Mode = Mode.OVERLAY
@export var world_environment_path: NodePath

func set_brightness(value: float) -> void
func get_brightness() -> float
func is_overlay_active() -> bool
```

`Mode.ENVIRONMENT` caveats are inherent to the approach: it drives the **active** `Environment` and
MenuKit never owns one (name yours through `world_environment_path`, or the controller walks the
current viewport's `World3D` and finds nothing in a 2D or menu-only scene); it crushes rather than
lifts true blacks at extremes; adjustment support varies by renderer; and it does not affect the UI,
so the "adjust until the logo is barely visible" calibration convention does not apply. The value is
applied as `adjustment_brightness` (a multiplier) rather than a gamma exponent, so a given slider
position does not look identical in the two modes — both are neutral at 1.0, which is the part that
matches.

Set `MKConfig.manage_brightness = false` to own it yourself; `video/brightness` then stays a plain
value you consume off `setting_changed`, and that is the documented floor.

---

## MKConfig

`class_name MKConfig extends Resource`. Exports are listed in
[INTEGRATION.md §3](INTEGRATION.md#3-mkconfig-slots-and-params).

```gdscript
const SETTINGS_SERVICE_NAME := "MKSettingsService"
const SETTINGS_SERVICE_PATH := "/root/MKSettingsService"

func validate() -> PackedStringArray                 # empty == valid; reports EVERYTHING at once
func get_visible_pages() -> Array[MKMenuPageDef]     # stable-sorted by `order`
func get_page(id: StringName) -> MKMenuPageDef
func creation_diagnostics() -> String
```

`SETTINGS_SERVICE_NAME` / `_PATH` are the one place the autoload name is written down — three runtime
sites resolve it, and a rename reaching only some of them fails **silently** into a second settings
backend over one JSON file plus a second brightness controller.

**Slot absence is never a problem.** What `validate()` reports: a slot whose script does not extend
its base, duplicate or empty page ids, an `initial_page` naming nothing, a palette failing its own
validation, a `backdrop_id` the catalog does not know, and the creation-flow equivalents.

### MKBackendSlot

```gdscript
class_name MKBackendSlot extends Resource

@export var backend_script: Script
@export var params: Dictionary = {}

func is_assigned() -> bool
func validate_against(expected_base: Script) -> String     # "" == valid
```

### MKMenuPageDef

```gdscript
class_name MKMenuPageDef extends Resource

@export var id: StringName = &""     # PUBLIC SURFACE — deep links are written against it
@export var title: String = ""
@export var icon: Texture2D = null
@export var scene: PackedScene = null
@export var visible: bool = true     # false = off the nav bar, still reachable by id
@export var order: int = 0

func is_valid() -> bool
```

### MKBackdropCatalog / MKBackdropDef / MKBackdrop

```gdscript
class_name MKBackdropCatalog extends Resource
@export var backdrops: Array[MKBackdropDef] = []
@export var default_id: StringName = &""
func get_backdrop(id: StringName) -> MKBackdropDef
func get_default() -> MKBackdropDef
func has_backdrop(id: StringName) -> bool          # probes without tripping the miss warning
func get_ids() -> Array[StringName]

class_name MKBackdropDef extends Resource
@export var id, display_name, texture, gradient_top, gradient_bottom, tint, blur_amount, scroll_speed
@export var scene: PackedScene = null              # 3D scene backdrop; wins over texture/gradient
@export var character_mount: StringName = &"CharacterMount"
func is_valid() -> bool
func is_generated() -> bool

class_name MKBackdrop extends Control
func apply_def(def: MKBackdropDef) -> void         # apply_def(null) CLEARS the layer
func apply_from_catalog(catalog: MKBackdropCatalog, id: StringName = &"") -> void
func clear() -> void
func get_active_def() -> MKBackdropDef
func set_character_scene(scene: PackedScene) -> void  # mounts under character_mount; null clears;
                                                      # remembered across backdrop swaps
```

A def carrying `scene` renders that 3D scene fullscreen in a `SubViewport` with its **own
`World3D`** (no light leakage either way); `texture`, the gradient, `tint`, `blur_amount` and
`scroll_speed` are ignored for it. The scene must carry its own `Camera3D` — a cameraless scene is
warned about by def path. `MKRoot.set_backdrop_character(scene)` is the shell-level forwarder, and
any page emitting `selection_changed(entry: Dictionary)` (as `MKCharacterSelect` does) drives it
automatically: the entry's `archetype` id resolves through `MKConfig.archetypes` to that archetype's
`preview_scene`, an unresolvable entry clears the mount.

---

## MKInputGlyphs

`@tool class_name MKInputGlyphs extends Node` — the device-aware prompt vocabulary, plus a tracker
for which device class the player is currently using.

**Text, not textures.** Nothing here loads or draws an image; a prompt is a `String` ("Escape",
"Mouse Left", "A") rendered by whatever `Label` or `Button` you already have.

### Static half (pure; no node required)

```gdscript
static func is_pad_event(event: InputEvent) -> bool
static func event_label(event: InputEvent) -> String
static func key_label(key: InputEventKey) -> String
static func mouse_button_label(index: int) -> String
static func joypad_button_label(index: int) -> String
static func action_label(action: StringName, prefer_pad: bool) -> String
```

`const JOY_BUTTON_NAMES` holds **SDL positions, not the legend printed on the player's pad**:
`JOY_BUTTON_A` is "the bottom face button" — Cross on a PlayStation pad. `Input.get_joy_button_string`
is preferred where available precisely because it can do better; it does not exist on Godot 4.7, so
every shipped pad label comes from this table.

Key bindings are stored by **physical keycode** so they stay under the same finger on an AZERTY
layout, and the label is mapped back through the *active* layout for display.

### Instance half (the tracker)

```gdscript
signal device_class_changed(pad: bool)
const AXIS_DEADZONE := 0.5

func is_pad_active() -> bool
```

It is a Node because `_input` requires one, and it is **not an autoload**: whoever needs device
tracking instantiates one and owns it. One per screen is the intended density.
`device_class_changed` fires only on a flip, never per event.

**This class never marks an event handled.** It observes.

### The dispatch-order contract

`_input` is dispatched in **reverse child order** (last child first), and `set_input_as_handled()`
stops every `_input` consumer that has not yet run for that same event.

> **The OWNER of a tracker guarantees the order by placing it LAST among its siblings.**

There is no flag and no priority number. A tracker placed before a consuming sibling is blind exactly
when it matters most: a device flip *during* a capture (the player putting the keyboard down
mid-prompt, or pressing the pad's reserved B) is consumed by the listening `MKRebindRow`, and the
prompt would keep naming the device that is no longer in hand.
`MKSettingsPanel._place_input_glyphs_last()` is the shipped implementation and runs at the end of
every build, because the natural order **inverts across a rebuild**.

The guarantee is **owner-subtree-relative**: an `_input`-consuming node mounted after the shell at
ancestor level dispatches first and can blind the tracker.

---

## MKFocus

`class_name MKFocus extends RefCounted` — statics only.

```gdscript
const TRAP_META := &"mk_focus_trapped"

static func collect_focusables(root: Node) -> Array[Control]
static func focus_first(root: Node) -> Control
static func link_chain(controls: Array[Control], vertical := true, wrap := true) -> void
static func chain_container(container: Node, vertical := true, wrap := true) -> Array[Control]
static func link_containers(from_container: Node, to_container: Node, vertical := true) -> void
static func trap(root: Node) -> Control
static func release(root: Node) -> void
static func is_within(node: Node, root: Node) -> bool
```

Guarantees:

- **`trap()` wraps focus on BOTH axes** and is safe to call defensively — a second trap is a no-op,
  not a re-grab.
- When every focusable under a modal is **disabled**, `trap()` wires the ring over the disabled set
  rather than returning null. Focus then sits on a control that cannot be activated, but every key
  and stick direction stays inside the modal — which is the property that makes it modal.
- **`release()` must be called on pop.** A control that keeps a trap's wrap-around ring while being
  reused as ordinary page content is a region focus can enter and never leave.
- `collect_focusables` **skips disabled buttons**. So settle selection and every enable flag *before*
  building a focus chain, or the chain wires a ring that steps over buttons about to become live.
  Correspondingly, a rebuild that frees the focused control leaves a null focus owner and a
  keyboard-dead page — recover focus explicitly after a rebuild.

---

## MKPreviewViewport

`class_name MKPreviewViewport extends SubViewportContainer` — a 3D preview slot with drag-spin and
inertia that accepts any host `PackedScene`. No rig, no humanoid assumption: equally a character, a
weapon or a piece of armour.

```gdscript
signal preview_changed()

const PIVOT_NAME := "ContentPivot"
const CAMERA_NAME := "PreviewCamera"
const KEY_LIGHT_NAME := "KeyLight"
const FILL_LIGHT_NAME := "FillLight"
const RIM_LIGHT_NAME := "RimLight"

@export var preview_scene: PackedScene       # setter: set_preview_scene()
@export var use_own_world := true
@export var auto_rotate := true
@export var auto_rotate_speed := 0.3
@export var zoom_min := 1.0
@export var zoom_max := 6.0
@export var zoom_step := 0.5
@export var pitch_min_deg := -20.0
@export var pitch_max_deg := 45.0
@export var drag_sensitivity := 0.01
@export var inertia_damping := 4.0

func set_preview_scene(scene: PackedScene) -> void
func get_content() -> Node3D
func frame_content() -> void
```

The five child names above are a **public surface**; renaming one is a public-surface change.

**Swap semantics.** A swap re-centres on the new content's bounds but **keeps the user's yaw, pitch
and zoom**, so cycling a character list preserves the chosen angle. Only the *first* content fits the
distance. If your content differs in scale by an order of magnitude, or grows meshes after
instancing (an equipped weapon appears, a rig streams in), call `frame_content()` — that is the one
call that refits distance unconditionally.

**`use_own_world` defaults true, and sharing leaks BOTH ways.** This node's key/fill/rim lights would
light the running game, and the game's `WorldEnvironment` and sun would light the preview — so the
same preview looks different over a night map than over a day map, and the game visibly brightens
while a character sheet is open. It is an opt-out precisely because the leak is invisible until
somebody notices the game got brighter. The rig is neutral three-point white with shadows off, so
your material shows as authored; attach your own `WorldEnvironment` to the content scene if you want
mood.

**It deliberately inherits PAUSABLE.** A preview inside a paused page stops spinning, which is the
required behaviour. Setting `PROCESS_MODE_ALWAYS` inside the addon would look like a bug fix and
silently break it — set the mode on **your** instance if you want an always-spinning preview.

---

## MKModalLayer

`class_name MKModalLayer extends Control` — a push/pop modal stack with a scrim and focus
save/restore.

```gdscript
signal modal_pushed(control: Control)
signal modal_popped(control: Control)
signal emptied()

@export var scrim_color := Color(0, 0, 0, 0.6)
@export var scrim_material: Material
@export var modal_z_index := 128

func push_modal(control: Control) -> void
func pop_modal() -> void
func remove_modal(control: Control) -> bool
func has_modal(control: Control) -> bool
func reap_modal(control: Control) -> void      # DESTROYS — always call deferred
func clear_for_teardown() -> void
func pop_all() -> void
func depth() -> int
func is_empty() -> bool
func top() -> Control
func handle_cancel() -> bool
```

**Ownership rules — do not confuse these.**

| Call | Ownership |
|---|---|
| `pop_modal` / `remove_modal` | Returns the control to whoever pushed it. A cached dialog can be reused. |
| `reap_modal` | **DESTROYS** it. Only for resolved corpses whose owner is already dead. |

```gdscript
layer.call_deferred(&"reap_modal", dialog)   # the deferral IS the mechanism
```

Deferring is what lets the two teardown shapes distinguish themselves: "the shell was destroyed with
the dialog still stacked" versus "only the owner died".

**Never reach around the layer.** Reparenting and freeing a stacked modal directly leaves the entry
in the stack — `is_empty()` reports false forever, the scrim stays up over nothing, and `MKRoot`
swallows every cancel gesture from then on.

**Two optional methods on a modal:**

```gdscript
func handle_cancel() -> bool      # true = keep the gesture and stay open
func _mk_layer_teardown() -> void # called during clear_for_teardown(), which emits no modal_popped
```

### MKConfirmDialog

`class_name MKConfirmDialog extends Control` — the generic 2–3 button modal.

```gdscript
signal confirmed()
signal cancelled()
signal alternate()

static func open(layer: MKModalLayer, title: String, body: String,
		confirm_text := "Confirm", cancel_text := "Cancel",
		destructive := false, alt_text := "") -> MKConfirmDialog

func get_default_focus_button() -> Button
func get_confirm_button() -> Button
func get_cancel_button() -> Button
func set_body(text: String) -> void
func handle_cancel() -> bool
```

```gdscript
var dialog := MKConfirmDialog.open(root.get_modal_layer(),
	"Delete character?", "This cannot be undone.", "Delete", "Cancel", true)
if dialog != null:
	dialog.confirmed.connect(_on_delete_confirmed)
```

- A dialog opened with `open()` **frees itself when popped** — you never own cleanup. One built with
  `.new()` and pushed yourself stays yours.
- `open()` returns **null** when `layer` is null, and disposes of the instance rather than handing
  back an unparented orphan.
- `destructive` styles Confirm with `MKTheme.DANGER_BUTTON` **and reorders the row** so the dialog
  opens focused on Cancel. Focus is decided by **button order**, because every focus route into a
  modal takes the first focusable in tree order. One consequence: Confirm's screen position differs
  between the two shapes (`Cancel | Delete` vs `Confirm | Cancel`).
- `alt_text` adds the third button; empty means a 2-button dialog.

---

## MKLog

`class_name MKLog extends RefCounted` — leveled logging with a verbose toggle
(`MKConfig.verbose`, or the `--mk-verbose` switch, which forces it on regardless).

```gdscript
enum Level { ERROR, WARN, INFO, DEBUG }
const PREFIX := "[MenuKit]"

static var observer: Callable                      # default: an empty Callable

static func error(message: String) -> void
static func warn(message: String) -> void
static func info(message: String) -> void
static func debug(message: String) -> void
static func is_verbose() -> bool
static func context(res, field := "") -> String    # "<resource path>[: field]"
```

**Every misconfiguration message names the offending resource path AND field** via `context()`, never
a bare "invalid setting".

**`MKLog.observer` is a testing seam, not a host feature.** Several MenuKit contracts are stated as
*counts of warnings* ("the shipped default pages build with zero warnings", "a panel with no backend
warns once for the page, not once per row"), and none is assertable without an observation point.
`debug` reaches the observer even when `verbose` is false, deliberately: some behaviours are *defined*
as "the panel keeps the widget as it is and says so", and the saying-so is the assertable half. The
default is an empty `Callable`, so nothing shipped pays for it and no host is expected to set it.

Policy: **warn, do not crash, on recoverable misconfiguration** (missing audio bus, absent InputMap
action, skipped CUSTOM row); crash loudly only on contract violations (duplicate creation payload
keys, a backend script that does not extend its base).

---

## MKJsonCodec

`class_name MKJsonCodec extends RefCounted` — the persisted-JSON type envelope **and the shared
atomic write**, both used by both shipped JSON backends.

```gdscript
const TYPE_TAG := "__mk_type"
const TYPE_PAYLOAD := "v"
const TAG_VECTOR2I := "Vector2i"
const TAG_INT := "int"

static func encode_value(value: Variant, envelope_ints: bool) -> Variant
static func decode_value(value: Variant, context := "") -> Variant
static func write_atomic(path: String, text: String) -> Error
```

The envelope is `{"__mk_type": "<type name>", "v": <payload>}`.

`write_atomic()` writes to a sibling `.tmp` and renames it over `path`, so an interrupted write
leaves the previous good file rather than a truncated one — the corruption both load paths would
otherwise have to quarantine. It returns `OK` or the failing `Error` and **logs nothing**: each
backend words its own failure. On a rename failure the `.tmp` is deliberately left in place (it holds
the only copy of the new data; the target still holds the last good one). Both shipped stores go
through it — a store of your own that writes `user://` should too.

**The envelope is a format surface with a versioning rule.** Adding a tag is *additive* (an old
reader meets an unknown tag as a plain dictionary, exactly as it already treated any object it did
not recognise). **Renaming or repurposing one is Breaking** and belongs in the CHANGELOG as such,
because files already on users' disks carry the old spelling.

**Decoding is deliberately tolerant of BOTH tags regardless of which backend is reading** — the bytes
on disk are the authority, not the flag the caller passes. That is what lets a file written by one
configuration be read by another with no migration step.

The `envelope_ints` split: `MKJsonSettingsBackend` passes `false` (its format predates the int
envelope and every application site coerces with an explicit `int(...)`, so enveloping would change
bytes for no behavioural gain and make every already-written file a mixed-format file);
`MKJsonProfileBackend` passes `true` (its payloads are opaque **host** dictionaries stored and handed
back verbatim, so MenuKit cannot know which fields are meant to be ints and cannot coerce at the read
site — the only alternative to int fidelity would be a silent lossy conversion of your data).

`__mk_type` carries the `__mk_` prefix so it cannot collide with a host payload field by accident,
and it is a **reserved namespace**: `MKJsonProfileBackend.create_profile` recursively refuses a
payload spelling it, with a warning naming the path.

---

## MKVersion

```gdscript
class_name MKVersion extends RefCounted

const VERSION := "0.2.0"
const MIN_GODOT := "4.7"

static func version_string() -> String
```

`MKVersion.VERSION` is the single source of truth, mirrored into `plugin.cfg`. Every release is a git
tag plus a CHANGELOG entry.

---

## Other public types

Documented in their own docs, listed here for completeness:

| Type | Doc |
|---|---|
| `MKPalette`, `MKTheme`, `MKThemeGenerator` | [THEMING.md](THEMING.md) |
| `MKSettingDef`, `MKSettingsPageDef`, `MKSettingsPanel`, `MKRebindRow`, `MKRevertCountdown`, `MKExampleCustomRow` | [SETTINGS_SCHEMA.md](SETTINGS_SCHEMA.md) |
| `MKCreationHost`, `MKCreationStepDef`, `MKArchetype`, `MKStatSchema`, `MKStatDef`, `MKStepName`, `MKStepArchetype`, `MKStepAppearance`, `MKStepPointbuy` | [CREATION_STEPS.md](CREATION_STEPS.md) |
| `MKPauseMenu`, `MKCharacterSelect`, `MKCharacterCreate`, `MKServerBrowser` | [INTEGRATION.md](INTEGRATION.md) |
| `MKWelcomePage`, `MKNavBar` | Shell furniture `MKRoot` builds and drives itself — their class docs in source are the reference; hosts configure them only through `MKConfig` (`pages`, titles, order) |
