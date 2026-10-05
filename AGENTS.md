# mob_midi — Agent Instructions

You're in **mob_midi**, a Mob capability plugin: MIDI in + out over USB-MIDI and BLE-MIDI on both iOS (CoreMIDI) and Android (`android.media.midi`). Public API is `MobMidi.{list_devices, open_input, open_output, send_note_on, send_note_off, send_cc, send_raw, parse}/*`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules, and [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md) for the manifest schema. This file is mob_midi-specific.

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

Native paths are **experimental** (README "Status"). No hardware needed for the core I/O loop: virtual MIDI devices exercise it end to end.

* **Android emulator:** add `android.media.midi.MidiDeviceService` subclasses to a throwaway host app (a service + `res/xml` device-info + a `<service>` with the `android.media.midi.MidiDeviceService` intent-filter and `BIND_MIDI_DEVICE_SERVICE` permission). A "synth" with only an input port that forwards to a "source" with only an output port lets you `open_input(source)`, then `open_output(synth)` fresh and send immediately (exercises the queue). Sleeping in the synth's `onCreate` delays the open (it shares the main looper with the `openDevice` callback), which exercises the 256-message bound. Drive it over `mix mob.connect --no-iex` + `:rpc.call(node, Code, :eval_string, [src])` so the NIF messages land in the eval process.
* **iOS simulator:** in the host's `ios/AppDelegate.m`, `MIDIDestinationCreate` a synth whose read proc `MIDIReceived`s into a `MIDISourceCreate` source.
* **USB-MIDI / BLE-MIDI hardware:** not verified for 0.1.2 (an earlier Oxygen 49 check is noted in the 0.1.0 changelog but predates the 0.1.2 bridge changes).

## The pre-empt-failure rules that matter here

1. **`open_input/2` is a subscription, not a request-response.** Packets arrive as messages to the CALLING process. If you open it from a short-lived task, the packets go to a dead pid. Open it from your screen's `mount` or a long-lived GenServer.
2. **Note on with velocity 0 is note off** by MIDI convention. `parse/1` normalises this; if you're implementing new MIDI decoding paths, keep that normalisation — otherwise sustained-note bugs will chase you forever.
3. **`send_raw/3` accepts binaries** — used for SysEx, MTC, or any status the typed helpers don't cover. Do NOT hand-craft note messages via `send_raw`; the typed helpers exist for a reason (clipping channel to 0..15, byte7 args to 0..127).
4. **Channel numbering:** `0..15` on the wire; most UIs show `1..16`. Do not silently offset — that's a UX decision the app makes.
5. **Hot-plug is asynchronous and iOS-only.** iOS sends `{:midi, :device_added | :device_removed, nil}` to the last `list_devices` caller; Android doesn't deliver hot-plug events yet. A `list_devices` snapshot goes stale the moment it's returned.
6. **`open_output/2` replies; `send_*` can fail.** The caller gets `{:midi, :opened, ...}` or `{:midi, :error, %{op: :open_output, ...}}`. Android opens asynchronously and queues up to 256 sends per device until then (`MobMidiBridge.MAX_PENDING_SENDS`); the NIF answers `:ok | :queued | {:error, reason}` and `MobMidi.send_result/2` maps that. Keep the Kotlin `SEND_*` codes and the zig switch in `nif_midi_send` in step.

## Pre-commit + release

Same gate as mob:

```bash
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
mix compile --warnings-as-errors
mix test
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need a `mix mob.deploy --native` of a host app and a device check (virtual MIDI devices on an emulator/simulator, see Testing; real USB/BLE hardware where you have it) before committing and before publishing.

The pre-push hook (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks`) runs format/credo/compile on every push and the full suite when `mix.exs` changes (release preflight).

Releases: `mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). Sign the manifest against the shared mob key first. Do NOT bump versions without explicit permission. See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model.
