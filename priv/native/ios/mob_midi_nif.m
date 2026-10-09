/* mob_midi_nif — iOS MIDI plugin NIF (Objective-C, CoreMIDI).
 *
 * Thin bridge to CoreMIDI: enumerate endpoints, connect a source for input,
 * send to a destination for output. Message encode/parse lives in Elixir
 * (MobMidi); this layer is raw bytes + device enumeration only.
 *
 * Device ids are CoreMIDI endpoint unique IDs (kMIDIPropertyUniqueID, an
 * SInt32) so they're stable across the BEAM boundary. Incoming packets and the
 * device list are delivered to the pid that called open_input / list_devices,
 * and open_output's result to its caller (captured via enif_self), as:
 *
 *   {:midi, :devices, [%{id, name, direction}]}
 *   {:midi, :raw, %{device: id, bytes: <<...>>}}
 *   {:midi, :device_added | :device_removed, nil}
 *   {:midi, :opened, %{device: id, direction: :output}}
 *   {:midi, :error, %{device: id, op: atom, reason: atom, dropped: 0}}
 *
 * open_output resolves the destination synchronously, so (unlike Android)
 * there is nothing to queue: :opened / :error is sent before it returns.
 * midi_send returns :ok or {:error, :not_open | :no_such_device |
 * :too_large | :send_failed}; a destination must be opened first, as on
 * Android.
 *
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc, platform: :ios). Hardware endpoints need a device; virtual
 * endpoints (MIDISourceCreate / MIDIDestinationCreate) work on the simulator.
 */
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <erl_nif.h>
#include <string.h>

static MIDIClientRef g_client = 0;
static MIDIPortRef g_in_port = 0;
static MIDIPortRef g_out_port = 0;

// Subscriber pids: input packets go to whoever opened an input; the device
// list goes to whoever called list_devices. Last caller wins (single consumer).
static ErlNifPid g_input_pid;
static BOOL g_have_input_pid = NO;
static ErlNifPid g_list_pid;
static BOOL g_have_list_pid = NO;

// Destination uids opened via open_output; guarded by @synchronized on itself.
static NSMutableSet<NSNumber *> *g_open_outputs = nil;

// ── delivery helpers ──────────────────────────────────────────────────────

static ERL_NIF_TERM midi_env3(ErlNifEnv *e, const char *tag,
                              ERL_NIF_TERM payload) {
  return enif_make_tuple3(e, enif_make_atom(e, "midi"), enif_make_atom(e, tag),
                          payload);
}

static void midi_send_raw(const ErlNifPid *pid, SInt32 device,
                          const UInt8 *data, int len) {
  if (!pid)
    return;
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM bin;
  unsigned char *buf = enif_make_new_binary(e, len, &bin);
  if (len)
    memcpy(buf, data, len);
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, device), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "bytes"), bin, &map);
  enif_send(NULL, (ErlNifPid *)pid, e, midi_env3(e, "raw", map));
  enif_free_env(e);
}

// Both are only called from inside a NIF, so they pass the caller's env to
// enif_send (NULL is for threads ERTS doesn't manage).
static void midi_send_error(ErlNifEnv *caller, const ErlNifPid *pid,
                            SInt32 device, const char *op,
                            const char *reason) {
  if (!pid)
    return;
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, device), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "op"), enif_make_atom(e, op),
                    &map);
  enif_make_map_put(e, map, enif_make_atom(e, "reason"),
                    enif_make_atom(e, reason), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "dropped"), enif_make_int(e, 0),
                    &map);
  enif_send(caller, (ErlNifPid *)pid, e, midi_env3(e, "error", map));
  enif_free_env(e);
}

static void midi_send_opened(ErlNifEnv *caller, const ErlNifPid *pid,
                             SInt32 device) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, device), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "direction"),
                    enif_make_atom(e, "output"), &map);
  enif_send(caller, (ErlNifPid *)pid, e, midi_env3(e, "opened", map));
  enif_free_env(e);
}

static NSMutableSet<NSNumber *> *open_outputs(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_open_outputs = [NSMutableSet set];
  });
  return g_open_outputs;
}

static void set_output_open(SInt32 uid, BOOL open) {
  NSMutableSet<NSNumber *> *set = open_outputs();
  @synchronized(set) {
    if (open)
      [set addObject:@(uid)];
    else
      [set removeObject:@(uid)];
  }
}

static BOOL output_is_open(SInt32 uid) {
  NSMutableSet<NSNumber *> *set = open_outputs();
  @synchronized(set) {
    return [set containsObject:@(uid)];
  }
}

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

// ── CoreMIDI callbacks ────────────────────────────────────────────────────

static void midi_read_proc(const MIDIPacketList *pktlist, void *readProcRefCon,
                           void *srcConnRefCon) {
  (void)readProcRefCon;
  if (!g_have_input_pid)
    return;
  SInt32 device = (SInt32)(intptr_t)srcConnRefCon;
  const MIDIPacket *p = &pktlist->packet[0];
  for (unsigned i = 0; i < pktlist->numPackets; i++) {
    midi_send_raw(&g_input_pid, device, p->data, p->length);
    p = MIDIPacketNext(p);
  }
}

static void midi_notify_proc(const MIDINotification *msg, void *refCon) {
  (void)refCon;
  if (!g_have_list_pid)
    return;
  if (msg->messageID == kMIDIMsgObjectAdded ||
      msg->messageID == kMIDIMsgObjectRemoved) {
    const char *tag = (msg->messageID == kMIDIMsgObjectAdded)
                          ? "device_added"
                          : "device_removed";
    ErlNifEnv *e = enif_alloc_env();
    // Payload is best-effort: just signal a change so the screen re-lists.
    enif_send(NULL, &g_list_pid, e,
              midi_env3(e, tag, enif_make_atom(e, "nil")));
    enif_free_env(e);
  }
}

static BOOL ensure_client(void) {
  if (g_client)
    return YES;
  OSStatus st =
      MIDIClientCreate(CFSTR("mob_midi"), midi_notify_proc, NULL, &g_client);
  if (st != noErr)
    return NO;
  MIDIInputPortCreate(g_client, CFSTR("mob_midi_in"), midi_read_proc, NULL,
                      &g_in_port);
  MIDIOutputPortCreate(g_client, CFSTR("mob_midi_out"), &g_out_port);
  return g_client != 0;
}

// ── NIFs ──────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_list_devices(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  enif_self(env, &g_list_pid);
  g_have_list_pid = YES;
  // No CoreMIDI client: say so instead of answering nothing, so the caller
  // (and MobMidi.SelfTest) can tell it from an empty device list.
  if (!ensure_client()) {
    midi_send_error(env, &g_list_pid, 0, "list_devices", "no_client");
    return enif_make_atom(env, "ok");
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
      CFStringRef cfname = NULL;
      MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cfname);
      char namebuf[128] = "MIDI";
      if (cfname) {
        CFStringGetCString(cfname, namebuf, sizeof(namebuf),
                           kCFStringEncodingUTF8);
        CFRelease(cfname);
      }
      ERL_NIF_TERM nb;
      size_t nlen = strlen(namebuf);
      unsigned char *nbp = enif_make_new_binary(e, nlen, &nb);
      memcpy(nbp, namebuf, nlen);

      ERL_NIF_TERM dev = enif_make_new_map(e);
      enif_make_map_put(e, dev, enif_make_atom(e, "id"),
                        enif_make_int(e, endpoint_uid(ep)), &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "name"), nb, &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "direction"),
                        enif_make_atom(e, input ? "input" : "output"), &dev);
      list = enif_make_list_cell(e, dev, list);
    }
  }

  enif_send(NULL, &g_list_pid, e, midi_env3(e, "devices", list));
  enif_free_env(e);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_open_input(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  if (!enif_get_int(env, argv[0], &uid))
    return enif_make_badarg(env);
  enif_self(env, &g_input_pid);
  g_have_input_pid = YES;
  if (!ensure_client()) {
    midi_send_error(env, &g_input_pid, (SInt32)uid, "open_input", "no_client");
    return enif_make_atom(env, "ok");
  }
  MIDIEndpointRef src = source_for_uid((SInt32)uid);
  if (src == 0) {
    midi_send_error(env, &g_input_pid, (SInt32)uid, "open_input", "no_such_device");
    return enif_make_atom(env, "ok");
  }
  MIDIPortConnectSource(g_in_port, src, (void *)(intptr_t)uid);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_open_output(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  if (!enif_get_int(env, argv[0], &uid))
    return enif_make_badarg(env);
  ErlNifPid pid;
  enif_self(env, &pid);
  // Output is a shared port; sending targets a destination by uid. Opening
  // checks the destination exists and marks it sendable.
  if (!ensure_client()) {
    midi_send_error(env, &pid, (SInt32)uid, "open_output", "no_client");
    return enif_make_atom(env, "ok");
  }
  if (dest_for_uid((SInt32)uid) == 0) {
    midi_send_error(env, &pid, (SInt32)uid, "open_output", "no_such_device");
    return enif_make_atom(env, "ok");
  }
  set_output_open((SInt32)uid, YES);
  midi_send_opened(env, &pid, (SInt32)uid);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  if (!enif_get_int(env, argv[0], &uid))
    return enif_make_badarg(env);
  set_output_open((SInt32)uid, NO);
  MIDIEndpointRef src = source_for_uid((SInt32)uid);
  if (src && g_in_port)
    MIDIPortDisconnectSource(g_in_port, src);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_send(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid;
  ErlNifBinary bin;
  if (!enif_get_int(env, argv[0], &uid))
    return enif_make_badarg(env);
  if (!enif_inspect_binary(env, argv[1], &bin) &&
      !enif_inspect_iolist_as_binary(env, argv[1], &bin))
    return enif_make_badarg(env);
  if (!output_is_open((SInt32)uid))
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "not_open"));
  MIDIEndpointRef dest = dest_for_uid((SInt32)uid);
  if (dest == 0)
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_such_device"));

  // One MIDIPacket carries at most 256 bytes here; refuse rather than
  // truncate (a cut-off SysEx is worse than an error).
  if (bin.size > 256)
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "too_large"));
  Byte buffer[512];
  MIDIPacketList *pktlist = (MIDIPacketList *)buffer;
  MIDIPacket *pkt = MIDIPacketListInit(pktlist);
  pkt = MIDIPacketListAdd(pktlist, sizeof(buffer), pkt, 0, bin.size, bin.data);
  if (pkt == NULL)
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "send_failed"));
  if (MIDISend(g_out_port, dest, pktlist) != noErr)
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_atom(env, "send_failed"));
  return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"midi_list_devices", 0, nif_list_devices, 0},
    {"midi_open_input", 1, nif_open_input, 0},
    {"midi_open_output", 1, nif_open_output, 0},
    {"midi_close", 1, nif_close, 0},
    {"midi_send", 2, nif_send, 0},
};

ERL_NIF_INIT(mob_midi_nif, nif_funcs, NULL, NULL, NULL, NULL)
