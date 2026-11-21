/*
 * mob_midi.h: the native C ABI of the mob_midi plugin.
 *
 * For a second native library linked into the same app (an audio engine's
 * static NIF, say) that wants MIDI without a BEAM hop: a sink that gets
 * incoming bytes on the MIDI receive thread, and a send that queues bytes for
 * an open output at a target time. Device enumeration, opening and closing
 * stay in Elixir (MobMidi); this header only moves bytes.
 *
 * Include it relative to your source, e.g. from c_src/my_nif.c:
 *     #include "../deps/mob_midi/priv/include/mob_midi.h"
 * The symbols live in mob_midi's native code, linked into the same app
 * binary as your NIF: priv/native/android/mob_midi_core.c on Android,
 * priv/native/ios/mob_midi_nif.m (CoreMIDI) on iOS. The two behave the same
 * except where marked "Android:" / "iOS:" below.
 *
 * ── Clock ──────────────────────────────────────────────────────────────────
 * Every timestamp is nanoseconds on the platform's MIDI clock, which
 * mob_midi_now_ns() and MobMidi.now_ns/0 read:
 *   Android: CLOCK_MONOTONIC (System.nanoTime(), the clock of
 *            android.media.midi timestamps).
 *   iOS:     mach_absolute_time() converted to ns (the clock of CoreMIDI's
 *            MIDITimeStamp and of AudioTimeStamp.mHostTime), the same as
 *            clock_gettime(CLOCK_UPTIME_RAW). It stops while the device
 *            sleeps. Darwin's CLOCK_MONOTONIC keeps counting through sleep,
 *            so it is a different clock: don't stamp with it. A host tick is
 *            125/3 ns on iPhones; at_ns is rounded up to a tick, so a
 *            message is stamped (and handed over) up to 42 ns after at_ns,
 *            never before, and a received stamp sent on keeps its tick.
 *
 * ── Receiving: sources, generations and the sink ──────────────────────────
 * Every opened input port (a device's output port opened by
 * MobMidi.open_input/3, or an input port of the app's own virtual device
 * opened by MobMidi.open_virtual/3) is a SOURCE: a small integer in
 * 1..MOB_MIDI_MAX_SOURCES-1, reused after the port closes. Each time a source
 * is taken, given back, or (Android, virtual device) another app starts or
 * stops sending into it, its GENERATION changes (a 31-bit counter: it
 * repeats only after 2^31 opens). Bytes are delivered only for the current
 * generation: once close returns, nothing of the old port's stream reaches
 * you, even a message its thread was already delivering (Android: on the
 * app's own virtual input ports the generation changes when the sending app
 * changes; a late message of the previous sender racing that change can
 * still land in the new one. iOS doesn't say who sends into a virtual
 * destination, so there the generation changes only on open and close). A
 * device that goes away has its ports closed, as if by close. A consumer that
 * parses (see mob_midi_parser.h) keeps one parser per source and resets it
 * when the generation it is called with differs from the last one it saw:
 * running status never leaks from one port into the next.
 *
 * The port's `deliver:` option picks who gets its bytes: :beam (default,
 * {:midi, :raw, ...} messages to the opener), :native (the sink only) or
 * :both. Ownership is per port: the BEAM path and the sink coexist, each port
 * routed to one or both.
 *
 * The sink is called on the port's MIDI receive thread (Android: one thread
 * per open port, so calls for different sources may run concurrently; iOS:
 * CoreMIDI's receive thread; calls for one source never overlap on either),
 * with the source's lock held. It must not block, allocate unboundedly, or
 * call mob_midi_set_sink; mob_midi_source_info and mob_midi_send are fine.
 * `bytes` is valid only during the call. A long message (SysEx) may arrive
 * split over several calls; treat it as a byte stream. `timestamp_ns` is the
 * sender's stamp as the platform delivered it: most senders stamp the MIDI
 * clock, some stamp 0 (iOS: an unstamped CoreMIDI packet is 0) or garbage;
 * see mob_midi_timestamp_or().
 *
 * ── Sending: output handles ───────────────────────────────────────────────
 * An open output (a device input port opened by MobMidi.open_output/3, or an
 * output port of the app's own virtual device after MobMidi.open_virtual/3)
 * has a handle: MobMidi.output_handle/2 returns it, and the {:midi, :opened,
 * ...} event of an output carries it as `handle`. Pass it to your NIF.
 * Handles carry the same counter: a closed port's handle answers
 * MOB_MIDI_ERR_NOT_OPEN, even after the same device/port is opened again
 * (until the counter wraps after 2^31 opens).
 *
 * mob_midi_send copies the bytes into the port's queue (no allocation),
 * wakes the port's dispatch thread and returns. That thread hands them to
 * the platform at `at_ns`, stamped with it (Android:
 * MidiReceiver.send(..., timestamp = at_ns); iOS: MIDISend to a destination
 * or MIDIReceived on the own virtual source, from a real-time thread, so
 * within tens of microseconds of at_ns); at once when `at_ns` is already
 * past (still stamped with `at_ns`), or when at_ns <= 0 (stamped with the
 * enqueue time). Messages leave in timestamp order, FIFO for equal stamps.
 * The queue holds MOB_MIDI_QUEUE_CAPACITY chunks of up to
 * MOB_MIDI_CHUNK_BYTES bytes per port; a stalled receiver (or, iOS, sends
 * scheduled far ahead) fills it and further sends answer
 * MOB_MIDI_ERR_QUEUE_FULL rather than block. Once a send has been refused,
 * every send to the port is refused until the queue has DRAINED: the
 * dispatch thread is back from the send it was stuck in, at most
 * MOB_MIDI_QUEUE_CAPACITY / 2 chunks are left and the largest message
 * refused meanwhile fits. The port's opener then gets {:midi, :drained,
 * %{device, port, handle, generation}}; native code sees sends succeed
 * again. mob_midi_discard drops what is queued (stale notes a stalled
 * receiver would get late) and starts a new queue generation, which the
 * drained event reports; bytes already handed to the platform can't be
 * recalled. The BEAM's MobMidi.send_raw/4 and MobMidi.discard/2 share the
 * same queue. Callable from any thread; it takes the port's mutex briefly,
 * so call it from your own sender thread, not an audio render callback.
 */
#ifndef MOB_MIDI_H
#define MOB_MIDI_H

#include <stddef.h>
#include <stdint.h>

#include "mob_midi_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any incompatible change to this header. */
#define MOB_MIDI_ABI_VERSION 1

/* Source ids are 1..MOB_MIDI_MAX_SOURCES-1: size per-source arrays by this. */
#define MOB_MIDI_MAX_SOURCES 64

/* Per-port send queue: chunks, and bytes per chunk (longer messages take
 * several chunks). One message may be at most CAPACITY x CHUNK_BYTES
 * (16 KiB) long and always leaves in one piece. */
#define MOB_MIDI_QUEUE_CAPACITY 256
#define MOB_MIDI_CHUNK_BYTES 64

enum {
    MOB_MIDI_OK = 0,
    MOB_MIDI_ERR_NOT_OPEN = -1,    /* no such open output (closed, never opened, stale handle) */
    MOB_MIDI_ERR_QUEUE_FULL = -2,  /* no room for the message, or refusing until drained */
    MOB_MIDI_ERR_NO_LISTENER = -3, /* own virtual output nobody has open (Android; iOS can't tell) */
    MOB_MIDI_ERR_BUSY = -4,        /* a sink is already registered */
    MOB_MIDI_ERR_INVALID = -5,     /* bad argument (NULL bytes, len 0, unknown source) */
    MOB_MIDI_ERR_UNSUPPORTED = -6, /* a platform without the native path (none today) */
    MOB_MIDI_ERR_TOO_LARGE = -7    /* longer than the whole queue; never fits */
};

/* An output handle (MobMidi.output_handle/2). Always > 0 when valid. */
typedef int64_t mob_midi_port;

typedef void (*mob_midi_sink_fn)(void *ctx, uint32_t source, uint32_t generation, const uint8_t *bytes,
                                 size_t len, int64_t timestamp_ns);

/* MOB_MIDI_ABI_VERSION of the linked implementation. */
int mob_midi_abi_version(void);

/* Register the app's one sink (fn non-NULL): MOB_MIDI_ERR_BUSY if another is
 * registered. Unregister with fn = NULL: returns once no call to the old sink
 * is running, so its ctx may be freed afterwards. Only ports opened with
 * deliver: :native | :both reach it. */
int mob_midi_set_sink(mob_midi_sink_fn fn, void *ctx);

/* The device id and port number behind a source's current generation:
 * MOB_MIDI_OK, or MOB_MIDI_ERR_INVALID if the source is closed. Any out
 * pointer may be NULL. */
int mob_midi_source_info(uint32_t source, uint32_t *generation, int32_t *device, int32_t *port);

/* Queue `len` bytes for output `port` at `at_ns` on the MIDI clock (<= 0:
 * now). MOB_MIDI_OK, or a negative MOB_MIDI_ERR_*. */
int mob_midi_send(mob_midi_port port, const uint8_t *bytes, size_t len, int64_t at_ns);

/* Drop everything queued for output `port`: the new queue generation (> 0),
 * or MOB_MIDI_ERR_NOT_OPEN. A port refusing sends keeps refusing until it
 * has drained (the drained event carries this generation, or a later one
 * when, Android, an own virtual output's listeners all left meanwhile). */
int mob_midi_discard(mob_midi_port port);

/* The MIDI clock in ns (see Clock above). */
int64_t mob_midi_now_ns(void);

/* A sender's stamp, or `now` when it is 0 or more than a second away from
 * `now` (a sender that doesn't stamp, or stamps on another clock). */
static inline int64_t mob_midi_timestamp_or(int64_t timestamp_ns, int64_t now_ns) {
    const int64_t second = 1000000000LL;
    return (timestamp_ns > now_ns - second && timestamp_ns < now_ns + second) ? timestamp_ns : now_ns;
}

#ifdef __cplusplus
}
#endif

#endif /* MOB_MIDI_H */
