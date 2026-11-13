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

On-device self-test: `MobMidi.SelfTest` (declared as `selftest:` in the
manifest) lists MIDI devices through the NIF; run it from a host app with
`mix mob.selftest` (mob_dev 0.7.17+). No attached MIDI device is a
`:needs_hardware` skip.

## Ports, timestamps, hot-plug

- **Ports**: `list_devices/1` reports each device's `input_ports` /
  `output_ports`; `open_input/3`, `open_output/3` and `send_raw/4` take
  `port:` (default 0). CoreMIDI endpoints are single ports.
- **Timestamps**: incoming `{:midi, :raw, ...}` carries the sender's
  `timestamp` and when the bridge `received` it (ns on the `MobMidi.now_ns/0`
  clock). `send_raw(socket, id, bytes, at: ns)` stamps outgoing bytes for when
  the receiver should act on them: MIDI clock without the BEAM's timer jitter.
- **Hot-plug**: the last `list_devices/1` caller gets `{:midi, :device_added |
  :device_removed, nil}` on both platforms.

## Virtual devices (the app as a MIDI device)

`MobMidi.open_virtual(socket, name)` subscribes to one of the app's own MIDI
devices: other apps on the phone see it, play into it (arriving as `{:midi,
:raw, ...}`) and listen to what `send_raw/4` sends to its id.

On iOS it creates a CoreMIDI source + destination of that name. On Android a
virtual device is declared in the app's manifest (Android reads its name and
ports from the app's own `res/xml`, so a plugin can't contribute a per-app
one). Generate the declaration, which uses the plugin's
`io.mob.midi.MobMidiDeviceService`:

```sh
mix mob_midi.gen.virtual_device --name "My Synth" --inputs 1 --outputs 1
# writes android/app/src/main/res/xml/mob_midi_device.xml and a fenced
# <service> block in android/app/src/main/AndroidManifest.xml;
# --check in CI, --remove to take it out; or config :mob_midi, :virtual_device
```

`--inputs` are ports other apps send into the app, `--outputs` ports it sends
out of (Humdinger: `--inputs 0 --outputs 1`; Magpie: `--inputs 1 --outputs 1`).
Then `MobMidi.open_virtual(socket, "My Synth")`. Android also reports who has
it open: `{:midi, :virtual_status, %{device: id, senders: n, listeners: n}}`.
A second device needs its own `<service>`: declare an empty subclass of
`io.mob.midi.MobMidiDeviceService` in the app. Android starts the service when
another app opens the device, possibly before the BEAM is up; bytes sent before
`open_virtual/3` are dropped.

## Native code (Android): `priv/include/mob_midi.h`

An audio engine in another static NIF of the app can take MIDI without the
BEAM: open inputs with `deliver: :native` (or `:both`, per port), register a
sink with `mob_midi_set_sink(fn, ctx)` and get `(source, generation, bytes,
len, timestamp_ns)` on the MIDI thread; pass an output's `handle` (from
`:opened` or `MobMidi.output_handle/2`) to it and call `mob_midi_send(handle,
bytes, len, at_ns)` from its own thread. Sends wait in the port's queue until
`at_ns` (the BEAM's `send_raw(..., at:)` shares that queue). Include it
relative to your source: `#include "../deps/mob_midi/priv/include/mob_midi.h"`.
The header documents thread and lifetime rules;
`priv/include/mob_midi_parser.h` is a matching header-only stream parser.

## Bluetooth MIDI devices (Android)

`MobMidi.scan_bluetooth(socket)` finds BLE-MIDI devices (`{:midi,
:bluetooth_device, %{address: a, name: n, rssi: dbm}}`), `MobMidi.connect_bluetooth(socket,
address)` connects one, which then lists and opens like a USB device; `close/2`
disconnects it. Ask for the `:midi_bluetooth` permission first
(`Mob.Permissions.request(socket, :midi_bluetooth)`). The plugin declares the Bluetooth
and location permissions scanning needs; the request includes location on every
version (Android 12+ too, as mob_dev can't mark `BLUETOOTH_SCAN`
`neverForLocation`), and scans need location switched on (`:location_off`). iOS pairs BLE-MIDI devices in the system UI
(`CABTMIDICentralViewController`); they are then ordinary CoreMIDI devices.

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

Ports, timestamps, hot-plug and virtual devices were then checked on an Android
emulator by a host app (FMutate) with a `MobMidiDeviceService` device played by,
and listening to, a second app; the iOS side of them is compile-checked only.

Not verified: USB-MIDI and BLE-MIDI hardware on either platform (including the
`MobMidi.Ble` peripheral and `connect_bluetooth/2`).

Activating both mob_midi and mob_bluetooth: both declare
`NSBluetoothAlwaysUsageDescription`, and mob_dev (0.7.14) refuses the native
build when two activated plugins declare the same key. Set it in the host's
`ios/Info.plist`: the host's value wins and the plugins no longer conflict.
