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
    # Advertise this phone as a BLE-MIDI peripheral so a computer can connect and
    # be played by the keys (side-effect call, like list_devices; status arrives
    # as :bt_le events). On the host this is a no-op.
    MobMidi.Ble.advertise(socket, "Mob MIDI")
    {:ok, Mob.Socket.assign(socket, outputs: [], output: nil, last_sent: nil, ble: "starting...")}
  end

  # Release the BLE-MIDI GATT server / advertiser on the way out. Without this,
  # revisiting the screen leaks Android GATT-server registrations (which
  # eventually exhaust the stack -> {:bt_le, :advertising_failed, %{reason:
  # :no_gatt_server}}) and leaves an iOS peripheral advertising in the
  # background.
  @spec terminate(term(), term()) :: :ok
  def terminate(_reason, socket) do
    MobMidi.Ble.stop(socket)
    :ok
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
            text("Tap a key to play a note over Bluetooth MIDI",
              text_size: :sm,
              text_color: :muted,
              padding: 4
            ),
            text("Bluetooth: #{assigns.ble}", text_size: :sm, text_color: :primary, padding: 4),
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

  # BLE-MIDI peripheral status (from MobBluetooth.Le, via MobMidi.Ble.advertise).
  def handle_info({:bt_le, :advertising_started}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :ble, "advertising as 'Mob MIDI'")}

  def handle_info({:bt_le, :advertising_failed, %{reason: reason}}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :ble, "BLE error: #{reason}")}

  def handle_info({:bt_le, :subscribed, _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :ble, "connected - computer is listening")}

  def handle_info({:bt_le, :unsubscribed, _}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :ble, "advertising as 'Mob MIDI'")}

  def handle_info({:bt_le, _evt, _payload}, socket), do: {:noreply, socket}
  def handle_info({:bt_le, _evt}, socket), do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp on_tap("o" <> id, socket) do
    output = String.to_integer(id)
    MobMidi.open_output(socket, output)
    Mob.Socket.assign(socket, :output, output)
  end

  defp on_tap("k" <> note, socket) do
    note = String.to_integer(note)

    # Always play the note out over BLE-MIDI (to whatever computer subscribed),
    # plus to a selected USB/wired output device if one is chosen.
    ts = System.monotonic_time(:millisecond)
    MobMidi.Ble.send_note_on(socket, @channel, note, @velocity, ts)
    MobMidi.Ble.send_note_off(socket, @channel, note, 0, ts)

    case socket.assigns.output do
      nil ->
        Mob.Socket.assign(socket, :last_sent, "note #{note} -> BLE")

      output ->
        MobMidi.send_note_on(socket, output, @channel, note, @velocity)
        MobMidi.send_note_off(socket, output, @channel, note, 0)
        Mob.Socket.assign(socket, :last_sent, "note #{note} -> BLE + device #{output}")
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
          key_button("#{name}#{octave + 3}", base + offset)
        end)
    }
  end

  # A piano key. Built with the ~MOB sigil + semantic theme tokens (NOT a
  # plain-map button with literal-hex colors): that's the only thing that
  # reliably renders a visible, *labelled* button on BOTH iOS and Android. iOS
  # button styling ignores literal-hex backgrounds (the key shows as the
  # background colour), and the plain-map + hex path dropped the labels — the
  # sigil + tokens is the proven home-screen pattern.
  defp key_button(label, note) do
    tap = {self(), :"k#{note}"}

    ~MOB(<Button text={label} background={:primary} text_color={:on_primary} text_size={:sm} padding={:space_md} weight={1} on_tap={tap} />)
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
