# Changelog

All notable changes to **mob_midi** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.3.0] - 2026-11-13

Consolidation (stacked on the entries below, from #5): mob_midi becomes the one
home for MIDI in Mob apps, so Humdinger's `humdinger_midi_port` and Magpie's
`magpie_midi` plugins can be deleted. Design: `decisions/2026-11-13-consolidate-midi.md`.

### Added
- **Native C ABI** (`priv/include/mob_midi.h`, Android): another static NIF of
  the app registers a sink with `mob_midi_set_sink/2` and gets `(source,
  generation, bytes, len, timestamp_ns)` on the MIDI thread (no BEAM message,
  no allocation), and sends with `mob_midi_send(handle, bytes, len, at_ns)`
  from any thread. Implemented in `priv/native/android/mob_midi_core.c`
  (`android.jni_source`). iOS links stubs that answer unsupported.
- `open_input/3` takes `port: :all` (every port, each its own source) and
  `deliver: :beam | :native | :both`; `open_virtual/3` takes `deliver:`.
- `output_handle/2`; output `{:midi, :opened, ...}` carries `handle`, input
  `:opened` carries `source`.
- Sources and generations: bytes of a closed or reopened port are dropped once
  `close/2` returns.
- `MobMidi.Parser` (stream state across packets); `priv/include/mob_midi_parser.h`
  (header-only C stream parser) with a host C test.
- `mix mob_midi.gen.virtual_device`: writes the host's `MidiDeviceService`
  declaration and `res/xml` from `--name/--inputs/--outputs` or
  `config :mob_midi, :virtual_device` (`--check` for CI, `--remove`).
- Device maps carry `address`; `{:midi, :bluetooth_device, ...}` carries `rssi`;
  BLE errors `:bluetooth_off`, `:location_off`, `:bad_address`;
  `connect_bluetooth/2` on a connected address answers `:connected` at once.
- `tools/MidiProbe.java` + `tools/midi_probe.sh`: an external-process probe
  for device checks (`"Name*"` matches a device by name prefix).
- **`{:midi, :drained, %{device, port, handle, generation}}` and
  `discard/2`** (Android): after a send answered `{:error, :queue_full}`, the
  port refuses every send until its queue has drained (the dispatch thread is
  back from the write it was stuck in, at most 128 chunks are left and the
  largest message refused meanwhile fits); then
  the port's opener gets `:drained`. `discard/2` (C: `mob_midi_discard`)
  drops what is queued and starts a new queue generation, which `:drained`
  carries (an own virtual output whose listeners all leave drops its queue,
  bumps the generation and still reports `:drained` if it was refusing). The
  queue logic lives in `priv/native/android/mob_midi_queue.h`, with a host C
  test.

### Changed
- **Android sends go through a per-port queue** (256 chunks of 64 bytes,
  ordered by `at:`) and a dispatch thread per open output. `send_raw/4`'s
  `at:` is now held until that time (#5 stamped and wrote at once). A listener
  that stops reading fills only its port's queue (`{:error, :queue_full}`);
  the BEAM never blocks on it.
- Port and device opens/closes run on a `mob_midi` worker thread, not the BEAM
  scheduler or the UI thread. So do the `MidiManager` lookups behind
  `list_devices`, `open_input`, `open_output`, `open_virtual`, and the
  Bluetooth adapter checks of `scan_bluetooth` / `connect_bluetooth` (binder
  calls): the NIFs only post the request, and the answers come from that
  thread (a BLE scan itself still starts and stops on the main thread, where
  Android delivers its results; `stop_bluetooth_scan` queues behind a pending
  `scan_bluetooth`).
- `close/2` racing an open still in flight: once `close/2` returns, no
  `:opened` of an open asked for before it can arrive (it answers `{:midi,
  :error, %{reason: :closed}}`); `:opened` is sent under the same lock
  `close/2` takes.
- Opens of one device share a single `MidiManager.openDevice` in flight
  (Android). On Android ≤ 11 the system's `MidiService` walks a device's
  connection list unlocked when its service connects, so a connection added
  or removed meanwhile crashes `system_server` (the phone's system restarts).
  Opening and closing a slow-starting device service in a loop, each open
  adding a connection of its own, did that on an Android 10 phone. It also
  ends the `:open_failed` a second open got while the first was in flight.
- Text that carries names (the device list JSON, a virtual device's name, BLE
  names and addresses) crosses JNI as UTF-8 byte arrays both ways, not
  `GetStringUTFChars` / `NewStringUTF` (modified UTF-8 split characters
  outside the BMP, such as an emoji in a device name, into invalid bytes, and
  `NewStringUTF` rejects them).
- `now_ns/0` reads `CLOCK_MONOTONIC` in C: mob's zig `nowNs` returned garbage
  on 32-bit ARM (its `timespec` is two `i64`s).
- `parse/1` follows running status and real-time interleave and decodes
  aftertouch, SysEx and system messages (real-time bytes were `:raw`).
- `open_output/3` on the app's own virtual device answers `{:midi, :error,
  %{reason: :own_device}}` (send to it with `send_raw` after `open_virtual/3`).
- Plugin manifest declares `BLUETOOTH`, `BLUETOOTH_ADMIN`,
  `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, and `:midi_bluetooth`
  requests location on Android 12+ too (fixes #5: on Android ≤ 11 it requested
  an undeclared location permission, which Android denies).
- NIF: `midi_open_input/3`, `midi_open_virtual/2`, new `midi_output_handle/2`,
  new `midi_discard/2`.

### Upgrading
- `parse/1`: `0xF8`…`0xFF` now come back as `%{type: :clock | :start | ...}`
  and running-status data as full events instead of `:raw` bytes; SysEx as one
  `%{type: :sysex}`. Match on the new types.
- `send_raw(..., at: t)` with `t` in the future now waits until `t` on Android.
- `{:error, :queue_full}` is sticky on Android: the port refuses sends until
  `{:midi, :drained, ...}` (C: `mob_midi_send` answers
  `MOB_MIDI_ERR_QUEUE_FULL` until then).
- Android: declare a virtual device with `mix mob_midi.gen.virtual_device`
  (its resource is `@xml/mob_midi_device`).
- A host C NIF includes `"../deps/mob_midi/priv/include/mob_midi.h"` (a path
  dependency: include from that path).

### Verified (this branch at 53bb2bf, moto e, Android 10, armeabi-v7a, throwaway mob.new 0.6.19 host)
- `dumpsys midi`: hosted device `MobMidiProbe 🎹`, `mInputPortCount=1,
  mOutputPortCount=2`, service `io.mob.midi.MobMidiDeviceService`; the app's
  `primaryCpuAbi=armeabi-v7a`. The emoji name came back intact from
  `list_devices`, from `open_virtual`'s `:opened`, and `open_virtual` found
  the device by it; `connect_bluetooth("🎹:00:00")` answered `:bad_address`
  and `open_virtual("Nope 🎸")` `:no_such_device`, app alive.
- Probe → hosted input port (100 note pairs, 200 packets, running status +
  `0xF8` inside messages): 200/200 to the BEAM, stamps identical to the
  probe's `SENT` lines, 100 note-on / 100 note-off / 100 clock; sender →
  bridge p50 1.24 ms, p95 1.60 ms; → BEAM process p50 1.93 ms, p95 2.85 ms.
  The C sink (same receive path, run on the build before the last Kotlin
  change): 200/200, stamps identical, the C parser 100 / 100 / 100,
  `mob_midi_source_info` matched every call, → sink p50 1.12 ms, p95 1.38 ms.
- Scheduled sends, ~400 ms ahead, 50 ms apart: 20 `send_raw at:` (port 0) and
  20 `mob_midi_send` from a pthread (port 1): 40/40 at the probe stamped
  exactly with the target, in order; arrival − target p50 2.18 / 2.01 ms,
  p95 4.48 / 3.67 ms.
- Message size: `mob_midi_send` of 16384 bytes into an empty queue accepted
  and delivered whole (17 packets: 16 × 1015 + 144 bytes, all stamped with
  the target; the last 120 ms after it); 16385 bytes → `MOB_MIDI_ERR_TOO_LARGE`
  / `{:error, :too_large}`. An 8 KiB SysEx due at T and, while it was being
  written, a 3-byte send stamped T − 10 ms: the SysEx arrived whole, the
  note after it.
- A 16 KiB send behind one note scheduled 300 ms ahead: `:queue_full`; a
  small send still refused; no `:drained` within 100 ms; one `:drained`
  3.9 ms after the note's target time; the 16 KiB resend accepted and
  delivered whole. (Before this fix `:drained` came 0.5 ms after the
  refusal, while the message still couldn't fit.)
- `port: :all` on the app's own 2-port device (`deliver: :both`): two
  sources, 10 messages per port to both the BEAM and the sink, by port.
- Stalled listener (the probe blocks in its first `onSend`): 624 sends
  accepted, then `:queue_full`; `mob_midi_send` from C then answered
  `MOB_MIDI_ERR_QUEUE_FULL` too; `discard/2` → `{:ok, g}`, a send after it
  still `:queue_full`; `:drained` 43.7 ms after the probe read again (50 ms
  polling), 8.40 s after the refusal; the next send accepted. In 2 of 5 such
  runs the dispatch thread came back from Android's write about 0.6 ms after
  the refusal although the probe was still stalled (462 / 516 sends accepted
  instead of 624), so `:drained` followed the discard at once; cause not
  found.
- A refusing own virtual output (256 notes scheduled 20 s ahead) whose only
  listener left: `:drained` with a new generation within 1 ms, then
  `:no_listener`. A listener killed while stalled: the queue is dropped but
  no `:drained` (the dispatch thread's write stays blocked; see the known
  limit on dead clients).
- Open/close races, 120 rounds of `open_input(port: :all)` + `open_output` on
  Magpie's device closed 0–300 ms later, twice (the second after `am
  force-stop` of Magpie, so its service cold-started): 105 / 107 input and
  102 / 104 output `:opened`, all before `close/2` returned; 33 + 29 opens
  cancelled with `:closed`; no `:open_failed`; no `:opened` after a
  `close/2`; `system_server` stayed up. Before the one-open-in-flight fix the
  same loop crashed `system_server` once, 14 s after Magpie's service process
  started (`ConcurrentModificationException` in
  `MidiService$Device.setDeviceServer`), and an earlier run had 28
  `:open_failed`.
- Hot-plug: `pm disable-user` / `pm enable` of Magpie → `:device_removed` /
  `:device_added` to the `list_devices` caller, re-list without / with it.

### Verified (earlier on this branch, before `:drained`; MobDevFix_arm emulator, Android 15 arm64, throwaway mob.new 0.6.19 host)
- `dumpsys midi`: hosted device `MobMidiProbe`, `mInputPortCount=1,
  mOutputPortCount=2`, service `io.mob.midi.MobMidiDeviceService`.
- Probe → hosted input port (100 packets, running status + `0xF8` inside
  messages): 100/100 to the BEAM and 100/100 to a static C NIF's sink, stamps
  equal to the probe's; Elixir and C parsers each 50 note-on, 50 note-off, 50
  clock. Sender → bridge p50 0.19–0.23 ms, p95 0.36 ms; → BEAM process p50
  0.34–0.39 ms; → sink p50 0.19–0.23 ms.
- Scheduled sends (20 from `send_raw at:`, 20 from `mob_midi_send` on a
  pthread, issued ~300 ms ahead): 40/40 at the probe stamped exactly with the
  target; arrival − target p50 0.65–2.9 ms, p95 2.3–10 ms (host load average
  ~900 during the runs; Magpie measured p50 0.7–1.1 ms on the same emulator).
- `port: :all` on a 2-port device: two sources; `deliver: :native` reached only
  the sink, reopening with `:beam` only the BEAM, old sources then invalid.
- Stalled listener: 3000 sends to its port → 557 queued, 2443 `:queue_full`,
  slowest `send_raw` 0.34 ms; the other port 50/50; the probe got all 557 once
  it read again.
- Hot-plug: `:device_removed` / `:device_added` when another app's MIDI
  service was disabled / enabled; `:virtual_status` sender/listener counts.
- Not verified: USB and BLE-MIDI hardware, `connect_bluetooth/2` against a
  device, iOS (compile-checked against the iOS SDK only).

### Added
- **Ports.** `open_input/3`, `open_output/3` and `send_raw/4` take `port:`
  (default 0); `list_devices/1` reports `input_ports` / `output_ports`. Android
  opened port 0 only.
- **Timestamps.** `{:midi, :raw, ...}` carries `port`, `timestamp` (the
  sender's) and `received` (when the bridge got it), in ns on the clock of the
  new `MobMidi.now_ns/0`. `send_raw/4` takes `at:` to stamp outgoing bytes.
- **Android hot-plug**: `{:midi, :device_added | :device_removed, nil}` to the
  last `list_devices/1` caller, as iOS already did; a removed device's ports
  are closed.
- **Virtual devices**: `open_virtual/2` subscribes to one of the app's own MIDI
  devices that other apps play into and listen to (`{:midi, :raw, ...}` in,
  `send_raw/4` out). Android: the host declares
  `io.mob.midi.MobMidiDeviceService` in its manifest (README) and gets
  `{:midi, :virtual_status, %{device, senders, listeners}}`; iOS: a CoreMIDI
  source + destination created by the call.
- **BLE-MIDI central (Android)**: `scan_bluetooth/2`, `stop_bluetooth_scan/1`,
  `connect_bluetooth/2` (`MidiManager.openBluetoothDevice`), and the
  `:midi_bluetooth` permission capability for `Mob.Permissions.request/2`.
- `list_devices/1` entries carry `manufacturer`, `type` (`:usb | :bluetooth |
  :virtual | :other`) and `own` (the app's own virtual devices);
  `parse_devices/1` normalises them.
- `open_input/3` answers `{:midi, :opened, %{device, port, direction: :input}}`
  or an `op: :open_input` error (`:no_such_device`, `:no_such_port`,
  `:open_failed`, `:no_output_port`) on both platforms; Android was silent.

### Changed
- **Breaking (NIF):** `midi_open_input/2`, `midi_open_output/2`,
  `midi_send/4` take the port (and the send timestamp); the `MobMidi`
  functions keep their old arities through default options.
- `{:midi, :opened, ...}` for outputs carries `port`.
- `send_*` can return `{:error, :no_listener}` (a virtual device nobody
  listens to).
- `MobMidi.Platform.current/0` is `:host` when mob's NIF isn't loaded, so the
  API returns `{:error, :unsupported}` on a host instead of raising.

### Verified
- Android emulator (API 37, x86_64), with FMutate as the host app and a
  second app on the same key: FMutate's declared `MobMidiDeviceService`
  device listed by `dumpsys midi`, played into by the second app (notes
  heard, `timestamp` / `received` on every packet, the sender → BEAM trip
  unchanged from FMutate's previous in-app bridge, median ~0.1 ms) and
  listened to (MIDI clock with `at:` stamps arriving exactly 20.833 ms apart
  at 120 BPM; `:virtual_status` listener counts); the second app's own
  virtual device opened as an input and played; hot-plug (reinstalling the
  second app removed and re-added its device; re-listed and reopened under its
  new id); the `:midi_bluetooth` permission dialog through
  `Mob.Permissions.request/2` and a 10 s `scan_bluetooth/2` started and
  stopped (no BLE-MIDI device in range).
- iOS: `mob_midi_nif.m` syntax-checked with clang against stub CoreMIDI /
  Foundation headers only; not built for or run on iOS.
- Not verified: USB / BLE-MIDI hardware, `connect_bluetooth/2` against a
  real device, multi-port hardware.

## [0.2.0] - 2026-10-09

### Added
- **On-device self-test** (MOB-418). `MobMidi.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls `midi_list_devices/0` (read-only) and classifies the native answer:
  devices listed pass; an empty list, or an Android device without a MIDI
  service, is `{:skip, :needs_hardware}`; an unregistered Android bridge, a
  missing Activity, a failed CoreMIDI client, a malformed list or no answer
  fail. Run it with `mix mob.selftest` from a host app (mob_dev 0.7.17+).

### Changed
- **Requires mob >= 0.9.15** (for `Mob.Plugin.SelfTest`): the `:mob`
  dependency is now `~> 0.9 and >= 0.9.15` (was `~> 0.7`) and the manifest's
  `mob_version` is `~> 0.9` (was `~> 0.7`).
- **Behaviour change: `list_devices/1` reports why it couldn't list.**
  Android delivered an empty list when the bridge had no Activity or the
  device has no `MidiManager`, and iOS delivered nothing when
  `MIDIClientCreate` failed. Both now deliver `{:midi, :error, %{device: 0,
  op: :list_devices, reason: :no_activity | :no_midi_service | :no_client,
  dropped: 0}}`, so "no devices" is no longer confused with "couldn't ask".
  Screens that call `list_devices/1` must now handle this message.

### Fixed
- iOS: `list_devices/1` always answers its own caller, even when a
  concurrent `list_devices/1` call from another process is in flight.

## [0.1.2] - 2026-10-05

Operator v1 release review fixes (MOB-397).

### Changed
- **`open_output/2` replies to its caller**: `{:midi, :opened, %{device: id,
  direction: :output}}` once the port is ready, or `{:midi, :error, %{device:
  id, op: :open_output, reason: atom, dropped: n}}` when it can't be opened,
  on both platforms. Reasons include `:no_such_device` (both), `:no_client`
  (iOS), and on Android `:no_midi_service`, `:open_failed`, `:no_input_port`,
  `:send_failed` (queue flush failed) and `:closed` (`close/2` cancelled an
  open in flight).
- **Android queues sends made while an output is still opening** (up to 256
  per device) and writes them in order once it opens. Before, the device opened
  asynchronously and those sends were silently dropped, so the first notes
  after `open_output/2` vanished. If the open fails the queue is discarded and
  the error event's `dropped` counts the lost messages.
- **Breaking: `send_*` return `{:error, reason}` when nothing was written or
  queued**, where 0.1.1 returned `socket` and silently dropped the message:
  `:not_open` (no `open_output/2`, closed, or failed to open), `:queue_full`,
  `:no_such_device` (iOS), `:too_large` (iOS, over 256 bytes; 0.1.1 truncated)
  or `:send_failed`. They still return `socket` on success. Code that pipes a
  `send_*` result on as the socket must bind it instead.
- **Breaking (iOS): `open_output/2` is required before sending**, as it already
  was on Android; 0.1.1's iOS NIF sent to any destination.
- iOS `{:midi, :error, ...}` events from `open_input/2` carry `device`, `op`
  and `dropped` alongside `reason`.
- Android names devices that lack `PROPERTY_NAME` (virtual
  `MidiDeviceService` devices) by manufacturer + product instead of "MIDI", and
  opening a device for input and output shares one `MidiDevice`.
- `MobMidi.KeyboardScreen` shows the selected output's state (opening / ready /
  error) and a failed send.

### Docs
- The native paths are marked **experimental**: verified against virtual MIDI
  devices on an Android emulator and the iOS simulator; USB-MIDI and BLE-MIDI
  hardware unverified. Replaces the "first pass, not device-verified" wording.
- Demo screen routes corrected to `/midi_keyboard` and `/midi_input`.
- The send example waits for `:opened`.
- README notes that a host activating both mob_midi and mob_bluetooth must set
  `NSBluetoothAlwaysUsageDescription` in its own `ios/Info.plist` (both plugins
  declare it; mob_dev 0.7.14 refuses the build otherwise).

## [0.1.1] - 2026-09-30

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.

## [0.1.0] - 2026-09-19

### Added

- Initial `mob_midi` plugin: MIDI in + out over USB / BLE for Mob apps.
  - `MobMidi` API: `list_devices/1`, `open_input/2`, `open_output/2`, `close/2`,
    `send_note_on/5`, `send_note_off/5`, `send_cc/5`, `send_program_change/4`,
    `send_raw/3`.
  - Pure, tested message layer: `note_on_bytes/3` & friends (encode) and
    `parse/1` (decode note on/off, CC, program change, pitch bend; velocity-0
    Note On normalised to Note Off; `:raw` for anything else), plus
    `parse_devices/1` to normalise the iOS list / Android JSON device payloads.
  - Tier-3 demo screens: `MobMidi.KeyboardScreen` (out; portrait-stubbed until
    mob's orientation lock lands) and `MobMidi.InputScreen` (in; visual).
    `MobMidi.KeyboardScreen` also sends notes over BLE-MIDI and shows incoming
    BLE-MIDI from the connected central. The demo screens register distinct
    routes, `/midi_keyboard` and `/midi_input`.
  - `MobMidi.Ble`: BLE-MIDI transport. The phone advertises as a BLE-MIDI
    peripheral (`advertise/2`, `stop/1`, `send_note_on/5`, `send_note_off/5`,
    `send_cc/5`, `send_midi/3`), plus pure `encode_packet/2` /
    `decode_packet/1` BLE-MIDI framing. Built on `MobBluetooth.Le`, so it adds
    a `mob_bluetooth ~> 0.3` dependency.
  - Native: CoreMIDI NIF (iOS), MidiManager Kotlin bridge + zig NIF (Android).
    Device-verified with an M-Audio Oxygen 49 on both platforms.
