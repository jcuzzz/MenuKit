# MenuKit

**A modular, fully re-skinnable menu framework for Godot 4.7.**

MenuKit gives a game everything between the splash screen and gameplay: a themed shell with
data-driven navigation, a settings menu that builds itself from resources, full input rebinding with
conflict detection, a character select/create flow with pluggable steps, a pause menu that actually
handles the pause, and an optional server browser.

Everything that touches your game — starting a match, saving a character, pausing the world — goes
through a **backend you supply**. MenuKit ships working defaults for every one of them, so it runs
before you have written any.

Version **0.1.0** · Godot **4.7** · Plugin folder `addons/menu_kit/`, class prefix `MK`.

---

## Features

- **Menu shell** — data-driven nav bar, page state machine, back stack, and a cancel/ESC precedence
  ladder that resolves rebind capture → modals → back stack → pause → quit-confirm.
- **Theming** — one `MKPalette` resource generates the whole `Theme` at runtime. Zero
  `add_theme_*_override` calls anywhere in the addon, which is what makes a palette swap actually
  re-skin every panel. CheckBox glyphs are rasterised from palette colours, so no image ships.
- **Settings** — pages and rows are `.tres` resources; seven row types including a `CUSTOM` escape
  hatch. Instant apply, plus a confirm-or-revert countdown for display changes that could leave the
  player unable to see the screen.
- **Rebinding** — capture widget, conflict modal with Replace / Keep both / Cancel, per-device abort,
  reserved events, reset-to-defaults, persistence by physical keycode.
- **Profiles + creation** — an opaque-dictionary roster behind `MKProfileBackend`, plus a creation
  host running reorderable steps over one shared payload. Name / Archetype / Appearance ship;
  point-buy ships **disabled by default**.
- **3D preview slot** — a `SubViewport` host with drag-spin and inertia that accepts any
  `PackedScene`. No rig, no humanoid assumption — equally a character, a weapon or a helmet.
- **Pause menu** — the same shell, page-based, with pause-policy abstraction. `MKTreePausePolicy`
  freezes the world; `MKNoPausePolicy` is the multiplayer answer where the menu opens over a live
  world.
- **Server browser** — optional, behind `MKNetworkBackend`. An unassigned slot hides the page
  entirely.
- **Diagnostics** — `MKLog` with a `--mk-verbose` switch, every misconfiguration message naming its
  resource path and field, and `MKRoot.dump_diagnostics()` as a one-call bug-report surface.
- **Gamepad and keyboard first** — every screen is completable with a pad alone and with a keyboard
  alone.
- **Headless test suite** under `tests/`, run against an isolated `user://` profile.

---

## Quickstart

**1.** Copy `addons/menu_kit/` into your project.

**2.** Enable **MenuKit** in *Project → Project Settings → Plugins*. This registers the
`menu_kit/config_path` setting, the `MKSettingsService` autoload, and a theme-bake tool menu entry.

**3.** Instance `res://addons/menu_kit/core/mk_root.tscn` in your menu scene and run.

That is a working, themed, persistent menu with a settings page and a character roster. To make it
yours: duplicate `addons/menu_kit/default_config.tres` into your own folder, point the shell's
`config` at your copy, and start filling in slots and pages —
see **[docs/INTEGRATION.md](docs/INTEGRATION.md)**.

---

## Running the demo

Open this repository in Godot 4.7 and press **F5** (main scene `res://demo/demo_main.tscn`).

The demo is a full integration, not a showcase: everything under `demo/` is host code, reaching
MenuKit only through configs and backends.

| Page | What it demonstrates |
|---|---|
| **Play** | A host-authored page and `MKSceneMenuBackend` starting the demo game scene |
| **Characters** | The roster: create, select, delete, with the confirm dialog |
| **Settings** | Video / Audio / Gameplay / Controls — every row type, the rebind flow, the D14 revert countdown, the brightness slider, and a live `CUSTOM` row |
| **Servers** | The server browser against `MKStubNetworkBackend`: refresh, connect, cancel, failure and timeout states |
| **Credits** | A second host page, plus a hidden "sub" page reachable only by `push_page` |

Press **Play** to enter the grey-box first-person demo game (WASD + mouse). **Escape** opens the
pause menu over the paused world — settings opened from there write the same store as the main menu,
and the revert countdown keeps ticking under the pause.

---

## Documentation

| Doc | For |
|---|---|
| **[docs/INTEGRATION.md](docs/INTEGRATION.md)** | Install, the three integration tiers, config and slots, a complete custom-backend example, the pause contract, limitations |
| **[docs/API.md](docs/API.md)** | Every public class, signature and signal |
| **[docs/THEMING.md](docs/THEMING.md)** | Palette → Theme, the type-variation vocabulary, re-skinning |
| **[docs/SETTINGS_SCHEMA.md](docs/SETTINGS_SCHEMA.md)** | Authoring settings pages and rows; rebinding; the persisted JSON formats |
| **[docs/CREATION_STEPS.md](docs/CREATION_STEPS.md)** | The step contract, payload ownership, point-buy, extending a step |
| **[docs/DECISIONS.md](docs/DECISIONS.md)** | The `D`-id glossary used throughout the source comments |
| **[CHANGELOG.md](CHANGELOG.md)** | Release history, initial persisted-format statement, known limitations |

---

## Assets and rights

**The addon ships no third-party assets** (`addons/menu_kit/` — the part you drop into your game).
No fonts, no audio files, no images, no icons — the default backdrop is a generated gradient, the
CheckBox glyph is rasterised from the palette at runtime, and input prompts are text rather than
keycap art. `MKPalette.font` and the four `*_sfx` exports on `MKRoot` are the documented swap
points for supplying your own. The **demo** carries one exception under decision D19: the rigged
demo character `demo/characters/UAL2_Standard.glb` (Quaternius Universal Animation Library 2,
**CC0 1.0**), with the pack's `LICENSE.txt` beside it — demo-only, deletable with the folder, and
never referenced from the addon.

**No repository-level `LICENSE` file ships** (decision D15; the CC0 file above covers only the
demo character asset): this is a private handoff for production use, not an
asset-store listing, and rights are a matter between the parties. One consequence worth stating
plainly: **with no written terms, code shipping inside a commercial product has no recorded answer to
who may reuse it.** If either party wants one, adding a `LICENSE` file is a one-commit change — and
it should happen **before this package is distributed to anyone beyond the original engagement.**
