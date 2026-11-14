defmodule MobMidi.ParserTest do
  use ExUnit.Case, async: true

  alias MobMidi.Parser

  # Feed packets one after another into one parser; returns the events of each.
  defp feed_all(packets) do
    {events, _} =
      Enum.map_reduce(packets, Parser.new(), fn bytes, p -> Parser.feed(p, bytes) end)

    events
  end

  defp on(note, vel), do: %{type: :note_on, channel: 0, note: note, velocity: vel}
  defp off(note), do: %{type: :note_off, channel: 0, note: note, velocity: 0}

  describe "running status" do
    test "note on, with a velocity-0 note on becoming note off" do
      assert MobMidi.parse(<<0x90, 60, 100, 62, 90, 60, 0>>) == [on(60, 100), on(62, 90), off(60)]
    end

    test "control change" do
      assert MobMidi.parse(<<0xB3, 7, 90, 10, 64>>) == [
               %{type: :cc, channel: 3, controller: 7, value: 90},
               %{type: :cc, channel: 3, controller: 10, value: 64}
             ]
    end

    test "two-byte messages: program change and channel aftertouch" do
      assert MobMidi.parse(<<0xC1, 5, 6, 0xD2, 40, 41>>) == [
               %{type: :program_change, channel: 1, program: 5},
               %{type: :program_change, channel: 1, program: 6},
               %{type: :channel_aftertouch, channel: 2, pressure: 40},
               %{type: :channel_aftertouch, channel: 2, pressure: 41}
             ]
    end

    test "pitch bend and poly aftertouch" do
      assert MobMidi.parse(<<0xE0, 0x00, 0x40, 0x7F, 0x7F, 0xA4, 60, 33>>) == [
               %{type: :pitch_bend, channel: 0, value: 8192},
               %{type: :pitch_bend, channel: 0, value: 16_383},
               %{type: :poly_aftertouch, channel: 4, note: 60, pressure: 33}
             ]
    end

    test "survives a packet boundary" do
      assert feed_all([<<0x90, 60, 100>>, <<62, 90>>]) == [[on(60, 100)], [on(62, 90)]]
    end
  end

  describe "real-time bytes" do
    test "between a status and its data, and between data bytes" do
      assert MobMidi.parse(<<0x90, 0xF8, 60, 0xFA, 100>>) == [
               %{type: :clock},
               %{type: :start},
               on(60, 100)
             ]
    end

    test "keep running status" do
      assert MobMidi.parse(<<0x90, 60, 100, 0xF8, 62, 0xFE, 90>>) == [
               on(60, 100),
               %{type: :clock},
               %{type: :active_sensing},
               on(62, 90)
             ]
    end

    test "inside SysEx are emitted without breaking it" do
      assert MobMidi.parse(<<0xF0, 0x7D, 0xF8, 0x01, 0xF7>>) == [
               %{type: :clock},
               %{type: :sysex, bytes: <<0xF0, 0x7D, 0x01, 0xF7>>}
             ]
    end

    test "each real-time status decodes" do
      assert MobMidi.parse(<<0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF>>) |> Enum.map(& &1.type) ==
               [:clock, :start, :continue, :stop, :active_sensing, :reset]
    end
  end

  describe "system common" do
    test "decodes and cancels running status" do
      assert MobMidi.parse(<<0x90, 60, 100, 0xF3, 4, 62, 90>>) == [
               on(60, 100),
               %{type: :song_select, song: 4},
               %{type: :raw, bytes: <<62>>},
               %{type: :raw, bytes: <<90>>}
             ]
    end

    test "quarter frame, song position (lsb first) and tune request" do
      assert MobMidi.parse(<<0xF1, 0x23, 0xF2, 0x01, 0x02, 0xF6>>) == [
               %{type: :mtc_quarter_frame, value: 0x23},
               %{type: :song_position, beats: 0x101},
               %{type: :tune_request}
             ]
    end
  end

  describe "split messages" do
    test "a message split across two packets decodes once complete" do
      assert feed_all([<<0x90, 60>>, <<100>>]) == [[], [on(60, 100)]]

      assert feed_all([<<0xE0>>, <<0x00, 0x40>>]) == [
               [],
               [%{type: :pitch_bend, channel: 0, value: 8192}]
             ]
    end

    test "SysEx completes across two packets" do
      assert feed_all([<<0xF0, 0x7D, 1>>, <<2, 0xF7>>]) == [
               [],
               [%{type: :sysex, bytes: <<0xF0, 0x7D, 1, 2, 0xF7>>}]
             ]
    end
  end

  describe "undecodable bytes" do
    test "SysEx ended by a status byte comes back as one :raw, then the status counts" do
      assert MobMidi.parse(<<0xF0, 0x7D, 1, 0x90, 60, 100>>) == [
               %{type: :raw, bytes: <<0xF0, 0x7D, 1>>},
               on(60, 100)
             ]
    end

    test "a new status mid-message reports the abandoned bytes" do
      assert MobMidi.parse(<<0x90, 60, 0xB0, 7, 90>>) == [
               %{type: :raw, bytes: <<0x90>>},
               %{type: :raw, bytes: <<60>>},
               %{type: :cc, channel: 0, controller: 7, value: 90}
             ]
    end

    test "a stray data byte with no running status" do
      assert MobMidi.parse(<<60, 0x90, 60, 100>>) == [%{type: :raw, bytes: <<60>>}, on(60, 100)]
    end

    test "undefined statuses and a lone 0xF7" do
      assert MobMidi.parse(<<0xF4, 0xF5, 0xF9, 0xFD, 0xF7>>) ==
               Enum.map([0xF4, 0xF5, 0xF9, 0xFD, 0xF7], &%{type: :raw, bytes: <<&1>>})
    end

    test "parse/1 reports a truncated tail byte by byte" do
      assert MobMidi.parse(<<0x90, 60, 100, 0xB0, 7>>) == [
               on(60, 100),
               %{type: :raw, bytes: <<0xB0>>},
               %{type: :raw, bytes: <<7>>}
             ]
    end

    test "flush/1 returns the pending bytes and resets" do
      {[], p} = Parser.feed(Parser.new(), <<0x90, 60>>)
      assert {[%{type: :raw, bytes: <<0x90>>}, %{type: :raw, bytes: <<60>>}], p} = Parser.flush(p)
      # Running status is gone too.
      assert Parser.feed(p, <<62, 90>>) |> elem(0) == [
               %{type: :raw, bytes: <<62>>},
               %{type: :raw, bytes: <<90>>}
             ]
    end
  end

  describe "SysEx cap" do
    test "a SysEx at the cap is kept" do
      body = :binary.copy(<<1>>, 65_535)

      assert MobMidi.parse(<<0xF0, body::binary, 0xF7>>) == [
               %{type: :sysex, bytes: <<0xF0, body::binary, 0xF7>>}
             ]
    end

    test "past the cap it comes back as :raw and the rest is dropped up to 0xF7" do
      body = :binary.copy(<<1>>, 65_535)

      {events, p} = Parser.feed(Parser.new(), <<0xF0, body::binary, 2, 3>>)
      assert events == [%{type: :raw, bytes: <<0xF0, body::binary>>}]

      # Still dropping in the next packet, until the 0xF7; real-time still passes.
      assert {[%{type: :clock}], p} = Parser.feed(p, <<4, 0xF8, 5, 0xF7>>)

      assert {[%{type: :cc, channel: 0, controller: 7, value: 1}], _} =
               Parser.feed(p, <<0xB0, 7, 1>>)
    end
  end
end
