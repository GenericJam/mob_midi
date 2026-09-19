# AGENTS.md — orientation for AI agents working on mob_midi

You're in **mob_midi**, a Mob capability plugin: MIDI in + out over USB-MIDI and BLE-MIDI on both iOS (CoreMIDI) and Android (`android.media.midi`). Public API is `MobMidi.{list_devices, open_input, open_output, send_note_on, send_note_off, send_cc, send_raw, parse}/*`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules. This file is mob_midi-specific.

> **Keep this file current.** When you change API shape, add a `host_requirements` entry, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_midi is, in one paragraph

Cross-platform MIDI: enumerate devices, hot-plug notifications, subscribe to inputs (packets arrive as `{:midi, :raw, %{device: id, bytes: bin}}`), and send outputs (`send_note_on/5`, `send_cc/4`, `send_raw/3`, etc). `parse/1` is a pure function that turns raw MIDI bytes into decoded event maps (`:note_on`, `:note_off`, `:cc`, `:program_change`, `:pitch_bend`, or `:raw` for anything it doesn't decode). All the platform-specific stuff (CoreMIDI clients + notify blocks on iOS, `MidiManager` device callbacks on Android) is behind the NIF; the Elixir surface is uniform.

## What mob_midi is NOT

* **Not `mob_bluetooth`.** BLE-MIDI is inside mob_midi. `mob_bluetooth` handles classic Bluetooth (SPP/HFP/HID) and generic BLE (advertise/scan/connect) — MIDI-over-BLE is a specific GATT profile that both platforms treat as a first-class MIDI source, so mob_midi handles it directly.
* **Not `mob_audio` / `mob_sound`.** MIDI is *symbolic* music events (note number + velocity), not audio samples. Rendering to sound is your app's problem (a synth engine, a sampler, or a downstream DAW that speaks MIDI).
* **Not a MIDI file player.** mob_midi is real-time MIDI I/O only. Parsing SMF (`.mid` files) belongs in a separate library.

## Anatomy of the plugin

* `lib/mob_midi.ex` — public API + pure `parse/1`.
* `src/mob_midi_nif.erl` — Erlang NIF stub.
* `priv/mob_plugin.exs` — plugin manifest. iOS `CoreMIDI` framework; Android runtime permissions per platform.
* `priv/native/ios/mob_midi_nif.m` — iOS NIF (ObjC): CoreMIDI client, source subscribing, `MIDIPacketList` send.
* `priv/native/jni/mob_midi_nif.zig` — Android NIF glue.
* `priv/native/android/MobMidiBridge.kt` — Kotlin bridge: `android.media.midi.MidiManager` device enumeration, input port opening, output writes.

## Testing

Elixir suite (host-side, no MIDI hardware needed):

```bash
mix test
```

The suite exercises `parse/1` heavily — that's the pure decoder and it should decode every MIDI status byte correctly (note on with velocity 0 normalizes to note off, running-status is handled, unknown bytes get `:raw`).

Native / device testing needs actual MIDI hardware. Verified so far:

* **USB-MIDI** on both platforms with an M-Audio Oxygen 49 keyboard.
* **BLE-MIDI** unverified end-to-end at time of writing (Elixir + screens green; native paths not device-verified).

## The pre-empt-failure rules that matter here

1. **`open_input/2` is a subscription, not a request-response.** Packets arrive as messages to the CALLING process. If you open it from a short-lived task, the packets go to a dead pid. Open it from your screen's `mount` or a long-lived GenServer.
2. **Note on with velocity 0 is note off** by MIDI convention. `parse/1` normalises this; if you're implementing new MIDI decoding paths, keep that normalisation — otherwise sustained-note bugs will chase you forever.
3. **`send_raw/3` accepts binaries** — used for SysEx, MTC, or any status the typed helpers don't cover. Do NOT hand-craft note messages via `send_raw`; the typed helpers exist for a reason (clipping channel to 0..15, byte7 args to 0..127).
4. **Channel numbering:** `0..15` on the wire; most UIs show `1..16`. Do not silently offset — that's a UX decision the app makes.
5. **Hot-plug is asynchronous.** Devices added/removed arrive as `{:midi, :device_added | :device_removed, ...}` messages. A `list_devices` snapshot goes stale the moment it's returned; treat the callback stream as the source of truth if you're building a UI.

## Pre-commit + release

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```

Native code isn't exercised by `mix test`; verify on real hardware before publishing.

`mix.exs` version bump on master triggers Hex publish. Sign the manifest against the shared mob key first. Do NOT bump versions without explicit permission. See `~/code/mob/RELEASE.md`.
