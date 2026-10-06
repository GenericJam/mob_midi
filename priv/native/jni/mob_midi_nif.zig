//! mob_midi_nif — Android MIDI plugin NIF (Zig).
//!
//! Bridges the midi_* NIFs to the Kotlin MobMidiBridge (android.media.midi).
//! The NIF surface is thin: enumeration + raw byte I/O. Message encode/parse
//! lives in Elixir (MobMidi). list_devices / open_input / open_output capture
//! the caller's pid (round-tripped through Kotlin as a jlong) and deliver
//! results back.
//!
//! Delivery contract (matches the iOS NIF):
//!   {:midi, :devices, json_binary}                        -- nativeDeliverMidiDevices
//!   {:midi, :raw, %{device: int, bytes: bin}}             -- nativeDeliverMidiRaw
//!   {:midi, :opened, %{device: int, direction: :output}}  -- nativeDeliverMidiOpened
//!   {:midi, :error, %{device:, op:, reason:, dropped:}}   -- nativeDeliverMidiError
//!
//! midi_send returns :ok (written), :queued (output still opening; flushed in
//! order when it opens) or {:error, :not_open | :queue_full | :send_failed}.
//!
//! mob-core ERTS / JNI bindings come in via the named imports @import("erts")
//! and @import("jni") that build.zig wires for plugin NIFs.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge method-id cache ──────────────────────────────────
const MidiMethods = struct {
    list_devices: jni.JMethodID = null,
    open_input: jni.JMethodID = null,
    open_output: jni.JMethodID = null,
    send: jni.JMethodID = null,
    close: jni.JMethodID = null,
};
var g_midi: MidiMethods = .{};
var g_midi_cls: jni.JClass = null;

export fn Java_io_mob_midi_MobMidiBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_midi_cls = jni.newGlobalRef(jenv, cls);
    if (g_midi_cls == null) return;
    g_midi.list_devices = jni.getStaticMethodID(jenv, cls, "listDevices", "(J)V");
    g_midi.open_input = jni.getStaticMethodID(jenv, cls, "openInput", "(JI)V");
    g_midi.open_output = jni.getStaticMethodID(jenv, cls, "openOutput", "(JI)V");
    g_midi.send = jni.getStaticMethodID(jenv, cls, "send", "(I[B)I");
    g_midi.close = jni.getStaticMethodID(jenv, cls, "close", "(I)V");
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

// open_input / open_output: capture the caller so events reach it.
fn callSelfDeviceVoid(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var dev: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, pidToJlong(pid), @as(jni.JInt, dev));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

export fn nif_midi_open_input(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfDeviceVoid(env, g_midi.open_input, argv);
}

fn callDeviceVoid(env: ?*erts.ErlNifEnv, mid: jni.JMethodID, argv: [*]const erts.ERL_NIF_TERM) erts.ERL_NIF_TERM {
    if (mid == null) return notLoaded(env);
    var dev: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0) return erts.badarg(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);
    jenv.*.CallStaticVoidMethod.?(jenv, g_midi_cls, mid, @as(jni.JInt, dev));
    if (clearPendingException(jenv)) return erts.atom(env, "error");
    return erts.ok(env);
}

export fn nif_midi_open_output(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callSelfDeviceVoid(env, g_midi.open_output, argv);
}

export fn nif_midi_close(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    return callDeviceVoid(env, g_midi.close, argv);
}

export fn nif_midi_send(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_midi.send == null) return notLoaded(env);
    var dev: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &dev) == 0) return erts.badarg(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[1], &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, argv[1], &bin) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jarr = jenv.*.NewByteArray.?(jenv, @intCast(bin.size));
    if (jarr == null) {
        _ = clearPendingException(jenv); // OutOfMemoryError
        return erts.errorTuple(env, erts.atom(env, "send_failed"));
    }
    jenv.*.SetByteArrayRegion.?(jenv, jarr, 0, @intCast(bin.size), @ptrCast(bin.data));
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_midi_cls, g_midi.send, @as(jni.JInt, dev), jarr);
    jenv.*.DeleteLocalRef.?(jenv, jarr);
    // A throw leaves `code` meaningless; check before trusting it.
    if (clearPendingException(jenv)) return erts.errorTuple(env, erts.atom(env, "send_failed"));
    // Codes mirror MobMidiBridge.SEND_*.
    return switch (code) {
        0 => erts.ok(env),
        1 => erts.atom(env, "queued"),
        2 => erts.errorTuple(env, erts.atom(env, "not_open")),
        3 => erts.errorTuple(env, erts.atom(env, "queue_full")),
        else => erts.errorTuple(env, erts.atom(env, "send_failed")),
    };
}

// ── Delivery thunks (called from MobMidiBridge.kt) ───────────────────────

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiDevices(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, json: jni.JString) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const cstr = jenv.*.GetStringUTFChars.?(jenv, json, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, json, cstr);
    const span = std.mem.span(cstr);

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const bin_term = makeBinary(env, span);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.atom(env, "devices"), bin_term });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiRaw(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, bytes: jni.JByteArray) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const len = jni.getArrayLength(jenv, bytes);

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(@intCast(len), &bin);
    if (len > 0) jni.getByteArrayRegion(jenv, bytes, 0, len, @ptrCast(bin.data));
    const bin_term = erts.enif_make_binary(env, &bin);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "bytes") },
        &.{ erts.enif_make_int(env, @intCast(device)), bin_term },
    ) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.atom(env, "raw"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiOpened(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const map = erts.makeMap(
        env,
        &.{ erts.atom(env, "device"), erts.atom(env, "direction") },
        &.{ erts.enif_make_int(env, @intCast(device)), erts.atom(env, "output") },
    ) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.atom(env, "opened"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn Java_io_mob_midi_MobMidiBridge_nativeDeliverMidiError(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, device: jni.JInt, op: jni.JString, reason: jni.JString, dropped: jni.JInt) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
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
    const msg = erts.makeTuple(env, .{ erts.atom(env, "midi"), erts.atom(env, "error"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIF table + init ─────────────────────────────────────────────────────

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "midi_list_devices", .arity = 0, .fptr = nif_midi_list_devices, .flags = 0 },
    .{ .name = "midi_open_input", .arity = 1, .fptr = nif_midi_open_input, .flags = 0 },
    .{ .name = "midi_open_output", .arity = 1, .fptr = nif_midi_open_output, .flags = 0 },
    .{ .name = "midi_close", .arity = 1, .fptr = nif_midi_close, .flags = 0 },
    .{ .name = "midi_send", .arity = 2, .fptr = nif_midi_send, .flags = 0 },
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
