defmodule :mob_midi_ios_test_nif do
  # The iOS NIF (priv/native/ios/mob_midi_nif.m) built for macOS with the
  # probes of test/c/mob_midi_ios_test_nif.m: the midi_* NIFs, the C ABI an
  # app's static NIF calls (sink, send, discard, source info) and a peer
  # CoreMIDI client standing in for another app or a device.
  @moduledoc false

  def load(path), do: :erlang.load_nif(String.to_charlist(path), 0)

  def midi_list_devices, do: :erlang.nif_error(:nif_not_loaded)
  def midi_open_input(_device, _port, _route), do: :erlang.nif_error(:nif_not_loaded)
  def midi_open_output(_device, _port), do: :erlang.nif_error(:nif_not_loaded)
  def midi_close(_device), do: :erlang.nif_error(:nif_not_loaded)
  def midi_send(_device, _port, _bytes, _at), do: :erlang.nif_error(:nif_not_loaded)
  def midi_now_ns, do: :erlang.nif_error(:nif_not_loaded)
  def midi_open_virtual(_name, _route), do: :erlang.nif_error(:nif_not_loaded)
  def midi_output_handle(_device, _port), do: :erlang.nif_error(:nif_not_loaded)
  def midi_discard(_device, _port), do: :erlang.nif_error(:nif_not_loaded)
  def sink_start, do: :erlang.nif_error(:nif_not_loaded)
  def sink_stop, do: :erlang.nif_error(:nif_not_loaded)
  def sink_take, do: :erlang.nif_error(:nif_not_loaded)
  def c_send(_handle, _bytes, _at), do: :erlang.nif_error(:nif_not_loaded)
  def c_discard(_handle), do: :erlang.nif_error(:nif_not_loaded)
  def c_source_info(_source), do: :erlang.nif_error(:nif_not_loaded)
  def c_now, do: :erlang.nif_error(:nif_not_loaded)
  def c_abi, do: :erlang.nif_error(:nif_not_loaded)
  def peer_open(_name), do: :erlang.nif_error(:nif_not_loaded)
  def peer_dispose, do: :erlang.nif_error(:nif_not_loaded)
  def peer_take, do: :erlang.nif_error(:nif_not_loaded)
  def peer_play(_bytes, _stamp), do: :erlang.nif_error(:nif_not_loaded)
  def peer_send(_device, _bytes, _stamp), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule MobMidi.IosHostTest do
  # The iOS native layer against real CoreMIDI on a Mac: loopbacks through an
  # own virtual device and a peer client's endpoints, through the BEAM API
  # and the C ABI of priv/include/mob_midi.h, with send times and stamps.
  # CoreMIDI and the NIF's code are the same on iOS; the simulator and device
  # checks are in the CHANGELOG.
  use ExUnit.Case, async: false

  @moduletag :macos_only
  @moduletag :requires_cc

  alias :mob_midi_ios_test_nif, as: Nif

  @root Path.expand("..", __DIR__)

  @ok 0
  @err_not_open -1
  @err_queue_full -2
  @err_busy -4
  @err_invalid -5
  @err_too_large -7

  @ms 1_000_000

  setup_all do
    dir = Path.join(System.tmp_dir!(), "mob_midi_ios_host_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    lib = Path.join(dir, "mob_midi_ios_test_nif.so")
    erts = Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])

    {out, status} =
      System.cmd(
        "cc",
        ~w(-bundle -undefined dynamic_lookup -fobjc-arc -fmodules -Wall -Wextra -Werror) ++
          ["-I", erts, "-framework", "CoreMIDI", "-framework", "Foundation"] ++
          [Path.join(@root, "test/c/mob_midi_ios_test_nif.m"), "-o", lib],
        stderr_to_stdout: true
      )

    assert status == 0, "cc failed:\n" <> out
    assert Nif.load(Path.rootname(lib)) == :ok
    on_exit(fn -> File.rm_rf!(dir) end)
    # The plugin's client is the process's first (hot-plug, see peer_open),
    # and this test process doesn't stay the hot-plug subscriber.
    Nif.midi_list_devices()

    receive do
      {:midi, :devices, _} ->
        :ok

      {:midi, :error, %{reason: :no_client}} ->
        # macOS stops an idle MIDIServer a few seconds after its last client
        # leaves; a client made as it exits loses its connection for good.
        flunk("MIDIClientCreate failed: MIDIServer was exiting (runs back to back?); rerun")
    after
      5000 -> flunk("no answer to midi_list_devices")
    end
  end

  setup do
    flush()
    Nif.sink_take()
    Nif.peer_take()
    on_exit(fn -> Nif.sink_stop() end)
    :ok
  end

  test "the C ABI version and clock are the plugin's" do
    assert Nif.c_abi() == 1
    a = Nif.c_now()
    b = Nif.midi_now_ns()
    assert b >= a and b - a < 10 * @ms
  end

  test "a send at a future time loops back through an own virtual device: bytes, stamp, timing" do
    id = open_virtual("mm loop")
    source = open_input(id, 3)
    assert Nif.sink_start() == @ok
    assert {:ok, handle} = Nif.midi_output_handle(id, 0)

    at = Nif.c_now() + 50 * @ms
    assert Nif.c_send(handle, <<0x90, 60, 100>>, at) == @ok
    assert_receive {:midi, :raw, %{device: ^id, port: 0, bytes: <<0x90, 60, 100>>} = raw}, 1000

    # Stamped with `at` (to the tick), handed over at `at`, not before.
    assert raw.timestamp >= at and raw.timestamp - at < 50
    assert raw.received >= at
    late = raw.received - at
    assert late < 20 * @ms, "arrived #{late} ns after its time"

    {@ok, generation, ^id, 0} = Nif.c_source_info(source)

    assert [{^source, ^generation, <<0x90, 60, 100>>, stamp, _arrived, 3}] = Nif.sink_take()
    assert stamp == raw.timestamp
    close(id)
  end

  test "sends reach a destination in time order, each at its time, stamped with it" do
    {dest, _src} = peer("mm peer order")
    handle = open_output(dest)
    now = Nif.c_now()
    times = for k <- [30, 10, 20], do: {k, now + k * @ms}

    for {k, at} <- times, do: assert(Nif.c_send(handle, <<0x90, k, 1>>, at) == @ok)
    Process.sleep(150)

    arrivals = Nif.peer_take()

    assert Enum.map(arrivals, fn {_, _, bytes, _, _, _} -> bytes end) ==
             [<<0x90, 10, 1>>, <<0x90, 20, 1>>, <<0x90, 30, 1>>]

    for {{_k, at}, {_, _, _, stamp, arrived, _}} <- Enum.zip(Enum.sort(times), arrivals) do
      assert stamp >= at and stamp - at < 50
      assert arrived >= at and arrived - at < 20 * @ms
    end

    close(dest)
    Nif.peer_dispose()
  end

  test "send timing: a hundred sends 5 ms ahead arrive on time" do
    {dest, _src} = peer("mm peer timing")
    handle = open_output(dest)

    late =
      for i <- 1..100 do
        at = Nif.c_now() + 5 * @ms
        assert Nif.c_send(handle, <<0x90, rem(i, 128), 1>>, at) == @ok
        Process.sleep(8)
        assert [{_, _, _, _stamp, arrived, 3}] = Nif.peer_take()
        assert arrived >= at
        arrived - at
      end

    sorted = Enum.sort(late)
    median = Enum.at(sorted, 50)
    worst = List.last(sorted)

    IO.puts(
      "\n    send at: -> arrival, 100 sends: median #{div(median, 1000)} us, worst #{div(worst, 1000)} us"
    )

    assert median < 2 * @ms
    close(dest)
    Nif.peer_dispose()
  end

  test "a device source opened with deliver: :native reaches only the sink, with the sender's stamp" do
    {_dest, src} = peer("mm peer in")
    source = open_input(src, 2)
    assert Nif.sink_start() == @ok

    stamp = Nif.c_now() + 2 * @ms
    assert Nif.peer_play(<<0xB0, 7, 90>>, stamp) == :ok
    Process.sleep(50)
    # Unstamped by the sender: the sink gets 0 (mob_midi_timestamp_or).
    assert Nif.peer_play(<<0xB0, 7, 91>>, 0) == :ok
    Process.sleep(50)

    {@ok, generation, ^src, 0} = Nif.c_source_info(source)

    assert [
             {^source, ^generation, <<0xB0, 7, 90>>, got, _, 3},
             {^source, ^generation, <<0xB0, 7, 91>>, 0, _, 3}
           ] =
             Nif.sink_take()

    assert got >= stamp and got - stamp < 50
    refute_received {:midi, :raw, _}
    close(src)
    Nif.peer_dispose()
  end

  test "what another app sends into an own virtual destination reaches the opener, per generation" do
    id = open_virtual("mm loop in")
    assert Nif.sink_start() == @ok
    dest = own_destination("mm loop in")

    assert Nif.peer_open("mm peer sender") |> is_tuple()
    assert Nif.peer_send(dest, <<0x90, 64, 80>>, 0) == :ok

    assert_receive {:midi, :raw,
                    %{device: ^id, bytes: <<0x90, 64, 80>>, timestamp: ts, received: rcv}},
                   1000

    # Unstamped: the BEAM gets the arrival time.
    assert ts == rcv
    assert Nif.sink_take() == []

    # A second open_virtual replaces the first: a new source and generation
    # for the native route, the old one closed.
    Nif.midi_open_virtual("mm loop in", 2)
    assert_receive {:midi, :opened, %{device: ^id, direction: :virtual}}
    assert Nif.peer_send(dest, <<0x80, 64, 0>>, 0) == :ok
    Process.sleep(50)
    assert [{source, generation, <<0x80, 64, 0>>, 0, _, 3}] = Nif.sink_take()
    assert {@ok, ^generation, ^id, 0} = Nif.c_source_info(source)
    refute_received {:midi, :raw, _}

    close(id)
    assert {@err_invalid, _, _, _} = Nif.c_source_info(source)
    assert Nif.peer_send(dest, <<0x90, 65, 80>>, 0) == :ok
    Process.sleep(50)
    assert Nif.sink_take() == []
    Nif.peer_dispose()
  end

  test "discard drops what is queued and starts a new queue generation" do
    {dest, _src} = peer("mm peer discard")
    handle = open_output(dest)
    at = Nif.c_now() + 200 * @ms
    for n <- 1..5, do: assert(Nif.c_send(handle, <<0x90, n, 1>>, at) == @ok)

    generation = Nif.c_discard(handle)
    assert generation > 1
    assert Nif.midi_discard(dest, 0) == {:ok, generation + 1}
    Process.sleep(300)
    assert Nif.peer_take() == []

    assert Nif.c_send(handle, <<0x90, 9, 1>>, 0) == @ok
    Process.sleep(50)
    assert [{_, _, <<0x90, 9, 1>>, _, _, 3}] = Nif.peer_take()
    close(dest)
    Nif.peer_dispose()
  end

  test "a full queue refuses every send until it has drained, then the opener hears :drained" do
    {dest, _src} = peer("mm peer full")
    handle = open_output(dest)
    at = Nif.c_now() + 100 * @ms
    for n <- 1..256, do: assert(Nif.c_send(handle, <<0xF8>>, at + n) == @ok)

    assert Nif.c_send(handle, <<0x90, 1, 1>>, 0) == @err_queue_full
    # Refusing: even a message that would fit is refused, BEAM sends too.
    assert Nif.midi_send(dest, 0, <<0xF8>>, 0) == {:error, :queue_full}

    assert_receive {:midi, :drained, %{device: ^dest, port: 0, handle: ^handle, generation: 1}},
                   1000

    assert Nif.c_send(handle, <<0x90, 1, 1>>, 0) == @ok
    Process.sleep(50)
    # CoreMIDI may hand a receiver several messages in one packet: count bytes.
    assert Enum.sum(Enum.map(Nif.peer_take(), fn {_, _, _, _, _, len} -> len end)) == 256 + 3
    close(dest)
    Nif.peer_dispose()
  end

  test "a message is never split or refused for its size up to 16 KiB, and too large beyond" do
    {dest, _src} = peer("mm peer sysex")
    handle = open_output(dest)
    sysex = <<0xF0>> <> :binary.copy(<<0x11>>, 16_382) <> <<0xF7>>
    assert byte_size(sysex) == 16_384
    assert Nif.c_send(handle, sysex <> <<0>>, 0) == @err_too_large
    assert Nif.midi_send(dest, 0, sysex <> <<0>>, 0) == {:error, :too_large}
    assert Nif.c_send(handle, sysex, 0) == @ok
    Process.sleep(200)
    arrivals = Nif.peer_take()
    assert Enum.sum(Enum.map(arrivals, fn {_, _, _, _, _, len} -> len end)) == 16_384
    close(dest)
    Nif.peer_dispose()
  end

  test "close: no bytes of the old port, its source closed and its handle not open" do
    {dest, src} = peer("mm peer close")
    source = open_input(src, 3)
    handle = open_output(dest)
    assert Nif.sink_start() == @ok

    Nif.midi_close(src)
    Nif.midi_close(dest)
    assert {@err_invalid, _, _, _} = Nif.c_source_info(source)
    assert Nif.c_send(handle, <<0x90, 1, 1>>, 0) == @err_not_open
    assert Nif.c_discard(handle) == @err_not_open
    assert Nif.midi_send(dest, 0, <<0x90, 1, 1>>, 0) == {:error, :not_open}
    assert Nif.midi_output_handle(dest, 0) == {:error, :not_open}

    assert Nif.peer_play(<<0x90, 2, 2>>, 0) == :ok
    Process.sleep(50)
    assert Nif.sink_take() == []
    refute_received {:midi, :raw, _}

    # Reopened: a new handle; the stale one stays closed.
    new_handle = open_output(dest)
    assert new_handle != handle
    assert Nif.c_send(handle, <<0x90, 1, 1>>, 0) == @err_not_open
    close(dest)
    Nif.peer_dispose()
  end

  test "an opened output opened again keeps its handle, and its events go to the new opener" do
    {dest, _src} = peer("mm peer reopen")
    handle = open_output(dest)
    me = self()

    task =
      Task.async(fn ->
        Nif.midi_open_output(dest, 0)
        assert_receive {:midi, :opened, %{device: ^dest, handle: ^handle}}
        send(me, :reopened)
        assert_receive {:midi, :drained, %{handle: ^handle}}, 1000
        :drained
      end)

    assert_receive :reopened
    at = Nif.c_now() + 50 * @ms
    for n <- 1..256, do: assert(Nif.c_send(handle, <<0xF8>>, at + n) == @ok)
    assert Nif.c_send(handle, <<0xF8>>, 0) == @err_queue_full
    assert Task.await(task) == :drained
    refute_received {:midi, :drained, _}
    close(dest)
    Nif.peer_dispose()
  end

  test "a device that goes away has its ports closed, then the subscriber hears :device_removed" do
    {dest, src} = peer("mm peer gone")
    source = open_input(src, 2)
    handle = open_output(dest)
    Nif.midi_list_devices()
    assert_receive {:midi, :devices, _}

    Nif.peer_dispose()
    assert_receive {:midi, :device_removed, nil}, 2000
    assert {@err_invalid, _, _, _} = Nif.c_source_info(source)
    assert Nif.c_send(handle, <<0x90, 1, 1>>, 0) == @err_not_open
  end

  test "one sink at a time; unregistering returns once no call is running" do
    assert Nif.sink_start() == @ok
    assert Nif.sink_start() == @err_busy
    assert Nif.sink_stop() == @ok
    assert Nif.sink_start() == @ok
  end

  test "errors are values: unknown devices, unopened outputs" do
    Nif.midi_open_output(12_345, 0)
    assert_receive {:midi, :error, %{device: 12_345, op: :open_output, reason: :no_such_device}}
    Nif.midi_open_input(12_345, 0, 1)
    assert_receive {:midi, :error, %{device: 12_345, op: :open_input, reason: :no_such_device}}
    assert Nif.midi_send(12_345, 0, <<0x90, 1, 1>>, 0) == {:error, :not_open}
    assert Nif.midi_discard(12_345, 0) == {:error, :not_open}
    assert Nif.midi_output_handle(12_345, 0) == {:error, :not_open}
    assert Nif.c_send(0, <<0x90>>, 0) == @err_not_open
    assert Nif.c_send(1, <<>>, 0) == @err_invalid
    assert {@err_invalid, _, _, _} = Nif.c_source_info(0)
    assert {@err_invalid, _, _, _} = Nif.c_source_info(64)
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp open_virtual(name) do
    Nif.midi_open_virtual(name, 1)
    assert_receive {:midi, :opened, %{device: id, direction: :virtual, name: ^name}}, 1000
    id
  end

  defp open_input(device, route) do
    Nif.midi_open_input(device, 0, route)

    assert_receive {:midi, :opened,
                    %{device: ^device, port: 0, direction: :input, source: source}},
                   1000

    assert source in 1..63
    source
  end

  defp open_output(device) do
    Nif.midi_open_output(device, 0)

    assert_receive {:midi, :opened,
                    %{device: ^device, port: 0, direction: :output, handle: handle}},
                   1000

    assert handle > 0
    handle
  end

  defp close(device), do: assert(Nif.midi_close(device) == :ok)

  defp peer(name) do
    assert {dest, src} = Nif.peer_open(name)
    {dest, src}
  end

  defp own_destination(name) do
    Nif.midi_list_devices()
    assert_receive {:midi, :devices, devices}, 1000

    %{id: id} =
      Enum.find(devices, &(&1.name == name and &1.direction == :output and &1.own == true))

    id
  end

  defp flush do
    receive do
      {:midi, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end

defmodule MobMidi.IosApiHostTest do
  # MobMidi and MobMidi.SelfTest as an iOS app runs them: the iOS NIF built
  # for macOS is loaded as :mob_midi_nif itself, and MobMidi.Platform says
  # :ios until the module is done. Every other module but the one above is
  # async, so they have all run by then. The NIF stays loaded: unloading it
  # would pull its code out from under its live CoreMIDI client and threads.
  use ExUnit.Case, async: false

  @moduletag :macos_only
  @moduletag :requires_cc

  @root Path.expand("..", __DIR__)
  @ms 1_000_000

  setup_all do
    dir = Path.join(System.tmp_dir!(), "mob_midi_ios_api_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    erts = Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])

    {out, status} =
      System.cmd(
        "cc",
        ~w(-bundle -undefined dynamic_lookup -fobjc-arc -fmodules -Wall -Wextra -Werror) ++
          ["-I", erts, "-framework", "CoreMIDI", "-framework", "Foundation"] ++
          [
            Path.join(@root, "priv/native/ios/mob_midi_nif.m"),
            "-o",
            Path.join(dir, "mob_midi_nif.so")
          ],
        stderr_to_stdout: true
      )

    assert status == 0, "cc failed:\n" <> out
    # src/mob_midi_nif.erl loads "mob_midi_nif" from the working directory.
    reload_nif_module(dir)
    # Loaded: answers instead of raising nif_not_loaded.
    assert :mob_midi_nif.midi_output_handle(0, 0) == {:error, :not_open}
    :persistent_term.put({MobMidi.Platform, :platform}, :ios)

    on_exit(fn ->
      :persistent_term.erase({MobMidi.Platform, :platform})
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp reload_nif_module(cwd) do
    here = File.cwd!()
    File.cd!(cwd)
    :code.purge(:mob_midi_nif)
    :code.delete(:mob_midi_nif)
    :code.purge(:mob_midi_nif)
    {:module, :mob_midi_nif} = :code.load_file(:mob_midi_nif)
    File.cd!(here)
  end

  # An own virtual device (its sink route too) with a BEAM input on its own
  # source: what is sent out of it comes back as :raw.
  defp open_loop(name) do
    assert MobMidi.Platform.current() == :ios
    assert MobMidi.open_virtual(:socket, name, deliver: :both) == :socket
    assert_receive {:midi, :opened, %{device: id, direction: :virtual, name: ^name}}, 1000
    assert MobMidi.open_input(:socket, id) == :socket
    assert_receive {:midi, :opened, %{device: ^id, port: 0, direction: :input, source: s}}, 1000
    assert s in 1..63
    on_exit(fn -> MobMidi.close(:socket, id) end)
    id
  end

  test "MobMidi.SelfTest's iOS loop passes against CoreMIDI" do
    assert MobMidi.SelfTest.run(%{platform: :ios, device: :simulator}) == :pass
  end

  test "deliver: :native and port: :all open on iOS; reopening an input gives it a new source" do
    id = open_loop("mm api routes")
    assert MobMidi.open_input(:socket, id, port: :all, deliver: :native) == :socket
    assert_receive {:midi, :opened, %{device: ^id, port: 0, direction: :input, source: s}}, 1000
    assert MobMidi.open_input(:socket, id, deliver: :both) == :socket
    assert_receive {:midi, :opened, %{device: ^id, port: 0, direction: :input, source: s2}}, 1000
    assert s2 != s
    assert {:ok, _handle} = MobMidi.output_handle(id)
    assert MobMidi.output_handle(id, port: 1) == {:error, :not_open}
  end

  test "send_raw at: goes out at that time, stamped with it; discard drops what waits" do
    id = open_loop("mm api send")
    at = MobMidi.now_ns() + 30 * @ms
    assert MobMidi.send_raw(:socket, id, <<0x90, 60, 100>>, at: at) == :socket
    assert_receive {:midi, :raw, %{device: ^id, port: 0, bytes: <<0x90, 60, 100>>} = raw}, 1000
    assert raw.timestamp >= at and raw.timestamp - at < 1000
    assert raw.received >= at

    later = MobMidi.now_ns() + 200 * @ms
    assert MobMidi.send_raw(:socket, id, <<0x90, 61, 100>>, at: later) == :socket
    assert MobMidi.discard(id) == {:ok, 2}
    refute_receive {:midi, :raw, _}, 300
  end

  test "close/2 ends an output's handle; opening it again gives a new one" do
    id = open_loop("mm api close")
    assert {:ok, handle} = MobMidi.output_handle(id)
    assert MobMidi.close(:socket, id) == :socket
    assert MobMidi.output_handle(id) == {:error, :not_open}
    assert MobMidi.discard(id) == {:error, :not_open}
    assert MobMidi.send_raw(:socket, id, <<0xF8>>) == {:error, :not_open}

    assert MobMidi.open_virtual(:socket, "mm api close") == :socket
    assert_receive {:midi, :opened, %{device: ^id, direction: :virtual}}, 1000
    assert {:ok, new_handle} = MobMidi.output_handle(id)
    assert new_handle != handle
  end
end
