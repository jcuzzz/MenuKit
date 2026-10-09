# Decision glossary

MenuKit's source comments cite decisions by id (`D14`, `D17`, …). This is the glossary. Each entry is
one line of what the id means; the docs linked in the right column carry the behaviour.

The ids are stable — they are how a comment names a constraint without restating it — so treat a
change to what an id *means* as a documentation break.

| Id | Decision | Where it shows |
|---|---|---|
| **D1** | Scope: menu shell + nav + theme + modal layer, settings, character select/create, pause menu — with character creation maximally modular. | [INTEGRATION.md](INTEGRATION.md) |
| **D2** | Delivery: a standalone runnable demo project **plus** an `addons/menu_kit/` folder that is independently copyable. | [README.md](../README.md) |
| **D3** | Game-state coupling: abstract backend interfaces with shipped working defaults, and **no autoload requirement** on the host. | [INTEGRATION.md §2](INTEGRATION.md#2-the-three-integration-tiers) |
| **D4** | Visual direction: neutral and fully re-skinnable via `MKPalette` → generated `Theme`; no game art. | [THEMING.md](THEMING.md) |
| **D5** | Settings modularity: data-driven schema resources — the panel builds itself from `.tres`, so adding a row is never an addon edit. | [SETTINGS_SCHEMA.md](SETTINGS_SCHEMA.md) |
| **D6** | Creation modularity: schema-driven pluggable steps, reorderable and extensible by resource. | [CREATION_STEPS.md](CREATION_STEPS.md) |
| **D7** | Multiplayer panel: included, optional, behind an `MKNetworkBackend` abstraction; an unassigned slot hides it entirely. | [API.md § MKNetworkBackend](API.md#mknetworkbackend) |
| **D8** | Repo: MenuKit lives in its own repository with its own history. | — |
| **D9** | Engine target: **Godot 4.7**. | [README.md](../README.md) |
| **D10** | Input rebinding: a full rebind UI with conflict detection, not a value list. | [SETTINGS_SCHEMA.md §4](SETTINGS_SCHEMA.md#4-keybind-rows) |
| **D11** | Persistence: JSON under `user://`. | [SETTINGS_SCHEMA.md §7](SETTINGS_SCHEMA.md#7-persisted-formats) |
| **D12** | Gamepad: full focus-based controller navigation — every screen completable with a pad alone. | [API.md § MKFocus](API.md#mkfocus) |
| **D13** | 3D preview: an optional preview **slot**, no rig — a `SubViewport` host with drag-spin/inertia accepting any host `PackedScene`. No character-model or humanoid assumption. | [API.md § MKPreviewViewport](API.md#mkpreviewviewport) |
| **D14** | Settings apply model: **instant apply**, plus a confirm-or-revert countdown for window mode and resolution. Unconfirmed means not kept. | [SETTINGS_SCHEMA.md §6](SETTINGS_SCHEMA.md#6-requires_confirm--the-d14-flow) |
| **D15** | *Superseded by D21.* Distribution & rights: originally a private handoff — no `LICENSE` file shipped. | — |
| **D16** | Production hardening: an automated headless test suite, versioned releases with CHANGELOG discipline, and diagnostics affordances (`MKLog`, `dump_diagnostics()`). | [API.md § MKLog](API.md#mklog) |
| **D17** | Point-buy step: **built and shipped, disabled by default**. MenuKit owns allocation, validation and confirm-gating only — never the meaning of a stat. | [CREATION_STEPS.md §5](CREATION_STEPS.md#5-point-buy) |
| **D18** | Package name: `MenuKit`; folder `addons/menu_kit/`; class prefix `MK` on every `class_name` in the addon, to avoid host collisions. | [API.md](API.md) |
| **D19** | Art carve-out, successor to D15 and narrow: the **demo** may ship CC0 art, carrying the pack's own license file beside the asset. The **addon** never ships any — a cold drop stays asset-free and the isolation gate keeps proving it. | [../demo/characters/LICENSE.txt](../demo/characters/LICENSE.txt) |
| **D20** | C# hosts get **adapter backends, not a port**: five GDScript adapters forwarding to a host-supplied node. Godot forbids a C# class extending a GDScript one, and loosening `MKBackendSlot.validate_against` would trade a compile-time contract for a runtime surprise; a full C# port would fork the package for every GDScript host. The five adapters are 47/49/61/82/191 lines (menu, pause, profile, network, settings — the settings one carries the boot-order self-heal) over a 348-line shared `MKCSharpDelegate`; they keep one implementation of every behaviour and ship no `.cs`. | [INTEGRATION.md §10](INTEGRATION.md#10-c-hosts) |
| **D21** | Distribution: **MIT open source**, superseding D15. The root `LICENSE` and the addon's own copy `addons/menu_kit/LICENSE.md` are identical, so a copied addon folder carries its terms. D19 stands: the addon ships no third-party assets; the demo's CC0 asset keeps its own license file. | [../LICENSE](../LICENSE) |

## Adopted defaults

Not numbered decisions, but they are cited in comments the same way and are part of the shipped
contract:

- **No bundled fonts and no bundled audio** — licensing. `MKPalette.font` and `MKRoot`'s four
  `*_sfx` exports are the documented swap points.
- **Reference resolution 1920×1080**, `content_scale_mode = canvas_items`,
  `content_scale_aspect = expand` — documented so a host can change it.

## Test-side ids

`tests/test_creation_host.gd` carries a `F8_NOISE` constant. `F8` is a build-time finding id, not a
host-facing decision: it names the archetype-default / step-ownership exclusion rule described in
[CREATION_STEPS.md §4](CREATION_STEPS.md#archetype-defaults-and-merge-order). No shipped addon file
references it.
