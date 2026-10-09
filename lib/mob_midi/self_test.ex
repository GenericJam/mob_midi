defmodule MobMidi.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One native round trip, read-only, no UI: `:mob_midi_nif.midi_list_devices/0`,
  then wait for what the native side sends back to the caller. Both platforms
  answer before the NIF returns (iOS enumerates CoreMIDI endpoints in the
  NIF; Android calls `MobMidiBridge.listDevices` over JNI on the calling
  thread), so the wait is short.

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
      no MIDI device attached to exercise.
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

  State: on iOS `midi_list_devices/0` makes the caller the hot-plug
  subscriber (`{:midi, :device_added | :device_removed, nil}`, last caller
  wins), as `MobMidi.list_devices/1` does; the next `list_devices` from a
  screen takes it back. Nothing is opened, sent or written.
  """
  @behaviour Mob.Plugin.SelfTest

  @answer_timeout 5_000

  @impl true
  def run(_ctx) do
    classify(:mob_midi_nif.midi_list_devices(), @answer_timeout)
  rescue
    e in ErlangError ->
      {:fail, "mob_midi_nif is not linked into this build: #{Exception.message(e)}"}
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
         "midi_list_devices/0 returned :ok but delivered no {:midi, :devices, _} " <>
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
end
