defmodule MobMidi.Ble do
  @moduledoc """
  BLE-MIDI transport: advertise the phone **as a Bluetooth LE MIDI peripheral**
  so a computer (or another phone) connects to it as a central and plays it.

  This is the "phone keyboard drives a computer synth, wirelessly" path. It's a
  thin layer over `MobBluetooth.Le` (the generic GATT-peripheral primitive): the
  only MIDI-specific parts here are the two well-known BLE-MIDI UUIDs and the
  packet framing (a 13-bit-millisecond timestamp header per the BLE-MIDI spec).
  Everything underneath — advertising, the GATT server, notifications, incoming
  writes — is generic Bluetooth and lives in `mob_bluetooth`.

  Once connected, the peripheral shows up in the host's MIDI stack
  (macOS: Audio MIDI Setup → Bluetooth; iOS/other: any BLE-MIDI client).

  ## Sending (phone → computer)

      socket = MobMidi.Ble.advertise(socket, "Mob MIDI")
      # wait for {:bt_le, :subscribed, _} (the central enabled notifications)
      ts = System.monotonic_time(:millisecond)
      socket = MobMidi.Ble.send_note_on(socket, 0, 60, 100, ts)
      socket = MobMidi.Ble.send_note_off(socket, 0, 60, 0, ts)

  ## Receiving (computer → phone)

  Incoming BLE-MIDI arrives as a `MobBluetooth.Le` write on the MIDI
  characteristic:

      {:bt_le, :write, %{characteristic: char, bytes: packet}}

  Strip the BLE framing with `decode_packet/1`, then `MobMidi.parse/1`:

      def handle_info({:bt_le, :write, %{bytes: packet}}, socket) do
        for ev <- MobMidi.parse(MobMidi.Ble.decode_packet(packet)), do: react(ev)
        {:noreply, socket}
      end
  """
  import Bitwise

  # The Bluetooth-SIG BLE-MIDI service + characteristic (MIDI over Bluetooth LE
  # spec). A peripheral advertising this service is recognised as a MIDI device
  # by macOS/iOS and standard BLE-MIDI clients.
  @service_uuid "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"
  @char_uuid "7772E5DB-3868-4112-A1A9-F2669D106BF3"

  @doc "The BLE-MIDI service UUID."
  @spec service_uuid() :: String.t()
  def service_uuid, do: @service_uuid

  @doc "The BLE-MIDI data I/O characteristic UUID."
  @spec characteristic_uuid() :: String.t()
  def characteristic_uuid, do: @char_uuid

  @doc """
  Advertise this device as a BLE-MIDI peripheral named `name`.

  Delegates to `MobBluetooth.Le.start_advertising/2` with the BLE-MIDI service
  and a single read/write/write-without-response/notify characteristic.
  Lifecycle + connection events arrive tagged `:bt_le` (see `MobBluetooth.Le`).
  """
  @spec advertise(socket :: term(), String.t()) :: term()
  def advertise(socket, name \\ "Mob MIDI") do
    MobBluetooth.Le.start_advertising(socket, %{
      local_name: name,
      service_uuid: @service_uuid,
      low_latency: true,
      characteristics: [
        %{uuid: @char_uuid, properties: [:read, :write, :write_without_response, :notify]}
      ]
    })
  end

  @doc "Stop advertising / tear down the BLE-MIDI peripheral."
  @spec stop(socket :: term()) :: term()
  def stop(socket), do: MobBluetooth.Le.stop_advertising(socket)

  # ── Sending ─────────────────────────────────────────────────────────────

  @doc "Send a Note On to subscribed centrals (`ts` is a `:millisecond` clock)."
  @spec send_note_on(term(), 0..15, 0..127, 0..127, integer()) :: term()
  def send_note_on(socket, channel, note, velocity, ts),
    do: send_midi(socket, MobMidi.note_on_bytes(channel, note, velocity), ts)

  @doc "Send a Note Off to subscribed centrals."
  @spec send_note_off(term(), 0..15, 0..127, 0..127, integer()) :: term()
  def send_note_off(socket, channel, note, velocity, ts),
    do: send_midi(socket, MobMidi.note_off_bytes(channel, note, velocity), ts)

  @doc "Send a Control Change to subscribed centrals."
  @spec send_cc(term(), 0..15, 0..127, 0..127, integer()) :: term()
  def send_cc(socket, channel, controller, value, ts),
    do: send_midi(socket, MobMidi.cc_bytes(channel, controller, value), ts)

  @doc """
  Send raw MIDI `bytes` (a single channel-voice or system message) to subscribed
  centrals, wrapped in a BLE-MIDI packet stamped at `ts` milliseconds.
  """
  @spec send_midi(term(), binary(), integer()) :: term()
  def send_midi(socket, bytes, ts) when is_binary(bytes) do
    MobBluetooth.Le.notify(socket, @char_uuid, encode_packet(bytes, ts))
  end

  # ── Packet framing (pure — unit-tested) ──────────────────────────────────

  @doc """
  Wrap raw MIDI `bytes` in a single BLE-MIDI packet.

  A BLE-MIDI packet is a header byte carrying the high 6 bits of a 13-bit
  millisecond timestamp, then a timestamp byte (low 7 bits) before the MIDI
  message. Both framing bytes have bit 7 set; the timestamp wraps every 8192 ms.
  """
  @spec encode_packet(binary(), integer()) :: binary()
  def encode_packet(bytes, ts) when is_binary(bytes) and is_integer(ts) do
    # `ts` may be negative — `System.monotonic_time/1` has an arbitrary origin.
    # Band against the 13-bit mask normalises any integer to 0..8191, so no
    # non-negative guard (an earlier `ts >= 0` guard crashed every key tap on
    # device, where monotonic time is negative).
    t = ts &&& 0x1FFF
    header = 0x80 ||| (t >>> 7 &&& 0x3F)
    ts_low = 0x80 ||| (t &&& 0x7F)
    <<header, ts_low>> <> bytes
  end

  @doc """
  Strip the BLE-MIDI framing from a packet, returning the concatenated raw MIDI
  bytes (feed the result to `MobMidi.parse/1`).

  Handles the common shape — a header followed by `timestamp + status + data`
  groups. Running-status messages (a timestamp followed directly by data bytes,
  reusing the prior status) are **not** reconstructed; the first complete
  message in such a packet is still recovered. Returns `<<>>` for a malformed or
  empty packet.
  """
  @spec decode_packet(binary()) :: binary()
  def decode_packet(<<header, rest::binary>>) when (header &&& 0x80) != 0 do
    strip(rest, <<>>)
  end

  def decode_packet(_), do: <<>>

  # A timestamp byte (bit 7 set) precedes a status byte (bit 7 set), then its
  # data bytes (bit 7 clear). Pull one message and recurse.
  defp strip(<<ts, status, rest::binary>>, acc)
       when (ts &&& 0x80) != 0 and (status &&& 0x80) != 0 do
    n = data_len(status)

    case rest do
      <<data::binary-size(^n), more::binary>> ->
        strip(more, acc <> <<status>> <> data)

      _ ->
        # truncated — keep what parses, drop the tail
        acc
    end
  end

  defp strip(_, acc), do: acc

  # Data-byte count for a channel-voice / common status byte.
  defp data_len(status) do
    case status &&& 0xF0 do
      # Program Change, Channel Pressure → 1 data byte
      0xC0 -> 1
      0xD0 -> 1
      # Note Off/On, Poly Pressure, Control Change, Pitch Bend → 2 data bytes
      _ -> 2
    end
  end
end
