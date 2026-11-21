defmodule MobMidi.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  Step one, on both platforms, read-only: `:mob_midi_nif.midi_list_devices/0`,
  then wait for what the native side sends back to the caller. Both platforms
  answer before the NIF returns (iOS enumerates CoreMIDI endpoints in the
  NIF; Android calls `MobMidiBridge.listDevices` over JNI on the calling
  thread), so the wait is short.

  Step two, on iOS, a loop through the app's own virtual device (Android
  can't make one without the host's declaration): `midi_open_virtual/2`
  makes "mob_midi selftest", `midi_open_input/3` subscribes to its source,
  `midi_output_handle/2` must give its output a native handle, and a short
  SysEx sent 20 ms ahead (`at:`) must come back as `{:midi, :raw, ...}`
  with its bytes, stamped with that time and received no earlier. That
  exercises the send queue and its dispatch thread, CoreMIDI, the receive
  path with its source and generation, and the clock, which the C ABI of
  `priv/include/mob_midi.h` shares with the BEAM path. It then closes the
  device; CoreMIDI keeps the endpoints until the app exits. A pass there
  makes the whole result `:pass` even with no MIDI hardware attached.

  The NIF's return value:

    * `:ok` — the call reached CoreMIDI / the Kotlin bridge; wait for the
      answer below.
    * `{:error, :nif_not_loaded}` returned (not raised) — Android: the zig
      NIF is linked but `MobMidiBridge.register()` never ran or the
      `listDevices` method-ID lookup failed. A failure.
    * `:error` — Android: no JNIEnv for this thread, or `listDevices` threw.
      A failure.
    * The host stub's `nif_not_loaded` raise — the native library is not
      linked into this build. A failure.

  The answer delivered to the caller:

    * `{:midi, :devices, devices}` with at least one device (iOS: a list of
      maps; Android: a JSON array) — `:pass`. On iOS this can include the
      CoreMIDI network session or another app's virtual endpoints even on a
      simulator: that is still a real enumeration from CoreMIDI, so it passes.
    * `{:midi, :devices, []}` (or `"[]"`) — `{:skip, :needs_hardware}`: the
      native stack answered, so the NIF and bridge are proven, but there is
      no MIDI device attached to exercise. (`Mob.Plugin.SelfTest` would also
      allow `:pass` here; this plugin reports a skip so a CI cell shows that
      MIDI I/O itself went unexercised. Init is proven either way.)
    * `{:midi, :error, %{op: :list_devices, reason: :no_midi_service}}` —
      `{:skip, :needs_hardware}`: Android delivered it through the bridge
      (proving it), but the device has no `MidiManager` (no
      `PackageManager.FEATURE_MIDI`).
    * `{:midi, :error, %{op: :list_devices, reason: :no_activity}}` —
      failure: the bootstrap never handed `MobMidiBridge` its Activity.
    * `{:midi, :error, %{op: :list_devices, reason: :no_client}}` — failure:
      iOS `MIDIClientCreate` failed.
    * A malformed device list, another error reason, or no answer within
      5 s — failure.

  State: `midi_list_devices/0` makes the caller the hot-plug subscriber
  (`{:midi, :device_added | :device_removed, nil}`, last caller wins), as
  `MobMidi.list_devices/1` does; the next `list_devices` from a screen takes
  it back. On Android nothing is opened, sent or written; on iOS the loop
  above leaves an idle "mob_midi selftest" virtual device that nothing is
  subscribed to. Stale list answers already in the caller's mailbox are
  flushed before the call, so only this call's answer is classified.
  """
  @behaviour Mob.Plugin.SelfTest

  @answer_timeout 5_000

  @loop_name "mob_midi selftest"
  # SysEx with the non-commercial manufacturer id 0x7D: nothing acts on it.
  @loop_bytes <<0xF0, 0x7D, 0x6D, 0x6D, 0xF7>>
  @loop_lead_ns 20_000_000
  # Received this long after its time at the latest (a loaded simulator).
  @loop_late_ns 500_000_000
  # A stamp converted to CoreMIDI ticks and back is up to a tick late.
  @tick_ns 1_000

  @impl true
  def run(ctx) do
    flush_answers()
    listed = classify(:mob_midi_nif.midi_list_devices(), @answer_timeout)

    case {listed, ctx[:platform]} do
      {{:fail, _}, _} -> listed
      {_, :ios} -> loopback()
      _ -> listed
    end
  catch
    :error, :nif_not_loaded ->
      {:fail,
       "mob_midi_nif is not linked into this build: midi_list_devices/0 raised nif_not_loaded"}
  end

  defp flush_answers do
    receive do
      {:midi, :devices, _} -> flush_answers()
      {:midi, :error, %{op: :list_devices}} -> flush_answers()
    after
      0 -> :ok
    end
  end

  @doc false
  # Classifies midi_list_devices/0's return value, then (on :ok) what the
  # native side delivers to the caller within `timeout` ms.
  @spec classify(term(), non_neg_integer()) :: Mob.Plugin.SelfTest.result()
  def classify(:ok, timeout), do: await_answer(timeout)

  def classify({:error, :nif_not_loaded}, _timeout),
    do:
      {:fail,
       "midi_list_devices/0 returned {:error, :nif_not_loaded}: the Kotlin MobMidiBridge " <>
         "is not registered (register() never ran or the listDevices method-ID lookup failed)"}

  def classify(:error, _timeout),
    do:
      {:fail,
       "midi_list_devices/0 returned :error: no JNIEnv for this thread or " <>
         "MobMidiBridge.listDevices threw"}

  def classify(other, _timeout),
    do: {:fail, "midi_list_devices/0 returned #{inspect(other)}, expected :ok"}

  defp await_answer(timeout) do
    receive do
      {:midi, :devices, payload} ->
        classify_devices(payload)

      {:midi, :error, %{op: :list_devices, reason: reason}} ->
        classify_error(reason)
    after
      timeout ->
        {:fail,
         "midi_list_devices/0 returned :ok but delivered no device list or list_devices error " <>
           "within #{timeout} ms"}
    end
  end

  defp classify_devices(payload) do
    case device_list(payload) do
      {:ok, []} ->
        {:skip, :needs_hardware}

      {:ok, devices} ->
        if Enum.all?(devices, &device?/1),
          do: :pass,
          else: {:fail, "midi_list_devices/0 delivered malformed devices: #{inspect(payload)}"}

      :error ->
        {:fail, "midi_list_devices/0 delivered #{inspect(payload)}, expected a device list"}
    end
  end

  # iOS delivers a list of maps; Android a JSON array string.
  defp device_list(list) when is_list(list), do: {:ok, list}

  defp device_list(json) when is_binary(json) do
    case :json.decode(json) do
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp device_list(_), do: :error

  defp device?(%{id: id}) when is_integer(id), do: true
  defp device?(%{"id" => id}) when is_integer(id), do: true
  defp device?(_), do: false

  defp classify_error(:no_midi_service), do: {:skip, :needs_hardware}

  defp classify_error(:no_activity),
    do:
      {:fail,
       "MobMidiBridge has no Activity (MobActivityAware.setActivity never called), " <>
         "so it cannot reach MidiManager"}

  defp classify_error(:no_client),
    do: {:fail, "CoreMIDI MIDIClientCreate failed, so midi_list_devices/0 cannot enumerate"}

  defp classify_error(reason),
    do: {:fail, "midi_list_devices/0 delivered error #{inspect(reason)}"}

  # ── iOS: a loop through an own virtual device ──────────────────────────

  defp loopback do
    :mob_midi_nif.midi_open_virtual(@loop_name, 1)

    case await_opened(:virtual) do
      {:ok, id} ->
        try do
          loop_through(id)
        after
          :mob_midi_nif.midi_close(id)
        end

      fail ->
        fail
    end
  end

  defp loop_through(id) do
    :mob_midi_nif.midi_open_input(id, 0, 1)

    with {:ok, _source} <- await_opened({:input, id}),
         {:ok, handle} when is_integer(handle) and handle > 0 <-
           :mob_midi_nif.midi_output_handle(id, 0),
         at = :mob_midi_nif.midi_now_ns() + @loop_lead_ns,
         :ok <- :mob_midi_nif.midi_send(id, 0, @loop_bytes, at) do
      await_loop(id, at)
    else
      {:fail, _} = fail -> fail
      other -> {:fail, "loopback through #{inspect(@loop_name)}: #{inspect(other)}"}
    end
  end

  defp await_opened(what) do
    receive do
      {:midi, :opened, %{device: id, direction: :virtual, name: @loop_name}}
      when what == :virtual ->
        {:ok, id}

      {:midi, :opened, %{device: id, direction: :input, source: source}}
      when what == {:input, id} and source > 0 ->
        {:ok, source}

      {:midi, :error, %{op: op, reason: reason}} when op in [:open_virtual, :open_input] ->
        loop_error(op, reason)
    after
      @answer_timeout ->
        {:fail, "loopback through #{inspect(@loop_name)}: no answer to opening #{inspect(what)}"}
    end
  end

  defp await_loop(id, at) do
    receive do
      {:midi, :raw, %{device: ^id} = raw} -> check_loop(at, raw)
    after
      @answer_timeout ->
        {:fail, "loopback through #{inspect(@loop_name)}: nothing came back within 5 s"}
    end
  end

  @doc false
  # What came back of the loop's send `at` a time: its bytes, stamped with
  # that time (to the CoreMIDI tick) and received no earlier.
  @spec check_loop(integer(), map()) :: Mob.Plugin.SelfTest.result()
  def check_loop(at, %{bytes: @loop_bytes, timestamp: stamp, received: received}) do
    cond do
      stamp < at or stamp - at > @tick_ns ->
        {:fail, "loopback stamped #{stamp}, sent for #{at}"}

      received < at ->
        {:fail, "loopback received #{at - received} ns before its time"}

      received - at > @loop_late_ns ->
        {:fail, "loopback received #{div(received - at, 1_000_000)} ms after its time"}

      true ->
        :pass
    end
  end

  def check_loop(_at, %{bytes: bytes}),
    do: {:fail, "loopback delivered #{inspect(bytes)}, sent #{inspect(@loop_bytes)}"}

  @doc false
  # A failed open of the loop: iOS refuses virtual endpoints to an app
  # without "audio" in UIBackgroundModes, which says nothing about MIDI I/O.
  @spec loop_error(atom(), atom()) :: Mob.Plugin.SelfTest.result()
  def loop_error(:open_virtual, :not_permitted),
    do:
      {:skip,
       "iOS refused a virtual MIDI device: the app's Info.plist has no \"audio\" in " <>
         "UIBackgroundModes, so the loopback could not run"}

  def loop_error(op, reason),
    do: {:fail, "loopback through #{inspect(@loop_name)}: #{op} failed: #{inspect(reason)}"}
end
