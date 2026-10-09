## What and why

<!-- What changes, and why it is needed. For a fix: what the defect was and why it existed. -->

## Checklist

- [ ] `./tools/check.ps1 -Smokes -Isolation` ends in `exit=0` (unfiltered)
- [ ] Every fix has a test that fails when the fix is reverted. Mutation run: <!-- what you reverted, what went red -->
- [ ] `CHANGELOG.md` `[Unreleased]` entry (marked **Breaking** if it touches public surface)
- [ ] Docs updated, and the changed claim grepped across the repo for stale mirrors
- [ ] Visual change: before/after captures attached (`tools/capture_scene.ps1`)
- [ ] Human-only checks (docs/DEVELOPMENT.md §6a) walked, or listed as not walked
