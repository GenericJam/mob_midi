defmodule MobMidi.KeyboardScreen do
  @moduledoc """
  MIDI **out** demo: a two-octave keyboard. Tap a key to send a note to the
  selected output device.

  ## Orientation (stubbed)

  This is meant to be a wide landscape keyboard. Until `Mob.Device.lock_orientation/1`
  lands in mob core (PR GenericJam/mob#49), it renders **portrait**: white keys
  only, two rows of seven so they fit a portrait width. Once the orientation lock
  is available, `mount/3` should call `Mob.Device.lock_orientation(:landscape)`
  and the layout swap to a single full piano (white + black keys). See the
  `# TODO(orientation)` markers.

  The render tree is built as plain node maps (the idiom mob screens use for
  dynamic / list-driven UI).
  """
  use Mob.Screen

  alias MobMidi

  @white_offsets [0, 2, 4, 5, 7, 9, 11]
  @white_names ["C", "D", "E", "F", "G", "A", "B"]
  @octave_bases [48, 60]
  @velocity 100
  @channel 0

  @spec mount(term(), term(), term()) :: {:ok, term()}
  def mount(_params, _session, socket) do
    # TODO(orientation): once mob#49 lands -> Mob.Device.lock_orientation(:landscape)
    MobMidi.list_devices(socket)
    {:ok, Mob.Socket.assign(socket, outputs: [], output: nil, last_sent: nil)}
  end

  @spec render(map()) :: map()
  def render(assigns) do
    %{
      type: :scroll,
      props: %{background: :background},
      children: [
        %{
          type: :column,
          props: %{background: :background, padding: :space_lg},
          children: [
            text("MIDI Keyboard", text_size: :xl, text_color: :on_surface, padding: :space_sm),
            text("Tap a key to send a note out", text_size: :sm, text_color: :muted, padding: 4),
            spacer(16),
            text("Output device", text_size: :sm, text_color: :muted, padding: 4),
            spacer(8),
            output_picker(assigns.outputs, assigns.output),
            spacer(24),
            octave_row(0),
            spacer(8),
            octave_row(1),
            spacer(20),
            sent_readout(assigns.last_sent)
          ]
        }
      ]
    }
  end

  # ── Taps + MIDI ─────────────────────────────────────────────────────────────

  @spec handle_info(term(), term()) :: {:noreply, term()}
  def handle_info({:tap, tag}, socket), do: {:noreply, on_tap(to_string(tag), socket)}

  def handle_info({:midi, :devices, payload}, socket) do
    outputs =
      payload |> MobMidi.parse_devices() |> Enum.filter(&(&1.direction in [:output, :both]))

    {:noreply, Mob.Socket.assign(socket, :outputs, outputs)}
  end

  def handle_info({:midi, :device_added, _}, socket) do
    MobMidi.list_devices(socket)
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp on_tap("o" <> id, socket) do
    output = String.to_integer(id)
    MobMidi.open_output(socket, output)
    Mob.Socket.assign(socket, :output, output)
  end

  defp on_tap("k" <> note, socket) do
    note = String.to_integer(note)

    case socket.assigns.output do
      nil ->
        Mob.Socket.assign(socket, :last_sent, "select an output device first")

      output ->
        MobMidi.send_note_on(socket, output, @channel, note, @velocity)
        MobMidi.send_note_off(socket, output, @channel, note, 0)
        Mob.Socket.assign(socket, :last_sent, "note #{note} -> device #{output}")
    end
  end

  defp on_tap(_other, socket), do: socket

  # ── Render helpers (plain node maps) ────────────────────────────────────────

  defp output_picker([], _selected),
    do: text("(no output devices found)", text_size: :sm, text_color: :muted, padding: 4)

  defp output_picker(outputs, selected) do
    %{
      type: :column,
      props: %{},
      children:
        Enum.map(outputs, fn o ->
          sel = o.id == selected

          button(o.name, :"o#{o.id}",
            background: if(sel, do: :primary, else: :surface),
            text_color: if(sel, do: :on_primary, else: :on_surface),
            text_size: :sm,
            padding: :space_sm
          )
        end)
    }
  end

  # TODO(orientation): in landscape this becomes one wide row with black keys.
  defp octave_row(octave) do
    base = Enum.at(@octave_bases, octave)

    %{
      type: :row,
      props: %{fill_width: true},
      children:
        Enum.map(Enum.zip(@white_offsets, @white_names), fn {offset, name} ->
          note = base + offset

          button("#{name}#{octave + 3}", :"k#{note}",
            background: :surface_raised,
            text_color: :on_surface,
            text_size: :sm,
            padding: :space_sm,
            weight: 1
          )
        end)
    }
  end

  defp sent_readout(nil), do: text("—", text_size: :sm, text_color: :muted, padding: 4)
  defp sent_readout(t), do: text("sent: #{t}", text_size: :sm, text_color: :primary, padding: 4)

  defp text(t, props), do: %{type: :text, props: Map.new([{:text, t} | props]), children: []}
  defp spacer(n), do: %{type: :spacer, props: %{size: n}, children: []}

  defp button(label, tag, props) do
    %{
      type: :button,
      props: Map.merge(%{text: label, on_tap: {self(), tag}}, Map.new(props)),
      children: []
    }
  end
end
