// mob_midi plugin — Android bridge (android.media.midi / MidiManager).
//
// Enumerates MIDI devices, opens input (receive) / output (send) ports, hosts
// the app's own virtual MIDI devices, scans for and connects BLE-MIDI devices.
// Message encode/parse lives in Elixir (MobMidi); bytes move through
// mob_midi_core.c (the plugin's android.jni_source):
//
//   receive: each opened input port is a "source" (nativeSourceOpen) with a
//            generation; its MidiReceiver hands every chunk to nativeReceive,
//            which drops a stale generation and routes the bytes to the BEAM
//            ({:midi, :raw, ...}) and/or the native sink of mob_midi.h.
//   send:    each open output has a slot in C (nativeOutputOpen) holding a
//            queue ordered by target time, and a Dispatcher thread here that
//            waits in nativeNextSend and calls MidiReceiver.send(bytes, stamp)
//            when a message is due. The BEAM (midi_send) and native code
//            (mob_midi_send) enqueue in C directly; Kotlin's send() only sees
//            ports still opening. A receiver that stops reading blocks only
//            its own Dispatcher, never the BEAM; its queue then refuses
//            sends until it has drained, and C sends the opener
//            {:midi, :drained, ...} (mob_midi_queue.h).
//
// The zig NIF (mob_midi_nif.zig) calls the @JvmStatic entry points and
// implements the nativeDeliver* thunks. MobPluginBootstrap.registerAll()
// calls register() at startup and hands it the Activity (MobActivityAware).
//
// A "device id" is MidiDeviceInfo.id. Ports are numbered per direction as
// Android numbers them, seen from the app: open_input reads the device's
// output port n (Android's outputPortCount = our input_ports), open_output
// writes its input port n (inputPortCount = our output_ports).
//
// Opening an output is asynchronous (MidiManager.openDevice calls back on the
// main looper). Sends made between openOutput and that callback are queued
// here (bounded by PENDING_CHUNKS, the C queue's size) and moved, in order, into the C queue
// once the port exists. The opener then gets {:midi, :opened, %{device, port,
// direction: :output, handle}}; on failure {:midi, :error, %{device, op:
// :open_output, reason, dropped}} and the queue is discarded.
//
// Timestamps are System.nanoTime() (CLOCK_MONOTONIC), the clock of
// MobMidi.now_ns/0 and mob_midi_now_ns().
package io.mob.midi

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiDeviceService
import android.media.midi.MidiDeviceStatus
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelUuid
import android.os.Process
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicIntegerArray
import org.json.JSONArray
import org.json.JSONObject

object MobMidiBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    @JvmStatic external fun nativeRegister()

    // Text that carries names (device lists, a virtual device's name, BLE
    // names and addresses) crosses JNI as UTF-8 byte arrays both ways: JNI's
    // String functions speak modified UTF-8, which turns a character outside
    // the BMP (an emoji in a device name) into surrogate bytes that aren't
    // valid UTF-8 and that NewStringUTF rejects.

    // {:midi, :devices, ...} carries a JSON array of device objects.
    @JvmStatic external fun nativeDeliverMidiDevices(pid: Long, json: ByteArray)

    // {:midi, :opened, %{device, port, direction}} (direction "input" |
    // "output") plus the input's `source` or the output's `handle` (0: none).
    @JvmStatic external fun nativeDeliverMidiOpened(
        pid: Long,
        device: Int,
        port: Int,
        direction: String,
        source: Int,
        handle: Long,
    )

    // {:midi, :opened, %{device, direction: :virtual, name}}.
    @JvmStatic external fun nativeDeliverMidiVirtualOpened(pid: Long, device: Int, name: ByteArray)

    // {:midi, :virtual_status, %{device, senders, listeners}}.
    @JvmStatic external fun nativeDeliverMidiVirtualStatus(pid: Long, device: Int, senders: Int, listeners: Int)

    // {:midi, tag, value}: value an atom, or nil when null.
    @JvmStatic external fun nativeDeliverMidiEvent(pid: Long, tag: String, value: String?)

    // {:midi, :bluetooth_device, %{address, name, rssi}}.
    @JvmStatic external fun nativeDeliverMidiBluetoothDevice(pid: Long, address: ByteArray, name: ByteArray, rssi: Int)

    // {:midi, :connected, %{device, address}}.
    @JvmStatic external fun nativeDeliverMidiConnected(pid: Long, device: Int, address: ByteArray)

    // {:midi, :error, %{device, op, reason, dropped}} — op/reason become atoms.
    @JvmStatic external fun nativeDeliverMidiError(
        pid: Long,
        device: Int,
        op: String,
        reason: String,
        dropped: Int,
    )

    // ── mob_midi_core.c ─────────────────────────────────────────────────────

    // A free source for (device, port) routed to `route` (ROUTE_*), as
    // (source shl 32) or generation; -1 when all are taken.
    @JvmStatic external fun nativeSourceOpen(device: Int, port: Int, pid: Long, route: Int): Long

    // A new generation for an open source (0 if it isn't open).
    @JvmStatic external fun nativeSourceRenew(source: Int): Int

    // Given back; returns once no delivery on it is in progress.
    @JvmStatic external fun nativeSourceClose(source: Int)

    // One received chunk, for the source's `generation` (dropped if stale).
    @JvmStatic external fun nativeReceive(
        source: Int,
        generation: Int,
        msg: ByteArray,
        offset: Int,
        count: Int,
        timestamp: Long,
    )

    // An output slot (state: opening) as its mob_midi.h handle; 0 = none
    // free. `pid` hears its {:midi, :drained, ...}.
    @JvmStatic external fun nativeOutputOpen(device: Int, port: Int, virtualPort: Boolean, pid: Long): Long

    // Sends to the handle are accepted from now on. `refused`: a send was
    // refused while it was opening, so it starts out refusing until drained.
    @JvmStatic external fun nativeOutputReady(handle: Long, refused: Boolean)

    // A later opener of an open output gets its events.
    @JvmStatic external fun nativeOutputOwner(handle: Long, pid: Long)

    // Closed: its queue is dropped and its Dispatcher ends.
    @JvmStatic external fun nativeOutputClose(handle: Long)

    // An own virtual output's listener count (0: sends answer :no_listener).
    @JvmStatic external fun nativeOutputListeners(handle: Long, listeners: Int)

    // Into the handle's queue whatever its state; a CORE_* code.
    @JvmStatic external fun nativeEnqueue(handle: Long, bytes: ByteArray, timestamp: Long): Int

    // The Dispatcher's wait: the next due bytes into buf, their stamp into
    // meta[0], the count returned; -1 once the output is closed.
    @JvmStatic external fun nativeNextSend(handle: Long, buf: ByteArray, meta: LongArray): Int

    // Routes (open_input / open_virtual `deliver:`): bit 0 BEAM, bit 1 sink.
    private const val ROUTE_BEAM = 1
    private const val ROUTE_NATIVE = 2

    // mob_midi.h codes.
    private const val CORE_OK = 0
    private const val CORE_NOT_OPEN = -1
    private const val CORE_QUEUE_FULL = -2
    private const val CORE_NO_LISTENER = -3

    // Bytes per MidiReceiver.send from a Dispatcher (DISPATCH_MAX in C).
    private const val DISPATCH_MAX = 1024

    // send() result codes; mob_midi_nif.zig maps them to :ok / :queued /
    // {:error, :not_open | :queue_full | :send_failed | :no_listener}.
    private const val SEND_OK = 0
    private const val SEND_QUEUED = 1
    private const val SEND_NOT_OPEN = 2
    private const val SEND_QUEUE_FULL = 3
    private const val SEND_FAILED = 4
    private const val SEND_NO_LISTENER = 5

    // What may be buffered per port while its output is opening, counted in
    // the C queue's 64-byte chunks (MOB_MIDI_QUEUE_CAPACITY x
    // MOB_MIDI_CHUNK_BYTES), so the whole pending queue always fits the C
    // queue on open. More before the port exists is the caller's bug: extra
    // sends get SEND_QUEUE_FULL instead of growing without bound.
    private const val PENDING_CHUNKS = 256
    private const val CHUNK_BYTES = 64

    // The BLE-MIDI GATT service (MIDI over Bluetooth LE 1.0).
    private const val BLE_MIDI_SERVICE = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"

    // Mob.Permissions capability that grants scanning for + connecting BLE-MIDI devices.
    private const val BLUETOOTH_CAPABILITY = "midi_bluetooth"

    // MidiDeviceInfo.PROPERTY_SERVICE_INFO is @hide; its key has been
    // "service_info" since API 23.
    private const val PROPERTY_SERVICE_INFO = "service_info"

    private class Pending(val bytes: ByteArray, val timestamp: Long)

    private class PendingOutput(val pids: MutableList<Long>) {
        val queue = ArrayDeque<Pending>()
        var chunks = 0

        // A send was refused (SEND_QUEUE_FULL): the port opens refusing, so
        // its opener hears :drained once it has room.
        var refused = false
    }

    // An open input port: its Android port and its C source.
    private class OpenInput(val port: MidiOutputPort, val source: Int)

    // An open output: its Android port (null for an own virtual device's) and
    // its C handle.
    private class OpenOutput(val port: MidiInputPort?, val handle: Long)

    // Takes due bytes out of an output's C queue and hands them to Android.
    // One per open output, so a receiver that stops reading (a stalled app on
    // our virtual port) holds up only its own queue.
    private class Dispatcher(private val handle: Long, private val target: MidiReceiver) :
        Thread("mob_midi_out") {
        init {
            isDaemon = true
        }

        override fun run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buf = ByteArray(DISPATCH_MAX)
            val meta = LongArray(1)
            while (true) {
                val n = nativeNextSend(handle, buf, meta)
                if (n < 0) return
                try {
                    target.send(buf, 0, n, meta[0])
                } catch (e: IOException) {
                    // The receiver went away mid-send; its close follows.
                } catch (e: IllegalStateException) {
                    // Closed under us.
                }
            }
        }
    }

    // An own virtual device's output port: whatever the service's receiver is
    // now (the service comes and goes with the apps that open the device).
    private class VirtualOut(private val deviceId: Int, private val port: Int) : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            val receivers = virtualServices[deviceId]?.outputPortReceivers ?: return
            receivers.getOrNull(port)?.send(msg, offset, count, timestamp)
        }
    }

    // An open_virtual subscription: the C sources of the device's input ports
    // (and their current generations) and the handles of its output ports.
    private class Virtual(
        val pid: Long,
        val sources: IntArray,
        val generations: AtomicIntegerArray,
        val handles: LongArray,
    )

    private var activityRef: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())

    // Device lookups (MidiManager.getDevices), device opens, port opens and
    // closes, hot-plug: binder calls into the MIDI service or other apps'
    // MIDI services. A service that never answers (Android can't close a
    // port while a write to a client that stopped reading is blocked) must
    // stall this thread, not a BEAM scheduler or the UI thread. So the NIF
    // entry points only post here (and touch local state), and every event
    // they answer with is sent from here, not from a scheduler thread.
    private val worker: Handler by lazy {
        val thread = HandlerThread("mob_midi")
        thread.start()
        Handler(thread.looper)
    }

    private val openDevices = ConcurrentHashMap<Int, MidiDevice>()
    private val inputs = ConcurrentHashMap<Long, OpenInput>() // (device, port) -> receive port

    // Guards outputs + pendingOutputs together, so a send either goes to the
    // port, joins the queue before the flush, or sees NOT_OPEN — never lost.
    private val sendLock = Any()
    private val outputs = HashMap<Long, OpenOutput>() // (device, port) -> send port
    private val pendingOutputs = HashMap<Long, PendingOutput>()

    // close(device) takes the next closeSeq under sendLock and records it in
    // lastClose. An open (input, virtual) takes closeSeq when it is asked
    // for; on the worker, under the lock that also guards its registration
    // and its :opened, it gives up if its device was closed since. So after
    // close() returns nothing of an open asked for before it arrives.
    private var closeSeq = 0L
    private val lastClose = HashMap<Int, Long>()

    private fun closedSince(deviceId: Int, seq: Long): Boolean =
        synchronized(sendLock) { (lastClose[deviceId] ?: 0L) > seq }

    private fun openSeq(): Long = synchronized(sendLock) { closeSeq }

    private fun utf8(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

    // The app's own virtual devices (MobMidiDeviceService subclasses), by
    // device id: open_virtual's subscription, the running services and the
    // last status (senders, listeners, then each output port's listeners).
    private val virtuals = ConcurrentHashMap<Int, Virtual>()
    private val virtualServices = ConcurrentHashMap<Int, MobMidiDeviceService>()
    private val virtualStatus = ConcurrentHashMap<Int, MidiDeviceStatus>()
    private val virtualLock = Any()

    // Hot-plug events go to the last list_devices caller (0 = nobody yet).
    @Volatile private var listPid = 0L
    private var callbackRegistered = false

    private var scanCallback: ScanCallback? = null
    private var scanPid = 0L
    private val scanSeen = HashSet<String>()

    private fun key(device: Int, port: Int): Long = (device.toLong() shl 32) or (port.toLong() and 0xffffffffL)

    private fun deviceOf(key: Long): Int = (key shr 32).toInt()

    // Called by the generated MobPluginBootstrap.registerAll BEFORE setActivity,
    // to cache this jclass + the nativeDeliver* method ids.
    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // MobActivityAware: receive the host Activity at startup (instance dispatch,
    // so not @JvmStatic). Hot-plug callbacks start here.
    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
        if (callbackRegistered) return
        val mm = activity.getSystemService(Context.MIDI_SERVICE) as? MidiManager ?: return
        if (Build.VERSION.SDK_INT >= 33) {
            mm.registerDeviceCallback(MidiManager.TRANSPORT_MIDI_BYTE_STREAM, { worker.post(it) }, deviceCallback)
        } else {
            @Suppress("DEPRECATION")
            mm.registerDeviceCallback(deviceCallback, worker)
        }
        callbackRegistered = true
    }

    // MobPermissionProvider: Mob.Permissions.request(socket, :midi_bluetooth)
    // asks for what scanning for and connecting BLE-MIDI devices needs. API
    // <= 30: fine location (BLUETOOTH / BLUETOOTH_ADMIN are install-time).
    // API 31+: the Nearby-devices permissions, plus location, because the
    // manifest's BLUETOOTH_SCAN can't claim neverForLocation (mob_dev writes
    // permissions without flags), so scans need it.
    override fun permissionsFor(cap: String): Array<String>? =
        if (cap != BLUETOOTH_CAPABILITY) {
            null
        } else if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun midiManager(): MidiManager? =
        activityRef?.get()?.getSystemService(Context.MIDI_SERVICE) as? MidiManager

    private val deviceCallback = object : MidiManager.DeviceCallback() {
        override fun onDeviceAdded(device: MidiDeviceInfo) {
            val pid = listPid
            if (pid != 0L) nativeDeliverMidiEvent(pid, "device_added", null)
        }

        override fun onDeviceRemoved(device: MidiDeviceInfo) {
            // Its ports are dead; release them so a reconnect opens fresh ones.
            close(device.id)
            val pid = listPid
            if (pid != 0L) nativeDeliverMidiEvent(pid, "device_removed", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun allDevices(mm: MidiManager): Array<MidiDeviceInfo> =
        if (Build.VERSION.SDK_INT >= 33) {
            mm.getDevicesForTransport(MidiManager.TRANSPORT_MIDI_BYTE_STREAM).toTypedArray()
        } else {
            mm.devices
        }

    private fun findDevice(mm: MidiManager, id: Int): MidiDeviceInfo? = allDevices(mm).firstOrNull { it.id == id }

    // Open the device once and share it between inputs and outputs, so opening
    // several ports of one device doesn't leak a second MidiDevice. Called on
    // the worker; `cb` runs there too.
    private fun withDevice(mm: MidiManager, info: MidiDeviceInfo, cb: (MidiDevice?) -> Unit) {
        openDevices[info.id]?.let { device ->
            worker.post { cb(device) }
            return
        }
        mm.openDevice(info, { device ->
            if (device == null) {
                cb(null)
            } else {
                val prev = openDevices.putIfAbsent(info.id, device)
                if (prev != null) closeQuietly(device)
                cb(prev ?: device)
            }
        }, worker)
    }

    // A virtual device declared by this app (a MobMidiDeviceService subclass in
    // its manifest).
    private fun isOwn(info: MidiDeviceInfo): Boolean {
        if (info.type != MidiDeviceInfo.TYPE_VIRTUAL) return false
        val pkg = activityRef?.get()?.packageName ?: return false
        @Suppress("DEPRECATION")
        val service = info.properties.getParcelable<ServiceInfo>(PROPERTY_SERVICE_INFO)
        return service?.packageName == pkg
    }

    // A Bluetooth device's address; "" for USB and virtual devices.
    private fun addressOf(info: MidiDeviceInfo): String {
        @Suppress("DEPRECATION")
        val bt = info.properties.getParcelable<BluetoothDevice>(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE)
        return bt?.address ?: ""
    }

    // An empty list means MidiManager answered with no devices. When there is
    // no MidiManager to ask, the caller gets {:midi, :error, %{op:
    // :list_devices, reason: :no_activity | :no_midi_service}} instead, so
    // "no devices" is never confused with "never asked" (MobMidi.SelfTest
    // relies on this). The caller also becomes the hot-plug subscriber.
    @JvmStatic
    fun listDevices(pid: Long) {
        listPid = pid
        worker.post { deliverDevices(pid) }
    }

    private fun deliverDevices(pid: Long) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverMidiError(pid, 0, "list_devices", "no_activity", 0); return
        }
        // null when the device lacks PackageManager.FEATURE_MIDI.
        val mm = activity.getSystemService(Context.MIDI_SERVICE) as? MidiManager ?: run {
            nativeDeliverMidiError(pid, 0, "list_devices", "no_midi_service", 0); return
        }
        val arr = JSONArray()
        for (info in allDevices(mm)) {
            // A device with output ports can be read from (an input source for us);
            // with input ports it can be written to (an output for us).
            val direction =
                when {
                    info.outputPortCount > 0 && info.inputPortCount > 0 -> "both"
                    info.outputPortCount > 0 -> "input"
                    else -> "output"
                }
            val type =
                when (info.type) {
                    MidiDeviceInfo.TYPE_USB -> "usb"
                    MidiDeviceInfo.TYPE_BLUETOOTH -> "bluetooth"
                    MidiDeviceInfo.TYPE_VIRTUAL -> "virtual"
                    else -> "other"
                }
            arr.put(
                JSONObject()
                    .put("id", info.id)
                    .put("name", deviceName(info))
                    .put("direction", direction)
                    .put("manufacturer", info.properties.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER) ?: "")
                    .put("type", type)
                    .put("address", addressOf(info))
                    .put("input_ports", info.outputPortCount)
                    .put("output_ports", info.inputPortCount)
                    .put("own", isOwn(info)),
            )
        }
        nativeDeliverMidiDevices(pid, utf8(arr.toString()))
    }

    // USB/BLE devices carry PROPERTY_NAME; virtual (MidiDeviceService) devices
    // often only declare manufacturer + product.
    private fun deviceName(info: MidiDeviceInfo): String {
        val props = info.properties
        props.getString(MidiDeviceInfo.PROPERTY_NAME)?.takeIf { it.isNotBlank() }?.let { return it }
        val parts = listOfNotNull(
            props.getString(MidiDeviceInfo.PROPERTY_MANUFACTURER),
            props.getString(MidiDeviceInfo.PROPERTY_PRODUCT),
        ).filter { it.isNotBlank() }
        return if (parts.isEmpty()) "MIDI" else parts.joinToString(" ")
    }

    // ── Input ───────────────────────────────────────────────────────────────

    // A source's receiver: stamps every chunk with the generation it was
    // opened with, so C drops what arrives after the port closed.
    private class SourceReceiver(val source: Int, @Volatile var generation: Int) : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            if (count > 0) nativeReceive(source, generation, msg, offset, count, timestamp)
        }
    }

    // port -1 opens every output port of the device, each its own source and
    // its own {:midi, :opened, ...}. route: ROUTE_* bits.
    @JvmStatic
    fun openInput(pid: Long, deviceId: Int, port: Int, route: Int) {
        val seq = openSeq()
        worker.post { startOpenInput(pid, deviceId, port, route, seq) }
    }

    private fun startOpenInput(pid: Long, deviceId: Int, port: Int, route: Int, seq: Long) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_midi_service", 0); return
        }
        val info = findDevice(mm, deviceId) ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_such_device", 0); return
        }
        val ports = if (port == -1) (0 until info.outputPortCount).toList() else listOf(port)
        if (ports.isEmpty() || ports.any { it < 0 || it >= info.outputPortCount }) {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_such_port", 0); return
        }
        withDevice(mm, info) { device ->
            for (p in ports) openInputPort(pid, deviceId, p, route, device, seq)
            releaseUnusedDevice(deviceId)
        }
    }

    private fun openInputPort(pid: Long, deviceId: Int, port: Int, route: Int, device: MidiDevice?, seq: Long) {
        val out = device?.openOutputPort(port)
        if (out == null) {
            nativeDeliverMidiError(pid, deviceId, "open_input", if (device == null) "open_failed" else "no_output_port", 0)
            return
        }
        val k = key(deviceId, port)
        // Under sendLock with close(): either close() ran first (give up) or
        // this input is registered and its :opened sent before close() takes
        // the lock, and close() then closes it.
        val packed = synchronized(sendLock) {
            if (closedSince(deviceId, seq)) {
                null
            } else {
                // Reopening a port replaces its subscription.
                closeInput(k)
                nativeSourceOpen(deviceId, port, pid, route).also {
                    if (it >= 0) {
                        val source = (it shr 32).toInt()
                        inputs[k] = OpenInput(out, source)
                        nativeDeliverMidiOpened(pid, deviceId, port, "input", source, 0)
                    }
                }
            }
        }
        if (packed == null || packed < 0) {
            closeQuietly(out)
            nativeDeliverMidiError(pid, deviceId, "open_input", if (packed == null) "closed" else "no_free_source", 0)
            return
        }
        // After :opened, so no bytes precede it. A close() since then has
        // closed the source: what this receiver hands over is dropped.
        out.connect(SourceReceiver((packed shr 32).toInt(), packed.toInt()))
    }

    private fun closeInput(k: Long) {
        val open = inputs.remove(k) ?: return
        // Source first: once it returns, nothing more of this port is delivered.
        nativeSourceClose(open.source)
        closeLater(open.port)
    }

    // ── Output ──────────────────────────────────────────────────────────────

    // The pending entry is made here, at once, so sends right after
    // open_output queue up; the device lookup and the open run on the worker.
    @JvmStatic
    fun openOutput(pid: Long, deviceId: Int, port: Int) {
        val k = key(deviceId, port)
        synchronized(sendLock) {
            val open = outputs[k]
            if (open != null) {
                val handle = open.handle
                worker.post { reopenOutput(pid, deviceId, port, handle) }
                return
            }
            // A second open while the first is in flight just waits on it.
            val pending = pendingOutputs[k]
            if (pending != null) {
                pending.pids.add(pid); return
            }
            pendingOutputs[k] = PendingOutput(mutableListOf(pid))
        }
        worker.post { startOpenOutput(deviceId, port) }
    }

    // An output opened again: :opened (and its events) for the new opener,
    // unless close() came first.
    private fun reopenOutput(pid: Long, deviceId: Int, port: Int, handle: Long) {
        synchronized(sendLock) {
            if (outputs[key(deviceId, port)]?.handle == handle) {
                nativeOutputOwner(handle, pid)
                nativeDeliverMidiOpened(pid, deviceId, port, "output", 0, handle)
                return
            }
        }
        nativeDeliverMidiError(pid, deviceId, "open_output", "closed", 0)
    }

    private fun startOpenOutput(deviceId: Int, port: Int) {
        val mm = midiManager()
        val info = mm?.let { findDevice(it, deviceId) }
        val failure =
            when {
                mm == null -> "no_midi_service"
                info == null -> "no_such_device"
                // send_raw to an own device's id already means "out of it" (its
                // output ports, open_virtual): writing into its input ports as a
                // client too would make (device, port) ambiguous.
                isOwn(info) -> "own_device"
                port < 0 || port >= info.inputPortCount -> "no_such_port"
                else -> null
            }
        if (failure != null) {
            failOutput(deviceId, port, failure)
            return
        }
        withDevice(mm!!, info!!) { device -> finishOpenOutput(deviceId, port, device) }
    }

    // The open failed before it reached the device: its openers (unless
    // close() cancelled it already) get the error, its queue is dropped.
    private fun failOutput(deviceId: Int, port: Int, reason: String) {
        val pending = synchronized(sendLock) { pendingOutputs.remove(key(deviceId, port)) } ?: return
        for (pid in pending.pids) nativeDeliverMidiError(pid, deviceId, "open_output", reason, pending.queue.size)
    }

    private fun finishOpenOutput(deviceId: Int, port: Int, device: MidiDevice?) {
        val k = key(deviceId, port)
        val inputPort = device?.openInputPort(port)
        var failure: String? = null
        val pending = synchronized(sendLock) {
            val pending = pendingOutputs.remove(k)
            when {
                // close() ran while we were opening: nobody wants this port.
                pending == null -> closeQuietly(inputPort)
                device == null -> failure = "open_failed"
                // An input port has one opener at a time: null while another app has it.
                inputPort == null -> failure = "no_input_port"
                else -> {
                    val handle = nativeOutputOpen(deviceId, port, false, pending.pids.last())
                    if (handle == 0L) {
                        closeQuietly(inputPort)
                        failure = "no_free_output"
                    } else {
                        // Under the lock, before the slot takes sends, so sends
                        // racing the open stay in order.
                        while (pending.queue.isNotEmpty()) {
                            val p = pending.queue.first()
                            if (nativeEnqueue(handle, p.bytes, p.timestamp) != CORE_OK) break
                            pending.queue.removeFirst()
                        }
                        nativeOutputReady(handle, pending.refused)
                        outputs[k] = OpenOutput(inputPort, handle)
                        Dispatcher(handle, inputPort).start()
                        // Under the lock too: a close() after this point
                        // finds the output, one before it removed `pending`.
                        for (pid in pending.pids) nativeDeliverMidiOpened(pid, deviceId, port, "output", 0, handle)
                    }
                }
            }
            pending
        }
        if (pending == null || failure != null) releaseUnusedDevice(deviceId)
        val reason = failure ?: return
        if (pending == null) return
        for (pid in pending.pids) nativeDeliverMidiError(pid, deviceId, "open_output", reason, pending.queue.size)
    }

    // Close a device we opened only for ports that didn't survive. A connected
    // Bluetooth device stays open: closing it would disconnect it.
    private fun releaseUnusedDevice(deviceId: Int) {
        val inUse = inputs.keys.any { deviceOf(it) == deviceId } ||
            synchronized(sendLock) {
                outputs.keys.any { deviceOf(it) == deviceId } || pendingOutputs.keys.any { deviceOf(it) == deviceId }
            } ||
            openDevices[deviceId]?.info?.type == MidiDeviceInfo.TYPE_BLUETOOTH
        if (!inUse) closeLater(openDevices.remove(deviceId))
    }

    // midi_send lands here only when C has no open output for (device, port):
    // still opening (queue it), or not open. timestamp: System.nanoTime() of
    // when the receiver should act on the bytes; 0 = now.
    @JvmStatic
    fun send(deviceId: Int, port: Int, bytes: ByteArray, timestamp: Long): Int {
        val ts = if (timestamp == 0L) System.nanoTime() else timestamp
        val k = key(deviceId, port)
        return synchronized(sendLock) {
            val open = outputs[k]
            if (open != null) {
                when (nativeEnqueue(open.handle, bytes, ts)) {
                    CORE_OK -> SEND_OK
                    CORE_QUEUE_FULL -> SEND_QUEUE_FULL
                    CORE_NO_LISTENER -> SEND_NO_LISTENER
                    CORE_NOT_OPEN -> SEND_NOT_OPEN
                    else -> SEND_FAILED
                }
            } else {
                val pending = pendingOutputs[k]
                val need = (bytes.size + CHUNK_BYTES - 1) / CHUNK_BYTES
                when {
                    pending == null -> SEND_NOT_OPEN
                    pending.refused || pending.chunks + need > PENDING_CHUNKS -> {
                        // Refused until the open port has drained, as in C.
                        pending.refused = true
                        SEND_QUEUE_FULL
                    }
                    else -> {
                        pending.queue.addLast(Pending(bytes, ts))
                        pending.chunks += need
                        SEND_QUEUED
                    }
                }
            }
        }
    }

    // close() during an in-flight open cancels it: waiting openers get
    // {:midi, :error, %{reason: :closed, dropped: n}} and the late openDevice
    // callback finds no pending entry and releases the device. Closing an own
    // virtual device ends its open_virtual subscription. Once it returns, no
    // :opened of an open asked for before it is still to come.
    @JvmStatic
    fun close(deviceId: Int) {
        val cancelled = ArrayList<PendingOutput>()
        val closed = ArrayList<OpenOutput>()
        synchronized(sendLock) {
            closeSeq += 1
            lastClose[deviceId] = closeSeq
            pendingOutputs.keys.filter { deviceOf(it) == deviceId }.forEach { k ->
                pendingOutputs.remove(k)?.let { cancelled.add(it) }
            }
            outputs.keys.filter { deviceOf(it) == deviceId }.forEach { k ->
                outputs.remove(k)?.let { closed.add(it) }
            }
        }
        // After lastClose: an open_virtual on the worker either sees it or
        // has registered (under virtualLock) before this removes it.
        closeVirtual(deviceId)
        for (o in closed) {
            nativeOutputClose(o.handle)
            closeLater(o.port)
        }
        inputs.keys.filter { deviceOf(it) == deviceId }.forEach { closeInput(it) }
        closeLater(openDevices.remove(deviceId))
        if (cancelled.isNotEmpty()) {
            worker.post {
                for (pending in cancelled) {
                    for (pid in pending.pids) {
                        nativeDeliverMidiError(pid, deviceId, "open_output", "closed", pending.queue.size)
                    }
                }
            }
        }
    }

    // ── Own virtual devices ─────────────────────────────────────────────────

    // Subscribe the caller to the app's own virtual device `name`: what other
    // apps send into its input ports goes to `route` (each port a source), its
    // output ports get handles (send_raw / mob_midi_send to all listening),
    // and who has it open arrives as {:midi, :virtual_status, ...}. A second
    // open_virtual replaces the first. `name`: UTF-8.
    @JvmStatic
    fun openVirtual(pid: Long, name: ByteArray, route: Int) {
        val seq = openSeq()
        val wanted = String(name, Charsets.UTF_8)
        worker.post { startOpenVirtual(pid, wanted, route, seq) }
    }

    private fun startOpenVirtual(pid: Long, name: String, route: Int, seq: Long) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, 0, "open_virtual", "no_midi_service", 0); return
        }
        val info = allDevices(mm).firstOrNull { isOwn(it) && deviceName(it) == name } ?: run {
            nativeDeliverMidiError(pid, 0, "open_virtual", "no_such_device", 0); return
        }
        val id = info.id
        closeVirtual(id)
        val sources = IntArray(info.inputPortCount)
        val generations = IntArray(info.inputPortCount)
        val handles = LongArray(info.outputPortCount)
        var failure: String? = null
        for (p in 0 until info.inputPortCount) {
            val packed = nativeSourceOpen(id, p, pid, route)
            if (packed < 0) {
                failure = "no_free_source"; break
            }
            sources[p] = (packed shr 32).toInt()
            generations[p] = packed.toInt()
        }
        for (p in 0 until info.outputPortCount) {
            if (failure != null) break
            val h = nativeOutputOpen(id, p, true, pid)
            if (h == 0L) {
                failure = "no_free_output"; break
            }
            handles[p] = h
        }
        // Registered and announced under virtualLock: close() takes its
        // closeSeq before it removes the subscription (under virtualLock), so
        // either this sees the close and gives up, or the close removes this.
        val opened = failure == null && synchronized(virtualLock) {
            if (closedSince(id, seq)) {
                failure = "closed"
                false
            } else {
                virtuals[id] = Virtual(pid, sources, AtomicIntegerArray(generations), handles)
                val status = virtualStatus[id]
                for (p in handles.indices) {
                    nativeOutputReady(handles[p], false)
                    nativeOutputListeners(handles[p], status?.getOutputPortOpenCount(p) ?: 0)
                    Dispatcher(handles[p], VirtualOut(id, p)).start()
                }
                nativeDeliverMidiVirtualOpened(pid, id, utf8(name))
                val (senders, listeners) = counts(status)
                nativeDeliverMidiVirtualStatus(pid, id, senders, listeners)
                true
            }
        }
        if (!opened) {
            sources.filter { it > 0 }.forEach { nativeSourceClose(it) }
            handles.filter { it > 0 }.forEach { nativeOutputClose(it) }
            nativeDeliverMidiError(pid, id, "open_virtual", failure ?: "closed", 0)
        }
    }

    private fun closeVirtual(deviceId: Int) {
        val v = synchronized(virtualLock) { virtuals.remove(deviceId) } ?: return
        v.sources.filter { it > 0 }.forEach { nativeSourceClose(it) }
        v.handles.filter { it > 0 }.forEach { nativeOutputClose(it) }
    }

    // (senders, listeners): input ports another app has open, connections to
    // the output ports.
    private fun counts(status: MidiDeviceStatus?): Pair<Int, Int> {
        if (status == null) return Pair(0, 0)
        val info = status.deviceInfo
        val senders = (0 until info.inputPortCount).count { status.isInputPortOpen(it) }
        val listeners = (0 until info.outputPortCount).sumOf { status.getOutputPortOpenCount(it) }
        return Pair(senders, listeners)
    }

    internal fun attachService(service: MobMidiDeviceService) {
        val info = service.deviceInfo ?: return
        virtualServices[info.id] = service
    }

    internal fun detachService(service: MobMidiDeviceService) {
        val info = service.deviceInfo ?: return
        if (!virtualServices.remove(info.id, service)) return
        synchronized(virtualLock) {
            val old = virtualStatus.remove(info.id)
            val v = virtuals[info.id] ?: return@synchronized
            v.handles.forEach { nativeOutputListeners(it, 0) }
            renewSources(v, old, null)
            nativeDeliverMidiVirtualStatus(v.pid, info.id, 0, 0)
        }
    }

    // Bytes another app sent into an own virtual device (binder thread).
    internal fun fromVirtual(deviceId: Int, port: Int, msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
        val v = virtuals[deviceId] ?: return
        if (port >= v.sources.size || count <= 0) return
        nativeReceive(v.sources[port], v.generations.get(port), msg, offset, count, timestamp)
    }

    // An input port whose sender came or went starts a new generation: the
    // next sender's stream starts from a fresh parser, and the last one's
    // late bytes are dropped. Android reports an open before handing the port
    // to the sender, so its first bytes already carry the new generation.
    private fun renewSources(v: Virtual, old: MidiDeviceStatus?, new: MidiDeviceStatus?) {
        for (p in v.sources.indices) {
            val was = old?.isInputPortOpen(p) ?: false
            val now = new?.isInputPortOpen(p) ?: false
            if (was != now) {
                val g = nativeSourceRenew(v.sources[p])
                if (g != 0) v.generations.set(p, g)
            }
        }
    }

    internal fun statusChanged(status: MidiDeviceStatus) {
        val id = status.deviceInfo.id
        val (senders, listeners) = counts(status)
        synchronized(virtualLock) {
            val old = virtualStatus.put(id, status)
            val v = virtuals[id] ?: return
            renewSources(v, old, status)
            for (p in v.handles.indices) nativeOutputListeners(v.handles[p], status.getOutputPortOpenCount(p))
            nativeDeliverMidiVirtualStatus(v.pid, id, senders, listeners)
        }
    }

    // ── Bluetooth (BLE-MIDI central) ────────────────────────────────────────

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (activityRef?.get()?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun bluetoothGranted(activity: Activity): Boolean =
        permissionsFor(BLUETOOTH_CAPABILITY)!!.all {
            activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    // Scans find nothing while location is switched off: on API <= 30
    // always, on 31+ because BLUETOOTH_SCAN isn't neverForLocation here.
    private fun locationOn(ctx: Context): Boolean =
        (ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.isLocationEnabled == true

    // Scan for BLE-MIDI devices for durationMs. The caller gets
    // {:midi, :bluetooth_scan, :started}, one {:midi, :bluetooth_device, ...}
    // per device found, then {:midi, :bluetooth_scan, :stopped}.
    @JvmStatic
    fun scanBluetooth(pid: Long, durationMs: Int) {
        worker.post { checkScan(pid, durationMs) }
    }

    // Adapter state is a binder call: on the worker.
    private fun checkScan(pid: Long, durationMs: Int) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "no_activity", 0); return
        }
        val adapter = if (activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            bluetoothAdapter()
        } else {
            null
        }
        val reason = when {
            adapter == null -> "unsupported"
            !bluetoothGranted(activity) -> "permission_denied"
            !adapter.isEnabled -> "bluetooth_off"
            !locationOn(activity) -> "location_off"
            else -> null
        }
        if (reason != null) {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", reason, 0); return
        }
        main.post { startScan(pid, durationMs) }
    }

    @Suppress("MissingPermission")
    private fun startScan(pid: Long, durationMs: Int) {
        stopScan()
        val scanner = bluetoothAdapter()?.bluetoothLeScanner ?: run {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "bluetooth_off", 0); return
        }
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                if (!scanSeen.add(device.address)) return
                val name = runCatching { device.name }.getOrNull() ?: result.scanRecord?.deviceName ?: device.address
                nativeDeliverMidiBluetoothDevice(pid, utf8(device.address), utf8(name), result.rssi)
            }

            override fun onScanFailed(errorCode: Int) {
                if (scanCallback === this) {
                    scanCallback = null
                    nativeDeliverMidiError(pid, 0, "scan_bluetooth", "scan_failed", 0)
                }
            }
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(BLE_MIDI_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(listOf(filter), settings, cb)
        } catch (e: SecurityException) {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "permission_denied", 0); return
        }
        scanCallback = cb
        scanPid = pid
        scanSeen.clear()
        nativeDeliverMidiEvent(pid, "bluetooth_scan", "started")
        main.postDelayed({ if (scanCallback === cb) stopScan() }, durationMs.toLong())
    }

    @JvmStatic
    fun stopBluetoothScan() {
        main.post { stopScan() }
    }

    @Suppress("MissingPermission")
    private fun stopScan() {
        val cb = scanCallback ?: return
        scanCallback = null
        try {
            bluetoothAdapter()?.bluetoothLeScanner?.stopScan(cb)
        } catch (e: SecurityException) {
            // Permission revoked mid-scan; the scan is gone either way.
        } catch (e: IllegalStateException) {
            // Bluetooth switched off mid-scan.
        }
        nativeDeliverMidiEvent(scanPid, "bluetooth_scan", "stopped")
    }

    // Connect a BLE-MIDI device by address: it becomes a MIDI device (listed,
    // openable) until close(device) disconnects it. The caller gets
    // {:midi, :connected, %{device, address}} (at once if it already is) or
    // an op: :connect_bluetooth error. `address`: UTF-8.
    @JvmStatic
    fun connectBluetooth(pid: Long, address: ByteArray) {
        val text = String(address, Charsets.UTF_8)
        worker.post { startConnect(pid, text) }
    }

    private fun startConnect(pid: Long, address: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "no_activity", 0); return
        }
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "no_midi_service", 0); return
        }
        val adapter = bluetoothAdapter()
        val reason = when {
            adapter == null -> "unsupported"
            !BluetoothAdapter.checkBluetoothAddress(address) -> "bad_address"
            !bluetoothGranted(activity) -> "permission_denied"
            !adapter.isEnabled -> "bluetooth_off"
            else -> null
        }
        if (reason != null) {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", reason, 0); return
        }
        openDevices.values.firstOrNull { addressOf(it.info) == address }?.let {
            nativeDeliverMidiConnected(pid, it.info.id, utf8(address)); return
        }
        val remote = adapter!!.getRemoteDevice(address)
        try {
            mm.openBluetoothDevice(remote, { device ->
                if (device == null) {
                    nativeDeliverMidiError(pid, 0, "connect_bluetooth", "open_failed", 0)
                } else {
                    val id = device.info.id
                    val prev = openDevices.putIfAbsent(id, device)
                    if (prev != null) closeQuietly(device)
                    nativeDeliverMidiConnected(pid, id, utf8(address))
                }
            }, worker)
        } catch (e: SecurityException) {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "permission_denied", 0)
        }
    }

    // Android objects are closed on the worker: closing a port blocks while a
    // write to it is blocked (see worker).
    private fun closeLater(c: java.io.Closeable?) {
        if (c != null) worker.post { closeQuietly(c) }
    }

    // close() on ports/devices is declared to throw IOException; never let one
    // escape into JNI on a BEAM scheduler thread.
    private fun closeQuietly(c: java.io.Closeable?) {
        try {
            c?.close()
        } catch (e: IOException) {
            // Already gone; nothing left to release.
        }
    }
}

// An app's own virtual MIDI device: other apps see it in their MIDI device
// lists, send into its input ports and listen to its output ports. Declare it
// in the host's AndroidManifest.xml (the device's name and ports live in the
// res/xml file the <meta-data> points to; `mix mob_midi.gen.virtual_device`
// writes both, see the README), then MobMidi.open_virtual(socket, name)
// subscribes to it. One <service> per device: for a second device, declare an
// empty subclass of this one.
open class MobMidiDeviceService : MidiDeviceService() {
    // Called from super.onCreate(), after deviceInfo is set.
    override fun onGetInputPortReceivers(): Array<MidiReceiver> {
        val info = deviceInfo ?: return emptyArray()
        return Array(info.inputPortCount) { port ->
            object : MidiReceiver() {
                override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                    MobMidiBridge.fromVirtual(info.id, port, msg, offset, count, timestamp)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        MobMidiBridge.attachService(this)
    }

    override fun onDestroy() {
        MobMidiBridge.detachService(this)
        super.onDestroy()
    }

    // Called on the opener's binder thread before it gets the port.
    override fun onDeviceStatusChanged(status: MidiDeviceStatus) {
        MobMidiBridge.statusChanged(status)
    }
}
