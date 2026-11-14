//! mob_midi_nif — Android MIDI plugin NIF (Zig).
//!
//! Bridges the midi_* NIFs to the Kotlin MobMidiBridge (android.media.midi).
//! The NIF surface is thin: enumeration + raw byte I/O. Message encode/parse
//! lives in Elixir (MobMidi). Calls that answer later capture the caller's pid
//! (round-tripped through Kotlin as a jlong) and deliver results back.
//!
//! Delivery contract (matches the iOS NIF):
//!   {:midi, :devices, json_binary}                                   -- nativeDeliverMidiDevices
//!   {:midi, :raw, %{device:, port:, bytes:, timestamp:, received:}}  -- nativeDeliverMidiRaw
//!   {:midi, :opened, %{device:, port:, direction: :input | :output}} -- nativeDeliverMidiOpened
//!   {:midi, :opened, %{device:, direction: :virtual, name:}}         -- nativeDeliverMidiVirtualOpened
//!   {:midi, :virtual_status, %{device:, senders:, listeners:}}       -- nativeDeliverMidiVirtualStatus
//!   {:midi, :device_added | :device_removed, nil}                    -- nativeDeliverMidiEvent
//!   {:midi, :bluetooth_scan, :started | :stopped}                    -- nativeDeliverMidiEvent
//!   {:midi, :bluetooth_device, %{address:, name:}}                   -- nativeDeliverMidiBluetoothDevice
//!   {:midi, :connected, %{device:, address:}}                        -- nativeDeliverMidiConnected
//!   {:midi, :error, %{device:, op:, reason:, dropped:}}              -- nativeDeliverMidiError
//!
//! midi_send returns :ok (written), :queued (output still opening; flushed in
//! order when it opens) or {:error, :not_open | :queue_full | :send_failed |
//! :no_listener}. Timestamps are CLOCK_MONOTONIC ns (System.nanoTime), the
//! clock of midi_now_ns/0.
//!
//! mob-core ERTS / JNI bindings come in via the named imports @import("erts")
//! and @import("jni") that build.zig wires for plugin NIFs.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

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
    g_midi.open_input = jni.getStaticMethodID(jenv, cls, "openInput", "(JII)V");
    g_midi.open_output = jni.getStaticMethodID(jenv, cls, "openOutput", "(JII)V");
    g_midi.send = jni.getStaticMethodID(jenv, cls, "send", "(II[BJ)I");
    g_midi.close = jni.getStaticMethodID(jenv, cls, "close", "(I)V");
    g_midi.open_virtual = jni.getStaticMethodID(jenv, cls, "openVirtual", "(JLjava/lang/String;)V");
    g_midi.scan_bluetooth = jni.getStaticMethodID(jenv, cls, "scanBluetooth", "(JI)V");
    g_midi.stop_bluetooth_scan = jni.getStaticMethodID(jenv, cls, "stopBluetoothScan", "()V");
    g_midi.connect_bluetooth = jni.getStaticMethodID(jenv, cls, "connectBluetooth", "(JLjava/lang/String;)V");
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

fn makeBinary(env: ?*erts.ErlNifEnv, data: []const u8) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(data.len, &bin);
    if (data.len > 0) @memcpy(bin.data[0..data.len], data);
    return erts.enif_make_binary(env, &bin);
}

// A Java string as a binary term (in a message env).
fn javaStringBinary(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, str: jni.JString) ?erts.ERL_NIF_TERM {
    const cstr = jni.getStringUTFChars(jenv, str) orelse return null;
    defer jni.releaseStringUTFChars(jenv, str, cstr);
    return makeBinary(env, std.mem.span(cstr));
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

// open_input / open_output (device, port): capture the caller so events reach it.
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

export fn nif_midi_open_input(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfDevicePortVoid(env, g_midi.open_input, argv);
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
    return erts.enif_make_int64(env, jni.nowNs());
}

// (pid, String) calls: open_virtual(name), connect_bluetooth(address).
fn callSelfStringVoid(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, arg: erts.ERL_NIF_TERM) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, arg, &bin) == 0) return erts.badarg(env);
    var buf: [256]u8 = undefined;
    if (bin.size >= buf.len) return erts.badarg(env);
    @memcpy(buf[0..bin.size], bin.data[0..bin.size]);
    buf[bin.size] = 0;
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    const jstr = jni.newStringUTF(jenv, @ptrCast(&buf));
    if (jstr == null) {
        _ = clearPendingException(jenv);
        return erts.atom(env, "error");
    }
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid), jstr);
    jni.deleteLocalRef(jenv, jstr);
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

export fn nif_midi_open_virtual(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfStringVoid(env, g_midi.open_virtual, argv[0]);
}

export fn nif_midi_connect_bluetooth(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfStringVoid(env, g_midi.connect_bluetooth, argv[0]);
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

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiDevices(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, json: jni.JString) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const bin_term = javaStringBinary(env, jenv, json) orelse return;
    sendMidi(env, pid_long, "devices", bin_term);
}

// The hot path: one incoming MIDI chunk, copied straight from the Java array
// into the message binary.
pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiRaw(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, port: jni.JInt, bytes: jni.JByteArray, offset: jni.JInt, count: jni.JInt, timestamp: jni.JLong, received: jni.JLong) callconv(.c) void {
    _ = cls;
    if (count <= 0) return;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(@intCast(count), &bin) == 0) return;
    jni.getByteArrayRegion(jenv, bytes, offset, count, @ptrCast(bin.data));
    const bin_term = erts.enif_make_binary(env, &bin);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "port"), erts.atom(env, "bytes"), erts.atom(env, "timestamp"), erts.atom(env, "received") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.enif_make_int(env, @intCast(port)), bin_term, erts.enif_make_int64(env, timestamp), erts.enif_make_int64(env, received) },
    ) orelse return;
    sendMidi(env, pid_long, "raw", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiOpened(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, port: jni.JInt, direction: jni.JString) callconv(.c) void {
    _ = cls;
    const dir_c = jni.getStringUTFChars(jenv, direction) orelse return;
    defer jni.releaseStringUTFChars(jenv, direction, dir_c);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "port"), erts.atom(env, "direction") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.enif_make_int(env, @intCast(port)), erts.enif_make_atom(env, dir_c) },
    ) orelse return;
    sendMidi(env, pid_long, "opened", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiVirtualOpened(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, name: jni.JString) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const name_term = javaStringBinary(env, jenv, name) orelse return;
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

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiBluetoothDevice(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, address: jni.JString, name: jni.JString) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const address_term = javaStringBinary(env, jenv, address) orelse return;
    const name_term = javaStringBinary(env, jenv, name) orelse return;
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "address"), erts.atom(env, "name") },
        &.{ address_term, name_term },
    ) orelse return;
    sendMidi(env, pid_long, "bluetooth_device", map);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiConnected(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, address: jni.JString) callconv(.c) void {
    _ = cls;
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const address_term = javaStringBinary(env, jenv, address) orelse return;
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
    .{ .name = "midi_open_input", .arity = 2, .fptr = nif_midi_open_input, .flags = 0 },
    .{ .name = "midi_open_output", .arity = 2, .fptr = nif_midi_open_output, .flags = 0 },
    .{ .name = "midi_close", .arity = 1, .fptr = nif_midi_close, .flags = 0 },
    .{ .name = "midi_send", .arity = 4, .fptr = nif_midi_send, .flags = 0 },
    .{ .name = "midi_now_ns", .arity = 0, .fptr = nif_midi_now_ns, .flags = 0 },
    .{ .name = "midi_open_virtual", .arity = 1, .fptr = nif_midi_open_virtual, .flags = 0 },
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
