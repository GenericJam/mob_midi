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

# Send: open the output, then send. The caller gets
#   {:midi, :opened, %{device: 7, direction: :output}} once the port is ready, or
#   {:midi, :error, %{device: 7, op: :open_output, reason: :no_such_device, dropped: 0}}
MobMidi.open_output(socket, device_id)

def handle_info({:midi, :opened, %{device: id}}, socket) do
  MobMidi.send_note_on(socket, id, 0, 60, 100)
  MobMidi.send_cc(socket, id, 0, 7, 90)
  {:noreply, socket}
end
```

Waiting for `:opened` is optional: Android opens the port asynchronously and
queues sends made before it opens (up to 256 per device), writing them in order
the moment it does. If the open fails, the queue is discarded and the error's
`dropped` counts the lost messages (`close/2` during the open reports `reason:
:closed` the same way). `send_*` return `socket` when the message was written or
queued and `{:error, reason}` when it wasn't (`:not_open`, `:queue_full`,
`:no_such_device`, `:too_large` for iOS sends over 256 bytes, `:send_failed`), so
bind the result instead of piping it on as the socket.

The NIF layer is deliberately thin (device enumeration + raw byte I/O); message
encode/parse lives in Elixir (`MobMidi`) where it's pure and unit-tested.

## Demo screens (tier 3)

Two screens the host auto-lists via `Mob.Plugins.screens()`:

- **`MobMidi.KeyboardScreen`** (`/midi_keyboard`) — a two-octave keyboard; tap a
  key to send a note to the selected output. Meant to be landscape; **currently
  portrait-stubbed** (white keys, two rows) until `Mob.Device.lock_orientation/1`
  lands in mob core ([mob#49](https://github.com/GenericJam/mob/pull/49)).
- **`MobMidi.InputScreen`** (`/midi_input`) — pick a source, watch incoming
  notes light up plus a decoded event log. Visual-first; an audible sine per
  note is a fast follow once `Mob.Audio` grows a tone primitive.

## Status: experimental

The Elixir surface (API, parser, screens) is unit-tested. The native layers (iOS
`priv/native/ios/mob_midi_nif.m` over CoreMIDI; Android
`priv/native/android/MobMidiBridge.kt` + `priv/native/jni/mob_midi_nif.zig` over
MidiManager) are **experimental**.

Verified for 0.1.2, on an Android emulator against virtual MIDI devices
(`android.media.midi.MidiDeviceService` loopbacks in a test host app):
`list_devices/1`, `open_output/2` with its `:opened` / `:error` events, sends
queued before the port opened arriving first and in order, the 256-message queue
bound, `send_*` errors for unopened or closed outputs, `open_input/2` receive, and
one device opened in both directions. On the iOS simulator against CoreMIDI
virtual endpoints (a `MIDIDestinationCreate` synth echoing to a
`MIDISourceCreate` source): `list_devices/1`, `open_output/2` events, `send_*`
(including the `:not_open` error) and `open_input/2` receive.

Not verified: USB-MIDI and BLE-MIDI hardware on either platform (including the
`MobMidi.Ble` peripheral). Android assumes a single port per device (port 0).

Activating both mob_midi and mob_bluetooth: both declare
`NSBluetoothAlwaysUsageDescription`, so set that key in the host's
`ios/Info.plist` (the host's value wins and the plugins don't conflict).
