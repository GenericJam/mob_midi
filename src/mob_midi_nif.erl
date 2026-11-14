%% mob_midi_nif — Erlang NIF module for the mob_midi plugin.
%%
%% The native side (iOS priv/native/ios/mob_midi_nif.m over CoreMIDI; Android
%% priv/native/jni/mob_midi_nif.zig bridging to the Kotlin MobMidiBridge over
%% android.media.midi) registers the midi_* NIFs under this module name. On
%% device the NIF is statically linked into the host binary; on a host dev
%% build it isn't linked, so on_load tolerates the failure and the stubs fall
%% back to nif_error until the native merge links the implementation in.
%%
%% The NIF surface is deliberately thin: device enumeration + raw byte I/O.
%% Message encoding/parsing lives in Elixir (MobMidi) where it's testable. An
%% input subscription / list_devices captures the CALLER's pid (enif_self) and
%% delivers results there as {:midi, ...} messages.
-module(mob_midi_nif).
-export([
    midi_list_devices/0,
    midi_open_input/2,
    midi_open_output/2,
    midi_close/1,
    midi_send/4,
    midi_now_ns/0,
    midi_open_virtual/1,
    midi_scan_bluetooth/1,
    midi_stop_bluetooth_scan/0,
    midi_connect_bluetooth/1
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_midi_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

midi_list_devices() ->
    erlang:nif_error(nif_not_loaded).

midi_open_input(_DeviceId, _Port) ->
    erlang:nif_error(nif_not_loaded).

midi_open_output(_DeviceId, _Port) ->
    erlang:nif_error(nif_not_loaded).

midi_close(_DeviceId) ->
    erlang:nif_error(nif_not_loaded).

midi_send(_DeviceId, _Port, _Bytes, _TimestampNs) ->
    erlang:nif_error(nif_not_loaded).

midi_now_ns() ->
    erlang:nif_error(nif_not_loaded).

midi_open_virtual(_Name) ->
    erlang:nif_error(nif_not_loaded).

%% Android only (iOS pairs BLE-MIDI through its own UI); MobMidi gates it.
midi_scan_bluetooth(_DurationMs) ->
    erlang:nif_error(nif_not_loaded).

midi_stop_bluetooth_scan() ->
    erlang:nif_error(nif_not_loaded).

midi_connect_bluetooth(_Address) ->
    erlang:nif_error(nif_not_loaded).
