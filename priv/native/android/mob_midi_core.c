/*
 * mob_midi_core.c: the Android byte paths of mob_midi, in C.
 *
 * Compiled into the app library as the plugin's android.jni_source, next to
 * the zig NIF (mob_midi_nif.zig) and any other static NIF of the app, so the
 * functions of priv/include/mob_midi.h resolve for all of them.
 *
 *   receive  MidiReceiver.onSend (MobMidiBridge, a MIDI thread)
 *              -> nativeReceive(source, generation, bytes, timestamp)
 *              -> the native sink and/or {:midi, :raw, ...} to the opener
 *   send     mob_midi_send / MobMidi.send_raw (midi_send NIF)
 *              -> the output's queue (ordered by target time)
 *              -> its dispatch thread (Kotlin, nativeNextSend)
 *              -> MidiReceiver.send(bytes, timestamp)
 *
 * Kotlin owns the Android objects (devices, ports, the virtual device's
 * service) and tells this file when a source or output opens and closes.
 * Everything here is fixed-size: no allocation per message on either path,
 * except the BEAM message itself.
 */
#include <jni.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "erl_nif.h"

#include "../../include/mob_midi.h"

#define ROUTE_BEAM 1u
#define ROUTE_NATIVE 2u

/* Bytes per call to the sink: a stack buffer, refilled for longer chunks. */
#define SINK_BUF 256

/* The dispatch thread's batch: messages due now with the same stamp go out
 * in one MidiReceiver.send. Kotlin's buffer has this size. */
#define DISPATCH_MAX 1024

#define OUT_SLOTS 32

/* ── Clock ─────────────────────────────────────────────────────────────── */

int64_t mob_midi_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int mob_midi_abi_version(void) { return MOB_MIDI_ABI_VERSION; }

/* Generations of sources and outputs come from one counter, so none repeats
 * until it wraps after 2^31 opens/renewals (a reused source or output slot
 * doesn't match a stale stamp). 31 bits, as output handles carry it above the
 * slot index. */
static atomic_uint g_generation = 0;

static uint32_t next_generation(void) {
    uint32_t g;
    do {
        g = (atomic_fetch_add(&g_generation, 1) + 1) & 0x7fffffffu;
    } while (g == 0);
    return g;
}

/* ── Sink ──────────────────────────────────────────────────────────────── */

static _Atomic(mob_midi_sink_fn) g_sink = NULL;
static _Atomic(void *) g_sink_ctx = NULL;
static atomic_int g_sink_calls = 0;
static pthread_mutex_t g_sink_lock = PTHREAD_MUTEX_INITIALIZER;

int mob_midi_set_sink(mob_midi_sink_fn fn, void *ctx) {
    pthread_mutex_lock(&g_sink_lock);
    if (fn) {
        if (atomic_load(&g_sink)) {
            pthread_mutex_unlock(&g_sink_lock);
            return MOB_MIDI_ERR_BUSY;
        }
        /* ctx first: a caller that sees fn sees its ctx. */
        atomic_store(&g_sink_ctx, ctx);
        atomic_store(&g_sink, fn);
    } else {
        atomic_store(&g_sink, NULL);
        /* A call that loaded the old fn has counted itself first. */
        while (atomic_load(&g_sink_calls) > 0) sched_yield();
        atomic_store(&g_sink_ctx, NULL);
    }
    pthread_mutex_unlock(&g_sink_lock);
    return MOB_MIDI_OK;
}

static void sink_call(uint32_t source, uint32_t generation, const uint8_t *bytes, size_t len, int64_t ts) {
    atomic_fetch_add(&g_sink_calls, 1);
    mob_midi_sink_fn fn = atomic_load(&g_sink);
    if (fn) fn(atomic_load(&g_sink_ctx), source, generation, bytes, len, ts);
    atomic_fetch_sub(&g_sink_calls, 1);
}

/* ── Sources ───────────────────────────────────────────────────────────── */

typedef struct {
    /* Held while delivering and while the generation changes, so a closed
     * port's thread can't deliver once close has returned. */
    pthread_mutex_t lock;
    bool used;
    uint32_t generation;
    uint32_t route;
    int64_t pid; /* the opener, as MobMidiBridge carries pids (a jlong) */
    int32_t device, port;
    /* Lock-free copy for mob_midi_source_info (callable from the sink, which
     * runs under `lock`): the generation while open (0 when closed) and
     * (device << 32) | port. */
    _Atomic uint32_t open_generation;
    _Atomic uint64_t where;
} source_t;

static source_t g_sources[MOB_MIDI_MAX_SOURCES];
static pthread_mutex_t g_sources_lock = PTHREAD_MUTEX_INITIALIZER; /* taking / giving back */
static int g_last_source = 0;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void init_once(void) {
    for (int i = 0; i < MOB_MIDI_MAX_SOURCES; i++) pthread_mutex_init(&g_sources[i].lock, NULL);
}

static void ensure_init(void) { pthread_once(&g_once, init_once); }

int mob_midi_source_info(uint32_t source, uint32_t *generation, int32_t *device, int32_t *port) {
    if (source == 0 || source >= MOB_MIDI_MAX_SOURCES) return MOB_MIDI_ERR_INVALID;
    ensure_init();
    source_t *s = &g_sources[source];
    for (;;) {
        uint32_t g = atomic_load(&s->open_generation);
        if (g == 0) return MOB_MIDI_ERR_INVALID;
        uint64_t w = atomic_load(&s->where);
        if (atomic_load(&s->open_generation) != g) continue; /* changed under us */
        if (generation) *generation = g;
        if (device) *device = (int32_t)(w >> 32);
        if (port) *port = (int32_t)(w & 0xffffffffu);
        return MOB_MIDI_OK;
    }
}

/* Under the source's lock. */
static void publish(source_t *s) {
    atomic_store(&s->open_generation, 0);
    atomic_store(&s->where, ((uint64_t)(uint32_t)s->device << 32) | (uint32_t)s->port);
    atomic_store(&s->open_generation, s->used ? s->generation : 0);
}

/* MobMidiBridge.nativeSourceOpen(device, port, pid, route): a free source
 * with a new generation, as (source << 32) | generation, or -1 when all are
 * taken. Round robin from the last one taken, so a source just given back is
 * the last to be reused. */
JNIEXPORT jlong JNICALL Java_io_mob_midi_MobMidiBridge_nativeSourceOpen(JNIEnv *j, jclass cls, jint device, jint port,
                                                                        jlong pid, jint route) {
    (void)j;
    (void)cls;
    ensure_init();
    pthread_mutex_lock(&g_sources_lock);
    int found = 0;
    for (int k = 1; k < MOB_MIDI_MAX_SOURCES; k++) {
        int i = (g_last_source + k - 1) % (MOB_MIDI_MAX_SOURCES - 1) + 1;
        if (!g_sources[i].used) {
            found = i;
            break;
        }
    }
    jlong result = -1;
    if (found) {
        source_t *s = &g_sources[found];
        pthread_mutex_lock(&s->lock);
        s->used = true;
        s->generation = next_generation();
        s->route = (uint32_t)route;
        s->pid = pid;
        s->device = device;
        s->port = port;
        publish(s);
        result = ((jlong)found << 32) | s->generation;
        pthread_mutex_unlock(&s->lock);
        g_last_source = found;
    }
    pthread_mutex_unlock(&g_sources_lock);
    return result;
}

/* MobMidiBridge.nativeSourceRenew(source): a new generation for an open
 * source (another app started or stopped sending into the virtual device's
 * port: its successor starts from a fresh parser). Returns it, or 0. */
JNIEXPORT jint JNICALL Java_io_mob_midi_MobMidiBridge_nativeSourceRenew(JNIEnv *j, jclass cls, jint source) {
    (void)j;
    (void)cls;
    if (source <= 0 || source >= MOB_MIDI_MAX_SOURCES) return 0;
    ensure_init();
    source_t *s = &g_sources[source];
    pthread_mutex_lock(&s->lock);
    uint32_t g = s->used ? (s->generation = next_generation()) : 0;
    publish(s);
    pthread_mutex_unlock(&s->lock);
    return (jint)g;
}

/* MobMidiBridge.nativeSourceClose(source): given back. Returns after any
 * delivery in progress on it has finished. */
JNIEXPORT void JNICALL Java_io_mob_midi_MobMidiBridge_nativeSourceClose(JNIEnv *j, jclass cls, jint source) {
    (void)j;
    (void)cls;
    if (source <= 0 || source >= MOB_MIDI_MAX_SOURCES) return;
    ensure_init();
    pthread_mutex_lock(&g_sources_lock);
    source_t *s = &g_sources[source];
    pthread_mutex_lock(&s->lock);
    s->used = false;
    s->generation = next_generation();
    s->route = 0;
    s->pid = 0;
    publish(s);
    pthread_mutex_unlock(&s->lock);
    pthread_mutex_unlock(&g_sources_lock);
}

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
    ERL_NIF_TERM a;
    if (enif_make_existing_atom(env, name, &a, ERL_NIF_LATIN1)) return a;
    return enif_make_atom(env, name);
}

/* {:midi, :raw, %{device, port, bytes, timestamp, received}}: the bytes go
 * from the Java array straight into the message binary. */
static void deliver_beam(JNIEnv *j, const source_t *s, jbyteArray msg, jint offset, jint count, jlong timestamp,
                         int64_t received) {
    ErlNifEnv *env = enif_alloc_env();
    if (!env) return;
    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)count, &bin)) {
        enif_free_env(env);
        return;
    }
    (*j)->GetByteArrayRegion(j, msg, offset, count, (jbyte *)bin.data);
    if ((*j)->ExceptionCheck(j)) {
        (*j)->ExceptionClear(j);
        enif_release_binary(&bin);
        enif_free_env(env);
        return;
    }
    ERL_NIF_TERM keys[5] = {atom(env, "device"), atom(env, "port"), atom(env, "bytes"), atom(env, "timestamp"),
                            atom(env, "received")};
    ERL_NIF_TERM vals[5] = {enif_make_int(env, s->device), enif_make_int(env, s->port), enif_make_binary(env, &bin),
                            enif_make_int64(env, timestamp), enif_make_int64(env, received)};
    ERL_NIF_TERM map;
    if (enif_make_map_from_arrays(env, keys, vals, 5, &map)) {
        ErlNifPid pid;
        pid.pid = (ERL_NIF_TERM)s->pid;
        enif_send(NULL, &pid, env, enif_make_tuple3(env, atom(env, "midi"), atom(env, "raw"), map));
    }
    enif_free_env(env);
}

/* MobMidiBridge.nativeReceive(source, generation, msg, offset, count,
 * timestamp): one MidiReceiver.onSend. Dropped unless `generation` is the
 * source's current one. */
JNIEXPORT void JNICALL Java_io_mob_midi_MobMidiBridge_nativeReceive(JNIEnv *j, jclass cls, jint source,
                                                                    jint generation, jbyteArray msg, jint offset,
                                                                    jint count, jlong timestamp) {
    (void)cls;
    if (source <= 0 || source >= MOB_MIDI_MAX_SOURCES || count <= 0 || !msg) return;
    int64_t received = mob_midi_now_ns();
    source_t *s = &g_sources[source];
    pthread_mutex_lock(&s->lock);
    if (s->used && s->generation == (uint32_t)generation) {
        if (s->route & ROUTE_NATIVE) {
            uint8_t buf[SINK_BUF];
            for (jint done = 0; done < count;) {
                jint n = count - done > SINK_BUF ? SINK_BUF : count - done;
                (*j)->GetByteArrayRegion(j, msg, offset + done, n, (jbyte *)buf);
                if ((*j)->ExceptionCheck(j)) {
                    (*j)->ExceptionClear(j);
                    break;
                }
                sink_call((uint32_t)source, (uint32_t)generation, buf, (size_t)n, timestamp);
                done += n;
            }
        }
        if (s->route & ROUTE_BEAM) deliver_beam(j, s, msg, offset, count, timestamp, received);
    }
    pthread_mutex_unlock(&s->lock);
}

/* ── Outputs ───────────────────────────────────────────────────────────── */

typedef struct {
    int64_t due;       /* when to hand it over */
    int64_t timestamp; /* the stamp it carries */
    uint64_t seq;      /* FIFO among equal `due` */
    uint8_t len;
    uint8_t bytes[MOB_MIDI_CHUNK_BYTES];
} out_msg;

enum { OUT_FREE = 0, OUT_OPENING, OUT_OPEN };

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cond; /* CLOCK_MONOTONIC: new message, or closed */
    int state;
    uint32_t generation;
    int32_t device, port;
    bool virtual_port; /* the app's own device: listeners gate sends */
    int listeners;
    uint64_t seq;
    int count;
    out_msg heap[MOB_MIDI_QUEUE_CAPACITY]; /* min-heap by (due, seq) */
} out_slot;

/* Allocated once, on the first output: a static table would put ~700 KB in
 * every app's .bss whether or not it sends MIDI. */
static _Atomic(out_slot *) g_outputs = NULL;
static pthread_mutex_t g_outputs_lock = PTHREAD_MUTEX_INITIALIZER; /* opening / closing slots */

static bool ensure_outputs(void) {
    pthread_mutex_lock(&g_outputs_lock);
    if (!atomic_load(&g_outputs)) {
        out_slot *slots = calloc(OUT_SLOTS, sizeof(out_slot));
        if (slots) {
            pthread_condattr_t attr;
            pthread_condattr_init(&attr);
            pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
            for (int i = 0; i < OUT_SLOTS; i++) {
                pthread_mutex_init(&slots[i].lock, NULL);
                pthread_cond_init(&slots[i].cond, &attr);
            }
            pthread_condattr_destroy(&attr);
            atomic_store(&g_outputs, slots);
        }
    }
    pthread_mutex_unlock(&g_outputs_lock);
    return atomic_load(&g_outputs) != NULL;
}

static inline mob_midi_port make_handle(int index, uint32_t generation) {
    return ((int64_t)generation << 32) | (int64_t)(index + 1);
}

/* The slot of a handle, locked, if the handle is its current generation. */
static out_slot *lock_handle(mob_midi_port handle) {
    out_slot *slots = atomic_load(&g_outputs);
    if (handle <= 0 || !slots) return NULL;
    int index = (int)(handle & 0xffffffff) - 1;
    uint32_t generation = (uint32_t)(handle >> 32);
    if (index < 0 || index >= OUT_SLOTS) return NULL;
    out_slot *o = &slots[index];
    pthread_mutex_lock(&o->lock);
    if (o->state == OUT_FREE || o->generation != generation) {
        pthread_mutex_unlock(&o->lock);
        return NULL;
    }
    return o;
}

static inline bool before(const out_msg *a, const out_msg *b) {
    return a->due < b->due || (a->due == b->due && a->seq < b->seq);
}

static void heap_push(out_slot *o, const out_msg *m) {
    int i = o->count++;
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (!before(m, &o->heap[parent])) break;
        o->heap[i] = o->heap[parent];
        i = parent;
    }
    o->heap[i] = *m;
}

static void heap_pop(out_slot *o) {
    out_msg last = o->heap[--o->count];
    int i = 0;
    for (;;) {
        int child = 2 * i + 1;
        if (child >= o->count) break;
        if (child + 1 < o->count && before(&o->heap[child + 1], &o->heap[child])) child++;
        if (!before(&o->heap[child], &last)) break;
        o->heap[i] = o->heap[child];
        i = child;
    }
    if (o->count > 0) o->heap[i] = last;
}

/* Under the slot's lock. */
static int enqueue_locked(out_slot *o, const uint8_t *bytes, size_t len, int64_t at_ns) {
    if (o->virtual_port && o->listeners <= 0) return MOB_MIDI_ERR_NO_LISTENER;
    size_t chunks = (len + MOB_MIDI_CHUNK_BYTES - 1) / MOB_MIDI_CHUNK_BYTES;
    if ((size_t)o->count + chunks > MOB_MIDI_QUEUE_CAPACITY) return MOB_MIDI_ERR_QUEUE_FULL;
    int64_t now = mob_midi_now_ns();
    int64_t stamp = at_ns > 0 ? at_ns : now;
    out_msg m;
    m.due = stamp;
    m.timestamp = stamp;
    for (size_t done = 0; done < len;) {
        size_t n = len - done > MOB_MIDI_CHUNK_BYTES ? MOB_MIDI_CHUNK_BYTES : len - done;
        m.seq = o->seq++;
        m.len = (uint8_t)n;
        memcpy(m.bytes, bytes + done, n);
        heap_push(o, &m);
        done += n;
    }
    pthread_cond_signal(&o->cond);
    return MOB_MIDI_OK;
}

int mob_midi_send(mob_midi_port port, const uint8_t *bytes, size_t len, int64_t at_ns) {
    if (!bytes || len == 0) return MOB_MIDI_ERR_INVALID;
    out_slot *o = lock_handle(port);
    if (!o) return MOB_MIDI_ERR_NOT_OPEN;
    int rc = o->state == OUT_OPEN ? enqueue_locked(o, bytes, len, at_ns) : MOB_MIDI_ERR_NOT_OPEN;
    pthread_mutex_unlock(&o->lock);
    return rc;
}

/* The open output of (device, port), or 0. For the NIF. */
mob_midi_port mob_midi__output_handle(int32_t device, int32_t port) {
    out_slot *slots = atomic_load(&g_outputs);
    if (!slots) return 0;
    for (int i = 0; i < OUT_SLOTS; i++) {
        out_slot *o = &slots[i];
        pthread_mutex_lock(&o->lock);
        bool match = o->state == OUT_OPEN && o->device == device && o->port == port;
        mob_midi_port h = match ? make_handle(i, o->generation) : 0;
        pthread_mutex_unlock(&o->lock);
        if (match) return h;
    }
    return 0;
}

/* midi_send NIF: MOB_MIDI_ERR_NOT_OPEN sends it to Kotlin, which queues it
 * while the port is still opening. */
int mob_midi__send_device(int32_t device, int32_t port, const uint8_t *bytes, size_t len, int64_t at_ns) {
    mob_midi_port h = mob_midi__output_handle(device, port);
    return h ? mob_midi_send(h, bytes, len, at_ns) : MOB_MIDI_ERR_NOT_OPEN;
}

/* MobMidiBridge.nativeOutputOpen(device, port, virtual): a slot for a port
 * Kotlin is opening, as its handle (0: all taken). Sends to it answer
 * NOT_OPEN until nativeOutputReady; Kotlin's own queue is flushed into it
 * with nativeEnqueue first, keeping the order. */
JNIEXPORT jlong JNICALL Java_io_mob_midi_MobMidiBridge_nativeOutputOpen(JNIEnv *j, jclass cls, jint device, jint port,
                                                                        jboolean virtual_port) {
    (void)j;
    (void)cls;
    if (!ensure_outputs()) return 0;
    out_slot *slots = atomic_load(&g_outputs);
    pthread_mutex_lock(&g_outputs_lock);
    jlong handle = 0;
    for (int i = 0; i < OUT_SLOTS && !handle; i++) {
        out_slot *o = &slots[i];
        pthread_mutex_lock(&o->lock);
        if (o->state == OUT_FREE) {
            o->state = OUT_OPENING;
            o->generation = next_generation();
            o->device = device;
            o->port = port;
            o->virtual_port = virtual_port;
            o->listeners = 0;
            o->count = 0;
            handle = make_handle(i, o->generation);
        }
        pthread_mutex_unlock(&o->lock);
    }
    pthread_mutex_unlock(&g_outputs_lock);
    return handle;
}

JNIEXPORT void JNICALL Java_io_mob_midi_MobMidiBridge_nativeOutputReady(JNIEnv *j, jclass cls, jlong handle) {
    (void)j;
    (void)cls;
    out_slot *o = lock_handle(handle);
    if (!o) return;
    o->state = OUT_OPEN;
    pthread_mutex_unlock(&o->lock);
}

/* Closed: queued messages are dropped and the dispatch thread ends (once a
 * MidiReceiver.send it is in returns). */
JNIEXPORT void JNICALL Java_io_mob_midi_MobMidiBridge_nativeOutputClose(JNIEnv *j, jclass cls, jlong handle) {
    (void)j;
    (void)cls;
    pthread_mutex_lock(&g_outputs_lock);
    out_slot *o = lock_handle(handle);
    if (o) {
        o->state = OUT_FREE;
        o->count = 0;
        o->generation = 0;
        pthread_cond_broadcast(&o->cond);
        pthread_mutex_unlock(&o->lock);
    }
    pthread_mutex_unlock(&g_outputs_lock);
}

/* Apps listening to an own virtual output port. */
JNIEXPORT void JNICALL Java_io_mob_midi_MobMidiBridge_nativeOutputListeners(JNIEnv *j, jclass cls, jlong handle,
                                                                            jint listeners) {
    (void)j;
    (void)cls;
    out_slot *o = lock_handle(handle);
    if (!o) return;
    o->listeners = listeners;
    /* Nobody to hear what is queued. */
    if (listeners <= 0) o->count = 0;
    pthread_mutex_unlock(&o->lock);
}

/* Kotlin's queue (sends made while the port was opening), in order, whatever
 * the slot's state. Returns a MOB_MIDI_* code. */
JNIEXPORT jint JNICALL Java_io_mob_midi_MobMidiBridge_nativeEnqueue(JNIEnv *j, jclass cls, jlong handle,
                                                                    jbyteArray bytes, jlong at_ns) {
    (void)cls;
    jsize len = bytes ? (*j)->GetArrayLength(j, bytes) : 0;
    if (len <= 0) return MOB_MIDI_ERR_INVALID;
    /* Not a critical section: the slot's mutex may be contended. This is the
     * rare open-time flush, so a copy is fine. */
    jbyte *data = (*j)->GetByteArrayElements(j, bytes, NULL);
    if (!data) return MOB_MIDI_ERR_INVALID;
    int rc = MOB_MIDI_ERR_NOT_OPEN;
    out_slot *o = lock_handle(handle);
    if (o) {
        rc = enqueue_locked(o, (const uint8_t *)data, (size_t)len, at_ns);
        pthread_mutex_unlock(&o->lock);
    }
    (*j)->ReleaseByteArrayElements(j, bytes, data, JNI_ABORT);
    return rc;
}

/* MobMidiBridge.nativeNextSend(handle, buf, meta): the dispatch thread's
 * wait. Blocks until the earliest message is due, copies it (and those due
 * with the same stamp, up to DISPATCH_MAX bytes) into `buf`, its stamp into
 * meta[0], and returns the byte count; -1 once the output is closed. */
JNIEXPORT jint JNICALL Java_io_mob_midi_MobMidiBridge_nativeNextSend(JNIEnv *j, jclass cls, jlong handle,
                                                                     jbyteArray buf, jlongArray meta) {
    (void)cls;
    uint8_t out[DISPATCH_MAX];
    int n = 0;
    int64_t stamp = 0;
    out_slot *o = lock_handle(handle);
    if (!o) return -1;
    for (;;) {
        if (o->state == OUT_FREE || o->generation != (uint32_t)(handle >> 32)) {
            pthread_mutex_unlock(&o->lock);
            return -1;
        }
        if (o->count == 0) {
            pthread_cond_wait(&o->cond, &o->lock);
            continue;
        }
        int64_t due = o->heap[0].due;
        if (due > mob_midi_now_ns()) {
            struct timespec until = {.tv_sec = due / 1000000000LL, .tv_nsec = due % 1000000000LL};
            pthread_cond_timedwait(&o->cond, &o->lock, &until);
            continue;
        }
        stamp = o->heap[0].timestamp;
        while (o->count > 0 && o->heap[0].timestamp == stamp && n + o->heap[0].len <= DISPATCH_MAX) {
            memcpy(out + n, o->heap[0].bytes, o->heap[0].len);
            n += o->heap[0].len;
            heap_pop(o);
        }
        break;
    }
    pthread_mutex_unlock(&o->lock);
    (*j)->SetByteArrayRegion(j, buf, 0, n, (const jbyte *)out);
    (*j)->SetLongArrayRegion(j, meta, 0, 1, (const jlong *)&stamp);
    return n;
}
