# mob_midi — Agent Instructions

You're in **mob_midi**, a Mob capability plugin: MIDI in + out over USB-MIDI and BLE-MIDI on both iOS (CoreMIDI) and Android (`android.media.midi`). Public API is `MobMidi.{list_devices, open_input, open_output, open_virtual, output_handle, close, send_note_on, send_note_off, send_cc, send_raw, now_ns, scan_bluetooth, stop_bluetooth_scan, connect_bluetooth, parse, parse_devices}/*`, `MobMidi.Parser`, `mix mob_midi.gen.virtual_device`, and the C ABI in `priv/include/mob_midi.h` (Android). Design record: `decisions/2026-11-13-consolidate-midi.md`.

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
* `lib/mob_midi/self_test.ex` — `MobMidi.SelfTest` (`Mob.Plugin.SelfTest`, manifest `selftest:`): `midi_list_devices/0` round trip; `classify/2` maps the NIF return + delivered answer to pass / skip / fail and is what the unit tests drive.
* `src/mob_midi_nif.erl` — Erlang NIF stub.
* `priv/mob_plugin.exs` — plugin manifest. iOS `CoreMIDI` framework; Android runtime permissions per platform.
* `priv/native/ios/mob_midi_nif.m` — iOS NIF (ObjC): CoreMIDI client, source subscribing, `MIDIPacketList` send.
* `priv/native/jni/mob_midi_nif.zig` — Android NIF glue.
* `priv/native/android/MobMidiBridge.kt` — Kotlin bridge: `android.media.midi.MidiManager` device enumeration + hot-plug callback, input/output ports by number (`port: :all`), the per-output `Dispatcher` threads, a `mob_midi` worker thread for every device/port open and close, BLE-MIDI scan + `openBluetoothDevice`, the `:midi_bluetooth` permission (`MobPermissionProvider`), and `MobMidiDeviceService`, the class host apps declare for their own virtual devices.
* `priv/native/android/mob_midi_core.c` — the plugin's `android.jni_source`: sources + generations, the native sink, per-output send queues (min-heap by target time), BEAM `{:midi, :raw, ...}` delivery. Implements `priv/include/mob_midi.h`.
* `priv/include/mob_midi.h`, `priv/include/mob_midi_parser.h` — the C ABI for another static NIF of the app, and a header-only stream parser (host test: `test/c/`, run by `test/mob_midi_c_parser_test.exs`).
* `lib/mob_midi/virtual_device.ex` + `lib/mix/tasks/mob_midi.gen.virtual_device.ex` — the host's `MidiDeviceService` declaration (mob_dev can't generate per-app Android resources; see the decision record).
* `tools/MidiProbe.java` + `tools/midi_probe.sh` — external-process probe (app_process) for device checks.

## Testing

Elixir suite (host-side, no MIDI hardware needed):

```bash
mix test
```

The suite exercises `parse/1` heavily — that's the pure decoder and it should decode every MIDI status byte correctly (note on with velocity 0 normalizes to note off, running-status is handled, unknown bytes get `:raw`).

Native paths are **experimental** (README "Status"). No hardware needed for the core I/O loop: virtual MIDI devices exercise it end to end.

* **Android emulator (what 0.3 used):** a throwaway `mob.new` host with this checkout as a path dependency (name the path `.../mob_midi`: mob_dev derives the plugin name from the directory, and delete a stale gitignored `priv/mob_plugin.sig`), `config :mob, :acknowledge_unsafe_plugins, [:mob_midi]`, `mix mob_midi.gen.virtual_device --name MobMidiProbe --inputs 1 --outputs 2`, and a tiny `c_src/` static NIF that registers a sink and calls `mob_midi_send`. Drive it over `mix mob.connect` + `:rpc.call(node, Code, :eval_string, [src])` from a long-lived process (messages go to the caller), and run `tools/midi_probe.sh <serial> MobMidiProbe notes|listen|stall ...` alongside. Keep IEx input lines under ~1000 characters (the pty truncates longer ones and wedges the session). Build with `mise exec zig@0.17.0 --` if `zig` on PATH is a dev build.
* **Android emulator, older recipe:** add `android.media.midi.MidiDeviceService` subclasses to a throwaway host app (a service + `res/xml` device-info + a `<service>` with the `android.media.midi.MidiDeviceService` intent-filter and `BIND_MIDI_DEVICE_SERVICE` permission).
* **iOS simulator:** in the host's `ios/AppDelegate.m`, `MIDIDestinationCreate` a synth whose read proc `MIDIReceived`s into a `MIDISourceCreate` source.
* **USB-MIDI / BLE-MIDI hardware:** not verified for 0.1.2 or 0.3 (an earlier Oxygen 49 check is noted in the 0.1.0 changelog but predates the 0.1.2 bridge changes).

## The pre-empt-failure rules that matter here

1. **`open_input/2` is a subscription, not a request-response.** Packets arrive as messages to the CALLING process. If you open it from a short-lived task, the packets go to a dead pid. Open it from your screen's `mount` or a long-lived GenServer.
2. **Note on with velocity 0 is note off** by MIDI convention. `parse/1` normalises this; if you're implementing new MIDI decoding paths, keep that normalisation — otherwise sustained-note bugs will chase you forever.
3. **`send_raw/3` accepts binaries** — used for SysEx, MTC, or any status the typed helpers don't cover. Do NOT hand-craft note messages via `send_raw`; the typed helpers exist for a reason (clipping channel to 0..15, byte7 args to 0..127).
4. **Channel numbering:** `0..15` on the wire; most UIs show `1..16`. Do not silently offset — that's a UX decision the app makes.
5. **Hot-plug is asynchronous.** Both platforms send `{:midi, :device_added | :device_removed, nil}` to the last `list_devices` caller (Android from `MidiManager.DeviceCallback`, registered in `setActivity`; a removed device's ports are closed). A `list_devices` snapshot goes stale the moment it's returned.
6. **`open_output/2` replies; `send_*` can fail.** The caller gets `{:midi, :opened, ...}` or `{:midi, :error, %{op: :open_output, ...}}`. Android opens asynchronously and queues up to 256 64-byte chunks per port until then (`MobMidiBridge.PENDING_CHUNKS`, the C queue's size, so the flush always fits); the NIF answers `:ok | :queued | {:error, reason}` and `MobMidi.send_result/2` maps that. Keep the Kotlin `SEND_*` codes and the zig switch in `nif_midi_send` in step.
8. **Timestamps are one clock.** `now_ns/0`, the `timestamp` / `received` of `:raw`, `send_raw`'s `at:` and every `mob_midi.h` timestamp are `CLOCK_MONOTONIC` ns on Android (`System.nanoTime`) and `mach_absolute_time` ns on iOS. The receive path (`nativeReceive` in `mob_midi_core.c`) and the send path (`mob_midi_send` → `nativeNextSend`) allocate nothing per message except the BEAM message itself: keep it that way. Keep the `MOB_MIDI_*` codes in `mob_midi.h`, the Kotlin `CORE_*` constants and the zig switch in `nif_midi_send` in step.
10. **Never block a BEAM scheduler or the UI thread on another app.** Android can't close a port while a write to a client that stopped reading is blocked (`MidiInputPort.close` waits on the writer's lock), and that deadlocks any binder call into the same `MidiDeviceServer`. So writes happen only on per-output `Dispatcher` threads, and device/port opens and closes only on the `mob_midi` worker thread. A dead client that never read can leave its port stuck until Android releases it; the queue answers `:queue_full` meanwhile.
9. **Virtual devices are declared by the host on Android.** Android reads a `MidiDeviceService`'s device name and ports from the app's manifest + `res/xml`, so the plugin ships only the class (`io.mob.midi.MobMidiDeviceService`); the README shows the declaration. `open_virtual/2` finds the device by name among the app's own (`MidiDeviceInfo.PROPERTY_SERVICE_INFO` package).
7. **`list_devices` never answers "no devices" when it couldn't ask.** No Activity / no `MidiManager` (Android) and a failed `MIDIClientCreate` (iOS) deliver `{:midi, :error, %{op: :list_devices, reason: :no_activity | :no_midi_service | :no_client}}`; an empty list means the platform answered. `MobMidi.SelfTest` depends on that distinction, so keep it when touching `listDevices` / `nif_list_devices`.

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
