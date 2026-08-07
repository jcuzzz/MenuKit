# Phase 8a staging — demo/, tests/, tools/

Knowledge displaced by the comment diet in `demo/**/*.gd`, `tests/**/*.gd` and `tools/**/*.gd`.
Everything below was staged BEFORE the comment carrying it was shortened or deleted.

## Host-relevant → Phase 9 docs

### INTEGRATION.md — the host half of the pause contract (from `demo/demo_game.gd`)

- The demo game scene is the shipped worked example of an integrator's ESC flow, and it is
  deliberately short: forward the gesture, show the shell, gate the camera. Anything longer means
  MenuKit failed to own the atomicity it claims.
- **The host scene runs PAUSABLE; the `MKRoot` child runs `PROCESS_MODE_ALWAYS`.** That is what
  makes `MKTreePausePolicy` observable at all: with `SceneTree.paused` true the host stops receiving
  `_process`, `_physics_process` and `_unhandled_input` while the shell keeps ticking.
- **The host writes `Input.mouse_mode` exactly ONCE, at boot, and never again.** Mouse mode is
  depth-counted inside `MKRoot` (a modal over the pause menu must not restore capture on dismiss);
  a host that also wrote it would fight the counter.
- **Gating the camera and movement on menu state is the HOST's job.** MenuKit frees the cursor
  whenever a surface is up, including under `MKNoPausePolicy` where the world keeps running — so
  relative mouse motion keeps arriving and polled WASD does not care that a Button has focus.
- **Show the shell BEFORE calling `open_pause_menu()`.** `MKRoot._show_page` defers
  `_focus_page_content`, and focus collection skips controls failing `is_visible_in_tree()`, so
  opening while hidden focuses nothing and the menu is dead to a gamepad.
- **A refused `open_pause_menu()` touched nothing.** The pre-check runs before any suspension, so
  the only thing the host has to undo is the visibility it just set. Without that, a config with no
  `pause` page leaves an opaque shell over the world with no way back.
- Any `ui_cancel` handling in the host is unreachable in the shipped configuration (the visible
  shell consumes it first; under a tree pause the host receives no input) — it exists for a host
  that reorders its children or swaps in `MKNoPausePolicy`.

### INTEGRATION.md — host page content (from `demo/pages/demo_page.gd`)

- A page is any `PackedScene` named by an `MKMenuPageDef`; host pages live outside the addon and
  need no addon edit to add.
- **Host page content wires its own focus chain** (`MKFocus.chain_container` + `MKFocus.focus_first`).
  Nothing does it for content the addon does not own.

### A tooling doc (or README) — the capture rigs (`tools/capture_rigs/*.gd`)

- Shoot the pause composition with
  `./tools/capture_scene.ps1 -Scene res://demo/demo_game.tscn -Rig res://tools/capture_rigs/pause_rig.gd`.
- Rig env vars: `MK_CAPTURE_SEED` (roster size, capped at 5), `MK_CAPTURE_CREATE` (push the creation
  page; numeric = advance Next N times), `MK_CAPTURE_CONNECT` (`<server id>` or `1`),
  `MK_CAPTURE_TAB`, `MK_CAPTURE_FOCUS_ROW`.
- Seeding isolation lives in the WRAPPER (`capture_scene.ps1` redirects APPDATA into `.agent_tmp`),
  never in a rig — rigs write through the ordinary backend.
- `capture_scene.gd` may only RAISE a rig's `wait_frames`, never cap it.

## Handoff candidates (maintainer-relevant, not already in BUILD_HANDOFF §4)

1. **`characters_rig.wait_frames()` is still 60 Hz-shaped.** §4's Phase 7 trap already records the
   general rule and names this rig as a sweep item; the diet could only restate the constraint in
   its doc comment, because raising `120` is a TOKEN change and out of scope for Phase 8a. It is
   still open: at 144/165 Hz an `MK_CAPTURE_CREATE=3` shot can photograph an earlier step.
   `pause_rig` (40) and `settings_rig` (40) carry the same softness and now say so.
2. **`tools/capture_scene.gd` pointed at `docs/tooling/visual_capture.md`, which does not exist in
   this repo** (it is a path from the source project). The stale link was deleted; if Phase 9 wants
   a capture ruleset doc, that is the reference to (re)create.
3. **`tests/test_creation_host.gd` still carries `const F8_NOISE`** — a plan finding-id in a CODE
   identifier, so the diet could not touch it. If finding ids are to leave the shipped asset
   entirely, that rename is a token change for a later slice (`DUPLICATE_KEY_NOISE` or similar).

## Deleted without restaging (the handoff already holds it)

Per-defect archaeology removed from test docs — "round N proved this undefended", "deleting X left
the suite green", "measured in round 4's fix-leg report", "an earlier revision of this test", "found
by the Phase 3 test leg" — is already recorded in BUILD_HANDOFF §1's per-phase defect tables and in
the commit history, one commit per review round. In each case the CONSTRAINT the archaeology was
attached to was kept and rewritten in the present tense (what a weaker assertion would fail to
catch), so nothing was lost from the file either. Specifically not restaged, because §4 already
carries the engine trap verbatim:

- lambdas capture locals by value (counter Arrays in `test_demo_game`, `test_preview_viewport`,
  `test_server_browser`, `test_input_glyphs`);
- deferred calls dropped in a delete cascade (`test_backend_ownership`, `test_revert_countdown`);
- `clampf` raises to its minimum first (`test_preview_viewport`);
- CSG bounds are zero on the frame the node is added (`test_preview_viewport`);
- `_ready` runs once per node lifetime (`test_preview_viewport`);
- headless GUI dispatch is dead / keyboard activation is the only honest gesture (every panel suite);
- `check.ps1` counts ERRORs, not WARNINGs (`test_server_browser`, `mk_test.gd`).
