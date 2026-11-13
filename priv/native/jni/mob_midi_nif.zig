//! mob_midi_nif — Android MIDI plugin NIF (Zig).
//!
//! Bridges the midi_* NIFs to the Kotlin MobMidiBridge (android.media.midi).
//! The NIF surface is thin: enumeration + raw byte I/O. Message encode/parse
//! lives in Elixir (MobMidi). Calls that answer later capture the caller's pid
//! (round-tripped through Kotlin as a jlong) and deliver results back.
//!
//! Delivery contract (matches the iOS NIF):
//!   {:midi, :devices, json_binary}                                   -- nativeDeliverMidiDevices
//!   {:midi, :raw, %{device:, port:, bytes:, timestamp:, received:}}  -- mob_midi_core.c (nativeReceive)
//!   {:midi, :opened, %{device:, port:, direction: :input, source:}}  -- nativeDeliverMidiOpened
//!   {:midi, :opened, %{device:, port:, direction: :output, handle:}} -- nativeDeliverMidiOpened
//!   {:midi, :opened, %{device:, direction: :virtual, name:}}         -- nativeDeliverMidiVirtualOpened
//!   {:midi, :virtual_status, %{device:, senders:, listeners:}}       -- nativeDeliverMidiVirtualStatus
//!   {:midi, :device_added | :device_removed, nil}                    -- nativeDeliverMidiEvent
//!   {:midi, :bluetooth_scan, :started | :stopped}                    -- nativeDeliverMidiEvent
//!   {:midi, :bluetooth_device, %{address:, name:, rssi:}}            -- nativeDeliverMidiBluetoothDevice
//!   {:midi, :connected, %{device:, address:}}                        -- nativeDeliverMidiConnected
//!   {:midi, :error, %{device:, op:, reason:, dropped:}}              -- nativeDeliverMidiError
//!   {:midi, :drained, %{device:, port:, handle:, generation:}}       -- mob_midi_core.c (nativeNextSend)
//!
//! midi_send returns :ok (queued for the port's dispatch thread), :queued
//! (output still opening; flushed in order when it opens) or {:error,
//! :not_open | :queue_full | :send_failed | :no_listener}. An open output's
//! bytes go straight into its queue in mob_midi_core.c (no JNI); only a port
//! that isn't open yet takes the Kotlin path. Timestamps are CLOCK_MONOTONIC
//! ns (System.nanoTime), the clock of midi_now_ns/0. midi_discard drops an
//! open output's queue (mob_midi_discard).
//!
//! Every call into Kotlin only records the request and posts it to the
//! bridge's worker thread (MidiManager lookups are binder calls), so no NIF
//! here blocks on another process; the answers come from that thread.
//!
//! mob-core ERTS / JNI bindings come in via the named imports @import("erts")
//! and @import("jni") that build.zig wires for plugin NIFs.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// mob_midi_core.c (the plugin's android.jni_source): the send queues.
extern fn mob_midi__send_device(device: i32, port: i32, bytes: [*]const u8, len: usize, at_ns: i64) c_int;
extern fn mob_midi__output_handle(device: i32, port: i32) i64;
extern fn mob_midi__discard_device(device: i32, port: i32) c_int;
// CLOCK_MONOTONIC ns, from mob_midi_core.c. Not mob_zig's nowNs: its
// Timespec is two i64s, which garbles the result on 32-bit ARM, where
// time_t and long are 32 bits.
extern fn mob_midi_now_ns() i64;
const MOB_MIDI_OK: c_int = 0;
const MOB_MIDI_ERR_NOT_OPEN: c_int = -1;
const MOB_MIDI_ERR_QUEUE_FULL: c_int = -2;
const MOB_MIDI_ERR_NO_LISTENER: c_int = -3;

// enif_get_int64 is a macro for enif_get_long where long is 64-bit (as in
// erl_nif.h), a real symbol elsewhere.
const enif_get_int64 = @extern(
    *const fn (?*erts.ErlNifEnv, erts.ERL_NIF_TERM, *i64) callconv(.c) c_int,
    .{ .name = if (@sizeOf(c_long) == 8) "enif_get_long" else "enif_get_int64" },
);

// ── Plugin-owned bridge method-id cache ──────────────────────────────────
const MidiMethods = struct {
    list_devices: jni.JMethodID = null,
    open_input: jni.JMethodID = null,
    open_output: jni.JMethodID = null,
    send: jni.JMethodID = null,
    close: jni.JMethodID = null,
    open_virtual: jni.JMethodID = null,
    scan_bluetooth: jni.JMethodID = null,
    stop_bluetooth_scan: jni.JMethodID = null,
    connect_bluetooth: jni.JMethodID = null,
};
var g_midi: MidiMethods = .{};
var g_midi_cls: jni.JClass = null;

export fn Java_io_mob_midi_MobMidiBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_midi_cls = jni.newGlobalRef(jenv, cls);
    if (g_midi_cls == null) return;
    g_midi.list_devices = jni.getStaticMethodID(jenv, cls, "listDevices", "(J)V");
    g_midi.open_input = jni.getStaticMethodID(jenv, cls, "openInput", "(JIII)V");
    g_midi.open_output = jni.getStaticMethodID(jenv, cls, "openOutput", "(JII)V");
    g_midi.send = jni.getStaticMethodID(jenv, cls, "send", "(II[BJ)I");
    g_midi.close = jni.getStaticMethodID(jenv, cls, "close", "(I)V");
    g_midi.open_virtual = jni.getStaticMethodID(jenv, cls, "openVirtual", "(J[BI)V");
    g_midi.scan_bluetooth = jni.getStaticMethodID(jenv, cls, "scanBluetooth", "(JI)V");
    g_midi.stop_bluetooth_scan = jni.getStaticMethodID(jenv, cls, "stopBluetoothScan", "()V");
    g_midi.connect_bluetooth = jni.getStaticMethodID(jenv, cls, "connectBluetooth", "(J[B)V");
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return @bitCast(pid.pid);
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) return .{ .pid = @bitCast(jpid) };
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = @intCast(low) };
}

inline fn notLoaded(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "nif_not_loaded") });
}

// UTF-8 bytes from Kotlin as a binary term (in a message env). Text that
// carries names comes as byte[], not String: GetStringUTFChars gives
// modified UTF-8, which turns a character outside the BMP (an emoji in a
// device name) into surrogate bytes that aren't valid UTF-8.
fn bytesBinary(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, arr: jni.JByteArray) ?erts.ERL_NIF_TERM {
    if (arr == null) return null;
    const len = jni.getArrayLength(jenv, arr);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(@intCast(len), &bin) == 0) return null;
    if (len > 0) jni.getByteArrayRegion(jenv, arr, 0, len, @ptrCast(bin.data));
    return erts.enif_make_binary(env, &bin);
}

// Never leave a pending Java exception on a BEAM scheduler thread: the next
// JNI call would be undefined (CheckJNI aborts). Returns true, after clearing
// it, when one was pending. mob_zig types ExceptionOccurred as opaque (and
// omits ExceptionCheck), so give it its JNI signature here; align(1) because a
// Thumb function pointer has bit 0 set.
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
}

// ── NIFs ─────────────────────────────────────────────────────────────────

fn callSelfVoid(env: ?*erts.ErlNifEnv, mid: jni.JMethodID) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

export fn nif_midi_list_devices(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callSelfVoid(env, g_midi.list_devices);
}

// open_output(device, port): capture the caller so events reach it.
fn callSelfDevicePortVoid(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var dev: c_int = 0;
    var port: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0 or erts.enif_get_int(env, argv[1], &port) == 0)
        return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid), @as(jni.JInt, dev), @as(jni.JInt, port));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

// open_input(device, port, route): port -1 = every port; route 1 = BEAM,
// 2 = native sink, 3 = both.
export fn nif_midi_open_input(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_midi.open_input == null) return notLoaded(env);
    var dev: c_int = 0;
    var port: c_int = 0;
    var route: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0 or erts.enif_get_int(env, argv[1], &port) == 0 or
        erts.enif_get_int(env, argv[2], &route) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, g_midi.open_input, pidToJlong(pid), @as(jni.JInt, dev), @as(jni.JInt, port), @as(jni.JInt, route));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

// midi_output_handle(device, port): the open output's mob_midi.h handle.
export fn nif_midi_output_handle(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var dev: c_int = 0;
    var port: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0 or erts.enif_get_int(env, argv[1], &port) == 0)
        return erts.badarg(env);
    const handle = mob_midi__output_handle(dev, port);
    if (handle <= 0) return erts.errorTuple(env, erts.atom(env, "not_open"));
    return erts.makeTuple(env, .{ erts.atom(env, "ok"), erts.enif_make_int64(env, handle) });
}

// midi_discard(device, port): drop the open output's queue; {:ok, generation}.
export fn nif_midi_discard(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var dev: c_int = 0;
    var port: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0 or erts.enif_get_int(env, argv[1], &port) == 0)
        return erts.badarg(env);
    const generation = mob_midi__discard_device(dev, port);
    if (generation <= 0) return erts.errorTuple(env, erts.atom(env, "not_open"));
    return erts.makeTuple(env, .{ erts.atom(env, "ok"), erts.enif_make_int(env, generation) });
}

export fn nif_midi_open_output(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfDevicePortVoid(env, g_midi.open_output, argv);
}

export fn nif_midi_close(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_midi.close == null) return notLoaded(env);
    var dev: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0) return erts.badarg(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, g_midi.close, @as(jni.JInt, dev));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

// midi_send(device, port, bytes, timestamp_ns); timestamp 0 = now.
export fn nif_midi_send(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_midi.send == null) return notLoaded(env);
    var dev: c_int = 0;
    var port: c_int = 0;
    var ts: i64 = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0 or erts.enif_get_int(env, argv[1], &port) == 0 or
        enif_get_int64(env, argv[3], &ts) == 0) return erts.badarg(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[2], &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, argv[2], &bin) == 0) return erts.badarg(env);
    if (bin.size == 0) return erts.ok(env);

    switch (mob_midi__send_device(dev, port, bin.data, bin.size, ts)) {
        MOB_MIDI_OK => return erts.ok(env),
        MOB_MIDI_ERR_QUEUE_FULL => return erts.errorTuple(env, erts.atom(env, "queue_full")),
        MOB_MIDI_ERR_NO_LISTENER => return erts.errorTuple(env, erts.atom(env, "no_listener")),
        MOB_MIDI_ERR_NOT_OPEN => {}, // opening, or not open: Kotlin knows which
        else => return erts.errorTuple(env, erts.atom(env, "send_failed")),
    }

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jarr = jenv.*.NewByteArray.?(jenv, @intCast(bin.size));
    if (jarr == null) {
        _ = clearPendingException(jenv); // OutOfMemoryError
        return erts.errorTuple(env, erts.atom(env, "send_failed"));
    }
    jenv.*.SetByteArrayRegion.?(jenv, jarr, 0, @intCast(bin.size), @ptrCast(bin.data));
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_midi_cls, g_midi.send, @as(jni.JInt, dev), @as(jni.JInt, port), jarr, @as(jni.JLong, ts));
    jenv.*.DeleteLocalRef.?(jenv, jarr);
    // A throw leaves `code` meaningless; check before trusting it.
    if (clearPendingException(jenv)) return erts.errorTuple(env, erts.atom(env, "send_failed"));
    // Codes mirror MobMidiBridge.SEND_*.
    return switch (code) {
        0 => erts.ok(env),
        1 => erts.atom(env, "queued"),
        2 => erts.errorTuple(env, erts.atom(env, "not_open")),
        3 => erts.errorTuple(env, erts.atom(env, "queue_full")),
        5 => erts.errorTuple(env, erts.atom(env, "no_listener")),
        else => erts.errorTuple(env, erts.atom(env, "send_failed")),
    };
}

// CLOCK_MONOTONIC ns: System.nanoTime's clock, which MIDI timestamps use.
export fn nif_midi_now_ns(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.enif_make_int64(env, mob_midi_now_ns());
}

// (pid, byte[][, Int]) calls: connect_bluetooth(address), open_virtual(name,
// route). The binary goes over as UTF-8 bytes: NewStringUTF takes modified
// UTF-8 and rejects a 4-byte sequence (CheckJNI aborts the app).
fn callSelfBytes(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, arg: erts.ERL_NIF_TERM, extra: ?c_int) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, arg, &bin) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    const jarr = jni.newByteArray(jenv, @intCast(bin.size));
    if (jarr == null) {
        _ = clearPendingException(jenv); // OutOfMemoryError
        return erts.atom(env, "error");
    }
    defer jni.deleteLocalRef(jenv, jarr);
    if (bin.size > 0) jni.setByteArrayRegion(jenv, jarr, 0, @intCast(bin.size), @ptrCast(bin.data));
    if (extra) |x| {
        jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid), jarr, @as(jni.JInt, x));
    } else {
        jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid), jarr);
    }
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

// open_virtual(name, route): route as for open_input.
export fn nif_midi_open_virtual(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var route: c_int = 0;
    if (erts.enif_get_int(env, argv[1], &route) == 0) return erts.badarg(env);
    return callSelfBytes(env, g_midi.open_virtual, argv[0], route);
}

export fn nif_midi_connect_bluetooth(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfBytes(env, g_midi.connect_bluetooth, argv[0], null);
}

export fn nif_midi_scan_bluetooth(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_midi.scan_bluetooth == null) return notLoaded(env);
    var duration_ms: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &duration_ms) == 0 or duration_ms <= 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, g_midi.scan_bluetooth, pidToJlong(pid), @as(jni.JInt, duration_ms));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

export fn nif_midi_stop_bluetooth_scan(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_midi.stop_bluetooth_scan == null) return notLoaded(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, g_midi.stop_bluetooth_scan);
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

// ── Delivery thunks (called from MobMidiBridge.kt) ───────────────────────

fn sendMidi(env: ?*erts.ErlNifEnv, pid_long: jni.JLong, comptime tag: [:0]const u8, payload: erts.ERL_NIF_TERM) void {
    var pid = pidFromLong(pid_long);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.atom(env, tag), payload });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiDevices(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, json: jni.JByteArray) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const bin_term = bytesBinary(env, jenv, json) orelse return;
    sendMidi(env, pid_long, "devices", bin_term);
}

// {:midi, :opened, %{device, port, direction}} plus, for an input, its
// mob_midi.h `source` and, for an output, its `handle` (0 = none).
pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiOpened(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, port: jni.JInt, direction: jni.JString, source: jni.JInt, handle: jni.JLong) callconv(.c) void {
    _ = cls;
    const dir_c = jni.getStringUTFChars(jenv, direction) orelse return;
    defer jni.releaseStringUTFChars(jenv, direction, dir_c);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var keys = [_]erts.ERL_NIF_TERM{ erts.atom(env, "device"), erts.atom(env, "port"), erts.atom(env, "direction"), 0 };
    var vals = [_]erts.ERL_NIF_TERM{ erts.enif_make_int(env, @intCast(device)), erts.enif_make_int(env, @intCast(port)), erts.enif_make_atom(env, dir_c), 0 };
    var n: usize = 3;
    if (source > 0) {
        keys[n] = erts.atom(env, "source");
        vals[n] = erts.enif_make_int(env, @intCast(source));
        n += 1;
    } else if (handle > 0) {
        keys[n] = erts.atom(env, "handle");
        vals[n] = erts.enif_make_int64(env, handle);
        n += 1;
    }
    const map = erts.makeMap(env, keys[0..n], vals[0..n]) orelse return;
    sendMidi(env, pid_long, "opened", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiVirtualOpened(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, name: jni.JByteArray) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const name_term = bytesBinary(env, jenv, name) orelse return;
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "direction"), erts.atom(env, "name") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.atom(env, "virtual"), name_term },
    ) orelse return;
    sendMidi(env, pid_long, "opened", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiVirtualStatus(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, senders: jni.JInt, listeners: jni.JInt) callconv(.c) void {
    _ = jenv;
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "senders"), erts.atom(env, "listeners") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.enif_make_int(env, @intCast(senders)), erts.enif_make_int(env, @intCast(listeners)) },
    ) orelse return;
    sendMidi(env, pid_long, "virtual_status", map);
}

// {:midi, tag, value}: tag and value become atoms; a null value is nil.
pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiEvent(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, tag: jni.JString, value: jni.JString) callconv(.c) void {
    _ = cls;
    const tag_c = jni.getStringUTFChars(jenv, tag) orelse return;
    defer jni.releaseStringUTFChars(jenv, tag, tag_c);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var value_term = erts.atom(env, "nil");
    if (value != null) {
        const value_c = jni.getStringUTFChars(jenv, value) orelse return;
        defer jni.releaseStringUTFChars(jenv, value, value_c);
        value_term = erts.enif_make_atom(env, value_c);
    }
    var pid = pidFromLong(pid_long);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.enif_make_atom(env, tag_c), value_term });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiBluetoothDevice(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, address: jni.JByteArray, name: jni.JByteArray, rssi: jni.JInt) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const address_term = bytesBinary(env, jenv, address) orelse return;
    const name_term = bytesBinary(env, jenv, name) orelse return;
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "address"), erts.atom(env, "name"), erts.atom(env, "rssi") },
        &.{ address_term, name_term, erts.enif_make_int(env, @intCast(rssi)) },
    ) orelse return;
    sendMidi(env, pid_long, "bluetooth_device", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiConnected(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, address: jni.JByteArray) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const address_term = bytesBinary(env, jenv, address) orelse return;
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "address") },
        &.{ erts.enif_make_int(env, @intCast(device)), address_term },
    ) orelse return;
    sendMidi(env, pid_long, "connected", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiError(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, op: jni.JString, reason: jni.JString, dropped: jni.JInt) callconv(.c) void {
    _ = cls;
    const op_c = jni.getStringUTFChars(jenv, op) orelse return;
    defer jni.releaseStringUTFChars(jenv, op, op_c);
    const reason_c = jni.getStringUTFChars(jenv, reason) orelse return;
    defer jni.releaseStringUTFChars(jenv, reason, reason_c);

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "op"), erts.atom(env, "reason"), erts.atom(env, "dropped") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.enif_make_atom(env, op_c), erts.enif_make_atom(env, reason_c), erts.enif_make_int(env, @intCast(dropped)) },
    ) orelse return;
    sendMidi(env, pid_long, "error", map);
}

// ── NIF table + init ─────────────────────────────────────────────────────

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "midi_list_devices", .arity = 0, .fptr = nif_midi_list_devices, .flags = 0 },
    .{ .name = "midi_open_input", .arity = 3, .fptr = nif_midi_open_input, .flags = 0 },
    .{ .name = "midi_open_output", .arity = 2, .fptr = nif_midi_open_output, .flags = 0 },
    .{ .name = "midi_close", .arity = 1, .fptr = nif_midi_close, .flags = 0 },
    .{ .name = "midi_send", .arity = 4, .fptr = nif_midi_send, .flags = 0 },
    .{ .name = "midi_now_ns", .arity = 0, .fptr = nif_midi_now_ns, .flags = 0 },
    .{ .name = "midi_open_virtual", .arity = 2, .fptr = nif_midi_open_virtual, .flags = 0 },
    .{ .name = "midi_output_handle", .arity = 2, .fptr = nif_midi_output_handle, .flags = 0 },
    .{ .name = "midi_discard", .arity = 2, .fptr = nif_midi_discard, .flags = 0 },
    .{ .name = "midi_scan_bluetooth", .arity = 1, .fptr = nif_midi_scan_bluetooth, .flags = 0 },
    .{ .name = "midi_stop_bluetooth_scan", .arity = 0, .fptr = nif_midi_stop_bluetooth_scan, .flags = 0 },
    .{ .name = "midi_connect_bluetooth", .arity = 1, .fptr = nif_midi_connect_bluetooth, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_midi_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_midi_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
