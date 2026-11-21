/* mob_midi_nif — iOS MIDI plugin NIF (Objective-C, CoreMIDI).
 *
 * The midi_* NIFs over CoreMIDI, and the native C ABI of
 * priv/include/mob_midi.h for another static NIF of the app, with the same
 * semantics as Android's priv/native/android/mob_midi_core.c:
 *
 *   receive  CoreMIDI's receive thread (the read proc of the input port, or
 *            of an own virtual destination)
 *              -> deliver(source, generation, packets)
 *              -> the native sink and/or {:midi, :raw, ...} to the opener
 *   send     mob_midi_send / MobMidi.send_raw (midi_send NIF)
 *              -> the output's queue (../android/mob_midi_queue.h, ordered
 *                 by target time)
 *              -> its dispatch thread (real-time priority), at that time
 *              -> MIDISend (a destination) or MIDIReceived (an own virtual
 *                 source), stamped with it
 *
 * Device ids are CoreMIDI endpoint unique IDs (kMIDIPropertyUniqueID, an
 * SInt32), stable across the BEAM boundary. Every CoreMIDI endpoint is a
 * single port, so `port` is always 0. Messages:
 *
 *   {:midi, :devices, [%{id, name, direction, manufacturer, type,
 *                        input_ports, output_ports, own}]}
 *   {:midi, :raw, %{device: id, port: 0, bytes: <<...>>, timestamp: ns,
 *                   received: ns}}
 *   {:midi, :device_added | :device_removed, nil}
 *   {:midi, :opened, %{device: id, port: 0, direction: :input, source: s}}
 *   {:midi, :opened, %{device: id, port: 0, direction: :output, handle: h}}
 *   {:midi, :opened, %{device: id, direction: :virtual, name: name}}
 *   {:midi, :drained, %{device: id, port: 0, handle: h, generation: g}}
 *   {:midi, :error, %{device: id, op: atom, reason: atom, dropped: 0}}
 *
 * Timestamps are nanoseconds of mach_absolute_time (MIDITimeStamp's clock,
 * mob_midi_clock.h), the clock of midi_now_ns/0 and mob_midi_now_ns(). An
 * incoming packet's `timestamp` is the sender's stamp (its arrival when the
 * sender left it 0; the native sink gets the 0).
 *
 * Opens and closes are synchronous: :opened / :error is sent before the NIF
 * returns. midi_send returns :ok or {:error, :not_open | :queue_full |
 * :too_large | :send_failed}. A virtual device (open_virtual) is a
 * MIDISourceCreate source (what midi_send to its id publishes; its id is the
 * device id) plus a MIDIDestinationCreate destination of the same name (what
 * other apps send into it arrives as :raw with the device id). CoreMIDI
 * doesn't tell a virtual source who listens, so its sends never answer
 * :no_listener here. Its endpoints stay until the app exits; close/2 ends
 * the subscription.
 *
 * Hot-plug: CoreMIDI calls a client's notify proc on the run loop of the
 * thread that first called MIDIClientCreate in the process, so the client is
 * made on a thread of its own ("mob_midi") that runs a run loop. A removed
 * device's open ports are closed there, as on Android.
 *
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc, platform: :ios); only this file is compiled, so the headers
 * it includes carry the rest. Hardware endpoints need a device; virtual
 * endpoints work on the simulator. test/mob_midi_ios_host_test.exs builds it
 * for macOS and runs it against real CoreMIDI.
 */
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <erl_nif.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "../../include/mob_midi.h"
#include "../android/mob_midi_queue.h"
#include "mob_midi_clock.h"

#define ROUTE_BEAM 1u
#define ROUTE_NATIVE 2u

/* The dispatch thread's batch: whole messages due now with the same stamp go
 * out in one packet. One message can be the whole queue. */
#define DISPATCH_MAX MOB_MIDI_QUEUE_MAX_BYTES

#define OUT_SLOTS 32
#define MAX_VIRTUALS 16

/* Opens, closes, the virtual devices, the hot-plug subscriber and the
 * removal sweep. Taken before any source or output lock. */
static pthread_mutex_t g_ops = PTHREAD_MUTEX_INITIALIZER;

// ── Clock ─────────────────────────────────────────────────────────────────

static mach_timebase_info_data_t g_timebase;
static pthread_once_t g_timebase_once = PTHREAD_ONCE_INIT;

static void timebase_init(void) { mach_timebase_info(&g_timebase); }

static int64_t host_to_ns(uint64_t host) {
  pthread_once(&g_timebase_once, timebase_init);
  return mob_midi_ticks_to_ns(host, g_timebase.numer, g_timebase.denom);
}

static uint64_t ns_to_host(int64_t ns) {
  pthread_once(&g_timebase_once, timebase_init);
  return mob_midi_ns_to_ticks(ns, g_timebase.numer, g_timebase.denom);
}

int64_t mob_midi_now_ns(void) { return host_to_ns(mach_absolute_time()); }

int mob_midi_abi_version(void) { return MOB_MIDI_ABI_VERSION; }

/* Generations of sources and outputs come from one counter, so none repeats
 * until it wraps after 2^31 opens (a reused source or output slot doesn't
 * match a stale stamp). 31 bits, as output handles carry it above the slot
 * index. */
static atomic_uint g_generation = 0;

static uint32_t next_generation(void) {
  uint32_t g;
  do {
    g = (atomic_fetch_add(&g_generation, 1) + 1) & 0x7fffffffu;
  } while (g == 0);
  return g;
}

// ── Sink ──────────────────────────────────────────────────────────────────

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
    while (atomic_load(&g_sink_calls) > 0)
      sched_yield();
    atomic_store(&g_sink_ctx, NULL);
  }
  pthread_mutex_unlock(&g_sink_lock);
  return MOB_MIDI_OK;
}

static void sink_call(uint32_t source, uint32_t generation,
                      const uint8_t *bytes, size_t len, int64_t ts) {
  atomic_fetch_add(&g_sink_calls, 1);
  mob_midi_sink_fn fn = atomic_load(&g_sink);
  if (fn)
    fn(atomic_load(&g_sink_ctx), source, generation, bytes, len, ts);
  atomic_fetch_sub(&g_sink_calls, 1);
}

// ── Terms ─────────────────────────────────────────────────────────────────

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  ERL_NIF_TERM a;
  if (enif_make_existing_atom(env, name, &a, ERL_NIF_LATIN1))
    return a;
  return enif_make_atom(env, name);
}

static ERL_NIF_TERM midi_env3(ErlNifEnv *e, const char *tag,
                              ERL_NIF_TERM payload) {
  return enif_make_tuple3(e, atom(e, "midi"), atom(e, tag), payload);
}

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

/* {:midi, tag, map} from `n` keys and values to `pid`. `caller` is the NIF's
 * env, or NULL on a thread ERTS doesn't manage. */
static void send_map(ErlNifEnv *caller, const ErlNifPid *pid, ErlNifEnv *e,
                     const char *tag, ERL_NIF_TERM *keys, ERL_NIF_TERM *vals,
                     unsigned n) {
  ERL_NIF_TERM map;
  if (enif_make_map_from_arrays(e, keys, vals, n, &map))
    enif_send(caller, (ErlNifPid *)pid, e, midi_env3(e, tag, map));
}

static void send_error(ErlNifEnv *caller, const ErlNifPid *pid, SInt32 device,
                       const char *op, const char *reason) {
  ErlNifEnv *e = enif_alloc_env();
  if (!e)
    return;
  ERL_NIF_TERM keys[4] = {atom(e, "device"), atom(e, "op"), atom(e, "reason"),
                          atom(e, "dropped")};
  ERL_NIF_TERM vals[4] = {enif_make_int(e, device), atom(e, op),
                          atom(e, reason), enif_make_int(e, 0)};
  send_map(caller, pid, e, "error", keys, vals, 4);
  enif_free_env(e);
}

/* {:midi, :opened, %{device, port: 0, direction}} plus the input's `source`
 * or the output's `handle`. */
static void send_opened(ErlNifEnv *caller, const ErlNifPid *pid,
                        SInt32 device, const char *direction, uint32_t source,
                        mob_midi_port handle) {
  ErlNifEnv *e = enif_alloc_env();
  if (!e)
    return;
  ERL_NIF_TERM keys[4] = {atom(e, "device"), atom(e, "port"),
                          atom(e, "direction"), 0};
  ERL_NIF_TERM vals[4] = {enif_make_int(e, device), enif_make_int(e, 0),
                          atom(e, direction), 0};
  unsigned n = 3;
  if (source > 0) {
    keys[n] = atom(e, "source");
    vals[n++] = enif_make_uint(e, source);
  } else if (handle > 0) {
    keys[n] = atom(e, "handle");
    vals[n++] = enif_make_int64(e, handle);
  }
  send_map(caller, pid, e, "opened", keys, vals, n);
  enif_free_env(e);
}

// ── Sources ───────────────────────────────────────────────────────────────

enum { SRC_INPUT = 1, SRC_VIRTUAL = 2 };

typedef struct {
  /* Held while delivering and while the generation changes, so a closed
   * port's packets can't be delivered once close has returned. */
  pthread_mutex_t lock;
  bool used;
  int kind;
  uint32_t generation;
  uint32_t route;
  ErlNifPid pid; /* the opener */
  int32_t device, port;
  MIDIEndpointRef endpoint; /* SRC_INPUT: the source connected to the input port */
  /* Lock-free copy for mob_midi_source_info (callable from the sink, which
   * runs under `lock`): the generation while open (0 when closed) and
   * (device << 32) | port. */
  _Atomic uint32_t open_generation;
  _Atomic uint64_t where;
} source_t;

static source_t g_sources[MOB_MIDI_MAX_SOURCES];
static pthread_mutex_t g_sources_lock =
    PTHREAD_MUTEX_INITIALIZER; /* taking / giving back */
static int g_last_source = 0;
static pthread_once_t g_sources_once = PTHREAD_ONCE_INIT;

static void sources_init(void) {
  for (int i = 0; i < MOB_MIDI_MAX_SOURCES; i++)
    pthread_mutex_init(&g_sources[i].lock, NULL);
}

int mob_midi_source_info(uint32_t source, uint32_t *generation,
                         int32_t *device, int32_t *port) {
  if (source == 0 || source >= MOB_MIDI_MAX_SOURCES)
    return MOB_MIDI_ERR_INVALID;
  source_t *s = &g_sources[source];
  for (;;) {
    uint32_t g = atomic_load(&s->open_generation);
    if (g == 0)
      return MOB_MIDI_ERR_INVALID;
    uint64_t w = atomic_load(&s->where);
    if (atomic_load(&s->open_generation) != g)
      continue; /* changed under us */
    if (generation)
      *generation = g;
    if (device)
      *device = (int32_t)(w >> 32);
    if (port)
      *port = (int32_t)(w & 0xffffffffu);
    return MOB_MIDI_OK;
  }
}

/* Under the source's lock. */
static void publish(source_t *s) {
  atomic_store(&s->open_generation, 0);
  atomic_store(&s->where,
               ((uint64_t)(uint32_t)s->device << 32) | (uint32_t)s->port);
  atomic_store(&s->open_generation, s->used ? s->generation : 0);
}

/* A free source with a new generation, as (source << 32) | generation, or -1
 * when all are taken. Round robin from the last one taken, so a source just
 * given back is the last to be reused. */
static int64_t source_open(int kind, int32_t device, int32_t port,
                           const ErlNifPid *pid, uint32_t route,
                           MIDIEndpointRef endpoint) {
  pthread_once(&g_sources_once, sources_init);
  pthread_mutex_lock(&g_sources_lock);
  int found = 0;
  for (int k = 1; k < MOB_MIDI_MAX_SOURCES; k++) {
    int i = (g_last_source + k - 1) % (MOB_MIDI_MAX_SOURCES - 1) + 1;
    if (!g_sources[i].used) {
      found = i;
      break;
    }
  }
  int64_t result = -1;
  if (found) {
    source_t *s = &g_sources[found];
    pthread_mutex_lock(&s->lock);
    s->used = true;
    s->kind = kind;
    s->generation = next_generation();
    s->route = route;
    s->pid = *pid;
    s->device = device;
    s->port = port;
    s->endpoint = endpoint;
    publish(s);
    result = ((int64_t)found << 32) | s->generation;
    pthread_mutex_unlock(&s->lock);
    g_last_source = found;
  }
  pthread_mutex_unlock(&g_sources_lock);
  return result;
}

/* Given back. Returns after any delivery in progress on it has finished. */
static void source_close(int source) {
  if (source <= 0 || source >= MOB_MIDI_MAX_SOURCES)
    return;
  pthread_once(&g_sources_once, sources_init);
  pthread_mutex_lock(&g_sources_lock);
  source_t *s = &g_sources[source];
  pthread_mutex_lock(&s->lock);
  s->used = false;
  s->generation = next_generation();
  s->route = 0;
  s->endpoint = 0;
  publish(s);
  pthread_mutex_unlock(&s->lock);
  pthread_mutex_unlock(&g_sources_lock);
}

/* Who gets an open source's bytes from now on (0: nobody, while it opens). */
static void source_route(int64_t packed, uint32_t route) {
  source_t *s = &g_sources[packed >> 32];
  pthread_mutex_lock(&s->lock);
  if (s->used && s->generation == (uint32_t)packed)
    s->route = route;
  pthread_mutex_unlock(&s->lock);
}

/* {:midi, :raw, %{device, port, bytes, timestamp, received}}; from
 * CoreMIDI's thread, under the source's lock. */
static void deliver_beam(const source_t *s, const uint8_t *bytes, size_t len,
                         int64_t timestamp, int64_t received) {
  ErlNifEnv *e = enif_alloc_env();
  if (!e)
    return;
  ERL_NIF_TERM bin;
  unsigned char *buf = enif_make_new_binary(e, len, &bin);
  if (!buf) {
    enif_free_env(e);
    return;
  }
  memcpy(buf, bytes, len);
  ERL_NIF_TERM keys[5] = {atom(e, "device"), atom(e, "port"), atom(e, "bytes"),
                          atom(e, "timestamp"), atom(e, "received")};
  ERL_NIF_TERM vals[5] = {enif_make_int(e, s->device), enif_make_int(e, s->port),
                          bin, enif_make_int64(e, timestamp),
                          enif_make_int64(e, received)};
  send_map(NULL, &s->pid, e, "raw", keys, vals, 5);
  enif_free_env(e);
}

/* One read proc call: dropped unless `generation` is the source's current
 * one. The sink gets each packet's bytes (valid for the call; a long SysEx
 * comes split over several packets) and the sender's stamp, 0 if it left it
 * unstamped; the BEAM gets the arrival time for an unstamped one. */
static void deliver(uint32_t source, uint32_t generation,
                    const MIDIPacketList *packets) {
  if (source == 0 || source >= MOB_MIDI_MAX_SOURCES || !packets)
    return;
  int64_t received = mob_midi_now_ns();
  source_t *s = &g_sources[source];
  pthread_mutex_lock(&s->lock);
  if (s->used && s->generation == generation) {
    const MIDIPacket *p = &packets->packet[0];
    for (UInt32 i = 0; i < packets->numPackets; i++) {
      if (p->length > 0) {
        int64_t stamp = p->timeStamp ? host_to_ns(p->timeStamp) : 0;
        if (s->route & ROUTE_NATIVE)
          sink_call(source, generation, p->data, p->length, stamp);
        if (s->route & ROUTE_BEAM)
          deliver_beam(s, p->data, p->length, stamp ? stamp : received,
                       received);
      }
      p = MIDIPacketNext(p);
    }
  }
  pthread_mutex_unlock(&s->lock);
}

// An open input's packets; srcConnRefCon is its (source << 32) | generation.
static void input_read_proc(const MIDIPacketList *packets, void *readProcRefCon,
                            void *srcConnRefCon) {
  (void)readProcRefCon;
  uint64_t packed = (uint64_t)(uintptr_t)srcConnRefCon;
  deliver((uint32_t)(packed >> 32), (uint32_t)packed, packets);
}

// ── Outputs ───────────────────────────────────────────────────────────────

typedef struct {
  pthread_mutex_t lock;
  pthread_cond_t cond; /* new message, discard, or closed */
  bool open;
  uint32_t generation; /* the handle's, not the queue's */
  int32_t device, port;
  bool virtual_port;        /* an own virtual source: MIDIReceived */
  MIDIEndpointRef endpoint; /* the destination, or the own virtual source */
  ErlNifPid pid;            /* the last opener: gets {:midi, :drained, ...} */
  mob_midi_queue q;
} out_slot;

/* Allocated once, on the first output: a static table would put ~700 KB in
 * every app's data whether or not it sends MIDI. */
static _Atomic(out_slot *) g_outputs = NULL;
static pthread_mutex_t g_outputs_lock =
    PTHREAD_MUTEX_INITIALIZER; /* opening / closing slots */

static bool ensure_outputs(void) {
  pthread_mutex_lock(&g_outputs_lock);
  if (!atomic_load(&g_outputs)) {
    out_slot *slots = calloc(OUT_SLOTS, sizeof(out_slot));
    if (slots) {
      for (int i = 0; i < OUT_SLOTS; i++) {
        pthread_mutex_init(&slots[i].lock, NULL);
        pthread_cond_init(&slots[i].cond, NULL);
      }
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
  if (handle <= 0 || !slots)
    return NULL;
  int index = (int)(handle & 0xffffffff) - 1;
  uint32_t generation = (uint32_t)(handle >> 32);
  if (index < 0 || index >= OUT_SLOTS)
    return NULL;
  out_slot *o = &slots[index];
  pthread_mutex_lock(&o->lock);
  if (!o->open || o->generation != generation) {
    pthread_mutex_unlock(&o->lock);
    return NULL;
  }
  return o;
}

/* No allocation, no CoreMIDI call: the bytes are copied into the queue and
 * the dispatch thread woken. A refusal wakes it too: one that is idle
 * (empty queue, or waiting on a later message) must look again, as the
 * queue may already be drained. */
int mob_midi_send(mob_midi_port port, const uint8_t *bytes, size_t len,
                  int64_t at_ns) {
  if (!bytes || len == 0)
    return MOB_MIDI_ERR_INVALID;
  out_slot *o = lock_handle(port);
  if (!o)
    return MOB_MIDI_ERR_NOT_OPEN;
  int rc = mob_midi_queue_push(&o->q, bytes, len,
                               at_ns > 0 ? at_ns : mob_midi_now_ns());
  if (rc == MOB_MIDI_OK || rc == MOB_MIDI_ERR_QUEUE_FULL)
    pthread_cond_signal(&o->cond);
  pthread_mutex_unlock(&o->lock);
  return rc;
}

int mob_midi_discard(mob_midi_port port) {
  out_slot *o = lock_handle(port);
  if (!o)
    return MOB_MIDI_ERR_NOT_OPEN;
  int rc = (int)mob_midi_queue_discard(&o->q);
  /* A dispatcher waiting on the old head re-checks: it may have drained. */
  pthread_cond_signal(&o->cond);
  pthread_mutex_unlock(&o->lock);
  return rc;
}

/* The open output of (device, port), or 0. */
static mob_midi_port output_handle(int32_t device, int32_t port) {
  out_slot *slots = atomic_load(&g_outputs);
  if (!slots)
    return 0;
  for (int i = 0; i < OUT_SLOTS; i++) {
    out_slot *o = &slots[i];
    pthread_mutex_lock(&o->lock);
    bool match = o->open && o->device == device && o->port == port;
    mob_midi_port h = match ? make_handle(i, o->generation) : 0;
    pthread_mutex_unlock(&o->lock);
    if (match)
      return h;
  }
  return 0;
}

/* {:midi, :drained, %{device, port, handle, generation}} to the opener.
 * From the dispatch thread (not an ERTS thread), under the slot's lock. */
static void deliver_drained(const out_slot *o, mob_midi_port handle) {
  ErlNifEnv *e = enif_alloc_env();
  if (!e)
    return;
  ERL_NIF_TERM keys[4] = {atom(e, "device"), atom(e, "port"), atom(e, "handle"),
                          atom(e, "generation")};
  ERL_NIF_TERM vals[4] = {enif_make_int(e, o->device), enif_make_int(e, o->port),
                          enif_make_int64(e, handle),
                          enif_make_uint(e, o->q.generation)};
  send_map(NULL, &o->pid, e, "drained", keys, vals, 4);
  enif_free_env(e);
}

/* The dispatch thread's wait. Blocks until the earliest message is due,
 * copies it (and the whole messages due with the same stamp, up to
 * DISPATCH_MAX bytes) into `out`, its stamp into *stamp, the endpoint into
 * *endpoint / *virtual_port, and returns the byte count; -1 once the output
 * is closed. Being back here means the last send returned, so this is also
 * where a refusing queue reports that it has drained. */
static int next_send(mob_midi_port handle, uint8_t *out, int64_t *stamp,
                     MIDIEndpointRef *endpoint, bool *virtual_port) {
  int n = 0;
  out_slot *o = lock_handle(handle);
  if (!o)
    return -1;
  mob_midi_queue_idle(&o->q);
  for (;;) {
    if (!o->open || o->generation != (uint32_t)(handle >> 32)) {
      pthread_mutex_unlock(&o->lock);
      return -1;
    }
    if (mob_midi_queue_drained(&o->q))
      deliver_drained(o, handle);
    if (o->q.count == 0) {
      pthread_cond_wait(&o->cond, &o->lock);
      continue;
    }
    int64_t now = mob_midi_now_ns();
    int64_t due = mob_midi_queue_next_due(&o->q);
    if (due > now) {
      int64_t wait = due - now;
      struct timespec rel = {.tv_sec = wait / 1000000000LL,
                             .tv_nsec = wait % 1000000000LL};
      pthread_cond_timedwait_relative_np(&o->cond, &o->lock, &rel);
      continue;
    }
    n = mob_midi_queue_take(&o->q, now, out, DISPATCH_MAX, stamp);
    *endpoint = o->endpoint;
    *virtual_port = o->virtual_port;
    break;
  }
  pthread_mutex_unlock(&o->lock);
  return n;
}

static MIDIPortRef g_out_port = 0;

/* Time-constraint (real-time) scheduling: a waiting dispatcher wakes within
 * microseconds of a message's due time. At a default priority Darwin's timer
 * coalescing makes it a millisecond late, often several. The thread
 * computes for microseconds per wake; the kernel demotes it if it overruns. */
static void set_realtime(void) {
  thread_time_constraint_policy_data_t policy = {
      .period = 0,
      .computation = (uint32_t)ns_to_host(200000),
      .constraint = (uint32_t)ns_to_host(1000000),
      .preemptible = 1,
  };
  thread_policy_set(pthread_mach_thread_np(pthread_self()),
                    THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                    THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

/* The end of the segment of a batch that starts at `i`: a SysEx (from 0xF0,
 * or the rest of one when a batch starts with data bytes) up to its 0xF7 or
 * the next status byte, or anything else up to the next 0xF0. CoreMIDI wants
 * a SysEx alone in its packets (MIDIPacket.data); real-time bytes inside one
 * stay in it. */
static int segment_end(const uint8_t *b, int n, int i) {
  int k = i + 1;
  if (!(b[i] == 0xF0 || (i == 0 && b[i] < 0x80))) {
    while (k < n && b[k] != 0xF0)
      k++;
    return k;
  }
  for (; k < n; k++) {
    if (b[k] == 0xF7)
      return k + 1;
    if (b[k] >= 0x80 && b[k] < 0xF8)
      return k;
  }
  return k;
}

static void hand_over(MIDIEndpointRef endpoint, bool virtual_port,
                      const MIDIPacketList *packets) {
  if (virtual_port)
    MIDIReceived(endpoint, packets);
  else
    MIDISend(g_out_port, endpoint, packets);
}

/* One per open output, so a send that misbehaves holds up only its own
 * queue. Ends when the output closes. */
static void *dispatcher_main(void *arg) {
  mob_midi_port handle = (mob_midi_port)(intptr_t)arg;
  pthread_setname_np("mob_midi_out");
  set_realtime();
  _Static_assert(DISPATCH_MAX < 65536, "one MIDIPacket holds a segment");
  uint8_t out[DISPATCH_MAX];
  uint8_t list[DISPATCH_MAX + 64] __attribute__((aligned(8)));
  for (;;) {
    int64_t stamp = 0;
    MIDIEndpointRef endpoint = 0;
    bool virtual_port = false;
    int n = next_send(handle, out, &stamp, &endpoint, &virtual_port);
    if (n < 0)
      return NULL;
    // A packet per segment (MIDIPacketListAdd joins same-time segments that
    // aren't SysEx); a full list goes out and a new one starts.
    MIDITimeStamp ts = ns_to_host(stamp);
    MIDIPacketList *packets = (MIDIPacketList *)list;
    MIDIPacket *p = MIDIPacketListInit(packets);
    for (int i = 0; i < n;) {
      int end = segment_end(out, n, i);
      MIDIPacket *next = MIDIPacketListAdd(packets, sizeof(list), p, ts,
                                           (ByteCount)(end - i), out + i);
      if (!next && packets->numPackets > 0) {
        hand_over(endpoint, virtual_port, packets);
        p = MIDIPacketListInit(packets);
        next = MIDIPacketListAdd(packets, sizeof(list), p, ts,
                                 (ByteCount)(end - i), out + i);
      }
      if (next)
        p = next;
      i = end;
    }
    if (packets->numPackets > 0)
      hand_over(endpoint, virtual_port, packets);
  }
}

/* A slot for an output that opens now, and its dispatch thread: the handle,
 * or 0 with *reason set. Under g_ops. */
static mob_midi_port output_open(int32_t device, int32_t port,
                                 bool virtual_port, MIDIEndpointRef endpoint,
                                 const ErlNifPid *pid, const char **reason) {
  *reason = "no_free_output";
  if (!ensure_outputs())
    return 0;
  out_slot *slots = atomic_load(&g_outputs);
  pthread_mutex_lock(&g_outputs_lock);
  mob_midi_port handle = 0;
  int index = -1;
  for (int i = 0; i < OUT_SLOTS && !handle; i++) {
    out_slot *o = &slots[i];
    pthread_mutex_lock(&o->lock);
    if (!o->open) {
      o->open = true;
      o->generation = next_generation();
      o->device = device;
      o->port = port;
      o->virtual_port = virtual_port;
      o->endpoint = endpoint;
      o->pid = *pid;
      mob_midi_queue_reset(&o->q);
      handle = make_handle(i, o->generation);
      index = i;
    }
    pthread_mutex_unlock(&o->lock);
  }
  if (handle) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (pthread_create(&thread, &attr, dispatcher_main,
                       (void *)(intptr_t)handle) != 0) {
      out_slot *o = &slots[index];
      pthread_mutex_lock(&o->lock);
      o->open = false;
      o->generation = 0;
      pthread_mutex_unlock(&o->lock);
      handle = 0;
      *reason = "open_failed";
    }
    pthread_attr_destroy(&attr);
  }
  pthread_mutex_unlock(&g_outputs_lock);
  return handle;
}

/* Closed: queued messages are dropped and the dispatch thread ends (once a
 * send it is in returns). Under g_ops. */
static void output_close(mob_midi_port handle) {
  pthread_mutex_lock(&g_outputs_lock);
  out_slot *o = lock_handle(handle);
  if (o) {
    o->open = false;
    o->generation = 0;
    o->endpoint = 0;
    mob_midi_queue_reset(&o->q);
    pthread_cond_broadcast(&o->cond);
    pthread_mutex_unlock(&o->lock);
  }
  pthread_mutex_unlock(&g_outputs_lock);
}

/* A later opener of the same output takes over its events. */
static void output_owner(mob_midi_port handle, const ErlNifPid *pid) {
  out_slot *o = lock_handle(handle);
  if (!o)
    return;
  o->pid = *pid;
  pthread_mutex_unlock(&o->lock);
}

/* Every open output of `device` that matches `virtual_port`, closed. Under
 * g_ops. */
static void close_outputs(int32_t device, bool virtual_port) {
  for (;;) {
    mob_midi_port h = 0;
    out_slot *slots = atomic_load(&g_outputs);
    for (int i = 0; slots && i < OUT_SLOTS && !h; i++) {
      out_slot *o = &slots[i];
      pthread_mutex_lock(&o->lock);
      if (o->open && o->device == device && o->virtual_port == virtual_port)
        h = make_handle(i, o->generation);
      pthread_mutex_unlock(&o->lock);
    }
    if (!h)
      return;
    output_close(h);
  }
}

// ── Own virtual devices ───────────────────────────────────────────────────

typedef struct {
  bool used;
  uint8_t *name; /* UTF-8, name_len bytes */
  size_t name_len;
  MIDIEndpointRef source, destination;
  SInt32 uid; /* the source's unique id: the device id */
  /* open_virtual's subscription: its source as (source << 32) | generation
   * (0: none), read by the destination's read proc; and its output's handle
   * (under g_ops). */
  _Atomic uint64_t current;
  mob_midi_port handle;
} virtual_t;

/* Never freed: an entry's address is its destination's read proc refCon,
 * and the endpoints live until the app exits. Under g_ops. */
static virtual_t g_virtuals[MAX_VIRTUALS];

// Another app sent into one of our virtual destinations.
static void virtual_read_proc(const MIDIPacketList *packets,
                              void *readProcRefCon, void *srcConnRefCon) {
  (void)srcConnRefCon;
  virtual_t *v = readProcRefCon;
  uint64_t packed = atomic_load(&v->current);
  if (packed)
    deliver((uint32_t)(packed >> 32), (uint32_t)packed, packets);
}

static virtual_t *virtual_for_uid(SInt32 uid) {
  for (int i = 0; i < MAX_VIRTUALS; i++)
    if (g_virtuals[i].used && g_virtuals[i].uid == uid)
      return &g_virtuals[i];
  return NULL;
}

static BOOL is_own_endpoint(MIDIEndpointRef ep) {
  for (int i = 0; i < MAX_VIRTUALS; i++)
    if (g_virtuals[i].used &&
        (g_virtuals[i].source == ep || g_virtuals[i].destination == ep))
      return YES;
  return NO;
}

/* Ends open_virtual's subscription: nothing other apps send in reaches the
 * opener once this returns, and its output handle is closed. Under g_ops. */
static void close_virtual(virtual_t *v) {
  uint64_t packed = atomic_exchange(&v->current, 0);
  if (packed)
    source_close((int)(packed >> 32));
  if (v->handle)
    output_close(v->handle);
  v->handle = 0;
}

// ── Endpoints ─────────────────────────────────────────────────────────────

static SInt32 endpoint_uid(MIDIEndpointRef ep) {
  SInt32 uid = 0;
  MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid);
  return uid;
}

static MIDIEndpointRef source_for_uid(SInt32 uid) {
  ItemCount n = MIDIGetNumberOfSources();
  for (ItemCount i = 0; i < n; i++) {
    MIDIEndpointRef ep = MIDIGetSource(i);
    if (endpoint_uid(ep) == uid)
      return ep;
  }
  return 0;
}

static MIDIEndpointRef dest_for_uid(SInt32 uid) {
  ItemCount n = MIDIGetNumberOfDestinations();
  for (ItemCount i = 0; i < n; i++) {
    MIDIEndpointRef ep = MIDIGetDestination(i);
    if (endpoint_uid(ep) == uid)
      return ep;
  }
  return 0;
}

static MIDIPortRef g_in_port = 0;

/* Every open input of `device`, closed and disconnected. Under g_ops; the
 * disconnect comes after the source's lock is let go (CoreMIDI may wait on
 * a read proc that is waiting on that lock). */
static void close_inputs(int32_t device) {
  pthread_once(&g_sources_once, sources_init);
  for (int i = 1; i < MOB_MIDI_MAX_SOURCES; i++) {
    source_t *s = &g_sources[i];
    pthread_mutex_lock(&s->lock);
    bool match = s->used && s->kind == SRC_INPUT && s->device == device;
    MIDIEndpointRef ep = s->endpoint;
    pthread_mutex_unlock(&s->lock);
    if (!match)
      continue;
    source_close(i);
    if (ep && g_in_port)
      MIDIPortDisconnectSource(g_in_port, ep);
  }
}

/* After a device went away: its open inputs and outputs are closed, as on
 * Android (an endpoint that is gone, or replaced by another with its id).
 * Under g_ops. */
static void close_removed(void) {
  pthread_once(&g_sources_once, sources_init);
  for (int i = 1; i < MOB_MIDI_MAX_SOURCES; i++) {
    source_t *s = &g_sources[i];
    pthread_mutex_lock(&s->lock);
    bool input = s->used && s->kind == SRC_INPUT;
    int32_t device = s->device;
    MIDIEndpointRef ep = s->endpoint;
    pthread_mutex_unlock(&s->lock);
    if (input && source_for_uid(device) != ep)
      close_inputs(device);
  }
  out_slot *slots = atomic_load(&g_outputs);
  for (int i = 0; slots && i < OUT_SLOTS; i++) {
    out_slot *o = &slots[i];
    pthread_mutex_lock(&o->lock);
    bool device_out = o->open && !o->virtual_port;
    int32_t device = o->device;
    MIDIEndpointRef ep = o->endpoint;
    mob_midi_port h = make_handle(i, o->generation);
    pthread_mutex_unlock(&o->lock);
    if (device_out && dest_for_uid(device) != ep)
      output_close(h);
  }
}

// A string property as a binary term ("" when unset).
static ERL_NIF_TERM string_property(ErlNifEnv *e, MIDIObjectRef obj,
                                    CFStringRef prop, const char *fallback) {
  CFStringRef cf = NULL;
  char buf[128];
  strlcpy(buf, fallback, sizeof(buf));
  if (MIDIObjectGetStringProperty(obj, prop, &cf) == noErr && cf) {
    CFStringGetCString(cf, buf, sizeof(buf), kCFStringEncodingUTF8);
    CFRelease(cf);
  }
  ERL_NIF_TERM term;
  size_t len = strlen(buf);
  memcpy(enif_make_new_binary(e, len, &term), buf, len);
  return term;
}

// usb / bluetooth by the owning driver; an endpoint without an entity is a
// virtual (app-created) one.
static const char *endpoint_type(MIDIEndpointRef ep) {
  MIDIEntityRef entity = 0;
  if (MIDIEndpointGetEntity(ep, &entity) != noErr || entity == 0)
    return "virtual";
  MIDIDeviceRef dev = 0;
  CFStringRef owner = NULL;
  const char *type = "other";
  if (MIDIEntityGetDevice(entity, &dev) == noErr &&
      MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &owner) ==
          noErr &&
      owner) {
    NSString *o = (__bridge NSString *)owner;
    if ([o rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch]
            .location != NSNotFound)
      type = "bluetooth";
    else if ([o rangeOfString:@"USB" options:NSCaseInsensitiveSearch]
                 .location != NSNotFound)
      type = "usb";
    CFRelease(owner);
  }
  return type;
}

// ── Client ────────────────────────────────────────────────────────────────

static MIDIClientRef g_client = 0;
static pthread_mutex_t g_client_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_client_cond = PTHREAD_COND_INITIALIZER;
static bool g_client_waiting = false;

// The list_devices caller hears hot-plug (last caller wins). Under g_ops.
static ErlNifPid g_list_pid;
static BOOL g_have_list_pid = NO;

/* On the "mob_midi" thread. A device that went away has its ports closed
 * first, then the subscriber hears of it, as on Android. */
static void notify_proc(const MIDINotification *msg, void *refCon) {
  (void)refCon;
  MIDINotificationMessageID id = msg->messageID;
  if (id != kMIDIMsgObjectAdded && id != kMIDIMsgObjectRemoved &&
      id != kMIDIMsgSetupChanged)
    return;
  pthread_mutex_lock(&g_ops);
  if (id != kMIDIMsgObjectAdded)
    close_removed();
  ErlNifPid pid = g_list_pid;
  BOOL have = g_have_list_pid;
  pthread_mutex_unlock(&g_ops);
  if (!have || id == kMIDIMsgSetupChanged)
    return;
  ErlNifEnv *e = enif_alloc_env();
  if (!e)
    return;
  // The payload is nil: a change to re-list on.
  const char *tag =
      id == kMIDIMsgObjectAdded ? "device_added" : "device_removed";
  enif_send(NULL, &pid, e, midi_env3(e, tag, atom(e, "nil")));
  enif_free_env(e);
}

/* Makes the client, then runs this thread's run loop for good: CoreMIDI
 * calls every client's notify proc on the run loop of the thread that first
 * called MIDIClientCreate, and a BEAM scheduler runs none. */
static void *client_main(void *arg) {
  (void)arg;
  pthread_setname_np("mob_midi");
  MIDIClientRef client = 0;
  OSStatus st = MIDIClientCreate(CFSTR("mob_midi"), notify_proc, NULL, &client);
  pthread_mutex_lock(&g_client_lock);
  if (st == noErr)
    g_client = client;
  g_client_waiting = false;
  pthread_cond_broadcast(&g_client_cond);
  pthread_mutex_unlock(&g_client_lock);
  if (st != noErr)
    return NULL;
  // A source that never fires, so the run loop has something to wait on.
  CFRunLoopSourceContext context = {0};
  CFRunLoopSourceRef keep = CFRunLoopSourceCreate(NULL, 0, &context);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), keep, kCFRunLoopDefaultMode);
  for (;;)
    CFRunLoopRun();
}

/* The client and its ports, made once (a failed attempt is retried by the
 * next call). */
static BOOL ensure_client(void) {
  pthread_mutex_lock(&g_client_lock);
  if (!g_client) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    g_client_waiting = true;
    if (pthread_create(&thread, &attr, client_main, NULL) == 0) {
      while (g_client_waiting)
        pthread_cond_wait(&g_client_cond, &g_client_lock);
    }
    g_client_waiting = false;
    pthread_attr_destroy(&attr);
  }
  if (g_client && !g_in_port)
    MIDIInputPortCreate(g_client, CFSTR("mob_midi_in"), input_read_proc, NULL,
                        &g_in_port);
  if (g_client && !g_out_port)
    MIDIOutputPortCreate(g_client, CFSTR("mob_midi_out"), &g_out_port);
  BOOL ok = g_client && g_in_port && g_out_port;
  pthread_mutex_unlock(&g_client_lock);
  return ok;
}

// ── NIFs ──────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_list_devices(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  // Answer THIS caller (a later list_devices takes the hot-plug
  // subscription, not this answer).
  ErlNifPid self;
  enif_self(env, &self);
  pthread_mutex_lock(&g_ops);
  g_list_pid = self;
  g_have_list_pid = YES;
  // No CoreMIDI client: say so instead of answering nothing, so the caller
  // (and MobMidi.SelfTest) can tell it from an empty device list.
  if (!ensure_client()) {
    pthread_mutex_unlock(&g_ops);
    send_error(env, &self, 0, "list_devices", "no_client");
    return atom(env, "ok");
  }

  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM list = enif_make_list(e, 0);

  // Sources = inputs, destinations = outputs.
  for (int pass = 0; pass < 2; pass++) {
    BOOL input = (pass == 0);
    ItemCount n =
        input ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < n; i++) {
      MIDIEndpointRef ep = input ? MIDIGetSource(i) : MIDIGetDestination(i);
      ERL_NIF_TERM keys[8] = {
          atom(e, "id"),           atom(e, "name"),
          atom(e, "direction"),    atom(e, "manufacturer"),
          atom(e, "type"),         atom(e, "input_ports"),
          atom(e, "output_ports"), atom(e, "own")};
      ERL_NIF_TERM vals[8] = {
          enif_make_int(e, endpoint_uid(ep)),
          string_property(e, ep, kMIDIPropertyDisplayName, "MIDI"),
          atom(e, input ? "input" : "output"),
          string_property(e, ep, kMIDIPropertyManufacturer, ""),
          atom(e, endpoint_type(ep)),
          enif_make_int(e, input ? 1 : 0),
          enif_make_int(e, input ? 0 : 1),
          atom(e, is_own_endpoint(ep) ? "true" : "false")};
      ERL_NIF_TERM dev;
      if (enif_make_map_from_arrays(e, keys, vals, 8, &dev))
        list = enif_make_list_cell(e, dev, list);
    }
  }
  pthread_mutex_unlock(&g_ops);

  enif_send(env, &self, e, midi_env3(e, "devices", list));
  enif_free_env(e);
  return atom(env, "ok");
}

// open_input(uid, port, route): port -1 (port: :all) is port 0, a CoreMIDI
// endpoint's only one; route 1 BEAM, 2 the native sink, 3 both. Opening an
// input again replaces its subscription.
static ERL_NIF_TERM nif_open_input(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port, route;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port) ||
      !enif_get_int(env, argv[2], &route) || route < 1 || route > 3)
    return enif_make_badarg(env);
  ErlNifPid self;
  enif_self(env, &self);
  const char *failure = NULL;
  pthread_mutex_lock(&g_ops);
  MIDIEndpointRef src = 0;
  if (!ensure_client())
    failure = "no_client";
  else if ((src = source_for_uid((SInt32)uid)) == 0)
    failure = "no_such_device";
  else if (port != 0 && port != -1)
    failure = "no_such_port";
  if (!failure) {
    close_inputs((int32_t)uid);
    // Delivering to nobody until :opened is out: no bytes precede it, and a
    // connect that fails sends no :opened.
    int64_t packed = source_open(SRC_INPUT, (int32_t)uid, 0, &self, 0, src);
    if (packed < 0) {
      failure = "no_free_source";
    } else if (MIDIPortConnectSource(g_in_port, src,
                                     (void *)(uintptr_t)packed) != noErr) {
      source_close((int)(packed >> 32));
      failure = "open_failed";
    } else {
      send_opened(env, &self, (SInt32)uid, "input", (uint32_t)(packed >> 32),
                  0);
      source_route(packed, (uint32_t)route);
    }
  }
  pthread_mutex_unlock(&g_ops);
  if (failure)
    send_error(env, &self, (SInt32)uid, "open_input", failure);
  return atom(env, "ok");
}

// open_output(uid, port): a destination's output and its dispatch thread. An
// output opened again answers :opened with the same handle and its later
// events go to the new opener.
static ERL_NIF_TERM nif_open_output(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port))
    return enif_make_badarg(env);
  ErlNifPid self;
  enif_self(env, &self);
  const char *failure = NULL;
  pthread_mutex_lock(&g_ops);
  MIDIEndpointRef dest = 0;
  if (!ensure_client())
    failure = "no_client";
  else if ((dest = dest_for_uid((SInt32)uid)) == 0)
    failure = "no_such_device";
  else if (port != 0)
    failure = "no_such_port";
  if (!failure) {
    mob_midi_port handle = output_handle((int32_t)uid, 0);
    if (handle) {
      // :opened first: the dispatcher may report :drained to the owner as
      // soon as it is set.
      send_opened(env, &self, (SInt32)uid, "output", 0, handle);
      output_owner(handle, &self);
    } else if ((handle = output_open((int32_t)uid, 0, false, dest, &self,
                                     &failure)) != 0) {
      send_opened(env, &self, (SInt32)uid, "output", 0, handle);
    }
  }
  pthread_mutex_unlock(&g_ops);
  if (failure)
    send_error(env, &self, (SInt32)uid, "open_output", failure);
  return atom(env, "ok");
}

// close(uid): every input and output of the device, and the open_virtual
// subscription of an own virtual device. Once it returns nothing more of
// them is delivered and their handles answer MOB_MIDI_ERR_NOT_OPEN.
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  if (!enif_get_int(env, argv[0], &uid))
    return enif_make_badarg(env);
  pthread_mutex_lock(&g_ops);
  virtual_t *v = virtual_for_uid((SInt32)uid);
  if (v)
    close_virtual(v);
  close_inputs((int32_t)uid);
  close_outputs((int32_t)uid, false);
  close_outputs((int32_t)uid, true);
  pthread_mutex_unlock(&g_ops);
  return atom(env, "ok");
}

// midi_send(uid, port, bytes, timestamp_ns); timestamp 0 = now. Into the
// open output's queue, as mob_midi_send.
static ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  ErlNifBinary bin;
  ErlNifSInt64 ts;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port) ||
      !enif_get_int64(env, argv[3], &ts))
    return enif_make_badarg(env);
  if (!enif_inspect_binary(env, argv[2], &bin) &&
      !enif_inspect_iolist_as_binary(env, argv[2], &bin))
    return enif_make_badarg(env);
  if (bin.size == 0)
    return atom(env, "ok");
  mob_midi_port handle = output_handle((int32_t)uid, (int32_t)port);
  int rc = handle ? mob_midi_send(handle, bin.data, bin.size, ts)
                  : MOB_MIDI_ERR_NOT_OPEN;
  switch (rc) {
  case MOB_MIDI_OK:
    return atom(env, "ok");
  case MOB_MIDI_ERR_NOT_OPEN:
    return error_tuple(env, "not_open");
  case MOB_MIDI_ERR_QUEUE_FULL:
    return error_tuple(env, "queue_full");
  case MOB_MIDI_ERR_TOO_LARGE:
    return error_tuple(env, "too_large");
  default:
    return error_tuple(env, "send_failed");
  }
}

// midi_output_handle(uid, port): the open output's mob_midi.h handle.
static ERL_NIF_TERM nif_output_handle(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port))
    return enif_make_badarg(env);
  mob_midi_port handle = output_handle((int32_t)uid, (int32_t)port);
  if (handle <= 0)
    return error_tuple(env, "not_open");
  return enif_make_tuple2(env, atom(env, "ok"), enif_make_int64(env, handle));
}

// midi_discard(uid, port): drop the open output's queue; {:ok, generation}.
static ERL_NIF_TERM nif_discard(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port))
    return enif_make_badarg(env);
  mob_midi_port handle = output_handle((int32_t)uid, (int32_t)port);
  int generation = handle ? mob_midi_discard(handle) : MOB_MIDI_ERR_NOT_OPEN;
  if (generation <= 0)
    return error_tuple(env, "not_open");
  return enif_make_tuple2(env, atom(env, "ok"), enif_make_int(env, generation));
}

static ERL_NIF_TERM nif_now_ns(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int64(env, mob_midi_now_ns());
}

/* The virtual device `name`, made the first time: a source (what the app
 * sends out of it) and a destination of that name (what other apps send
 * into it). NULL with *reason set. Under g_ops. */
static virtual_t *virtual_named(const ErlNifBinary *name, const char **reason) {
  for (int i = 0; i < MAX_VIRTUALS; i++) {
    virtual_t *v = &g_virtuals[i];
    if (v->used && v->name_len == name->size &&
        memcmp(v->name, name->data, name->size) == 0)
      return v;
  }
  *reason = "open_failed";
  virtual_t *v = NULL;
  for (int i = 0; i < MAX_VIRTUALS && !v; i++)
    if (!g_virtuals[i].used)
      v = &g_virtuals[i];
  if (!v)
    return NULL;
  CFStringRef cf = CFStringCreateWithBytes(NULL, name->data, (CFIndex)name->size,
                                           kCFStringEncodingUTF8, false);
  uint8_t *copy = malloc(name->size ? name->size : 1);
  if (!cf || !copy) {
    if (cf)
      CFRelease(cf);
    free(copy);
    return NULL;
  }
  MIDIEndpointRef src = 0, dst = 0;
  OSStatus st = MIDISourceCreate(g_client, cf, &src);
  if (st == noErr)
    st = MIDIDestinationCreate(g_client, cf, virtual_read_proc, v, &dst);
  if (st != noErr) {
    // iOS refuses virtual endpoints to an app without "audio" in its
    // Info.plist UIBackgroundModes.
    if (st == kMIDINotPermitted)
      *reason = "not_permitted";
    if (src)
      MIDIEndpointDispose(src);
    CFRelease(cf);
    free(copy);
    return NULL;
  }
  CFRelease(cf);
  memcpy(copy, name->data, name->size);
  v->name = copy;
  v->name_len = name->size;
  v->source = src;
  v->destination = dst;
  v->uid = endpoint_uid(src);
  atomic_store(&v->current, 0);
  v->handle = 0;
  v->used = true;
  return v;
}

// open_virtual(name, route): subscribe the caller to the virtual device
// `name` (made the first time): what other apps send into it goes to
// `route` (as open_input), and its output gets a handle (send_raw /
// mob_midi_send to every app listening). A second open_virtual replaces the
// first.
static ERL_NIF_TERM nif_open_virtual(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary name;
  int route;
  if (!enif_inspect_binary(env, argv[0], &name) ||
      !enif_get_int(env, argv[1], &route) || route < 1 || route > 3)
    return enif_make_badarg(env);
  ErlNifPid self;
  enif_self(env, &self);
  const char *failure = NULL;
  SInt32 device = 0;
  pthread_mutex_lock(&g_ops);
  virtual_t *v = NULL;
  if (!ensure_client())
    failure = "no_client";
  else
    v = virtual_named(&name, &failure);
  if (v) {
    device = v->uid;
    close_virtual(v);
    int64_t packed =
        source_open(SRC_VIRTUAL, v->uid, 0, &self, (uint32_t)route, 0);
    mob_midi_port handle = 0;
    if (packed < 0)
      failure = "no_free_source";
    else if ((handle = output_open(v->uid, 0, true, v->source, &self,
                                   &failure)) == 0)
      source_close((int)(packed >> 32));
    if (handle) {
      failure = NULL;
      v->handle = handle;
      ErlNifEnv *e = enif_alloc_env();
      if (e) {
        ERL_NIF_TERM name_term;
        memcpy(enif_make_new_binary(e, name.size, &name_term), name.data,
               name.size);
        ERL_NIF_TERM keys[3] = {atom(e, "device"), atom(e, "direction"),
                                atom(e, "name")};
        ERL_NIF_TERM vals[3] = {enif_make_int(e, v->uid), atom(e, "virtual"),
                                name_term};
        send_map(env, &self, e, "opened", keys, vals, 3);
        enif_free_env(e);
      }
      // After :opened, so no bytes precede it.
      atomic_store(&v->current, (uint64_t)packed);
    }
  }
  pthread_mutex_unlock(&g_ops);
  if (failure)
    send_error(env, &self, device, "open_virtual", failure);
  return atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
// The Bluetooth central NIFs are Android-only: MobMidi gates them off iOS, so
// they aren't registered here.
static ErlNifFunc nif_funcs[] = {
    {"midi_list_devices", 0, nif_list_devices, 0},
    {"midi_open_input", 3, nif_open_input, 0},
    {"midi_open_output", 2, nif_open_output, 0},
    {"midi_close", 1, nif_close, 0},
    {"midi_send", 4, nif_send, 0},
    {"midi_now_ns", 0, nif_now_ns, 0},
    {"midi_open_virtual", 2, nif_open_virtual, 0},
    {"midi_output_handle", 2, nif_output_handle, 0},
    {"midi_discard", 2, nif_discard, 0},
};

ERL_NIF_INIT(mob_midi_nif, nif_funcs, NULL, NULL, NULL, NULL)
