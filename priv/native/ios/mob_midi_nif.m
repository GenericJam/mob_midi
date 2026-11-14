/* mob_midi_nif — iOS MIDI plugin NIF (Objective-C, CoreMIDI).
 *
 * Thin bridge to CoreMIDI: enumerate endpoints, connect a source for input,
 * send to a destination for output, host the app's own virtual endpoints.
 * Message encode/parse lives in Elixir (MobMidi); this layer is raw bytes +
 * device enumeration only.
 *
 * Device ids are CoreMIDI endpoint unique IDs (kMIDIPropertyUniqueID, an
 * SInt32) so they're stable across the BEAM boundary. Every CoreMIDI endpoint
 * is a single port, so `port` is always 0. Incoming packets and the device
 * list are delivered to the pid that called open_input / list_devices, and
 * open_output's result to its caller (captured via enif_self), as:
 *
 *   {:midi, :devices, [%{id, name, direction, manufacturer, type,
 *                        input_ports, output_ports, own}]}
 *   {:midi, :raw, %{device: id, port: 0, bytes: <<...>>, timestamp: ns,
 *                   received: ns}}
 *   {:midi, :device_added | :device_removed, nil}
 *   {:midi, :opened, %{device: id, port: 0, direction: :input | :output}}
 *   {:midi, :opened, %{device: id, direction: :virtual, name: name}}
 *   {:midi, :error, %{device: id, op: atom, reason: atom, dropped: 0}}
 *
 * Timestamps are nanoseconds of mach_absolute_time (MIDITimeStamp's clock),
 * the clock of midi_now_ns/0: an incoming packet's timestamp is the sender's
 * (or its arrival when unstamped); midi_send's timestamp schedules the packet
 * (0 = now).
 *
 * open_output resolves the destination synchronously, so (unlike Android)
 * there is nothing to queue: :opened / :error is sent before it returns.
 * midi_send returns :ok or {:error, :not_open | :no_such_device |
 * :too_large | :send_failed}; a destination must be opened first, as on
 * Android. A virtual device (open_virtual) is a MIDISourceCreate source (what
 * midi_send to its id publishes) plus a MIDIDestinationCreate destination of
 * the same name (what other apps send arrives as :raw with the source's id).
 *
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc, platform: :ios). Hardware endpoints need a device; virtual
 * endpoints (MIDISourceCreate / MIDIDestinationCreate) work on the simulator.
 */
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <erl_nif.h>
#include <mach/mach_time.h>
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

// The app's own virtual devices (open_virtual), guarded by @synchronized on
// g_virtuals: name -> VirtualDevice.
@interface MobMidiVirtual : NSObject
@property(nonatomic) MIDIEndpointRef source;
@property(nonatomic) MIDIEndpointRef destination;
@property(nonatomic) SInt32 uid; // the source's unique id: the device id
@property(nonatomic) ErlNifPid pid;
@end
@implementation MobMidiVirtual
@end

static NSMutableDictionary<NSString *, MobMidiVirtual *> *g_virtuals = nil;

static NSMutableDictionary<NSString *, MobMidiVirtual *> *virtuals(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_virtuals = [NSMutableDictionary dictionary];
  });
  return g_virtuals;
}

static MobMidiVirtual *virtual_for_uid(SInt32 uid) {
  NSMutableDictionary<NSString *, MobMidiVirtual *> *all = virtuals();
  @synchronized(all) {
    for (MobMidiVirtual *v in all.allValues)
      if (v.uid == uid)
        return v;
  }
  return nil;
}

static BOOL is_own_endpoint(MIDIEndpointRef ep) {
  NSMutableDictionary<NSString *, MobMidiVirtual *> *all = virtuals();
  @synchronized(all) {
    for (MobMidiVirtual *v in all.allValues)
      if (v.source == ep || v.destination == ep)
        return YES;
  }
  return NO;
}

// ── time ──────────────────────────────────────────────────────────────────

static mach_timebase_info_data_t timebase(void) {
  static mach_timebase_info_data_t tb;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    mach_timebase_info(&tb);
  });
  return tb;
}

static ErlNifSInt64 host_to_ns(UInt64 host) {
  mach_timebase_info_data_t tb = timebase();
  return (ErlNifSInt64)((__uint128_t)host * tb.numer / tb.denom);
}

static UInt64 ns_to_host(ErlNifSInt64 ns) {
  mach_timebase_info_data_t tb = timebase();
  return (UInt64)((__uint128_t)ns * tb.denom / tb.numer);
}

// ── delivery helpers ──────────────────────────────────────────────────────

static ERL_NIF_TERM midi_env3(ErlNifEnv *e, const char *tag,
                              ERL_NIF_TERM payload) {
  return enif_make_tuple3(e, enif_make_atom(e, "midi"), enif_make_atom(e, tag),
                          payload);
}

static void midi_send_raw(const ErlNifPid *pid, SInt32 device,
                          const UInt8 *data, int len, MIDITimeStamp stamp) {
  if (!pid)
    return;
  UInt64 now = mach_absolute_time();
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM bin;
  unsigned char *buf = enif_make_new_binary(e, len, &bin);
  if (len)
    memcpy(buf, data, len);
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, device), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "port"), enif_make_int(e, 0),
                    &map);
  enif_make_map_put(e, map, enif_make_atom(e, "bytes"), bin, &map);
  enif_make_map_put(e, map, enif_make_atom(e, "timestamp"),
                    enif_make_int64(e, host_to_ns(stamp ? stamp : now)), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "received"),
                    enif_make_int64(e, host_to_ns(now)), &map);
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
                             SInt32 device, const char *direction) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, device), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "port"), enif_make_int(e, 0),
                    &map);
  enif_make_map_put(e, map, enif_make_atom(e, "direction"),
                    enif_make_atom(e, direction), &map);
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

// ── CoreMIDI callbacks ────────────────────────────────────────────────────

static void midi_read_proc(const MIDIPacketList *pktlist, void *readProcRefCon,
                           void *srcConnRefCon) {
  (void)readProcRefCon;
  if (!g_have_input_pid)
    return;
  SInt32 device = (SInt32)(intptr_t)srcConnRefCon;
  const MIDIPacket *p = &pktlist->packet[0];
  for (unsigned i = 0; i < pktlist->numPackets; i++) {
    midi_send_raw(&g_input_pid, device, p->data, p->length, p->timeStamp);
    p = MIDIPacketNext(p);
  }
}

// Another app sent into one of our virtual destinations; refCon is its
// MobMidiVirtual.
static void virtual_read_proc(const MIDIPacketList *pktlist,
                              void *readProcRefCon, void *srcConnRefCon) {
  (void)srcConnRefCon;
  MobMidiVirtual *v = (__bridge MobMidiVirtual *)readProcRefCon;
  ErlNifPid pid = v.pid;
  const MIDIPacket *p = &pktlist->packet[0];
  for (unsigned i = 0; i < pktlist->numPackets; i++) {
    midi_send_raw(&pid, v.uid, p->data, p->length, p->timeStamp);
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
  // Answer THIS caller (a concurrent list_devices may overwrite g_list_pid,
  // the hot-plug subscriber, before we send).
  ErlNifPid self;
  enif_self(env, &self);
  g_list_pid = self;
  g_have_list_pid = YES;
  // No CoreMIDI client: say so instead of answering nothing, so the caller
  // (and MobMidi.SelfTest) can tell it from an empty device list.
  if (!ensure_client()) {
    midi_send_error(env, &self, 0, "list_devices", "no_client");
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
      ERL_NIF_TERM dev = enif_make_new_map(e);
      enif_make_map_put(e, dev, enif_make_atom(e, "id"),
                        enif_make_int(e, endpoint_uid(ep)), &dev);
      enif_make_map_put(
          e, dev, enif_make_atom(e, "name"),
          string_property(e, ep, kMIDIPropertyDisplayName, "MIDI"), &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "direction"),
                        enif_make_atom(e, input ? "input" : "output"), &dev);
      enif_make_map_put(
          e, dev, enif_make_atom(e, "manufacturer"),
          string_property(e, ep, kMIDIPropertyManufacturer, ""), &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "type"),
                        enif_make_atom(e, endpoint_type(ep)), &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "input_ports"),
                        enif_make_int(e, input ? 1 : 0), &dev);
      enif_make_map_put(e, dev, enif_make_atom(e, "output_ports"),
                        enif_make_int(e, input ? 0 : 1), &dev);
      enif_make_map_put(
          e, dev, enif_make_atom(e, "own"),
          enif_make_atom(e, is_own_endpoint(ep) ? "true" : "false"), &dev);
      list = enif_make_list_cell(e, dev, list);
    }
  }

  enif_send(env, &self, e, midi_env3(e, "devices", list));
  enif_free_env(e);
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_open_input(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port))
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
  if (port != 0) {
    midi_send_error(env, &g_input_pid, (SInt32)uid, "open_input", "no_such_port");
    return enif_make_atom(env, "ok");
  }
  if (MIDIPortConnectSource(g_in_port, src, (void *)(intptr_t)uid) != noErr) {
    midi_send_error(env, &g_input_pid, (SInt32)uid, "open_input", "open_failed");
    return enif_make_atom(env, "ok");
  }
  midi_send_opened(env, &g_input_pid, (SInt32)uid, "input");
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_open_output(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  (void)argc;
  int uid, port;
  if (!enif_get_int(env, argv[0], &uid) || !enif_get_int(env, argv[1], &port))
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
  if (port != 0) {
    midi_send_error(env, &pid, (SInt32)uid, "open_output", "no_such_port");
    return enif_make_atom(env, "ok");
  }
  set_output_open((SInt32)uid, YES);
  midi_send_opened(env, &pid, (SInt32)uid, "output");
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

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
                          enif_make_atom(env, reason));
}

// midi_send(uid, port, bytes, timestamp_ns); timestamp 0 = now.
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

  MobMidiVirtual *v = virtual_for_uid((SInt32)uid);
  MIDIEndpointRef dest = 0;
  if (!v) {
    if (!output_is_open((SInt32)uid))
      return error_tuple(env, "not_open");
    dest = dest_for_uid((SInt32)uid);
    if (dest == 0)
      return error_tuple(env, "no_such_device");
  }
  if (port != 0)
    return error_tuple(env, "send_failed");

  // One MIDIPacket carries at most 256 bytes here; refuse rather than
  // truncate (a cut-off SysEx is worse than an error).
  if (bin.size > 256)
    return error_tuple(env, "too_large");
  Byte buffer[512];
  MIDIPacketList *pktlist = (MIDIPacketList *)buffer;
  MIDIPacket *pkt = MIDIPacketListInit(pktlist);
  MIDITimeStamp stamp = ts > 0 ? ns_to_host(ts) : 0;
  pkt = MIDIPacketListAdd(pktlist, sizeof(buffer), pkt, stamp, bin.size,
                          bin.data);
  if (pkt == NULL)
    return error_tuple(env, "send_failed");
  OSStatus st = v ? MIDIReceived(v.source, pktlist)
                  : MIDISend(g_out_port, dest, pktlist);
  if (st != noErr)
    return error_tuple(env, "send_failed");
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_now_ns(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  return enif_make_int64(env, host_to_ns(mach_absolute_time()));
}

// open_virtual(name): create (once) a source + destination of that name and
// make the caller their subscriber.
static ERL_NIF_TERM nif_open_virtual(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin))
    return enif_make_badarg(env);
  ErlNifPid pid;
  enif_self(env, &pid);
  if (!ensure_client()) {
    midi_send_error(env, &pid, 0, "open_virtual", "no_client");
    return enif_make_atom(env, "ok");
  }
  NSString *name = [[NSString alloc] initWithBytes:bin.data
                                            length:bin.size
                                          encoding:NSUTF8StringEncoding];
  if (!name)
    return enif_make_badarg(env);

  NSMutableDictionary<NSString *, MobMidiVirtual *> *all = virtuals();
  MobMidiVirtual *v;
  @synchronized(all) {
    v = all[name];
    if (!v) {
      v = [MobMidiVirtual new];
      MIDIEndpointRef src = 0, dst = 0;
      if (MIDISourceCreate(g_client, (__bridge CFStringRef)name, &src) !=
              noErr ||
          MIDIDestinationCreate(g_client, (__bridge CFStringRef)name,
                                virtual_read_proc, (__bridge void *)v,
                                &dst) != noErr) {
        if (src)
          MIDIEndpointDispose(src);
        midi_send_error(env, &pid, 0, "open_virtual", "open_failed");
        return enif_make_atom(env, "ok");
      }
      v.source = src;
      v.destination = dst;
      v.uid = endpoint_uid(src);
      all[name] = v; // keeps v alive for the read proc's refCon
    }
    v.pid = pid;
  }

  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM name_term;
  memcpy(enif_make_new_binary(e, bin.size, &name_term), bin.data, bin.size);
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "device"),
                    enif_make_int(e, v.uid), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "direction"),
                    enif_make_atom(e, "virtual"), &map);
  enif_make_map_put(e, map, enif_make_atom(e, "name"), name_term, &map);
  enif_send(env, &pid, e, midi_env3(e, "opened", map));
  enif_free_env(e);
  return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
// The Bluetooth central NIFs are Android-only: MobMidi gates them off iOS, so
// they aren't registered here.
static ErlNifFunc nif_funcs[] = {
    {"midi_list_devices", 0, nif_list_devices, 0},
    {"midi_open_input", 2, nif_open_input, 0},
    {"midi_open_output", 2, nif_open_output, 0},
    {"midi_close", 1, nif_close, 0},
    {"midi_send", 4, nif_send, 0},
    {"midi_now_ns", 0, nif_now_ns, 0},
    {"midi_open_virtual", 1, nif_open_virtual, 0},
};

ERL_NIF_INIT(mob_midi_nif, nif_funcs, NULL, NULL, NULL, NULL)
