defmodule MobMidi.Platform do
  @moduledoc false
  # MIDI is first-class on both mobile platforms (CoreMIDI on iOS,
  # android.media.midi on Android), so unlike classic Bluetooth there's no
  # per-platform gap — only the host (dev / tests) has no MIDI stack. Pure
  # predicate so it's unit-testable without the NIF.
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:host), do: true
  def unsupported?(_), do: false

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
