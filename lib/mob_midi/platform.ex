defmodule MobMidi.Platform do
  @moduledoc false
  # MIDI is first-class on both mobile platforms (CoreMIDI on iOS,
  # android.media.midi on Android), so unlike classic Bluetooth there's no
  # per-platform gap — only the host (dev / tests) has no MIDI stack. Pure
  # predicates so they're unit-testable without the NIF.
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:host), do: true
  def unsupported?(_), do: false

  # Connecting BLE-MIDI devices as a central from code: Android's
  # MidiManager.openBluetoothDevice. iOS pairs BLE-MIDI devices through its
  # own UI (CABTMIDICentralViewController), after which they are ordinary
  # CoreMIDI endpoints.
  @spec bluetooth_central?(atom()) :: boolean()
  def bluetooth_central?(:android), do: true
  def bluetooth_central?(_), do: false

  # The C ABI of priv/include/mob_midi.h (native sink, output handles):
  # Android's mob_midi_core.c. iOS links stubs that answer "unsupported".
  @spec native_abi?(atom()) :: boolean()
  def native_abi?(:android), do: true
  def native_abi?(_), do: false

  # :host when mob's NIF isn't loaded (dev, tests), so callers get
  # {:error, :unsupported} instead of a raise. Asked once per VM: it can't
  # change, and it is on the path of every incoming message's now_ns/0.
  @spec current :: atom()
  def current do
    case :persistent_term.get({__MODULE__, :platform}, nil) do
      nil ->
        platform = ask_platform()
        :persistent_term.put({__MODULE__, :platform}, platform)
        platform

      platform ->
        platform
    end
  end

  defp ask_platform do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end
end
