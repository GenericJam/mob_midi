defmodule MobMidi do
  @moduledoc """
  MIDI in + out for Mob apps.

  Receive from a controller (keyboard, pads) and send to external synths / DAWs,
  over **USB-MIDI** and **BLE-MIDI**. Unlike `MobBluetooth` (classic BT, Android
  only), MIDI is first-class on both platforms, so this is a real cross-platform
  surface: **CoreMIDI** on iOS, **`android.media.midi`** on Android.

  ## API style

  Same as the rest of Mob: callbacks take and return `socket` unchanged; results
  arrive in `handle_info/2` as messages tagged `:midi`. Functions return
  `{:error, :unsupported}` on the host (no MIDI stack outside a device).

  ## Discovering devices

      MobMidi.list_devices(socket)
      # => {:midi, :devices, [%{id: 1, name: "Oxygen 49", direction: :input}, ...]}

  When the platform can't be asked, the caller gets `{:midi, :error, %{device:
  0, op: :list_devices, reason: reason, dropped: 0}}` instead: `:no_activity`
  (Android: the bridge never got its Activity), `:no_midi_service` (Android:
  the device has no MIDI support) or `:no_client` (iOS: `MIDIClientCreate`
  failed). An empty list means the platform answered and found no devices.

  Hot-plug: a device appearing / disappearing sends `{:midi, :device_added,
  nil}` / `{:midi, :device_removed, nil}` to the last `list_devices/1` caller,
  on both platforms; re-list on either. On Android a removed device's open
  ports are closed.

  ## Receiving

      MobMidi.open_input(socket, device_id)              # port 0
      MobMidi.open_input(socket, device_id, port: 1)     # a multi-port device
      MobMidi.open_input(socket, device_id, port: :all)  # every port (Android)

  Each opened port answers `{:midi, :opened, %{device: id, port: n,
  direction: :input, source: s}}` (`source` on Android: its id in the native
  ABI, see "Native code" below), then its incoming MIDI is delivered to the
  calling process as raw packets:

      {:midi, :raw, %{device: id, port: 0, bytes: <<0x90, 60, 100>>,
                      timestamp: sent_ns, received: received_ns}}

  After `close/2` returns, no further bytes of the closed port are sent, not
  even ones its MIDI thread was already delivering (Android); messages already
  in the mailbox stay there.

  Parse it with `parse/1` (pure, so it's unit-testable and you decide how much
  to decode):

      def handle_info({:midi, :raw, %{bytes: b}}, socket) do
        for ev <- MobMidi.parse(b), do: react(ev)
        {:noreply, socket}
      end

  `parse/1` returns events like `%{type: :note_on, channel: 0, note: 60,
  velocity: 100}` (`:note_on` with velocity 0 is normalised to `:note_off`),
  following running status and real-time bytes interleaved anywhere; see
  `parse/1` for every event, and `MobMidi.Parser` to carry a stream's state
  across packets.

  ## Sending

  Open the output first. `open_output/2` replies to the calling process with
  `{:midi, :opened, %{device: id, port: n, direction: :output, handle: h}}`
  once the port is ready (`handle`: Android, for native code; see "Native
  code"), or `{:midi, :error, %{device: id, op: :open_output, reason: reason,
  dropped: n}}` if it can't be opened:

      MobMidi.open_output(socket, device_id)

      def handle_info({:midi, :opened, %{device: id}}, socket) do
        MobMidi.send_note_on(socket, id, 0, 60, 100)   # ch 0, middle C, vel 100
        MobMidi.send_note_off(socket, id, 0, 60, 0)
        MobMidi.send_cc(socket, id, 0, 7, 90)          # ch 0, CC#7 (volume)
        MobMidi.send_raw(socket, id, <<0xF0, ...>>)    # SysEx / anything
        {:noreply, socket}
      end

      def handle_info({:midi, :error, %{op: :open_output, reason: reason}}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :midi_error, reason)}

  You don't have to wait for `:opened`: Android opens the port asynchronously,
  and sends made before it opens are queued (up to 256 messages per port)
  and written in order the moment it does. If the open fails, the queue is
  discarded and the error event's `dropped` says how many messages were lost.
  iOS opens synchronously, so the event arrives before `open_output/2` returns.

  On Android a send doesn't write to the port itself: it joins the port's
  queue (ordered by `at:`, at most 256 chunks of 64 bytes), and a thread of
  the port's own writes it, so a receiver that stops reading never blocks the
  caller: its queue fills and sends answer `{:error, :queue_full}`.

  `send_*` return `socket` when the message was queued, and `{:error,
  reason}` when it wasn't: `:not_open` (no `open_output/2` for that device, or
  it was closed or failed to open), `:queue_full`, `:no_such_device` (iOS: the
  destination disappeared), `:too_large` (iOS: over 256 bytes in one send),
  `:no_listener` (a virtual device nobody listens to) or `:send_failed`;
  `{:error, :unsupported}` on the host and `{:error, :nif_not_loaded}` if the
  native bridge isn't registered. So bind the result rather than piping it on
  as the socket.

  Channels are `0..15` on the wire (shown as 1..16 in most UIs). Notes /
  velocities / values are `0..127`.

  ## Timing

  `now_ns/0` is the clock of MIDI timestamps. Incoming packets carry the
  sender's `timestamp` and when the bridge `received` them, so an app can see
  what delivery costs. `send_raw/4` with `at:` sends at that time: Android
  holds the bytes in the port's queue until then and hands them over stamped
  with it (iOS schedules the CoreMIDI packet), which takes the BEAM's
  scheduling jitter out of MIDI clock, as long as the send is made ahead.

  ## Native code

  Another native library in the app (an audio engine's static NIF) can take
  MIDI without the BEAM, through the C ABI in `priv/include/mob_midi.h`
  (Android; on iOS its functions answer "unsupported"):

    * open inputs with `deliver: :native` (or `:both`) and register a sink
      with `mob_midi_set_sink/2`: it gets `(source, generation, bytes, len,
      timestamp_ns)` on the MIDI thread, no message, no allocation;
    * pass an output's `handle` (from `:opened` or `output_handle/2`) to it
      and call `mob_midi_send(handle, bytes, len, at_ns)` from its own thread.

  `priv/include/mob_midi_parser.h` is a matching header-only stream parser.
  The header documents thread and lifetime rules.

  ## Virtual devices

  `open_virtual/3` makes the app itself a MIDI device other apps can play
  into and listen to (a software synth's input, say). See its doc and the
  README for the Android declaration (`mix mob_midi.gen.virtual_device`
  writes it).

  ## Bluetooth

  On Android, `scan_bluetooth/2` finds BLE-MIDI devices and
  `connect_bluetooth/2` connects one, after which it is an ordinary device.
  iOS pairs BLE-MIDI devices through the system UI.

  ## Status: experimental

  The native MIDI paths are experimental. Verified against virtual MIDI
  devices on an Android emulator (`android.media.midi.MidiDeviceService`
  loopbacks in a test host app) and, for 0.1.2, on the iOS simulator (CoreMIDI
  virtual endpoints). Not verified: USB-MIDI and BLE-MIDI hardware on either
  platform, including `MobMidi.Ble` and `connect_bluetooth/2`. See the
  CHANGELOG for what each release checked.
  """

  import Bitwise

  # Android: MidiDeviceInfo id; iOS: CoreMIDI endpoint unique id (an SInt32, can be negative).
  @type device_id :: integer()
  @type channel :: 0..15
  @type byte7 :: 0..127

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Enumerate available MIDI devices. Result: `{:midi, :devices, [device]}`, or
  `{:midi, :error, %{op: :list_devices, ...}}` when the platform can't be asked
  (see "Discovering devices" above).
  """
  @spec list_devices(term()) :: term()
  def list_devices(socket) do
    guarded(socket, fn -> :mob_midi_nif.midi_list_devices() end)
  end

  @doc """
  Subscribe to a device's MIDI input.

  Options:

    * `port:` one of the device's `input_ports` (default 0), or `:all` for
      every one of them, each its own subscription with its own `:opened`
      (iOS endpoints have a single port, so `:all` is port 0 there).
    * `deliver:` who gets the bytes: `:beam` (default, `{:midi, :raw, ...}`
      messages to the calling process), `:native` (the sink a native library
      registered with `mob_midi_set_sink`, see "Native code" in the module
      doc; no messages) or `:both`. Android only for anything but `:beam`.

  The calling process receives `{:midi, :opened, %{device: id, port: port,
  direction: :input, source: s}}` per port, then each incoming packet as
  `{:midi, :raw, %{device: id, port: port, bytes: binary, timestamp: ns,
  received: ns}}` (`timestamp`: the sender's stamp; `received`: when the
  bridge got it; both on the `now_ns/0` clock). Opening a port again replaces
  its subscription. Errors: `{:midi, :error, %{op: :open_input, reason:
  :no_such_device | :no_such_port | :open_failed | :no_free_source | ...}}`.
  """
  @spec open_input(term(), device_id(), keyword()) :: term()
  def open_input(socket, device_id, opts \\ []) when is_integer(device_id) do
    port = input_port(opts)
    route = route(opts)

    native_guarded(socket, route, fn ->
      :mob_midi_nif.midi_open_input(device_id, port, route)
    end)
  end

  @doc """
  Open a device's MIDI output so `send_*` can write to it. Options: `port:`
  (default 0), one of the device's `output_ports`; `send_raw/4` takes the
  same `port:`.

  The calling process receives `{:midi, :opened, %{device: id, port: port,
  direction: :output, handle: h}}` when the port is ready (`handle` on
  Android: see `output_handle/2`), or `{:midi, :error, %{device: id, op:
  :open_output, reason: reason, dropped: n}}` when it can't be opened
  (reasons include `:no_such_device`, `:no_such_port`, `:open_failed`,
  `:no_input_port` (another app has the port), `:no_free_output`, and
  `:closed` when `close/2` cancels an open still in flight). Sends made
  before `:opened` are queued and flushed in order; see "Sending" above.
  """
  @spec open_output(term(), device_id(), keyword()) :: term()
  def open_output(socket, device_id, opts \\ []) when is_integer(device_id) do
    port = port(opts)
    guarded(socket, fn -> :mob_midi_nif.midi_open_output(device_id, port) end)
  end

  @doc "Close every open input/output port of `device_id` (disconnects a Bluetooth device)."
  @spec close(term(), device_id()) :: term()
  def close(socket, device_id) when is_integer(device_id) do
    guarded(socket, fn -> :mob_midi_nif.midi_close(device_id) end)
  end

  @doc "Send a Note On."
  @spec send_note_on(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_note_on(socket, device_id, channel, note, velocity) do
    send_raw(socket, device_id, note_on_bytes(channel, note, velocity))
  end

  @doc "Send a Note Off."
  @spec send_note_off(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_note_off(socket, device_id, channel, note, velocity) do
    send_raw(socket, device_id, note_off_bytes(channel, note, velocity))
  end

  @doc "Send a Control Change (CC)."
  @spec send_cc(term(), device_id(), channel(), byte7(), byte7()) :: term()
  def send_cc(socket, device_id, channel, controller, value) do
    send_raw(socket, device_id, cc_bytes(channel, controller, value))
  end

  @doc "Send a Program Change."
  @spec send_program_change(term(), device_id(), channel(), byte7()) :: term()
  def send_program_change(socket, device_id, channel, program) do
    send_raw(socket, device_id, program_change_bytes(channel, program))
  end

  @doc """
  Send raw MIDI bytes (SysEx, or anything `send_*` doesn't cover).

  Options: `port:` (default 0, see `open_output/3`) and `at:`, a `now_ns/0`
  timestamp of when the bytes should be acted on (default: now). Android
  keeps them in the port's queue until then and hands them over stamped with
  it; iOS schedules the CoreMIDI packet. Sending ahead with `at:` takes the
  BEAM's scheduling jitter out of timing that matters, such as MIDI clock. A
  time already past sends at once.

  Returns `socket` when the bytes were queued (or held while the output is
  still opening); `{:error, reason}` when they weren't (see "Sending" above).
  """
  @spec send_raw(term(), device_id(), binary(), keyword()) :: term()
  def send_raw(socket, device_id, bytes, opts \\ [])
      when is_integer(device_id) and is_binary(bytes) do
    if MobMidi.Platform.unsupported?(MobMidi.Platform.current()) do
      {:error, :unsupported}
    else
      result = :mob_midi_nif.midi_send(device_id, port(opts), bytes, timestamp(opts))
      send_result(socket, result)
    end
  end

  @doc """
  The clock of MIDI timestamps, in nanoseconds: `CLOCK_MONOTONIC`
  (`System.nanoTime()`) on Android, `mach_absolute_time` in ns on iOS. Use it
  for `send_raw/4`'s `at:` and to compare with the `timestamp` / `received`
  of incoming bytes. On the host (no MIDI stack) it is the BEAM's monotonic
  clock.
  """
  @spec now_ns() :: integer()
  def now_ns do
    if MobMidi.Platform.unsupported?(MobMidi.Platform.current()),
      do: System.monotonic_time(:nanosecond),
      else: :mob_midi_nif.midi_now_ns()
  end

  @doc """
  Subscribe to one of the app's own virtual MIDI devices, by name: a device
  other apps on the phone see and play into (and listen to). The calling
  process receives `{:midi, :opened, %{device: id, direction: :virtual,
  name: name}}`, then what other apps send into it as `{:midi, :raw, ...}`
  with that `device` id; `send_raw/4` to the id (and `port:`) sends out of it
  to every app listening (`{:error, :no_listener}` when none is), and
  `output_handle/2` gives native code the same.

  Options: `deliver:` as for `open_input/3`, for what other apps send in.

  On Android the app declares the device (see the README, "Virtual devices";
  `mix mob_midi.gen.virtual_device` writes the declaration) and also gets
  `{:midi, :virtual_status, %{device: id, senders: n, listeners: n}}`
  whenever another app opens or closes it. On iOS `open_virtual/3` creates a
  CoreMIDI source + destination of that name; iOS doesn't report who is
  connected. `{:midi, :error, %{op: :open_virtual, reason: :no_such_device}}`
  when Android has no such device of this app's. A second `open_virtual/3`
  replaces the first; on Android `close/2` on the id ends it (iOS keeps
  the CoreMIDI endpoints until the app exits).
  """
  @spec open_virtual(term(), String.t(), keyword()) :: term()
  def open_virtual(socket, name, opts \\ []) when is_binary(name) do
    route = route(opts)
    native_guarded(socket, route, fn -> :mob_midi_nif.midi_open_virtual(name, route) end)
  end

  @doc """
  The native handle of an open output (Android): `{:ok, handle}` for the C
  ABI's `mob_midi_send` (see "Native code"), `{:error, :not_open}` when
  `device_id`'s `port:` (default 0) isn't open (yet), `{:error,
  :unsupported}` elsewhere. Outputs of the app's own virtual device have one
  from `open_virtual/3` on. A handle dies with its port: reopening gives a
  new one.
  """
  @spec output_handle(device_id(), keyword()) :: {:ok, pos_integer()} | {:error, atom()}
  def output_handle(device_id, opts \\ []) when is_integer(device_id) do
    if MobMidi.Platform.native_abi?(MobMidi.Platform.current()),
      do: :mob_midi_nif.midi_output_handle(device_id, port(opts)),
      else: {:error, :unsupported}
  end

  @doc """
  Scan for BLE-MIDI devices (Android). Options: `duration_ms:` (default
  10 000). The caller receives `{:midi, :bluetooth_scan, :started}`, one
  `{:midi, :bluetooth_device, %{address: address, name: name, rssi: dbm}}` per
  device found, and `{:midi, :bluetooth_scan, :stopped}`; or `{:midi, :error,
  %{op: :scan_bluetooth, reason: :permission_denied | :bluetooth_off |
  :location_off | :unsupported | :scan_failed}}`.

  Needs the `:midi_bluetooth` permission (`Mob.Permissions.request(socket,
  :midi_bluetooth)`). iOS pairs BLE-MIDI devices through the system UI
  (`CABTMIDICentralViewController`), after which they are ordinary devices:
  `{:error, :unsupported}` there.
  """
  @spec scan_bluetooth(term(), keyword()) :: term()
  def scan_bluetooth(socket, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, 10_000)

    bluetooth_guarded(socket, fn ->
      :mob_midi_nif.midi_scan_bluetooth(duration)
    end)
  end

  @doc "Stop a `scan_bluetooth/2` early (Android)."
  @spec stop_bluetooth_scan(term()) :: term()
  def stop_bluetooth_scan(socket),
    do: bluetooth_guarded(socket, fn -> :mob_midi_nif.midi_stop_bluetooth_scan() end)

  @doc """
  Connect a BLE-MIDI device found by `scan_bluetooth/2` (Android). It then
  appears in `list_devices/1` (with its `address`) and opens like any other
  device; `close/2` disconnects it. The caller receives `{:midi, :connected,
  %{device: id, address: address}}` (at once if it is already connected) or
  `{:midi, :error, %{op: :connect_bluetooth, reason: :bad_address |
  :permission_denied | :bluetooth_off | :open_failed | ...}}`.
  """
  @spec connect_bluetooth(term(), String.t()) :: term()
  def connect_bluetooth(socket, address) when is_binary(address),
    do: bluetooth_guarded(socket, fn -> :mob_midi_nif.midi_connect_bluetooth(address) end)

  # The NIF answers :ok (written), :queued (Android output still opening),
  # {:error, reason}, or a bare :error when it couldn't reach the JVM.
  @doc false
  @spec send_result(term(), term()) :: term()
  def send_result(socket, result) when result in [:ok, :queued], do: socket
  def send_result(_socket, {:error, reason}) when is_atom(reason), do: {:error, reason}
  def send_result(_socket, :error), do: {:error, :send_failed}

  # `port:` / `at:` / `deliver:` options, validated before they reach the NIF.
  @doc false
  @spec port(keyword()) :: non_neg_integer()
  def port(opts) do
    case Keyword.get(opts, :port, 0) do
      p when is_integer(p) and p >= 0 -> p
      other -> raise ArgumentError, "port must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  # open_input's port: also :all, which the NIF takes as -1.
  @doc false
  @spec input_port(keyword()) :: integer()
  def input_port(opts) do
    case Keyword.get(opts, :port, 0) do
      :all ->
        -1

      p when is_integer(p) and p >= 0 ->
        p

      other ->
        raise ArgumentError, "port must be a non-negative integer or :all, got: #{inspect(other)}"
    end
  end

  # The NIF's route bits: 1 BEAM messages, 2 the native sink.
  @doc false
  @spec route(keyword()) :: 1..3
  def route(opts) do
    case Keyword.get(opts, :deliver, :beam) do
      :beam ->
        1

      :native ->
        2

      :both ->
        3

      other ->
        raise ArgumentError, "deliver must be :beam, :native or :both, got: #{inspect(other)}"
    end
  end

  @doc false
  @spec timestamp(keyword()) :: non_neg_integer()
  def timestamp(opts) do
    case Keyword.get(opts, :at, 0) do
      t when is_integer(t) and t >= 0 -> t
      other -> raise ArgumentError, "at must be a now_ns/0 timestamp, got: #{inspect(other)}"
    end
  end

  # ── Pure message encoders (testable; status nibble | channel) ───────────

  @doc false
  @spec note_on_bytes(channel(), byte7(), byte7()) :: binary()
  def note_on_bytes(ch, note, vel) when ch in 0..15 and note in 0..127 and vel in 0..127,
    do: <<bor(0x90, ch), note, vel>>

  @doc false
  @spec note_off_bytes(channel(), byte7(), byte7()) :: binary()
  def note_off_bytes(ch, note, vel) when ch in 0..15 and note in 0..127 and vel in 0..127,
    do: <<bor(0x80, ch), note, vel>>

  @doc false
  @spec cc_bytes(channel(), byte7(), byte7()) :: binary()
  def cc_bytes(ch, ctrl, val) when ch in 0..15 and ctrl in 0..127 and val in 0..127,
    do: <<bor(0xB0, ch), ctrl, val>>

  @doc false
  @spec program_change_bytes(channel(), byte7()) :: binary()
  def program_change_bytes(ch, prog) when ch in 0..15 and prog in 0..127,
    do: <<bor(0xC0, ch), prog>>

  # ── Pure parser ─────────────────────────────────────────────────────────

  @doc """
  Parse a complete MIDI byte stream into a list of events. Pure and stateless:
  a one-shot `MobMidi.Parser.feed/2` + `MobMidi.Parser.flush/1`, so a truncated
  tail comes back as `:raw`. For packets from a live source, where a message
  can straddle two packets, keep a `MobMidi.Parser` per source instead. See
  `MobMidi.Parser` for the event shapes (velocity-0 Note On is `:note_off`).
  """
  @spec parse(binary()) :: [map()]
  def parse(bytes) when is_binary(bytes) do
    {events, parser} = MobMidi.Parser.feed(MobMidi.Parser.new(), bytes)
    {tail, _} = MobMidi.Parser.flush(parser)
    events ++ tail
  end

  @doc """
  Normalise a `{:midi, :devices, payload}` payload to a list of
  `%{id: integer, name: binary, direction: :input | :output | :both,
  manufacturer: binary, type: :usb | :bluetooth | :virtual | :other,
  address: binary, input_ports: n, output_ports: n, own: boolean}`.

  Directions are the app's: `input_ports` counts the ports `open_input/3` can
  read (`port: 0..n-1`; Android's `outputPortCount`), `output_ports` the ones
  `open_output/3` can write (Android's `inputPortCount`); `direction` sums
  them up. `type` is the transport. `address` is a Bluetooth device's address
  (`""` otherwise), so an app can tell which device a `connect_bluetooth/2`
  became. `own` marks the app's own virtual devices (see `open_virtual/3`),
  which a device picker usually hides.

  iOS delivers a list of maps directly; Android delivers a JSON string (the
  Kotlin bridge builds it from `MidiDeviceInfo`). This collapses both, so a
  screen can do `payload |> MobMidi.parse_devices() |> Enum.filter(...)`. Pure.
  """
  @spec parse_devices(list() | binary() | term()) :: [map()]
  def parse_devices(devices) when is_list(devices), do: Enum.map(devices, &atomize_device/1)

  def parse_devices(json) when is_binary(json) do
    case decode_json(json) do
      list when is_list(list) -> Enum.map(list, &atomize_device/1)
      _ -> []
    end
  end

  def parse_devices(_), do: []

  # :json.decode/1 raises on malformed input; treat that as "no devices".
  defp decode_json(json) do
    :json.decode(json)
  rescue
    ErlangError -> :error
  end

  defp atomize_device(d) when is_map(d) do
    d =
      normalize_keys(d, [
        :id,
        :name,
        :direction,
        :manufacturer,
        :type,
        :address,
        :input_ports,
        :output_ports,
        :own
      ])

    direction = direction_atom(d[:direction])

    %{
      id: d[:id],
      name: d[:name],
      direction: direction,
      manufacturer: d[:manufacturer] || "",
      type: type_atom(d[:type]),
      address: d[:address] || "",
      input_ports: d[:input_ports] || if(direction in [:input, :both], do: 1, else: 0),
      output_ports: d[:output_ports] || if(direction in [:output, :both], do: 1, else: 0),
      own: d[:own] == true
    }
  end

  # Devices arrive with atom keys (native bridge) or string keys (JSON);
  # fill each atom key from its string twin when the atom key is missing.
  defp normalize_keys(d, keys) do
    Enum.reduce(keys, d, fn key, acc ->
      if Map.has_key?(acc, key),
        do: acc,
        else: Map.put(acc, key, Map.get(acc, Atom.to_string(key)))
    end)
  end

  defp type_atom(t) when t in ["usb", "bluetooth", "virtual"], do: String.to_existing_atom(t)
  defp type_atom(t) when t in [:usb, :bluetooth, :virtual], do: t
  defp type_atom(_), do: :other

  defp direction_atom("input"), do: :input
  defp direction_atom("output"), do: :output
  defp direction_atom("both"), do: :both
  defp direction_atom(a) when a in [:input, :output, :both], do: a
  defp direction_atom(_), do: :input

  # ── Helper ──────────────────────────────────────────────────────────────

  defp guarded(socket, fun) do
    if MobMidi.Platform.unsupported?(MobMidi.Platform.current()) do
      {:error, :unsupported}
    else
      fun.()
      socket
    end
  end

  defp bluetooth_guarded(socket, fun) do
    if MobMidi.Platform.bluetooth_central?(MobMidi.Platform.current()),
      do: guarded(socket, fun),
      else: {:error, :unsupported}
  end

  # Anything but deliver: :beam needs the C ABI (Android).
  defp native_guarded(socket, route, fun) do
    platform = MobMidi.Platform.current()

    if route != 1 and not MobMidi.Platform.native_abi?(platform),
      do: {:error, :unsupported},
      else: guarded(socket, fun)
  end
end
