defmodule MobMidiTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "message encoders (pure)" do
    test "note_on / note_off set the right status nibble + channel" do
      assert MobMidi.note_on_bytes(0, 60, 100) == <<0x90, 60, 100>>
      assert MobMidi.note_on_bytes(3, 60, 100) == <<0x93, 60, 100>>
      assert MobMidi.note_off_bytes(0, 60, 0) == <<0x80, 60, 0>>
    end

    test "cc + program change" do
      assert MobMidi.cc_bytes(0, 7, 90) == <<0xB0, 7, 90>>
      assert MobMidi.program_change_bytes(1, 5) == <<0xC1, 5>>
    end

    test "out-of-range args raise (the guards)" do
      assert_raise FunctionClauseError, fn -> MobMidi.note_on_bytes(16, 60, 100) end
      assert_raise FunctionClauseError, fn -> MobMidi.note_on_bytes(0, 128, 100) end
    end
  end

  describe "parse/1" do
    test "decodes note on / off" do
      assert MobMidi.parse(<<0x90, 60, 100>>) == [
               %{type: :note_on, channel: 0, note: 60, velocity: 100}
             ]

      assert MobMidi.parse(<<0x82, 60, 40>>) == [
               %{type: :note_off, channel: 2, note: 60, velocity: 40}
             ]
    end

    test "note on with velocity 0 is normalised to note off" do
      assert MobMidi.parse(<<0x90, 60, 0>>) == [
               %{type: :note_off, channel: 0, note: 60, velocity: 0}
             ]
    end

    test "cc, program change, pitch bend" do
      assert MobMidi.parse(<<0xB0, 7, 90>>) == [
               %{type: :cc, channel: 0, controller: 7, value: 90}
             ]

      assert MobMidi.parse(<<0xC1, 5>>) == [%{type: :program_change, channel: 1, program: 5}]
      # pitch bend value = (msb << 7) ||| lsb
      assert MobMidi.parse(<<0xE0, 0x00, 0x40>>) == [
               %{type: :pitch_bend, channel: 0, value: 8192}
             ]
    end

    test "parses a multi-message stream and emits :raw for the undecodable tail" do
      events = MobMidi.parse(<<0x90, 60, 100, 0x80, 60, 0, 0xF8>>)
      assert Enum.map(events, & &1.type) == [:note_on, :note_off, :raw]
    end
  end

  describe "parse_devices/1" do
    test "passes a list of device maps through, normalising direction" do
      ios = [%{id: 7, name: "Oxygen 49", direction: :input}]
      assert MobMidi.parse_devices(ios) == [%{id: 7, name: "Oxygen 49", direction: :input}]
    end

    test "decodes the Android JSON payload (string keys + string direction)" do
      json =
        ~s([{"id":7,"name":"Oxygen 49","direction":"input"},{"id":9,"name":"Synth","direction":"output"}])

      assert MobMidi.parse_devices(json) == [
               %{id: 7, name: "Oxygen 49", direction: :input},
               %{id: 9, name: "Synth", direction: :output}
             ]
    end

    test "tolerates garbage" do
      assert MobMidi.parse_devices("not json") == []
      assert MobMidi.parse_devices(nil) == []
    end
  end

  describe "platform gating" do
    test "MobMidi is supported on ios + android, not the host" do
      refute MobMidi.Platform.unsupported?(:ios)
      refute MobMidi.Platform.unsupported?(:android)
      assert MobMidi.Platform.unsupported?(:host)
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the NIF stub exports the midi_* surface + is nif_not_loaded on host" do
      exports = :mob_midi_nif.module_info(:exports)
      assert {:midi_list_devices, 0} in exports
      assert {:midi_send, 2} in exports
      assert_raise ErlangError, ~r/nif_not_loaded/, fn -> :mob_midi_nif.midi_list_devices() end
    end
  end

  describe "manifest" do
    test "loads + validates clean as a tier-3 plugin (screens + per-platform NIFs)" do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      assert %{errors: []} = Validator.validate_plugin(manifest, @plugin_dir, "0.7.5")
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "declares both screens, both NIFs, and the CoreMIDI framework" do
      {m, _} = Code.eval_file(Path.join(@plugin_dir, "priv/mob_plugin.exs"))

      routes = Enum.map(m.screens, & &1.default_route)
      assert "/midi/keyboard" in routes
      assert "/midi/input" in routes

      langs = Enum.map(m.nifs, & &1.lang) |> Enum.sort()
      assert langs == [:objc, :zig]
      assert "CoreMIDI" in m.ios.frameworks
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "native sources use the right platform APIs" do
      ios = File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_midi_nif.m"))
      assert ios =~ "#import <CoreMIDI/CoreMIDI.h>"
      assert ios =~ "MIDIClientCreate"

      kt = File.read!(Path.join(@plugin_dir, "priv/native/android/MobMidiBridge.kt"))
      assert kt =~ "android.media.midi.MidiManager"
      assert kt =~ "MidiReceiver"
    end
  end
end
