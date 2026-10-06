# Changelog

All notable changes to **mob_midi** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

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
