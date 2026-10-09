defmodule MobMidiTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobMidi.SelfTest

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

  describe "send_result/2 (native send outcome)" do
    setup do
      %{socket: Mob.Socket.new(MobMidi.KeyboardScreen)}
    end

    test "written and queued sends both hand the socket back", %{socket: socket} do
      assert MobMidi.send_result(socket, :ok) == socket
      assert MobMidi.send_result(socket, :queued) == socket
    end

    test "a send that went nowhere is an error, not a silent no-op", %{socket: socket} do
      assert MobMidi.send_result(socket, {:error, :not_open}) == {:error, :not_open}
      assert MobMidi.send_result(socket, {:error, :queue_full}) == {:error, :queue_full}
      assert MobMidi.send_result(socket, :error) == {:error, :send_failed}
    end
  end

  describe "KeyboardScreen output events" do
    setup do
      socket =
        MobMidi.KeyboardScreen
        |> Mob.Socket.new()
        |> Mob.Socket.assign(output: 7, output_status: "opening...")

      %{socket: socket}
    end

    test ":opened for the selected output marks it ready", %{socket: socket} do
      {:noreply, socket} =
        MobMidi.KeyboardScreen.handle_info(
          {:midi, :opened, %{device: 7, direction: :output}},
          socket
        )

      assert socket.assigns.output_status == "ready"
    end

    test "an open_output error shows its reason", %{socket: socket} do
      error = %{device: 7, op: :open_output, reason: :no_input_port, dropped: 2}
      {:noreply, socket} = MobMidi.KeyboardScreen.handle_info({:midi, :error, error}, socket)
      assert socket.assigns.output_status == "error: no_input_port"
    end

    test "a late reply for a previously selected output is ignored", %{socket: socket} do
      {:noreply, socket} =
        MobMidi.KeyboardScreen.handle_info(
          {:midi, :opened, %{device: 3, direction: :output}},
          socket
        )

      assert socket.assigns.output_status == "opening..."
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
      assert %{errors: []} = Validator.validate_plugin(manifest, @plugin_dir, "0.9.15")
    end

    test "declares the self-test, which passes the validator without a selftest warning" do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      assert manifest.selftest == MobMidi.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(manifest, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "declares both screens, both NIFs, and the CoreMIDI framework" do
      {m, _} = Code.eval_file(Path.join(@plugin_dir, "priv/mob_plugin.exs"))

      routes = Enum.map(m.screens, & &1.default_route)
      assert "/midi_keyboard" in routes
      assert "/midi_input" in routes

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

  describe "MobMidi.SelfTest" do
    defp answer(msg) do
      send(self(), msg)
      result = SelfTest.classify(:ok, 0)
      assert Mob.Plugin.SelfTest.result?(result)
      result
    end

    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      assert {:fail, reason} = result = SelfTest.run(%{platform: :android, device: :emulator})
      assert reason =~ "mob_midi_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "an unregistered Android bridge or a JNI failure fails without waiting for an answer" do
      send(self(), {:midi, :devices, []})

      for {ret, prefix} <- [
            {{:error, :nif_not_loaded}, "midi_list_devices/0 returned {:error, :nif_not_loaded}"},
            {:error, "midi_list_devices/0 returned :error"},
            {:queued, "midi_list_devices/0 returned :queued, expected :ok"}
          ] do
        assert {:fail, reason} = result = SelfTest.classify(ret, 0)
        assert String.starts_with?(reason, prefix)
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "a non-empty device list passes, from iOS (maps) or Android (JSON)" do
      assert answer({:midi, :devices, [%{id: -12_345, name: "Network", direction: :input}]}) ==
               :pass

      assert answer({:midi, :devices, ~s([{"id":3,"name":"Oxygen 49","direction":"both"}])}) ==
               :pass
    end

    test "an empty device list is a hardware skip on both platforms" do
      assert answer({:midi, :devices, []}) == {:skip, :needs_hardware}
      assert answer({:midi, :devices, "[]"}) == {:skip, :needs_hardware}
    end

    test "list_devices errors: no MIDI service skips, a missing Activity or client fails" do
      err = &{:midi, :error, %{device: 0, op: :list_devices, reason: &1, dropped: 0}}

      assert answer(err.(:no_midi_service)) == {:skip, :needs_hardware}
      assert {:fail, "MobMidiBridge has no Activity" <> _} = answer(err.(:no_activity))
      assert {:fail, "CoreMIDI MIDIClientCreate failed" <> _} = answer(err.(:no_client))
      assert {:fail, "midi_list_devices/0 delivered error :bogus"} = answer(err.(:bogus))
    end

    test "a malformed device list fails instead of passing or skipping" do
      assert {:fail, "midi_list_devices/0 delivered \"not json\"" <> _} =
               answer({:midi, :devices, "not json"})

      assert {:fail, "midi_list_devices/0 delivered %{}" <> _} = answer({:midi, :devices, %{}})

      assert {:fail, "midi_list_devices/0 delivered malformed devices" <> _} =
               answer({:midi, :devices, [%{name: "no id"}]})
    end

    test "ignores other MIDI traffic and fails when no list arrives" do
      send(self(), {:midi, :device_added, nil})
      send(self(), {:midi, :error, %{device: 7, op: :open_output, reason: :closed, dropped: 0}})

      assert {:fail, "midi_list_devices/0 returned :ok but delivered no" <> _} =
               result = SelfTest.classify(:ok, 0)

      assert Mob.Plugin.SelfTest.result?(result)
    end
  end
end
