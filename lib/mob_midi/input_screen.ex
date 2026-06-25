defmodule MobMidi.InputScreen do
  @moduledoc """
  MIDI **in** demo: pick a source, then watch incoming notes light up.

  Visual-first (v1): incoming Note On adds to the lit set, Note Off removes it,
  and a short event log shows the raw stream decoded by `MobMidi.parse/1`. An
  audible sine per note is a fast follow once `Mob.Audio` grows a tone primitive
  (today `Mob.Audio` only plays files).

  Render tree is plain node maps (the idiom for list-driven mob screens).
  """
  use Mob.Screen

  alias MobMidi

  @log_limit 8

  @spec mount(term(), term(), term()) :: {:ok, term()}
  def mount(_params, _session, socket) do
    MobMidi.list_devices(socket)
    {:ok, Mob.Socket.assign(socket, inputs: [], input: nil, active: MapSet.new(), log: [])}
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
            text("MIDI Input", text_size: :xl, text_color: :on_surface, padding: :space_sm),
            text("Pick a source, then play it", text_size: :sm, text_color: :muted, padding: 4),
            spacer(16),
            text("Input source", text_size: :sm, text_color: :muted, padding: 4),
            spacer(8),
            source_picker(assigns.inputs, assigns.input),
            spacer(24),
            text("Playing", text_size: :sm, text_color: :muted, padding: 4),
            spacer(8),
            active_notes(assigns.active),
            spacer(24),
            text("Recent", text_size: :sm, text_color: :muted, padding: 4),
            spacer(8),
            event_log(assigns.log)
          ]
        }
      ]
    }
  end

  # ── Taps + MIDI ─────────────────────────────────────────────────────────────

  @spec handle_info(term(), term()) :: {:noreply, term()}
  def handle_info({:tap, tag}, socket) do
    case to_string(tag) do
      "i" <> id ->
        input = String.to_integer(id)
        MobMidi.open_input(socket, input)
        {:noreply, Mob.Socket.assign(socket, :input, input)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:midi, :devices, payload}, socket) do
    inputs = payload |> MobMidi.parse_devices() |> Enum.filter(&(&1.direction in [:input, :both]))
    {:noreply, Mob.Socket.assign(socket, :inputs, inputs)}
  end

  def handle_info({:midi, :device_added, _}, socket) do
    MobMidi.list_devices(socket)
    {:noreply, socket}
  end

  def handle_info({:midi, :raw, %{bytes: bytes}}, socket) do
    {active, log} =
      Enum.reduce(
        MobMidi.parse(bytes),
        {socket.assigns.active, socket.assigns.log},
        fn ev, {act, lg} -> {apply_event(act, ev), [describe(ev) | lg]} end
      )

    socket =
      socket
      |> Mob.Socket.assign(:active, active)
      |> Mob.Socket.assign(:log, Enum.take(log, @log_limit))

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp apply_event(active, %{type: :note_on, note: n}), do: MapSet.put(active, n)
  defp apply_event(active, %{type: :note_off, note: n}), do: MapSet.delete(active, n)
  defp apply_event(active, _), do: active

  defp describe(%{type: :note_on, note: n, velocity: v}), do: "note on #{n} v#{v}"
  defp describe(%{type: :note_off, note: n}), do: "note off #{n}"
  defp describe(%{type: :cc, controller: c, value: v}), do: "cc #{c}=#{v}"
  defp describe(%{type: :program_change, program: p}), do: "program #{p}"
  defp describe(%{type: :pitch_bend, value: v}), do: "pitch bend #{v}"
  defp describe(%{type: :raw}), do: "raw"

  # ── Render helpers ──────────────────────────────────────────────────────────

  defp source_picker([], _selected),
    do: text("(no input devices found)", text_size: :sm, text_color: :muted, padding: 4)

  defp source_picker(inputs, selected) do
    %{
      type: :column,
      props: %{},
      children:
        Enum.map(inputs, fn i ->
          sel = i.id == selected

          button(i.name, :"i#{i.id}",
            background: if(sel, do: :primary, else: :surface),
            text_color: if(sel, do: :on_primary, else: :on_surface),
            text_size: :sm,
            padding: :space_sm
          )
        end)
    }
  end

  defp active_notes(active) do
    notes = active |> MapSet.to_list() |> Enum.sort()

    children =
      if notes == [] do
        [text("(nothing playing)", text_size: :sm, text_color: :muted, padding: 4)]
      else
        Enum.map(notes, fn n ->
          %{
            type: :text,
            props: %{
              text: "#{n}",
              background: :primary,
              text_color: :on_primary,
              text_size: :md,
              padding: :space_sm
            },
            children: []
          }
        end)
      end

    %{type: :row, props: %{fill_width: true}, children: children}
  end

  defp event_log([]), do: text("—", text_size: :sm, text_color: :muted, padding: 4)

  defp event_log(log) do
    %{
      type: :column,
      props: %{},
      children:
        Enum.map(log, fn line ->
          text(line, text_size: :sm, text_color: :on_surface, padding: 2)
        end)
    }
  end

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
