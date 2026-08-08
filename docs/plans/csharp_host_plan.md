# Plan — C# host compatibility

**Status:** PLANNED. **Written:** 2026-08-08.
**Goal:** a Godot .NET (C#) host can integrate MenuKit fully — backends included — without
forking the addon or waiting for a C# port. The recipient's project is C#; after this slice the
owner assesses whether a full port is still wanted.

---

## 1. The problem, precisely

GDScript addons run fine inside C# projects, and every duck-typed seam MenuKit already has
(`selection_changed`, the page contract, `Call()`-driven shell methods) crosses the language
boundary as-is. The ONE hard wall is inheritance: **Godot does not support a C# class extending a
GDScript class**, and MenuKit's five backend extension points (`MKMenuBackend`,
`MKProfileBackend`, `MKSettingsBackend`, `MKNetworkBackend`, `MKPausePolicy`) are GDScript bases
that `MKBackendSlot.validate_against` rightly refuses anything not extending.

The fix is NOT loosening validation. It is five thin GDScript **adapter backends** that extend
the bases and forward everything to a host-supplied C# node — the C# team writes plain C# and
never touches GDScript.

## 2. The adapter layer (`addons/menu_kit/backends/interop/`)

- `mk_csharp_delegate.gd` — shared `RefCounted` helper owning the three mechanisms every adapter
  needs, written once:
  - **Resolution:** the slot's `params` carry `delegate_path` (absolute node path, typically a C#
    autoload). Resolved lazily on first use AND re-checked while unresolved (the C# autoload may
    sit below the adapter in autoload order); a missing delegate warns ONCE naming the path and
    the adapter, then the adapter degrades exactly like an unassigned slot.
  - **Dual-spelling call:** GDScript contracts are snake_case; C# methods register under their
    exact (conventionally PascalCase) names. `forward(method, args)` tries `has_method(snake)`
    then `has_method(PascalCase(snake))`; a delegate answering neither warns once per method
    naming both spellings, and the adapter returns the base's own default for that method
    (degrade-visible, the repo's existing convention for non-abstract base defaults).
  - **Signal re-emission:** for each signal the base declares, if the delegate has a same-named
    signal, connect and re-emit through the adapter (variadic arity handled per signal, not
    generically guessed).
- Five adapters, one per base, each overriding the base's full public contract and forwarding
  through the helper: `mk_csharp_menu_backend.gd`, `mk_csharp_profile_backend.gd`,
  `mk_csharp_settings_backend.gd`, `mk_csharp_network_backend.gd`, `mk_csharp_pause_policy.gd`.
  Each also forwards `_mk_configure(params)` to the delegate (minus `delegate_path`) if the
  delegate exposes it, so C# backends get their params through the same door GDScript ones do.
- Read each base's ACTUAL contract from source before writing an adapter — override every public
  method including non-abstract defaults whose behaviour a host would expect to own (e.g. the
  profile base's `is_name_available`), and NONE of the base's internal plumbing.
- Everything stays inside `addons/menu_kit/` — no external `res://` path, no theme overrides; the
  isolation gate must stay green. No C# files ship in the addon (a `.cs` in the addon would fail
  to compile in a GDScript-only host — the reverse of the problem this slice fixes).

## 3. What is documented, not coded

New `docs/INTEGRATION.md` section "C# hosts", covering:

- The one-wall rule (no cross-language inheritance) and the adapter pattern with a full worked
  example: a C# `ProfileBackend.cs` sketch (method names, `Godot.Collections` types, signals)
  plus the slot wiring (`backend_script` = the adapter, `params = {"delegate_path": "/root/…"}`).
- Type mapping cautions: adapters hand C# code `Godot.Collections.Dictionary`/`Array` (NOT
  `System.Collections`); returns must be Variant-compatible; `StringName` vs `string` in signal
  names is handled by Godot.
- The already-cross-language seams, stated as such: pages in C# (a `Control` with a
  `selection_changed` signal gets the backdrop wiring; `_mk_step_*` creation-step methods can be
  authored in C# under those exact snake_case names — C# permits them and `Call` matches by
  registered name); driving the shell from C# (`GetNode`, `Call`, `Connect` snippets for the
  MKRoot surface and `MKSettingsService`).
- The honest limit: this repo's gate has no .NET engine build, so the adapters are proven against
  a GDScript STAND-IN delegate that mimics the C# surface (PascalCase methods + signals); the
  first real-C# proof happens in the recipient's project. Goes in BUILD_HANDOFF §6a as a new
  human row, and the CHANGELOG says the same.

## 4. Tests

New suite `tests/test_csharp_adapters.gd` against a stand-in delegate (GDScript node exposing
ONLY PascalCase methods + the expected signals — the shape a C# node presents; a second stand-in
with snake_case proves the first spelling path):

- Every adapter validates against its base through a real `MKBackendSlot` (the wall this slice
  exists for).
- Method forwarding both spellings; arguments and returns intact verbatim; the degrade path
  (missing delegate, missing method) warns once by name and returns the base default —
  `MKLog.observer` pins the once-ness.
- Signal re-emission per base signal (roster_changed, setting_changed, …): delegate emits →
  adapter re-emits with args intact.
- `_mk_configure` params reach the delegate minus `delegate_path`.
- End-to-end: an `MKRoot` on a config whose profile slot is the adapter + a PascalCase stand-in
  roster — the character select page renders the stand-in's roster (proves the adapters work
  through the REAL shell path, not just in isolation).

## 5. Verification & docs

- `./tools/check.ps1 -Smokes -Isolation` full gate (isolation is load-bearing here: the interop
  folder is new addon surface).
- Docs: INTEGRATION.md §"C# hosts", API.md (adapter classes + the delegate contract), CHANGELOG
  Unreleased, BUILD_HANDOFF §6a row (real-C# proof is post-handoff), DECISIONS.md (the
  adapter-over-port decision and its rationale).
- No captures — nothing visual ships.

## 6. Out of scope, stated

- A C# port of MenuKit (assessed by the owner after this lands).
- Shipping any `.cs` file, `.csproj`, or .NET-edition engine requirement.
- Testing against a real .NET Godot build (recorded as the §6a row instead).
