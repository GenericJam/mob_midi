defmodule MobMidi.BleTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias MobMidi.Ble

  describe "uuids" do
    test "exposes the Bluetooth-SIG BLE-MIDI service + characteristic" do
      assert Ble.service_uuid() == "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"
      assert Ble.characteristic_uuid() == "7772E5DB-3868-4112-A1A9-F2669D106BF3"
    end
  end

  describe "encode_packet/2" do
    test "prepends a header + timestamp byte (both with bit 7 set)" do
      <<header, ts_low, rest::binary>> = Ble.encode_packet(<<0x90, 60, 100>>, 0)
      assert (header &&& 0x80) != 0
      assert (ts_low &&& 0x80) != 0
      assert rest == <<0x90, 60, 100>>
    end

    test "splits a 13-bit millisecond timestamp across header/low bytes" do
      # ts 200 -> high 6 bits = 1, low 7 bits = 72 (0x48)
      assert Ble.encode_packet(<<0x90, 60, 100>>, 200) == <<0x81, 0xC8, 0x90, 60, 100>>
    end

    test "wraps the timestamp every 8192 ms" do
      assert Ble.encode_packet(<<0x90, 60, 100>>, 8192) == Ble.encode_packet(<<0x90, 60, 100>>, 0)
    end

    test "accepts a negative timestamp (System.monotonic_time/1 can be negative)" do
      # Regression: a `ts >= 0` guard here crashed every key tap on device,
      # where monotonic time is negative. Must not raise and must round-trip.
      packet = Ble.encode_packet(<<0x90, 60, 100>>, -123_456)
      assert <<h, t, rest::binary>> = packet
      assert (h &&& 0x80) != 0
      assert (t &&& 0x80) != 0
      assert rest == <<0x90, 60, 100>>
      assert Ble.decode_packet(packet) == <<0x90, 60, 100>>
    end
  end

  describe "decode_packet/1 round-trips encode_packet/2" do
    test "note on" do
      packet = Ble.encode_packet(<<0x90, 60, 100>>, 1234)
      assert Ble.decode_packet(packet) == <<0x90, 60, 100>>
    end

    test "program change (single data byte)" do
      packet = Ble.encode_packet(<<0xC0, 7>>, 50)
      assert Ble.decode_packet(packet) == <<0xC0, 7>>
    end

    test "the decoded bytes parse back to the original event" do
      packet = Ble.encode_packet(MobMidi.note_on_bytes(0, 64, 90), 10)

      assert [%{type: :note_on, channel: 0, note: 64, velocity: 90}] =
               packet |> Ble.decode_packet() |> MobMidi.parse()
    end
  end

  describe "decode_packet/1" do
    test "recovers multiple timestamp-prefixed messages in one packet" do
      packet = <<0x80, 0x80, 0x90, 60, 100, 0x80, 0x80, 60, 0>>
      assert Ble.decode_packet(packet) == <<0x90, 60, 100, 0x80, 60, 0>>
    end

    test "returns empty on a malformed or empty packet" do
      assert Ble.decode_packet(<<>>) == <<>>
      # header without bit 7 set is not a BLE-MIDI packet
      assert Ble.decode_packet(<<0x00, 0x80, 0x90, 60, 100>>) == <<>>
    end

    test "drops a truncated trailing message rather than crashing" do
      # header + ts + status but only one of two expected data bytes
      assert Ble.decode_packet(<<0x80, 0x80, 0x90, 60>>) == <<>>
    end
  end
end
