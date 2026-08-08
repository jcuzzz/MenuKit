# Plan — Rigged demo character (Quaternius Universal Animation Library, CC0)

**Status:** IMPLEMENTED 2026-08-08 (orchestrated: opus implementation + test legs, fable review).
Rev 2 — the owner redirected the source from KayKit Adventurers to the Quaternius Universal
Animation Library already vetted in the ARPG (2026-08-08). One departure from §4 recorded during
the build: `demo/demo_creation/preview_vanguard.tscn` was RETAINED (not deleted) as
`test_preview_viewport`'s CSG deferred-bounds subject; the other two primitives are gone.
**Written:** 2026-08-08, after the 3D-scene-backdrop slice (`8c02e41`).
**Goal:** the demo's three archetypes preview as a rigged character playing an idle animation —
in the fullscreen 3D menu backdrop AND in the creation flow's `MKPreviewViewport`.

---

## 1. The decision this plan encodes

Use the ARPG's **Quaternius Universal Animation Library** —
`Workingfile\assets\Universal Animation Library 2[Standard]\Unreal-Godot\UAL2_Standard.glb` — a
rigged mannequin whose `.glb` carries the full animation set, idle included. Chosen over
downloading anything new AND over the KayKit pack rev 1 named, because:

- **The license proof ships inside the pack.** `License.txt` beside the asset states CC0 1.0
  Universal with the Quaternius attribution — rev 1's whole Phase 0 research burden is already
  answered on disk; the file just travels with the copy.
- One neutral mannequin fits MenuKit's stance better than five genre-flavoured adventurers: the
  demo demonstrates "a rigged character stands in the scene", not "MenuKit is a fantasy kit"
  (the same argument the shipped neutral archetype makes).
- Already vetted in the owner's Godot 4.7 pipeline; copy direction Workingfile → MenuKit is the
  established one-way port; Workingfile is not modified.

Take the **non-`_RM`** variant (in-place animations — root-motion idles would walk the mannequin
off the dais) from **UAL2** (the newer library), single source. UAL1 stays untouched unless
UAL2's idle reads badly in the capture, which is a probe question, not a plan fork.

**Scope amendment (unchanged from rev 1).** BUILD_HANDOFF §9 / D15: "no third-party art." The
carve-out is deliberate and narrow: the **addon** stays asset-free (cold drop unchanged, the
isolation gate keeps proving it); the **demo** gains CC0 art only — the §3.1 "demo carries the
rich version" pattern. Record as a successor decision in `docs/DECISIONS.md`, in the CHANGELOG
Unreleased block, and amend BUILD_HANDOFF §9's sentence ("demo may carry CC0 art with its
license file; the addon never carries any").

**Known cost, accepted:** the `.glb` is ~8 MB because it carries the whole animation library and
the demo uses one idle. Trimming to an idle-only export needs a Blender pass and a new authored
artifact — out of scope; note the weight in the CHANGELOG line. The Female Mannequin variant
(`Mannequin_F.glb`, 1.4 MB) is mesh-only (no animation library) and is NOT a lighter substitute
by itself; it becomes interesting only if a later slice retargets animations, which this plan
does not do.

## 2. Asset copy

Into `demo/characters/`:

| File | Source |
|---|---|
| `UAL2_Standard.glb` | `Universal Animation Library 2[Standard]\Unreal-Godot\` |
| `LICENSE.txt` | `Universal Animation Library 2[Standard]\License.txt`, copied verbatim |

- **Raw assets only — never `.import` files** (they carry the source project's UIDs/dest paths;
  this project regenerates its own on reimport).
- After copying, one reimport (`check.ps1` triggers it) and confirm the `.glb` loads headless —
  a shipped resource that cannot load headlessly must fail the gate, not a review.
- The mannequin is material-coloured, no external textures — nothing else to carry.

## 3. Preview scenes

Three thin scenes over ONE shared asset, `demo/characters/preview_{vanguard,arcanist,scout}.tscn`,
replacing the CSG primitives as the archetype `preview_scene`s:

- Root `Node3D`; instanced `UAL2_Standard.glb` child; the imported `AnimationPlayer`'s
  `autoplay` set to the idle. **Probe the real animation name first** (open the imported scene or
  list `get_animation_list()` in a throwaway probe — Quaternius names are `Idle_A`-style but the
  import may prefix an `AnimationLibrary`; a wrong autoplay string is silent). Set it as an
  editable-instance override in the `.tscn`, no script.
- **Per-archetype distinction is a material tint**, the role the three cube colours played: an
  editable-instance `material_override` (or surface override) on the mannequin's MeshInstance3D
  path, one `StandardMaterial3D` per scene in the archetype's colour family (red/blue/green as
  the cubes were). If the mannequin's import refuses a clean override path, fall back to ONE
  shared untinted preview scene for all three archetypes and record it — distinction is nice,
  not load-bearing.
- No script anywhere. Autoplay makes the idle work in BOTH consumers with zero addon changes:
  the backdrop viewport processes normally; `MKPreviewViewport` inherits PAUSABLE so the idle
  freezes under pause — required behaviour (the Phase 5/6 decision; do not "fix" it).
- Scale/orientation: Quaternius mannequins are ~1.8 units, feet-origin, facing +Z under glTF
  import — verify by capture, not assumption; correct on the preview scene root if needed.

**Backdrop mount height changes.** `menu_backdrop_3d.tscn` parks `CharacterMount` at `y = 0.7`,
sized for a centre-origin 1.1 cube. A feet-origin rig must stand ON the dais: move the mount to
`y = 0.15` (dais top). Re-check the camera framing by capture — a 1.8-unit figure fills more
frame than the cube did; adjust camera position/pitch in the same scene edit if it crops.

## 4. Data re-point

- `demo/demo_archetypes/{vanguard,arcanist,scout}.tres`: `preview_scene` → the new scenes. Ids,
  names, payloads unchanged — the selection→backdrop→mount chain keys off `archetype` ids and is
  untouched.
- The addon `default_config.tres`'s neutral archetype keeps NO preview scene (never had art).
- Delete `demo/demo_creation/preview_{vanguard,arcanist,scout}.tscn` with the re-point — after
  it they are referenced by nothing. Their teaching comment ("the viewport assumes nothing about
  what it is shown") moves to wherever still needs it; the widget's own class doc already states
  it, so deletion is likely clean.

## 5. Tests

Extend `tests/test_backdrop_scene.gd` (or a small `test_demo_characters.gd` if it reads better):

- Each shipped archetype `preview_scene` loads, instantiates headless, and contains an
  `AnimationPlayer` whose `autoplay` names an animation that EXISTS in its list — the
  fixture-vs-shipped rule; a renamed animation after a re-export fails red instead of T-posing
  silently.
- The three defs resolve three DISTINCT scene resources (or the recorded one-shared-scene
  fallback, whichever §3 lands on) — pins the re-point actually happened.
- The end-to-end shell test keeps passing unmodified (it asserts mount occupancy, not mesh type).
- The look stays with the captures; nothing about it is assertable headless.

## 6. Verification

- `./tools/check.ps1 -Smokes -Isolation` green (all new paths under `demo/` — isolation must
  stay clean).
- Captures, all READ before claiming done: seeded Characters page (mannequin idling on the
  dais), `characters_rig` + `MK_CAPTURE_CREATE` to the appearance step (mannequin in the preview
  viewport), plain main-menu shot (empty dais unchanged). A capture is one frame — it proves
  pose and framing, not motion; motion is the human row.
- Human rows to append to BUILD_HANDOFF §6a: idle FEEL on a real display, and
  pause-freezes-the-preview from the pause menu with the character loaded.

## 7. Doc sync (same slice, not a follow-up)

- `docs/DECISIONS.md`: the D15 carve-out (demo may ship CC0 art; addon never ships any; the
  pack's license file ships beside the asset).
- `CHANGELOG.md` Unreleased: rigged demo character, pack name + CC0 + the ~8 MB note,
  primitives replaced.
- `BUILD_HANDOFF.md` §9 sentence amended; §6a rows added.
- `docs/THEMING.md` §7's demo pointer stays true (worked example now includes the character).

## 8. Risks / traps carried in

- Animation names and `AnimationLibrary` prefixes are import-dependent — probe, never assume.
- Feet-origin drove the mount move (§3); a future pack swap must re-check origin convention.
- Copied `.import` files from another project are poison (§2).
- The material-tint override path may not survive the glb's import layout — the recorded
  fallback is one shared scene, not a script (§3).
- `MKPreviewViewport` frames from bounds and already handles late-arriving meshes — do not add
  framing code to the preview scenes.
- The bracketed folder names (`…Library[Standard]`) glob in PowerShell — use `-LiteralPath` for
  every copy command, or the copy silently matches nothing.
