# Agent instructions

Start with [`AGENTS.md`](AGENTS.md) — mob_midi-specific orientation.
Then read `~/code/mob/AGENTS.md` + `~/code/mob/CLAUDE.md` for the system view
and `~/code/mob/MOB_PLUGINS.md` for the manifest schema.

Pre-commit checklist (same as mob):

```bash
mix test
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
```

Native changes (.m / .zig / .kt) aren't exercised by `mix test` — they
need a `mix mob.deploy --native` of a host app with real MIDI hardware
(USB or BLE) attached, and a device check before committing.

The pre-push hook (`.githooks/pre-push`, activated via
`git config core.hooksPath .githooks`) runs format/credo/compile on every
push and the full suite when mix.exs changes (release preflight).

Releases: mix.exs version bump on master triggers `.github/workflows/release.yml`
(tag + GitHub Release + Hex publish). See ~/code/mob/RELEASE.md for the
trigger model; do NOT bump versions without explicit permission.
