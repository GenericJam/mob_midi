# mob_midi

MIDI **in + out** for [Mob](https://github.com/GenericJam/mob) apps, over
USB-MIDI and BLE-MIDI. Unlike classic Bluetooth, MIDI is first-class on both
platforms, so this is a real cross-platform surface: **CoreMIDI** on iOS,
**`android.media.midi`** on Android.

```elixir
# Discover
MobMidi.list_devices(socket)
# => {:midi, :devices, [%{id: 7, name: "Oxygen 49", direction: :input}, ...]}

# Receive
MobMidi.open_input(socket, device_id)
# => {:midi, :raw, %{device: 7, bytes: <<0x90, 60, 100>>}}
#    parse it: MobMidi.parse(bytes) -> [%{type: :note_on, channel: 0, note: 60, velocity: 100}]

# Send
MobMidi.open_output(socket, device_id)
MobMidi.send_note_on(socket, device_id, 0, 60, 100)
MobMidi.send_cc(socket, device_id, 0, 7, 90)
```

The NIF layer is deliberately thin (device enumeration + raw byte I/O); message
encode/parse lives in Elixir (`MobMidi`) where it's pure and unit-tested.

## Demo screens (tier 3)

Two screens the host auto-lists via `Mob.Plugins.screens()`:

- **`MobMidi.KeyboardScreen`** (`/midi/keyboard`) — a two-octave keyboard; tap a
  key to send a note to the selected output. Meant to be landscape; **currently
  portrait-stubbed** (white keys, two rows) until `Mob.Device.lock_orientation/1`
  lands in mob core ([mob#49](https://github.com/GenericJam/mob/pull/49)).
- **`MobMidi.InputScreen`** (`/midi/input`) — pick a source, watch incoming
  notes light up plus a decoded event log. Visual-first; an audible sine per
  note is a fast follow once `Mob.Audio` grows a tone primitive.

## Status

**Early.** The Elixir surface (API, parser, screens) is built and unit-tested.
The native layers (iOS `priv/native/ios/mob_midi_nif.m` over CoreMIDI; Android
`priv/native/android/MobMidiBridge.kt` + `priv/native/jni/mob_midi_nif.zig` over
MidiManager) are a **first pass, not yet device-compiled or verified** — device
verification (USB controller on a Moto G; CoreMIDI on an iPhone) is the next
step. Android currently assumes a single port per device (multi-port is a
follow-up).
