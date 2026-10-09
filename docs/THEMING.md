# Theming MenuKit

MenuKit is re-skinned by swapping **one resource**: an `MKPalette`. Every panel, row, dialog, tab and
focus ring reads its look from a `Theme` generated from that palette at runtime. There are no
per-panel edits, and there is no theme file you have to keep in sync.

---

## 1. The mechanism

```
MKPalette  ──MKThemeGenerator.build()──▶  Theme  ──assigned to MKRoot──▶  every descendant Control
```

`MKRoot._ready()` generates the `Theme` from `MKConfig.palette` and assigns it to itself. Godot
propagates a `Theme` down the whole `Control` subtree, so every panel MenuKit builds — and every host
page under the shell — is styled without touching it.

The editor's **Project → Tools → Bake MenuKit Theme** entry writes the same generated `Theme` to
`res://addons/menu_kit/themes/generated_theme.tres` purely so panel scenes are not unstyled while you
author them. The artifact is gitignored, it is never the source of truth, and deleting it changes
nothing at runtime.

---

## 2. `MKPalette` fields

Field **names** are a published contract — a host's alternate palettes are written against them, so a
rename is a **Breaking** CHANGELOG entry. A field earns its place only if more than one control reads
it, or if a re-skinner would obviously reach for it.

**Surfaces**

| Field | Reads as |
|---|---|
| `background` | The page/backdrop base plane |
| `surface` | Panel bodies |
| `surface_raised` | Buttons, raised rows, the active nav tab |
| `surface_sunken` | Sliders' groove, text fields, scrollbar troughs |

**Lines**

| Field | Reads as |
|---|---|
| `border` | Every resting border |
| `border_focus` | The focused border and the focus ring |

**Text**

| Field | Reads as |
|---|---|
| `text` | Body copy |
| `text_bright` | Headers, emphasised values |
| `text_dim` | Secondary copy, hints |
| `text_disabled` | Disabled controls |

**Accent** — `accent`, `accent_hover`, `accent_pressed`, `accent_text` (the foreground *on* accent).

**Danger** — `danger`, `danger_hover`, `danger_pressed`, `danger_text`. Used by the
`MKDangerButton` variation, so a delete and a quit never look like an OK.

**Overlay** — `scrim`. Not a `Theme` item (the modal layer draws a plain `ColorRect`), so `MKRoot`
drives it directly: the **shell-owned** `MKModalLayer` takes `palette.scrim` when the shell is built
and again on every palette swap. A `MKModalLayer` you mount yourself is untouched and keeps its own
exported `scrim_color`.

**Metrics** — `corner_radius` (0–32), `border_width` (0–8), `focus_width` (0–8).

**Spacing** — `spacing_xs`, `spacing_sm`, `spacing_md`, `spacing_lg` (each 0–64). These drive the
generated StyleBoxes' content margins, so they change *layout density*, not just colour.

**Typography** — `font` (a `Font`, null = Godot's default; MenuKit bundles no font for licensing
reasons), plus `font_size_small`, `font_size_normal`, `font_size_header`, `font_size_title`.

`MKPalette.get_validation_problems() -> PackedStringArray` and `validate() -> bool` report a palette
that cannot produce a usable theme; `MKConfig.validate()` folds the result in.

### Known holes

- **`font_size_title` is generated but unconsumed** by any shipped control.

---

## 3. The type-variation vocabulary

The second published name vocabulary. These are `theme_type_variation` names; renaming one is
**Breaking**. `MKTheme.VARIATION_BASE` is the authoritative map, and it is the whole list:

| Constant | Name | Base type |
|---|---|---|
| `MKTheme.NAV_TAB` | `MKNavTab` | `Button` |
| `MKTheme.NAV_TAB_ACTIVE` | `MKNavTabActive` | `Button` |
| `MKTheme.PANEL_BUTTON` | `MKPanelButton` | `Button` |
| `MKTheme.PRIMARY_BUTTON` | `MKPrimaryButton` | `Button` |
| `MKTheme.DANGER_BUTTON` | `MKDangerButton` | `Button` |
| `MKTheme.PANEL` | `MKPanel` | `PanelContainer` |
| `MKTheme.FOCUS_RING` | `MKFocusRing` | `Panel` |
| `MKTheme.HEADER` | `MKHeader` | `Label` |
| `MKTheme.ROW_LABEL` | `MKRowLabel` | `Label` |

Apply one through the helper, never by assigning the property directly — the helper validates the
name against the vocabulary and warns on an unknown one:

```gdscript
MKTheme.set_variation(my_button, MKTheme.PRIMARY_BUTTON)

# Dynamic state is a variation SWAP, never a StyleBox written onto the control:
MKTheme.set_variation_if(tab, is_active, MKTheme.NAV_TAB_ACTIVE, MKTheme.NAV_TAB)
```

Two audit helpers exist for host validation: `MKTheme.theme_defines_all(theme)` (every variation is
both registered *and* actually styled — registration alone is not styling) and
`MKTheme.variation_is_styled(theme, variation)`.

Base engine types the generator styles directly, so plain controls need no variation at all:
`Button`, `Label`, `PanelContainer`/`Panel`, `LineEdit`, `HSlider`/`VSlider`, `CheckBox`,
`OptionButton`, `SpinBox` (through its internal `LineEdit`), scrollbars, `TabContainer`,
`PopupMenu`.

---

## 4. The no-override rule

**MenuKit ships zero `add_theme_*_override` calls, and your skinnable additions should too.**

The reason is mechanical: an override beats the `Theme`. A package that used overrides could never be
re-skinned by swapping an `MKPalette` — the swap would regenerate a `Theme` that the overrides
silently outrank, and the re-theme test would pass for everything except the controls someone
"just quickly fixed". This is enforced by an automated isolation check over `addons/menu_kit/`, and
the rule binds host-facing examples (`MKExampleCustomRow`) exactly as hard as core panels.

The consequence for you: to change a look, change the palette or add a type variation — never write
a colour onto a control.

### Focus, and the one genuine hole

Every focusable control the generator styles carries a `focus` StyleBox with the same content margins
as its own `normal` box: `Button` and its four variations, `OptionButton`, `LineEdit`, and the
`TabContainer` tab strip. `SpinBox` takes focus through its internal `LineEdit`.

`HSlider`/`VSlider` are the exception, and it is the **engine's**: a Slider defines no focus StyleBox
at all, so there is nothing for the generator to write. MenuKit's answer is to parent an
`MKTheme.FOCUS_RING` `Panel` to the control (`MKSettingsPanel` and `MKRebindRow` do this). The ring is
themed and re-skins with everything else.

**If you add a slider-like control, you owe it the same ring.** That is the vocabulary's answer for
any control that cannot own a focus box.

### CheckBox glyphs are generated; CheckButton is not

`CheckBox`'s `checked` / `unchecked` icons (and their `_disabled` variants) are **rasterised from
palette colours at generation time** into `ImageTexture`s. So a palette swap recolours them for free
and no image file ships. The glyph is a fixed 20 px (`MKThemeGenerator.CHECK_ICON_SIZE`) beside
host-raised font sizes — engine-consistent, and accepted.

`CheckButton` is deliberately left on the engine's own art: its icon is a **switch**, a different
shape with different states, and MenuKit does not use it. The `radio_*` icons are likewise untouched,
because a `CheckBox` only draws them when it carries a `ButtonGroup` and no MenuKit row assigns one.

---

## 5. Re-theming at runtime

Two supported gestures:

**Swap the palette on the live config.** `MKConfig.palette` is watched: assigning a new `MKPalette`
regenerates the `Theme` and restyles the whole shell. `MKRoot` also subscribes to the *current*
palette's `Resource.changed`, so editing a palette field in the inspector restyles live, and a swap
unsubscribes the old one.

```gdscript
var alt := load("res://demo/alt_skin/alt_palette.tres") as MKPalette
$MKRoot.config.palette = alt
```

**Edit fields on the palette in place.** Each exported field emits `changed`, so the same
regeneration path runs.

What is **not** supported is assigning `MKRoot.config` itself at runtime — that re-runs nothing,
rebuilds no nav and restyles nothing. Swap the palette, not the config.

If you need the `Theme` for your own controls outside the shell subtree:

```gdscript
var theme := MKThemeGenerator.build(my_palette)
my_control.theme = theme
```

`MKThemeGenerator` also exposes two StyleBox factories so host-authored controls can match the
generated look exactly: `flat(pal, bg, border, border_width, ...)` and
`focus_box(pal, margin_h, margin_v)`.

---

## 6. Worked example — the alt skin

The demo ships a second palette at **`res://demo/alt_skin/alt_palette.tres`**. It exists to prove one
claim: *swapping the palette restyles every panel with no per-panel edit.* That is the re-theme ship
gate, and it is verified rather than asserted.

How to build your own, by mechanism rather than by copying values:

1. **Duplicate the default.** In the FileSystem dock, duplicate
   `res://addons/menu_kit/themes/default_palette.tres` into **your own folder** — never edit the one
   inside `addons/menu_kit/`, or the next addon update overwrites it.
2. **Move the surfaces first.** `background`, `surface`, `surface_raised`, `surface_sunken` establish
   the value structure. Keep them monotonic: sunken darker than surface darker than raised, or the
   generated depth cues invert.
3. **Then the text ramp.** `text_bright` > `text` > `text_dim` > `text_disabled` in contrast against
   `surface`. The CheckBox glyph is rasterised from these, so a text ramp with no contrast produces a
   check mark you cannot see against the panel.
4. **Then accent and danger.** Each is a triple (`_hover` lighter, `_pressed` darker) plus its own
   foreground (`accent_text` / `danger_text`) — the foreground is what keeps a label legible when the
   button fills with the accent.
5. **Then `border_focus`.** This is the single most load-bearing colour for gamepad and keyboard
   navigation: it draws every focus border *and* the `MKFocusRing`. If a skin fails keyboard-only
   traversal, this is almost always why.
6. **Metrics and spacing last.** `corner_radius`, `border_width`, `focus_width` change silhouette;
   the four `spacing_*` values change density and therefore layout.
7. **Verify by swapping, not by screenshotting one panel.** Point `MKConfig.palette` at the new
   resource and walk the whole shell: nav tabs (both states), every settings row type, a rebind row
   mid-capture, a modal + its scrim, the confirm dialog's danger button, character select cards, and
   the creation flow. Anything that did not move is either an override (a bug — see §4) or a colour
   the generator does not read yet (see the known holes in §2).

---

## 7. Backdrops

`MKConfig.backdrop_catalog` + `backdrop_id` select the main-menu backdrop. The catalog is an
**authored array** (`MKBackdropCatalog.backdrops: Array[MKBackdropDef]`) — never a filesystem scan —
so it is export-safe and loads headlessly with no autoload lookup. A miss warns through `MKLog`
naming the resource and field; `has_backdrop(id)` probes without tripping that warning.

An `MKBackdropDef` carries `texture` (optional), `gradient_top`/`gradient_bottom`, `tint`,
`blur_amount` and `scroll_speed`. **A def with no texture renders a generated gradient**, which is
why the shipped catalog references no external image and the addon bundles no art (the demo
carries its own CC0 character asset under decision D19; the addon never references it).

A def may instead carry `scene` (a `PackedScene`): the backdrop then renders that 3D scene
**fullscreen** in a `SubViewport` with its own `World3D`, and every 2D field above is ignored — the
scene owns its look, including its own `Camera3D` (a cameraless scene warns by def path). Its
`character_mount` names the node `MKBackdrop.set_character_scene()` stands a character under; the
shell drives that from any page emitting `selection_changed` (see [API.md](API.md)). The demo's
`demo/backdrops/` pair is the worked example; the addon's default catalog stays a generated
gradient so a cold drop references no scene asset.

`MKBackdrop.apply_def(null)` **clears** the layer — null is not ignored; it is how you turn the
backdrop off (because you supply your own 3D background) through the same call you use to set one.
`MKRoot.show_backdrop = false` does the same declaratively, and is what a pause shell uses.
