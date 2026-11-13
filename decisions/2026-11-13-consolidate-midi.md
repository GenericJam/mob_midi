# 2026-11-13: one home for MIDI in Mob apps (mob_midi 0.3)

## Context

Four MIDI efforts existed side by side:

- **mob_midi 0.2.0** (Hex): list/open/send over CoreMIDI and
  `android.media.midi`, Android port 0 only, no timestamps, no Android
  hot-plug, no app-owned virtual device, no BLE central.
- **PR #5** (`fmutate-features`, for FMutate): ports, timestamps on the
  `now_ns/0` clock, Android hot-plug, `open_virtual/2` (host-declared
  `MidiDeviceService`), BLE-MIDI central scan/connect. Unreleased.
- **Humdinger** `plugins/humdinger_midi_port`: device watcher with
  transport/address/port counts/own, BLE central, a virtual "Humdinger" port
  (0 in / 1 out) with a writer thread so a stalled listener can't block the
  BEAM.
- **Magpie** `plugins/magpie_midi` (branch `midi`): the same device layer
  plus a virtual "Magpie" port (1 in / 1 out), every output port of a device
  opened as its own source with a generation, bytes going straight from the
  MIDI thread into Magpie's C audio engine, and a native sending thread that
  hands bytes to Android at a target time.

This branch is stacked on #5 and keeps its API. It adds what Humdinger and
Magpie need that #5 lacks, so both plugins can be deleted.

## Decisions

### Elixir API (additive over #5)

- `open_input(socket, id, port: n | :all, deliver: :beam | :native | :both)`.
  `:all` opens every port the device can be read from, each its own
  subscription with its own `{:midi, :opened, %{..., source: s}}`.
- `open_virtual(socket, name, deliver: ...)`; `output_handle(id, port: n)`.
- `{:midi, :opened, %{direction: :output, handle: h}}` carries the native
  handle.
- `{:midi, :raw, %{device, port, bytes, timestamp, received}}` is #5's shape,
  unchanged.
- Device maps gain `address` (Bluetooth address, `""` otherwise).
- `{:midi, :bluetooth_device, ...}` gains `rssi`; BLE errors gain
  `:bluetooth_off`, `:location_off`, `:bad_address`.
- `send_raw/4`'s `at:` is now honoured on Android: the bytes wait in the
  port's queue until then (#5 stamped them and wrote them at once, which only
  helps receivers that schedule by timestamp; our own virtual device's
  listeners, and most apps, don't).
- `parse/1` follows running status and real-time interleave and decodes
  aftertouch, SysEx and system messages; `MobMidi.Parser` carries a stream's
  state across packets.

### Direction semantics (defined once)

Everything is from the app's viewpoint. `input_ports` are ports the app
**reads** (`open_input/3`; Android's `outputPortCount`), `output_ports` ports
it **writes** (`open_output/3`; Android's `inputPortCount`). The virtual
device generator uses Android's own words because it writes Android's XML:
`--inputs` are ports other apps send INTO the app, `--outputs` ports the app
sends OUT of. So Humdinger is `--inputs 0 --outputs 1`, and the app sees its
own device as `input_ports: 1, output_ports: 0` (it could read its own
output) in `list_devices`, as any other app does.

### Timestamp domains

One clock per platform, named by `now_ns/0`: Android `CLOCK_MONOTONIC` ns
(`System.nanoTime`, what `android.media.midi` stamps with), iOS
`mach_absolute_time` in ns. `timestamp` is the sender's stamp as delivered
(some senders stamp 0 or another clock: `mob_midi_timestamp_or()` in the
header falls back to now), `received` is when mob_midi got the bytes. BLE-MIDI
packet timestamps (13-bit ms, `MobMidi.Ble`) and audio-output frame clocks
(Magpie's AAudio mapping) are other domains; converting into `now_ns` is the
caller's job (Magpie keeps its frame→`CLOCK_MONOTONIC` mapping).

### Native C ABI (`priv/include/mob_midi.h`, Android)

- Implemented in `priv/native/android/mob_midi_core.c`, the plugin's
  `android.jni_source`, linked into the same app library as every static NIF,
  so another NIF (Magpie's `magpie_audio`) calls it directly.
- **Receive**: each opened input port is a source (1..63) with a generation
  from a global counter (never repeats). Kotlin's `MidiReceiver` passes the
  generation it was opened with; C delivers only the current one, under the
  source's lock, so once close returns nothing of the old port arrives. A
  sink `(ctx, source, generation, bytes, len, timestamp_ns)` registered with
  `mob_midi_set_sink` is called on the MIDI thread: no BEAM message, no
  allocation (a 256-byte stack buffer per call). Unregistering waits for
  calls in flight.
- **Send**: each open output (device port, or own virtual output port) has a
  slot in C: a fixed min-heap of 256 64-byte chunks ordered by (target time,
  FIFO) and a Kotlin dispatch thread (`THREAD_PRIORITY_URGENT_AUDIO`) that
  waits in C on a `CLOCK_MONOTONIC` condition variable and calls
  `MidiReceiver.send(bytes, timestamp)` when the earliest message is due.
  `mob_midi_send(handle, bytes, len, at_ns)` (any thread) and the BEAM's
  `midi_send` NIF both enqueue in C without JNI; only a port still opening
  goes through Kotlin's pending queue. Handles carry the slot's generation,
  so a stale handle answers `MOB_MIDI_ERR_NOT_OPEN`.
- One dispatcher per output keeps Humdinger's property: a listener that
  stops reading blocks its own queue (sends then answer `queue_full`), never
  the BEAM or other ports.
- A header-only stream parser (`mob_midi_parser.h`) with Magpie's rules
  (running status, real-time interleave, SysEx skipped) for native users.
- iOS: the functions exist and answer `MOB_MIDI_ERR_UNSUPPORTED`; Elixir
  refuses `deliver: :native` there.

### Ownership

Per port, explicit: `deliver:` routes each input port to the BEAM opener, the
sink, or both. The sink is one per app (`MOB_MIDI_ERR_BUSY` for a second).
Reopening a port replaces its subscription (new source). Hot-plug events go to
the last `list_devices/1` caller (#5's rule, both platforms).

### Hosted virtual port configuration

mob_dev's plugin manifest can contribute `android.manifest_application_snippets`
and `android.res_files`, but both are static: snippets are strings and res
files are copied from the plugin directory (`MobDev.Plugin.Merge.android_res_files/1`,
`native_build.ex` `apply_plugin_android_res!`). The only generator hooks
(`nifs_generator`, `screens_generator`, `ui_components_generator`) don't cover
Android manifest or resources, and res files are covered by the plugin
signature, so generating them into the dep at build time would fail
verification. Android reads a `MidiDeviceService`'s name and ports from the
app's own XML, as raw attribute strings (no `@string` references). So #5's
claim holds: the host declares the service. To make that one validated
command instead of hand-written XML, mob_midi ships
`mix mob_midi.gen.virtual_device --name N --inputs I --outputs O`, which writes
`res/xml/mob_midi_device.xml` and a fenced `<service>` block in the host's
`AndroidManifest.xml` (`--check` for CI, `--remove`), reading
`config :mob_midi, :virtual_device` when no flags are given. If mob_dev ever
grows an Android-resource generator, the task's pure functions
(`MobMidi.VirtualDevice`) are what it would call.

## What moves into mob_midi, what stays in the apps

Moves (both apps delete their copies): `MidiManager.DeviceCallback`, device
description (transport, address, port counts, own), BLE permissions, service
UUID scan, `openBluetoothDevice`, disconnect, the `MidiDeviceService` class and
its status tracking, generations for late bytes, every-port input, the
stalled-listener-safe writer, timestamped output, the stream parser.

Stays app-side: which devices to auto-open and remember (Humdinger's BLE
recall, Magpie's persisted choices), Humdinger's drain/release policy after a
`queue_full`, Magpie's sampler mapping (`Magpie.Midi.Map`), clock
generation/follow, its audio-frame→`CLOCK_MONOTONIC` conversion and its
sender thread's batching and late-tick dropping (it calls `mob_midi_send` at
the target time instead of Kotlin).

## Migration

**Humdinger** (`plugins/humdinger_midi_port` deleted):
`mix mob_midi.gen.virtual_device --name Humdinger --inputs 0 --outputs 1`
(device name and port named "Humdinger", as today); `config :mob, :plugins`
drops `:humdinger_midi_port`. `Humdinger.Output.Port`: `open_virtual(socket,
"Humdinger")` from its owner process, `send_raw(socket, own_id, bytes)` (or
`at:`), `{:midi, :virtual_status, %{listeners: n}}` replaces `connections`;
`{:error, :queue_full}` replaces its overflow answer (its "drained" sentinel
has no equivalent: release held notes on `queue_full` and retry on the next
`virtual_status`). `Humdinger.Output.Device`: `list_devices` (+ `address`,
`type`, `input_ports`/`output_ports`, `own`), `{:midi, :device_added |
:device_removed, nil}` then re-list, `scan_bluetooth/2`, `connect_bluetooth/2`,
`close/2`; the BLE recall stays in Humdinger.

**Magpie** (`plugins/magpie_midi` deleted): generate the device with
`--name Magpie --inputs 1 --outputs 1`. `Magpie.Midi` uses `list_devices`,
`open_input(socket, id, port: :all, deliver: :native)` for devices,
`open_virtual(socket, "Magpie", deliver: :native)` for the port,
`open_output/3` + the `handle` from `:opened` / `output_handle/2` for
destinations. `magpie_audio.c` drops its JNI registration of
`MagpieMidi.nativeIn/nativeActivate/nativeEvent` and its Kotlin `send`
call: it `#include "../deps/mob_midi/priv/include/mob_midi.h"`, registers its
sink (`source`, `generation` map onto its per-source parsers; a new
generation is its `source_renew`), and its sending thread calls
`mob_midi_send(handle, bytes, len, t)` per destination at the target time.
Source ids go up to 63 (was 16). Device events come to Elixir instead of
`nativeEvent`.

**FMutate** (PR #5's consumer; its repository isn't on this machine): already
on #5's API. New: `send_raw` `at:` is held until that time (clock sent ahead
still lands on time; sent late it goes at once), `open_virtual/3`, and its
hand-written `<service>` can be regenerated with the task (it must then use
`@xml/mob_midi_device`).
