# Changelog

All notable changes to **mob_midi** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - unreleased

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
  - Native first pass (not yet device-verified): CoreMIDI NIF (iOS),
    MidiManager Kotlin bridge + zig NIF (Android).
