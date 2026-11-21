/* Host test NIF for priv/native/ios/mob_midi_nif.m (macOS, real CoreMIDI),
 * loaded by test/mob_midi_ios_host_test.exs as :mob_midi_ios_test_nif.
 *
 * The iOS NIF compiles unchanged for macOS: this file includes it whole
 * (its ERL_NIF_INIT disabled) and registers its midi_* NIFs next to probes:
 *
 *   - the C ABI as an app's static NIF uses it (Magpie's magpie_audio.c): a
 *     sink recording what it gets, mob_midi_send / discard / source_info;
 *   - "another app": a CoreMIDI client of its own with a destination that
 *     records what arrives (bytes, stamp, arrival) and a source that plays
 *     into the plugin, both called `name` (peer_open/1), disposable to stand
 *     in for an unplugged device (peer_dispose/0).
 */
#include <erl_nif.h>

#pragma push_macro("ERL_NIF_INIT")
#undef ERL_NIF_INIT
#define ERL_NIF_INIT(NAME, FUNCS, LOAD, RELOAD, UPGRADE, UNLOAD)
#include "../../priv/native/ios/mob_midi_nif.m"
#pragma pop_macro("ERL_NIF_INIT")

#define RING 1024
#define REC_BYTES 512

typedef struct {
  uint32_t source, generation;
  int64_t stamp, arrived;
  size_t len; /* bytes received; only the first REC_BYTES are kept */
  uint8_t bytes[REC_BYTES];
} rec_t;

typedef struct {
  pthread_mutex_t lock;
  rec_t recs[RING];
  int count;
} ring_t;

static ring_t g_sink_ring = {.lock = PTHREAD_MUTEX_INITIALIZER};
static ring_t g_peer_ring = {.lock = PTHREAD_MUTEX_INITIALIZER};

static void ring_put(ring_t *r, uint32_t source, uint32_t generation,
                     const uint8_t *bytes, size_t len, int64_t stamp) {
  int64_t arrived = mob_midi_now_ns();
  pthread_mutex_lock(&r->lock);
  if (r->count < RING) {
    rec_t *x = &r->recs[r->count++];
    x->source = source;
    x->generation = generation;
    x->stamp = stamp;
    x->arrived = arrived;
    x->len = len;
    memcpy(x->bytes, bytes, len < REC_BYTES ? len : REC_BYTES);
  }
  pthread_mutex_unlock(&r->lock);
}

/* [{source, generation, bytes, stamp, arrived, len}], oldest first; empties
 * the ring. */
static ERL_NIF_TERM ring_take(ErlNifEnv *env, ring_t *r) {
  pthread_mutex_lock(&r->lock);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (int i = r->count - 1; i >= 0; i--) {
    rec_t *x = &r->recs[i];
    size_t kept = x->len < REC_BYTES ? x->len : REC_BYTES;
    ERL_NIF_TERM bin;
    memcpy(enif_make_new_binary(env, kept, &bin), x->bytes, kept);
    ERL_NIF_TERM t[6] = {enif_make_uint(env, x->source),
                         enif_make_uint(env, x->generation), bin,
                         enif_make_int64(env, x->stamp),
                         enif_make_int64(env, x->arrived),
                         enif_make_uint64(env, x->len)};
    list = enif_make_list_cell(env, enif_make_tuple_from_array(env, t, 6), list);
  }
  r->count = 0;
  pthread_mutex_unlock(&r->lock);
  return list;
}

static void record_sink(void *ctx, uint32_t source, uint32_t generation,
                        const uint8_t *bytes, size_t len, int64_t stamp) {
  (void)ctx;
  ring_put(&g_sink_ring, source, generation, bytes, len, stamp);
}

static ERL_NIF_TERM t_sink_start(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int(env, mob_midi_set_sink(record_sink, NULL));
}

static ERL_NIF_TERM t_sink_stop(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int(env, mob_midi_set_sink(NULL, NULL));
}

static ERL_NIF_TERM t_sink_take(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return ring_take(env, &g_sink_ring);
}

static ERL_NIF_TERM t_c_send(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifSInt64 handle, at;
  ErlNifBinary bin;
  if (!enif_get_int64(env, argv[0], &handle) ||
      !enif_inspect_binary(env, argv[1], &bin) ||
      !enif_get_int64(env, argv[2], &at))
    return enif_make_badarg(env);
  return enif_make_int(env, mob_midi_send(handle, bin.data, bin.size, at));
}

static ERL_NIF_TERM t_c_discard(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifSInt64 handle;
  if (!enif_get_int64(env, argv[0], &handle))
    return enif_make_badarg(env);
  return enif_make_int(env, mob_midi_discard(handle));
}

static ERL_NIF_TERM t_c_source_info(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  unsigned source;
  if (!enif_get_uint(env, argv[0], &source))
    return enif_make_badarg(env);
  uint32_t generation = 0;
  int32_t device = 0, port = 0;
  int rc = mob_midi_source_info(source, &generation, &device, &port);
  return enif_make_tuple4(env, enif_make_int(env, rc),
                          enif_make_uint(env, generation),
                          enif_make_int(env, device), enif_make_int(env, port));
}

static ERL_NIF_TERM t_c_now(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int64(env, mob_midi_now_ns());
}

static ERL_NIF_TERM t_c_abi(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int(env, mob_midi_abi_version());
}

// ── The peer: another app's client ────────────────────────────────────────

static MIDIClientRef g_peer = 0;
static MIDIPortRef g_peer_out = 0;
static MIDIEndpointRef g_peer_dst = 0, g_peer_src = 0;

static void peer_read(const MIDIPacketList *packets, void *ref, void *conn) {
  (void)ref;
  (void)conn;
  const MIDIPacket *p = &packets->packet[0];
  for (UInt32 i = 0; i < packets->numPackets; i++) {
    ring_put(&g_peer_ring, 0, 0, p->data, p->length,
             p->timeStamp ? host_to_ns(p->timeStamp) : 0);
    p = MIDIPacketNext(p);
  }
}

// peer_open(name) -> {dest_uid, source_uid} | error
static ERL_NIF_TERM t_peer_open(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary name;
  if (!enif_inspect_binary(env, argv[0], &name))
    return enif_make_badarg(env);
  // The plugin's client first: CoreMIDI notifies every client on the run
  // loop of the thread that made the first one.
  if (!ensure_client())
    return atom(env, "error");
  if (!g_peer &&
      (MIDIClientCreate(CFSTR("mob_midi test peer"), NULL, NULL, &g_peer) !=
           noErr ||
       MIDIOutputPortCreate(g_peer, CFSTR("peer out"), &g_peer_out) != noErr))
    return atom(env, "error");
  CFStringRef cf = CFStringCreateWithBytes(NULL, name.data, (CFIndex)name.size,
                                           kCFStringEncodingUTF8, false);
  OSStatus a = MIDIDestinationCreate(g_peer, cf, peer_read, NULL, &g_peer_dst);
  OSStatus b = MIDISourceCreate(g_peer, cf, &g_peer_src);
  CFRelease(cf);
  if (a != noErr || b != noErr)
    return atom(env, "error");
  return enif_make_tuple2(env, enif_make_int(env, endpoint_uid(g_peer_dst)),
                          enif_make_int(env, endpoint_uid(g_peer_src)));
}

static ERL_NIF_TERM t_peer_dispose(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  if (g_peer_dst)
    MIDIEndpointDispose(g_peer_dst);
  if (g_peer_src)
    MIDIEndpointDispose(g_peer_src);
  g_peer_dst = g_peer_src = 0;
  return atom(env, "ok");
}

static ERL_NIF_TERM t_peer_take(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return ring_take(env, &g_peer_ring);
}

/* peer_play(bytes, stamp_ns): out of the peer's source (to whoever
 * connected it); peer_send(dest_uid, bytes, stamp_ns): from the peer's
 * output port into a destination. A stamp of 0 leaves it unstamped. */
static ERL_NIF_TERM peer_packets(ErlNifEnv *env, const ERL_NIF_TERM argv[],
                                 int uid) {
  ErlNifBinary bin;
  ErlNifSInt64 stamp;
  if (!enif_inspect_binary(env, argv[0], &bin) ||
      !enif_get_int64(env, argv[1], &stamp))
    return enif_make_badarg(env);
  Byte buf[1024];
  MIDIPacketList *packets = (MIDIPacketList *)buf;
  MIDIPacket *p = MIDIPacketListInit(packets);
  p = MIDIPacketListAdd(packets, sizeof(buf), p,
                        stamp > 0 ? ns_to_host(stamp) : 0, bin.size, bin.data);
  if (!p)
    return atom(env, "error");
  OSStatus st = uid ? MIDISend(g_peer_out, dest_for_uid(uid), packets)
                    : MIDIReceived(g_peer_src, packets);
  return st == noErr ? atom(env, "ok") : atom(env, "error");
}

static ERL_NIF_TERM t_peer_play(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  return peer_packets(env, argv, 0);
}

static ERL_NIF_TERM t_peer_send(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  if (!enif_get_int(env, argv[0], &uid) || uid == 0)
    return enif_make_badarg(env);
  return peer_packets(env, argv + 1, uid);
}

static ErlNifFunc test_funcs[] = {
    {"midi_list_devices", 0, nif_list_devices, 0},
    {"midi_open_input", 3, nif_open_input, 0},
    {"midi_open_output", 2, nif_open_output, 0},
    {"midi_close", 1, nif_close, 0},
    {"midi_send", 4, nif_send, 0},
    {"midi_now_ns", 0, nif_now_ns, 0},
    {"midi_open_virtual", 2, nif_open_virtual, 0},
    {"midi_output_handle", 2, nif_output_handle, 0},
    {"midi_discard", 2, nif_discard, 0},
    {"sink_start", 0, t_sink_start, 0},
    {"sink_stop", 0, t_sink_stop, 0},
    {"sink_take", 0, t_sink_take, 0},
    {"c_send", 3, t_c_send, 0},
    {"c_discard", 1, t_c_discard, 0},
    {"c_source_info", 1, t_c_source_info, 0},
    {"c_now", 0, t_c_now, 0},
    {"c_abi", 0, t_c_abi, 0},
    {"peer_open", 1, t_peer_open, 0},
    {"peer_dispose", 0, t_peer_dispose, 0},
    {"peer_take", 0, t_peer_take, 0},
    {"peer_play", 2, t_peer_play, 0},
    {"peer_send", 3, t_peer_send, 0},
};

ERL_NIF_INIT(mob_midi_ios_test_nif, test_funcs, NULL, NULL, NULL, NULL)
