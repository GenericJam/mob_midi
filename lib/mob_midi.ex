defmodule MobMidi do
  @moduledoc """
  MIDI in + out for Mob apps.

  Receive from a controller (keyboard, pads) and send to external synths / DAWs,
  over **USB-MIDI** and **BLE-MIDI**. Unlike `MobBluetooth` (classic BT, Android
  only), MIDI is first-class on both platforms, so this is a real cross-platform
  surface: **CoreMIDI** on iOS, **`android.media.midi`** on Android.

  ## API style

  Same as the rest of Mob: callbacks take and return `socket` unchanged; results
  arrive in `handle_info/2` as messages tagged `:midi`. Functions return
  `{:error, :unsupported}` on the host (no MIDI stack outside a device).

  ## Discovering devices

      MobMidi.list_devices(socket)
      # => {:midi, :devices, [%{id: 1, name: "Oxygen 49", direction: :input}, ...]}

  Hot-plug: on iOS a device appearing / disappearing sends
  `{:midi, :device_added, nil}` / `{:midi, :device_removed, nil}` to the last
  `list_devices/1` caller; re-list on either. Android doesn't deliver hot-plug
  events yet, so re-run `list_devices/1` there.

  ## Receiving

      MobMidi.open_input(socket, device_id)   # subscribe to that source

  Incoming MIDI is delivered to the calling process as raw packets:

      {:midi, :raw, %{device: id, bytes: <<0x90, 60, 100>>}}

  Parse it with `parse/1` (pure, so it's unit-testable and you decide how much
  to decode):

      def handle_info({:midi, :raw, %{bytes: b}}, socket) do
        for ev <- MobMidi.parse(b), do: react(ev)
        {:noreply, socket}
      end

  `parse/1` returns events like `%{type: :note_on, channel: 0, note: 60,
  velocity: 100}` (`:note_on` with velocity 0 is normalised to `:note_off`),
  `:note_off`, `:cc`, `:program_change`, `:pitch_bend`, and `%{type: :raw,
  bytes: ...}` for anything it doesn't decode.

  ## Sending

  Open the output first. `open_output/2` replies to the calling process with
  `{:midi, :opened, %{device: id, direction: :output}}` once the port is ready,
  or `{:midi, :error, %{device: id, op: :open_output, reason: reason, dropped:
  n}}` if it can't be opened:

      MobMidi.open_output(socket, device_id)

      def handle_info({:midi, :opened, %{device: id}}, socket) do
        MobMidi.send_note_on(socket, id, 0, 60, 100)   # ch 0, middle C, vel 100
        MobMidi.send_note_off(socket, id, 0, 60, 0)
        MobMidi.send_cc(socket, id, 0, 7, 90)          # ch 0, CC#7 (volume)
        MobMidi.send_raw(socket, id, <<0xF0, ...>>)    # SysEx / anything
        {:noreply, socket}
      end

      def handle_info({:midi, :error, %{op: :open_output, reason: reason}}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :midi_error, reason)}

  You don't have to wait for `:opened`: Android opens the port asynchronously,
  and sends made before it opens are queued (up to 256 messages per device)
  and written in order the moment it does. If the open fails, the queue is
  discarded and the error event's `dropped` says how many messages were lost.
  iOS opens synchronously, so the event arrives before `open_output/2` returns.

  `send_*` return `socket` when the message was written or queued, and
  `{:error, reason}` when it wasn't: `:not_open` (no `open_output/2` for that
  device, or it was closed or failed to open), `:queue_full`, `:no_such_device`
  (iOS: the destination disappeared), `:too_large` (iOS: over 256 bytes in one
  send) or `:send_failed`; `{:error, :unsupported}` on the host. So bind the
  result rather than piping it on as the socket.

  Channels are `0..15` on the wire (shown as 1..16 in most UIs). Notes /
  velocities / values are `0..127`.

  ## Status: experimental

  The native MIDI paths are experimental. Verified for 0.1.2 against virtual
  MIDI devices: on an Android emulator (`android.media.midi.MidiDeviceService`
  loopbacks in a test host app) and on the iOS simulator (CoreMIDI virtual
  endpoints), covering `list_devices/1`, `open_output/2` and its events, sends
  queued before the port opened (Android), `send_*` errors, `open_input/2`
  receive and `close/2`. Not verified: USB-MIDI and BLE-MIDI hardware on either
  platform, including `MobMidi.Ble`. Android uses port 0 of each device.
  """

  import Bitwise

  # Android: MidiDeviceInfo id; iOS: CoreMIDI endpoint unique id (an SInt32, can be negative).
  @type device_id :: integer()
  @type channel :: 0..15
  @type byte7 :: 0..127

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Enumerate available MIDI devices. Result: `{:midi, :devices, [device]}`."
  @spec list_devices(term()) :: term()
  def list_devices(socket) do
    guarded(socket, fn -> :mob_midi_nif.midi_list_devices() end)
  end

  @doc """
  Subscribe to a device's MIDI input. Incoming packets arrive as
  `{:midi, :raw, %{device: id, bytes: binary}}` to the calling process.
  """
  @spec open_input(term(), device_id()) :: term()
  def open_input(socket, device_id) when is_integer(device_id) do
    guarded(socket, fn -> :mob_midi_nif.midi_open_input(device_id) end)
  end

  @doc """
  Open a device's MIDI output so `send_*` can write to it.

  The calling process receives `{:midi, :opened, %{device: id, direction:
  :output}}` when the port is ready, or `{:midi, :error, %{device: id, op:
  :open_output, reason: reason, dropped: n}}` when it can't be opened (reasons
  include `:no_such_device`, `:open_failed`, `:no_input_port`, and `:closed`
  when `close/2` cancels an open still in flight). Sends made before `:opened`
  are queued and flushed in order; see "Sending" above.
  """
  @spec open_output(term(), device_id()) :: term()
  def open_output(socket, device_id) when is_integer(device_id) do
    guarded(socket, fn -> :mob_midi_nif.midi_open_output(device_id) end)
  end

  @doc "Close any open input/output for `device_id`."
  @spec close(term(), device_id()) :: term()
  def close(socket, device_id) when is_integer(device_id) do
    guarded(socket, fn -> :mob_midi_nif.midi_close(device_id) end)
  end

  @doc "Send a Note On."
  @spec send_note_on(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_note_on(socket, device_id, channel, note, velocity) do
    send_raw(socket, device_id, note_on_bytes(channel, note, velocity))
  end

  @doc "Send a Note Off."
  @spec send_note_off(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_note_off(socket, device_id, channel, note, velocity) do
    send_raw(socket, device_id, note_off_bytes(channel, note, velocity))
  end

  @doc "Send a Control Change (CC)."
  @spec send_cc(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_cc(socket, device_id, channel, controller, value) do
    send_raw(socket, device_id, cc_bytes(channel, controller, value))
  end

  @doc "Send a Program Change."
  @spec send_program_change(term(), device_id(), channel(), byte7()) :: term()
  def send_program_change(socket, device_id, channel, program) do
    send_raw(socket, device_id, program_change_bytes(channel, program))
  end

  @doc """
  Send raw MIDI bytes (SysEx, or anything `send_*` doesn't cover).

  Returns `socket` when the bytes were written, or queued while the output is
  still opening; `{:error, reason}` when they weren't (see "Sending" above).
  """
  @spec send_raw(term(), device_id(), binary()) :: term()
  def send_raw(socket, device_id, bytes) when is_integer(device_id) and is_binary(bytes) do
    if MobMidi.Platform.unsupported?(MobMidi.Platform.current()) do
      {:error, :unsupported}
    else
      send_result(socket, :mob_midi_nif.midi_send(device_id, bytes))
    end
  end

  # The NIF answers :ok (written), :queued (Android output still opening),
  # {:error, reason}, or a bare :error when it couldn't reach the JVM.
  @doc false
  @spec send_result(term(), term()) :: term()
  def send_result(socket, result) when result in [:ok, :queued], do: socket
  def send_result(_socket, {:error, reason}) when is_atom(reason), do: {:error, reason}
  def send_result(_socket, :error), do: {:error, :send_failed}

  # ── Pure message encoders (testable; status nibble | channel) ───────────

  @doc false
  @spec note_on_bytes(channel(), byte7(), byte7()) :: binary()
  def note_on_bytes(ch, note, vel) when ch in 0..15 and note in 0..127 and vel in 0..127,
    do: <<bor(0x90, ch), note, vel>>

  @doc false
  @spec note_off_bytes(channel(), byte7(), byte7()) :: binary()
  def note_off_bytes(ch, note, vel) when ch in 0..15 and note in 0..127 and vel in 0..127,
    do: <<bor(0x80, ch), note, vel>>

  @doc false
  @spec cc_bytes(channel(), byte7(), byte7()) :: binary()
  def cc_bytes(ch, ctrl, val) when ch in 0..15 and ctrl in 0..127 and val in 0..127,
    do: <<bor(0xB0, ch), ctrl, val>>

  @doc false
  @spec program_change_bytes(channel(), byte7()) :: binary()
  def program_change_bytes(ch, prog) when ch in 0..15 and prog in 0..127,
    do: <<bor(0xC0, ch), prog>>

  # ── Pure parser ─────────────────────────────────────────────────────────

  @doc """
  Parse a raw MIDI byte stream into a list of events. Pure — handles the common
  channel-voice messages (note on/off, CC, program change, pitch bend) and emits
  `%{type: :raw, bytes: ...}` for one byte at a time when it can't decode (SysEx,
  running status, real-time bytes). Velocity-0 Note On is normalised to
  `:note_off`.
  """
  @spec parse(binary()) :: [map()]
  def parse(bytes) when is_binary(bytes), do: parse(bytes, [])

  defp parse(<<>>, acc), do: Enum.reverse(acc)

  defp parse(<<status, note, vel, rest::binary>>, acc)
       when status in 0x90..0x9F do
    type = if vel == 0, do: :note_off, else: :note_on
    ev = %{type: type, channel: band(status, 0x0F), note: note, velocity: vel}
    parse(rest, [ev | acc])
  end

  defp parse(<<status, note, vel, rest::binary>>, acc)
       when status in 0x80..0x8F do
    ev = %{type: :note_off, channel: band(status, 0x0F), note: note, velocity: vel}
    parse(rest, [ev | acc])
  end

  defp parse(<<status, ctrl, val, rest::binary>>, acc)
       when status in 0xB0..0xBF do
    ev = %{type: :cc, channel: band(status, 0x0F), controller: ctrl, value: val}
    parse(rest, [ev | acc])
  end

  defp parse(<<status, lsb, msb, rest::binary>>, acc)
       when status in 0xE0..0xEF do
    ev = %{type: :pitch_bend, channel: band(status, 0x0F), value: bor(bsl(msb, 7), lsb)}
    parse(rest, [ev | acc])
  end

  defp parse(<<status, prog, rest::binary>>, acc)
       when status in 0xC0..0xCF do
    ev = %{type: :program_change, channel: band(status, 0x0F), program: prog}
    parse(rest, [ev | acc])
  end

  # Anything else (SysEx, real-time, running status, a truncated tail): emit one
  # raw byte and advance, so a stream is never silently dropped.
  defp parse(<<b, rest::binary>>, acc) do
    parse(rest, [%{type: :raw, bytes: <<b>>} | acc])
  end

  @doc """
  Normalise a `{:midi, :devices, payload}` payload to a list of
  `%{id: integer, name: binary, direction: :input | :output | :both}`.

  iOS delivers a list of maps directly; Android delivers a JSON string (the
  Kotlin bridge builds it from `MidiDeviceInfo`). This collapses both, so a
  screen can do `payload |> MobMidi.parse_devices() |> Enum.filter(...)`. Pure.
  """
  @spec parse_devices(list() | binary() | term()) :: [map()]
  def parse_devices(devices) when is_list(devices), do: Enum.map(devices, &atomize_device/1)

  def parse_devices(json) when is_binary(json) do
    case decode_json(json) do
      list when is_list(list) -> Enum.map(list, &atomize_device/1)
      _ -> []
    end
  end

  def parse_devices(_), do: []

  # :json.decode/1 raises on malformed input; treat that as "no devices".
  defp decode_json(json) do
    :json.decode(json)
  rescue
    ErlangError -> :error
  end

  defp atomize_device(d) when is_map(d) do
    d = normalize_keys(d, [:id, :name, :direction])

    %{
      id: d[:id],
      name: d[:name],
      direction: direction_atom(d[:direction])
    }
  end

  # Devices arrive with atom keys (native bridge) or string keys (JSON);
  # fill each atom key from its string twin when the atom value is missing.
  defp normalize_keys(d, keys) do
    Enum.reduce(keys, d, fn key, acc ->
      if acc[key], do: acc, else: Map.put(acc, key, Map.get(acc, Atom.to_string(key)))
    end)
  end

  defp direction_atom("input"), do: :input
  defp direction_atom("output"), do: :output
  defp direction_atom("both"), do: :both
  defp direction_atom(a) when a in [:input, :output, :both], do: a
  defp direction_atom(_), do: :input

  # ── Helper ──────────────────────────────────────────────────────────────

  defp guarded(socket, fun) do
    if MobMidi.Platform.unsupported?(MobMidi.Platform.current()) do
      {:error, :unsupported}
    else
      fun.()
      socket
    end
  end
end
