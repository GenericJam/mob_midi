# Changelog

All notable changes to **mob_midi** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

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
