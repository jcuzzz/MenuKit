# Changelog

All notable changes to MenuKit are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What counts as Breaking.** Any change to a backend method signature, an exported `Resource` field
name, a `Theme` type-variation name, a `MKMenuPageDef.id` the shipped configs rely on, a `RowType`
enum value, or a persisted JSON key. Those are exactly the surfaces host game code and users'
existing files are written against. Adding a JSON envelope tag is additive, not Breaking; renaming or
repurposing one is Breaking.

---

## [Unreleased]

### Added

- **3D scene backdrops** — `MKBackdropDef.scene` (`PackedScene`) renders fullscreen in a
  `SubViewport` with its own `World3D`; when set it wins over the texture/gradient path outright.
  `MKBackdropDef.character_mount` (default `&"CharacterMount"`) names the node
  `MKBackdrop.set_character_scene()` mounts a character under — the ARPG main-menu shape: the whole
  screen is the viewport and the selected character stands in the data-driven scene. The scene must
  carry its own `Camera3D` (warned by def path otherwise). Additive: existing texture/gradient defs
  are byte-identical in behaviour.
- **`MKCharacterSelect.selection_changed(entry)`** — id-gated selection announcement (`{}` = an
  emptied roster). `MKRoot` connects it duck-typed on any shown page and resolves
  `entry.archetype` → `MKConfig.archetypes` → `preview_scene` into the backdrop mount;
  `MKRoot.set_backdrop_character(scene)` is the direct seam.
- The demo now ships a 3D menu backdrop (`demo/backdrops/menu_backdrop_3d.tscn` + catalog); the
  addon's default catalog remains the generated gradient, so a cold drop still references no scene
  asset and stays warning-free.
- **A rigged demo character** — the three demo archetypes now preview as an animated mannequin
  instead of coloured CSG primitives. `demo/characters/UAL2_Standard.glb` is Quaternius' *Universal
  Animation Library 2* (Standard, non-root-motion), **CC0 1.0**, with the pack's `LICENSE.txt`
  beside it; `preview_{vanguard,arcanist,scout}.tscn` are three scriptless scenes over that one
  asset, each autoplaying `Idle_FoldArms` under a different body tint (the purple joint bands are
  deliberately left the pack's shared accent on every archetype — only the body surface is
  tinted). The `.glb` is **~8 MB** because it carries the whole 43-animation library and the demo
  plays one idle — accepted rather than re-exported. `demo/backdrops/menu_backdrop_3d.tscn`'s `CharacterMount` moved from `y = 0.7`
  to `y = 0.15` (the dais top) because the rig is feet-origin, not centre-origin. Demo-only: the
  addon ships no art (D19).

## [0.1.0] — 2026-08-08

First release. Everything is new, so the sections below summarise rather than enumerate.

### Added

- **Shell** — `MKRoot` (`mk_root.tscn`): data-driven nav bar from `MKConfig.pages`, page state
  machine, back stack, cancel/ESC precedence ladder (rebind capture → modal stack → back stack →
  pause rung → root quit-confirm), mouse-mode depth counting, audio hook points,
  `dump_diagnostics()`.
- **Theming** — `MKPalette` → `MKThemeGenerator` → runtime `Theme`, the nine-name `MKTheme` type
  variation vocabulary, generated CheckBox glyphs, an editor theme-bake tool menu entry. Zero
  `add_theme_*_override` calls in the addon, enforced by an automated isolation check.
- **Modals** — `MKModalLayer` (push/pop stack, scrim, focus save/restore that tolerates the
  remembered control having been freed) and `MKConfirmDialog` (2–3 buttons, destructive styling and
  focus reorder).
- **Backends** — five abstract extension points (`MKMenuBackend`, `MKProfileBackend`,
  `MKSettingsBackend`, `MKNetworkBackend`, `MKPausePolicy`) with six shipped defaults
  (`MKSceneMenuBackend`, `MKJsonProfileBackend`, `MKJsonSettingsBackend`, `MKStubNetworkBackend`,
  `MKTreePausePolicy`, `MKNoPausePolicy`), the `MKBackendSlot` + `_mk_configure(params)` convention,
  and warnings by name for unclaimed params.
- **Settings service** — the optional `MKSettingsService` autoload, the `menu_kit/config_path`
  project setting, and the documented no-autoload manual path.
- **Settings** — `MKSettingDef` / `MKSettingsPageDef` schema resources, seven row types, engine
  application of the reserved video/audio ids, `MKBrightnessController` (overlay and environment
  modes), the D14 confirm-or-revert countdown, `visible_condition_id`, and a shipped `CUSTOM` row
  reference implementation.
- **Rebinding** — `MKRebindRow` capture with per-device abort, reserved events derived from the
  boot-default non-keyboard `ui_cancel` bindings plus `extra_reserved_events`, the conflict modal
  (Replace / Keep both / Cancel), per-action and global reset-to-defaults, persistence by physical
  keycode.
- **Profiles and creation** — `MKCharacterSelect`, `MKCharacterCreate`, `MKCreationHost` with a
  four-method step contract, the Name / Archetype / Appearance steps, and a point-buy step
  (`MKStatSchema` / `MKStatDef`) shipped **disabled by default**.
- **3D preview** — `MKPreviewViewport`: own-world rendering by default, neutral three-point rig,
  drag-spin with inertia, zoom, and content-bounds framing.
- **Pause** — `MKPauseMenu` as a page (never a second shell), `MKRoot.open/close_pause_menu()`, the
  pause-policy seam, hide-is-close, and `pause_menu_toggled` for host camera gating.
- **Server browser** — `MKServerBrowser` with connect-state UI; hidden entirely when the network slot
  is unassigned, which is the shipped default.
- **Diagnostics** — `MKLog` (error/warn/info/debug, `--mk-verbose`, resource-path-and-field context),
  `MKConfig.validate()` reporting every problem at once, `MKVersion`.
- **Demo** — a full host integration under `demo/`: main menu, four settings pages, three archetypes
  with preview scenes, a point-buy schema, a grey-box first-person game scene with the complete ESC
  flow, and an alternate palette proving the re-skin.
- **Tooling** — `tools/check.ps1` (headless compile gate, `-Smokes` for the isolated test suite,
  plus `-Isolation` and `-NoImport`), `tools/capture_scene.ps1` with capture rigs.

### Persisted formats — initial statement

These formats ship for the first time at `0.1.0`. Everything below is the **initial** shape; from
here on, any change to it is Breaking and will say so.

- **Settings store** (`user://menukit_settings.json`, `version: 1`): `{version, values, input}`.
  `values` envelopes **`Vector2i` only** — plain JSON numbers read back as floats, and every
  application site coerces explicitly.
- **Input event dictionaries** carry a **`device` field**, and **absent means `-1`** (all devices).
  It is written explicitly because `InputEvent`'s per-class default is not -1
  (`InputEventJoypadButton` 0, `InputEventKey` 16, `InputEventMouseButton` 32), and omitting it would
  silently narrow a pad binding to controller 0. Four event types are carriable: `key`,
  `mouse_button`, `joypad_button`, `joypad_motion`.
- **JSON type envelope**: `{"__mk_type": "<type name>", "v": <payload>}`, with tags `Vector2i` and
  `int`. **Decoding tolerates every known tag regardless of which backend reads the file** — the
  bytes on disk are the authority.
- **`__mk_type` is a reserved namespace.** A creation payload may not spell it at any depth;
  `MKJsonProfileBackend.create_profile` refuses such a payload with a warning naming the path,
  because accepting it would write a file whose load quarantines the whole roster.
- **Profile store** (`user://menukit_profiles.json`, `version: 1`): `{version, next_id, profiles}`.
  This backend envelopes **ints as well as `Vector2i`**, because a profile payload is opaque host
  data it cannot coerce at the read site. Ids are minted `p_000001`, monotonic, never reissued after
  a delete.
- **Profile names are normalised: stored trimmed.** The uniqueness rule is checked against the
  trimmed value, so storing the raw payload would make the rule bypassable by whitespace.
- **Newer-store read-only latch.** A profile store whose `version` exceeds this build's schema is
  left byte-identical and the backend latches read-only against it (creates return `{}`, deletes
  return `false`), with one warning naming both versions. The latch follows the file: replace it and
  writes resume. The settings backend deliberately takes the opposite position — a settings value is
  an annoyance to lose, a roster is not.
- **Corruption policy.** An unparseable or wrong-shaped store is renamed aside to
  `<name>.corrupt-<n>.json` and defaults boot with one warning. **Nothing is ever deleted.**
- **Settings are flushed on exit** — `MKSettingsService._exit_tree()` on the autoload tier, or
  `MKRoot._exit_tree()` on the standalone tier. **A crash or `OS.kill` loses that session's writes.**
  Call `MKSettingsBackend.save()` yourself wherever a hard flush matters.

### Known limitations

Documented properties of `0.1.0`, not open defects:

- **Gamepad button labels are SDL positions, not the legend on the player's pad.**
  `Input.get_joy_button_string` does not exist on Godot 4.7, so every label comes from the positional
  table — a DualShock shows "B" for Circle.
- **Editor-side behaviour is unverified by the automated suite** (plugin enable/disable cycle, the
  theme bake). Both need an interactive editor session.
- **Two simultaneous service-less shells stack two gamma passes.** No shipped configuration mounts
  that shape; a host running it owns brightness itself or mounts the settings service.
- **The settings-service adopt path ignores a slot's `params`** (the instance already exists).
  Configure the service's slot instead; the omission is noted at debug level.
- **Quit to Menu runs the world for the remainder of that frame** — the pause state is closed before
  the backend's deferred scene change, which is mandatory for a backend that swaps no scene.
- **Reparenting a live `MKRoot` is unsupported**: `_exit_tree()` discards pause and nav state with no
  signal. Close the pause menu first.
- **Assigning `MKRoot.config` at runtime does nothing.** Swapping `MKConfig.palette` is supported.
- **`MKPalette.font_size_title` is generated but unconsumed** by any shipped control. (`scrim` is
  read: `MKRoot` drives the shell-owned `MKModalLayer` from it at build and on every palette swap; a
  host-owned `MKModalLayer` keeps its own exported `scrim_color`.)
- **The `MKInputGlyphs` dispatch guarantee is owner-subtree-relative**: an `_input`-consuming node
  mounted after the shell at ancestor level dispatches first and can blind the device tracker. No
  shipped node does this.
- **`_events_match` cost**: a stored physical-only event and a stored keycode-only event for the same
  key never match. Unreachable through shipped paths (captured events carry both codes); reachable
  for a host seeding keycode-only events through `set_action_events`.
- **Point-buy restore honours per-stat ranges but not the pool.** An over-pool restored payload
  renders a negative remaining; the validity gate holds, so it cannot be confirmed.
- **`MKCreationHost` has no `step_changed` signal.** A step needing to read payload state after bind
  hooks `visibility_changed`, as the shipped appearance step does.
- **`MKServerBrowser` selects row 0 when re-entered mid-connect**, not the in-flight server. Connect
  is disabled meanwhile, so no mis-connect is possible.
- **Two shipped scenes are unreferenced** (`mk_modal_layer.tscn`, `mk_confirm_dialog.tscn`) — both
  types are built in code; the scenes are authoring conveniences.
- **Some cosmetic alignment drift remains**: rebind buttons' left edges are ragged against the
  slider/enum control column, and empty-roster copy is centred while roster cards left-align.

[0.1.0]: #010--2026-08-08
