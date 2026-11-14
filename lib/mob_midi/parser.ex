defmodule MobMidi.Parser do
  @moduledoc """
  Stateful MIDI 1.0 byte-stream parser. Pure.

  A MIDI source delivers packets that may split a message anywhere, so the
  state carries running status, a partially received message and an
  in-progress SysEx from one `feed/2` to the next. Keep one parser per source.

      {events, parser} = MobMidi.Parser.feed(parser, bytes)

  Events:

    * `%{type: :note_on | :note_off, channel: 0..15, note: n, velocity: v}` —
      a Note On with velocity 0 is reported as `:note_off`
    * `%{type: :poly_aftertouch, channel: c, note: n, pressure: p}`
    * `%{type: :cc, channel: c, controller: n, value: v}`
    * `%{type: :program_change, channel: c, program: p}`
    * `%{type: :channel_aftertouch, channel: c, pressure: p}`
    * `%{type: :pitch_bend, channel: c, value: 0..16_383}` (8192 = centre)
    * `%{type: :sysex, bytes: <<0xF0, ..., 0xF7>>}` — complete, framing included
    * `%{type: :mtc_quarter_frame, value: v}`, `%{type: :song_position, beats: b}`,
      `%{type: :song_select, song: s}`, `%{type: :tune_request}`
    * `%{type: :clock | :start | :continue | :stop | :active_sensing | :reset}`
    * `%{type: :raw, bytes: binary}` — bytes that can't be decoded: a stray data
      byte, an undefined status (0xF4 0xF5 0xF9 0xFD), an 0xF7 outside SysEx, a
      message abandoned by a new status byte (one event per byte), or a SysEx
      cut short by a status byte or the size cap (one event, from its 0xF0)

  MIDI 1.0 rules: data bytes after a complete channel message reuse its status
  (running status); system common messages cancel running status; real-time
  bytes (0xF8–0xFF) may appear anywhere, even mid-message or inside SysEx, are
  emitted where they fall and disturb nothing. A SysEx accumulates at most
  65_536 bytes (from its 0xF0); past that it is emitted as `:raw` and the rest
  is dropped up to its 0xF7.
  """

  import Bitwise

  @sysex_max 65_536

  # status: the message being assembled, kept as running status after a
  # channel message completes. pending: the bytes actually received for the
  # partial message (reversed), so an abandoned one can be reported as :raw.
  # sysex: nil | :skip (over the cap) | reversed list of the bytes so far.
  defstruct status: nil, need: 0, data: [], pending: [], sysex: nil, sysex_size: 0

  @opaque t :: %__MODULE__{}
  @type event :: map()

  @doc "A fresh parser: no running status, nothing pending."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed the next packet from a source. Returns the events it completes, in
  stream order, and the state to feed the next packet into.
  """
  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{} = p, bytes) when is_binary(bytes) do
    {acc, p} = step(bytes, p, [])
    {Enum.reverse(acc), p}
  end

  @doc """
  End of stream: report whatever is still pending as `:raw` (a partial message
  one event per byte; an unterminated SysEx as one event) and reset.
  """
  @spec flush(t()) :: {[event()], t()}
  def flush(%__MODULE__{} = p) do
    {Enum.reverse(raw_bytes(p.pending, sysex_raw(p.sysex, []))), new()}
  end

  # ── Byte loop ──────────────────────────────────────────────────────────

  defp step(<<>>, p, acc), do: {acc, p}

  defp step(<<b, rest::binary>>, p, acc) when b >= 0xF8, do: step(rest, p, [realtime(b) | acc])

  defp step(<<b, rest::binary>>, %{sysex: nil} = p, acc) when b < 0x80 do
    {acc, p} = data_byte(b, p, acc)
    step(rest, p, acc)
  end

  defp step(<<b, rest::binary>>, %{sysex: nil} = p, acc) do
    acc = raw_bytes(p.pending, acc)
    {acc, p} = status_byte(b, %{p | status: nil, need: 0, data: [], pending: []}, acc)
    step(rest, p, acc)
  end

  defp step(<<b, rest::binary>>, p, acc) do
    {acc, p} = sysex_byte(b, p, acc)
    step(rest, p, acc)
  end

  # ── Outside SysEx ──────────────────────────────────────────────────────

  defp data_byte(b, %{status: nil} = p, acc), do: {[raw(<<b>>) | acc], p}

  defp data_byte(b, %{data: data, need: need} = p, acc) when length(data) + 1 < need,
    do: {acc, %{p | data: [b | data], pending: [b | p.pending]}}

  defp data_byte(b, %{status: status, data: data} = p, acc) do
    ev = decode(status, Enum.reverse([b | data]))
    # Running status survives a channel message; a system common one clears it.
    status = if status < 0xF0, do: status, else: nil
    {[ev | acc], %{p | status: status, data: [], pending: []}}
  end

  defp status_byte(0xF0, p, acc), do: {acc, %{p | sysex: [<<0xF0>>], sysex_size: 1}}
  defp status_byte(0xF6, p, acc), do: {[%{type: :tune_request} | acc], p}

  defp status_byte(b, p, acc) when b in [0xF4, 0xF5, 0xF7], do: {[raw(<<b>>) | acc], p}

  defp status_byte(b, p, acc), do: {acc, %{p | status: b, need: data_len(b), pending: [b]}}

  defp data_len(0xF2), do: 2
  defp data_len(b) when b in [0xF1, 0xF3], do: 1
  defp data_len(b) when band(b, 0xF0) in [0xC0, 0xD0], do: 1
  defp data_len(_), do: 2

  # ── Inside SysEx ───────────────────────────────────────────────────────

  defp sysex_byte(b, %{sysex: :skip} = p, acc) when b < 0x80, do: {acc, p}

  defp sysex_byte(b, %{sysex_size: size} = p, acc) when b < 0x80 and size >= @sysex_max,
    do: {sysex_raw(p.sysex, acc), %{p | sysex: :skip, sysex_size: 0}}

  defp sysex_byte(b, %{sysex: sx, sysex_size: size} = p, acc) when b < 0x80,
    do: {acc, %{p | sysex: [b | sx], sysex_size: size + 1}}

  defp sysex_byte(0xF7, %{sysex: :skip} = p, acc), do: {acc, end_sysex(p)}

  defp sysex_byte(0xF7, %{sysex: sx} = p, acc) do
    bytes = IO.iodata_to_binary(Enum.reverse([0xF7 | sx]))
    {[%{type: :sysex, bytes: bytes} | acc], end_sysex(p)}
  end

  # Any other status byte ends the SysEx unterminated, then counts as itself.
  defp sysex_byte(b, p, acc) do
    acc = sysex_raw(p.sysex, acc)
    status_byte(b, end_sysex(p), acc)
  end

  defp end_sysex(p), do: %{p | sysex: nil, sysex_size: 0}

  defp sysex_raw(sx, acc) when is_list(sx), do: [raw(IO.iodata_to_binary(Enum.reverse(sx))) | acc]
  defp sysex_raw(_, acc), do: acc

  # ── Events ─────────────────────────────────────────────────────────────

  defp decode(status, [d1 | d2]) when status < 0xF0 do
    channel_event(band(status, 0xF0), band(status, 0x0F), d1, List.first(d2))
  end

  defp decode(0xF1, [v]), do: %{type: :mtc_quarter_frame, value: v}
  defp decode(0xF2, [lsb, msb]), do: %{type: :song_position, beats: bor(bsl(msb, 7), lsb)}
  defp decode(0xF3, [s]), do: %{type: :song_select, song: s}

  defp channel_event(0x80, ch, note, vel),
    do: %{type: :note_off, channel: ch, note: note, velocity: vel}

  defp channel_event(0x90, ch, note, 0),
    do: %{type: :note_off, channel: ch, note: note, velocity: 0}

  defp channel_event(0x90, ch, note, vel),
    do: %{type: :note_on, channel: ch, note: note, velocity: vel}

  defp channel_event(0xA0, ch, note, p),
    do: %{type: :poly_aftertouch, channel: ch, note: note, pressure: p}

  defp channel_event(0xB0, ch, ctrl, val),
    do: %{type: :cc, channel: ch, controller: ctrl, value: val}

  defp channel_event(0xC0, ch, prog, nil),
    do: %{type: :program_change, channel: ch, program: prog}

  defp channel_event(0xD0, ch, p, nil), do: %{type: :channel_aftertouch, channel: ch, pressure: p}

  defp channel_event(0xE0, ch, lsb, msb),
    do: %{type: :pitch_bend, channel: ch, value: bor(bsl(msb, 7), lsb)}

  defp realtime(0xF8), do: %{type: :clock}
  defp realtime(0xFA), do: %{type: :start}
  defp realtime(0xFB), do: %{type: :continue}
  defp realtime(0xFC), do: %{type: :stop}
  defp realtime(0xFE), do: %{type: :active_sensing}
  defp realtime(0xFF), do: %{type: :reset}
  defp realtime(b), do: raw(<<b>>)

  defp raw(bytes), do: %{type: :raw, bytes: bytes}

  # pending is reversed; prepending each byte onto the reversed acc keeps
  # stream order once acc is reversed.
  defp raw_bytes(pending, acc),
    do: pending |> Enum.reverse() |> Enum.reduce(acc, &[raw(<<&1>>) | &2])
end
