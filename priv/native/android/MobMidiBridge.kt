// mob_midi plugin — Android bridge (android.media.midi / MidiManager).
//
// Thin bridge: enumerate MIDI devices, open input (receive) / output (send)
// ports, stream incoming bytes to the BEAM, host the app's own virtual MIDI
// devices, scan for and connect BLE-MIDI devices. Message encode/parse lives in
// Elixir (MobMidi); this layer is raw bytes + enumeration only.
//
// The native thunks (nativeRegister + nativeDeliver*) are exported from the
// sibling zig NIF mob_midi_nif.zig. MobPluginBootstrap.registerAll() calls
// register() at startup and hands it the Activity (MobActivityAware).
//
// A "device id" is MidiDeviceInfo.id; ports are numbered per direction as
// Android numbers them (open_input reads output port n, open_output writes
// input port n).
//
// Opening an output is asynchronous (MidiManager.openDevice calls back on the
// main looper). Sends made between openOutput and that callback are queued
// (bounded, MAX_PENDING_SENDS) and flushed in order once the port exists. The
// opener then gets {:midi, :opened, %{device, port, direction: :output}}; on
// failure it gets {:midi, :error, %{device, op: :open_output, reason, dropped}}
// and the queue is discarded. A send to a port with no open or opening output
// returns SEND_NOT_OPEN.
//
// Timestamps are System.nanoTime() (CLOCK_MONOTONIC), the clock of
// MobMidi.now_ns/0: incoming bytes carry the sender's stamp and the moment the
// bridge got them; a send's timestamp travels with the bytes to the receiver.
package io.mob.midi

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
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
import android.os.Looper
import android.os.ParcelUuid
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

object MobMidiBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    @JvmStatic external fun nativeRegister()

    // {:midi, :devices, ...} carries a JSON array of device objects.
    @JvmStatic external fun nativeDeliverMidiDevices(pid: Long, json: String)

    // {:midi, :raw, %{device, port, bytes, timestamp, received}}: bytes is
    // msg[offset, offset + count), copied natively.
    @JvmStatic external fun nativeDeliverMidiRaw(
        pid: Long,
        device: Int,
        port: Int,
        msg: ByteArray,
        offset: Int,
        count: Int,
        timestamp: Long,
        received: Long,
    )

    // {:midi, :opened, %{device, port, direction}}, direction "input" | "output".
    @JvmStatic external fun nativeDeliverMidiOpened(pid: Long, device: Int, port: Int, direction: String)

    // {:midi, :opened, %{device, direction: :virtual, name}}.
    @JvmStatic external fun nativeDeliverMidiVirtualOpened(pid: Long, device: Int, name: String)

    // {:midi, :virtual_status, %{device, senders, listeners}}.
    @JvmStatic external fun nativeDeliverMidiVirtualStatus(pid: Long, device: Int, senders: Int, listeners: Int)

    // {:midi, tag, value}: value an atom, or nil when null.
    @JvmStatic external fun nativeDeliverMidiEvent(pid: Long, tag: String, value: String?)

    // {:midi, :bluetooth_device, %{address, name}}.
    @JvmStatic external fun nativeDeliverMidiBluetoothDevice(pid: Long, address: String, name: String)

    // {:midi, :connected, %{device, address}}.
    @JvmStatic external fun nativeDeliverMidiConnected(pid: Long, device: Int, address: String)

    // {:midi, :error, %{device, op, reason, dropped}} — op/reason become atoms.
    @JvmStatic external fun nativeDeliverMidiError(
        pid: Long,
        device: Int,
        op: String,
        reason: String,
        dropped: Int,
    )

    // send() result codes; mob_midi_nif.zig maps them to :ok / :queued /
    // {:error, :not_open | :queue_full | :send_failed | :no_listener}.
    private const val SEND_OK = 0
    private const val SEND_QUEUED = 1
    private const val SEND_NOT_OPEN = 2
    private const val SEND_QUEUE_FULL = 3
    private const val SEND_FAILED = 4
    private const val SEND_NO_LISTENER = 5

    // Messages buffered per port while its output is opening. A burst larger
    // than this before the port exists is the caller's bug; extra sends get
    // SEND_QUEUE_FULL instead of growing without bound.
    private const val MAX_PENDING_SENDS = 256

    // The BLE-MIDI GATT service (MIDI over Bluetooth LE 1.0).
    private const val BLE_MIDI_SERVICE = "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"

    // Mob.Permissions capability that grants scanning for + connecting BLE-MIDI devices.
    private const val BLUETOOTH_CAPABILITY = "midi_bluetooth"

    private class Pending(val bytes: ByteArray, val timestamp: Long)

    private class PendingOutput(val pids: MutableList<Long>) {
        val queue = ArrayDeque<Pending>()
    }

    private var activityRef: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())

    private val openDevices = ConcurrentHashMap<Int, MidiDevice>()
    private val outputPorts = ConcurrentHashMap<Long, MidiOutputPort>() // (device, port) -> receive port

    // Guards inputPorts + pendingOutputs together, so a send either goes to the
    // port, joins the queue before the flush, or sees NOT_OPEN — never lost.
    private val sendLock = Any()
    private val inputPorts = HashMap<Long, MidiInputPort>() // (device, port) -> send port
    private val pendingOutputs = HashMap<Long, PendingOutput>()

    // The app's own virtual devices (MobMidiDeviceService subclasses): who
    // listens to each (open_virtual's caller), the running services, and the
    // last status, all by device id.
    private val virtualSubscribers = ConcurrentHashMap<Int, Long>()
    private val virtualServices = ConcurrentHashMap<Int, MobMidiDeviceService>()
    private val virtualStatus = ConcurrentHashMap<Int, IntArray>()

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
            mm.registerDeviceCallback(MidiManager.TRANSPORT_MIDI_BYTE_STREAM, { main.post(it) }, deviceCallback)
        } else {
            @Suppress("DEPRECATION")
            mm.registerDeviceCallback(deviceCallback, main)
        }
        callbackRegistered = true
    }

    // MobPermissionProvider: Mob.Permissions.request(socket, :midi_bluetooth)
    // asks for what scanning for and connecting BLE-MIDI devices needs.
    override fun permissionsFor(cap: String): Array<String>? =
        if (cap != BLUETOOTH_CAPABILITY) {
            null
        } else if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
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
    // several ports of one device doesn't leak a second MidiDevice.
    private fun withDevice(mm: MidiManager, info: MidiDeviceInfo, cb: (MidiDevice?) -> Unit) {
        openDevices[info.id]?.let { cb(it); return }
        mm.openDevice(info, { device ->
            if (device == null) {
                cb(null)
            } else {
                val prev = openDevices.putIfAbsent(info.id, device)
                if (prev != null) closeQuietly(device)
                cb(prev ?: device)
            }
        }, main)
    }

    // A virtual device declared by this app (a MobMidiDeviceService subclass in
    // its manifest).
    private fun isOwn(info: MidiDeviceInfo): Boolean {
        if (info.type != MidiDeviceInfo.TYPE_VIRTUAL) return false
        val pkg = activityRef?.get()?.packageName ?: return false
        // MidiDeviceInfo.PROPERTY_SERVICE_INFO is @hide; its key has been "service_info" since API 23.
        @Suppress("DEPRECATION")
        val service = info.properties.getParcelable<ServiceInfo>("service_info")
        return service?.packageName == pkg
    }

    // An empty list means MidiManager answered with no devices. When there is
    // no MidiManager to ask, the caller gets {:midi, :error, %{op:
    // :list_devices, reason: :no_activity | :no_midi_service}} instead, so
    // "no devices" is never confused with "never asked" (MobMidi.SelfTest
    // relies on this). The caller also becomes the hot-plug subscriber.
    @JvmStatic
    fun listDevices(pid: Long) {
        listPid = pid
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
                    .put("input_ports", info.outputPortCount)
                    .put("output_ports", info.inputPortCount)
                    .put("own", isOwn(info)),
            )
        }
        nativeDeliverMidiDevices(pid, arr.toString())
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

    @JvmStatic
    fun openInput(pid: Long, deviceId: Int, port: Int) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_midi_service", 0); return
        }
        val info = findDevice(mm, deviceId) ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_such_device", 0); return
        }
        if (port < 0 || port >= info.outputPortCount) {
            nativeDeliverMidiError(pid, deviceId, "open_input", "no_such_port", 0); return
        }
        withDevice(mm, info) { device ->
            val out = device?.openOutputPort(port)
            if (out == null) {
                nativeDeliverMidiError(pid, deviceId, "open_input", if (device == null) "open_failed" else "no_output_port", 0)
                releaseUnusedDevice(deviceId)
                return@withDevice
            }
            closeQuietly(outputPorts.put(key(deviceId, port), out))
            out.connect(object : MidiReceiver() {
                override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                    nativeDeliverMidiRaw(pid, deviceId, port, msg, offset, count, timestamp, System.nanoTime())
                }
            })
            nativeDeliverMidiOpened(pid, deviceId, port, "input")
        }
    }

    @JvmStatic
    fun openOutput(pid: Long, deviceId: Int, port: Int) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_output", "no_midi_service", 0); return
        }
        val info = findDevice(mm, deviceId) ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_output", "no_such_device", 0); return
        }
        if (port < 0 || port >= info.inputPortCount) {
            nativeDeliverMidiError(pid, deviceId, "open_output", "no_such_port", 0); return
        }
        val k = key(deviceId, port)
        val alreadyOpen = synchronized(sendLock) {
            when {
                inputPorts.containsKey(k) -> true
                else -> {
                    // A second open while the first is in flight just waits on it.
                    val pending = pendingOutputs[k]
                    if (pending != null) {
                        pending.pids.add(pid); return
                    }
                    pendingOutputs[k] = PendingOutput(mutableListOf(pid))
                    false
                }
            }
        }
        if (alreadyOpen) {
            nativeDeliverMidiOpened(pid, deviceId, port, "output"); return
        }
        withDevice(mm, info) { device -> finishOpenOutput(deviceId, port, device) }
    }

    private fun finishOpenOutput(deviceId: Int, port: Int, device: MidiDevice?) {
        val k = key(deviceId, port)
        val inputPort = device?.openInputPort(port)
        var failure: String? = null
        var dropped = 0
        val pending = synchronized(sendLock) {
            val pending = pendingOutputs.remove(k)
            when {
                // close() ran while we were opening: nobody wants this port.
                pending == null -> closeQuietly(inputPort)
                device == null -> failure = "open_failed"
                inputPort == null -> failure = "no_input_port"
                else ->
                    try {
                        // Flush under the lock so sends racing the open stay in order.
                        while (pending.queue.isNotEmpty()) {
                            val p = pending.queue.first()
                            inputPort.send(p.bytes, 0, p.bytes.size, p.timestamp)
                            pending.queue.removeFirst()
                        }
                        inputPorts[k] = inputPort
                    } catch (e: IOException) {
                        closeQuietly(inputPort)
                        failure = "send_failed"
                    }
            }
            if (pending != null) dropped = pending.queue.size
            pending
        }
        if (pending == null || failure != null) releaseUnusedDevice(deviceId)
        if (pending == null) return
        for (pid in pending.pids) {
            val reason = failure
            if (reason == null) {
                nativeDeliverMidiOpened(pid, deviceId, port, "output")
            } else {
                nativeDeliverMidiError(pid, deviceId, "open_output", reason, dropped)
            }
        }
    }

    // Close a device we opened only for ports that didn't survive. A connected
    // Bluetooth device stays open: closing it would disconnect it.
    private fun releaseUnusedDevice(deviceId: Int) {
        val inUse = outputPorts.keys.any { deviceOf(it) == deviceId } ||
            synchronized(sendLock) { inputPorts.keys.any { deviceOf(it) == deviceId } } ||
            openDevices[deviceId]?.info?.type == MidiDeviceInfo.TYPE_BLUETOOTH
        if (!inUse) closeQuietly(openDevices.remove(deviceId))
    }

    // timestamp: System.nanoTime() of when the receiver should act on the
    // bytes; 0 = now.
    @JvmStatic
    fun send(deviceId: Int, port: Int, bytes: ByteArray, timestamp: Long): Int {
        val ts = if (timestamp == 0L) System.nanoTime() else timestamp
        if (virtualSubscribers.containsKey(deviceId)) return sendVirtual(deviceId, port, bytes, ts)
        val k = key(deviceId, port)
        return synchronized(sendLock) {
            val inputPort = inputPorts[k]
            if (inputPort != null) {
                try {
                    inputPort.send(bytes, 0, bytes.size, ts)
                    SEND_OK
                } catch (e: IOException) {
                    SEND_FAILED
                }
            } else {
                val pending = pendingOutputs[k]
                when {
                    pending == null -> SEND_NOT_OPEN
                    pending.queue.size >= MAX_PENDING_SENDS -> SEND_QUEUE_FULL
                    else -> {
                        pending.queue.addLast(Pending(bytes, ts))
                        SEND_QUEUED
                    }
                }
            }
        }
    }

    // Out of an own virtual device's output port, to every app listening. The
    // service only runs while some app has the device open.
    private fun sendVirtual(deviceId: Int, port: Int, bytes: ByteArray, timestamp: Long): Int {
        val service = virtualServices[deviceId] ?: return SEND_NO_LISTENER
        if ((virtualStatus[deviceId]?.get(1) ?: 0) == 0) return SEND_NO_LISTENER
        // null until the service's MidiDeviceServer exists.
        val receivers: Array<MidiReceiver> = service.outputPortReceivers ?: return SEND_NO_LISTENER
        if (port < 0 || port >= receivers.size) return SEND_FAILED
        return try {
            receivers[port].send(bytes, 0, bytes.size, timestamp)
            SEND_OK
        } catch (e: IOException) {
            SEND_FAILED
        }
    }

    // close() during an in-flight open cancels it: waiting openers get
    // {:midi, :error, %{reason: :closed, dropped: n}} and the late openDevice
    // callback finds no pending entry and releases the device. Closing an own
    // virtual device unsubscribes its listener.
    @JvmStatic
    fun close(deviceId: Int) {
        virtualSubscribers.remove(deviceId)
        val cancelled = ArrayList<PendingOutput>()
        val ports = ArrayList<MidiInputPort>()
        synchronized(sendLock) {
            pendingOutputs.keys.filter { deviceOf(it) == deviceId }.forEach { k ->
                pendingOutputs.remove(k)?.let { cancelled.add(it) }
            }
            inputPorts.keys.filter { deviceOf(it) == deviceId }.forEach { k ->
                inputPorts.remove(k)?.let { ports.add(it) }
            }
        }
        ports.forEach { closeQuietly(it) }
        outputPorts.keys.filter { deviceOf(it) == deviceId }.forEach { k -> closeQuietly(outputPorts.remove(k)) }
        closeQuietly(openDevices.remove(deviceId))
        for (pending in cancelled) {
            for (pid in pending.pids) {
                nativeDeliverMidiError(pid, deviceId, "open_output", "closed", pending.queue.size)
            }
        }
    }

    // ── Own virtual devices ─────────────────────────────────────────────────

    // Subscribe the caller to the app's own virtual device `name`: what other
    // apps send into it arrives as {:midi, :raw, ...}, who has it open as
    // {:midi, :virtual_status, ...}; send() to its id goes out of it.
    @JvmStatic
    fun openVirtual(pid: Long, name: String) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, 0, "open_virtual", "no_midi_service", 0); return
        }
        val info = allDevices(mm).firstOrNull { isOwn(it) && deviceName(it) == name } ?: run {
            nativeDeliverMidiError(pid, 0, "open_virtual", "no_such_device", 0); return
        }
        virtualSubscribers[info.id] = pid
        nativeDeliverMidiVirtualOpened(pid, info.id, name)
        val status = virtualStatus[info.id]
        nativeDeliverMidiVirtualStatus(pid, info.id, status?.get(0) ?: 0, status?.get(1) ?: 0)
    }

    internal fun attachService(service: MobMidiDeviceService) {
        val info = service.deviceInfo ?: return
        virtualServices[info.id] = service
    }

    internal fun detachService(service: MobMidiDeviceService) {
        val info = service.deviceInfo ?: return
        virtualServices.remove(info.id, service)
        updateVirtualStatus(info.id, 0, 0)
    }

    // Bytes another app sent into an own virtual device (binder thread).
    internal fun fromVirtual(deviceId: Int, port: Int, msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
        val pid = virtualSubscribers[deviceId] ?: return
        nativeDeliverMidiRaw(pid, deviceId, port, msg, offset, count, timestamp, System.nanoTime())
    }

    internal fun updateVirtualStatus(deviceId: Int, senders: Int, listeners: Int) {
        virtualStatus[deviceId] = intArrayOf(senders, listeners)
        val pid = virtualSubscribers[deviceId] ?: return
        nativeDeliverMidiVirtualStatus(pid, deviceId, senders, listeners)
    }

    // ── Bluetooth (BLE-MIDI central) ────────────────────────────────────────

    private fun bluetoothManager(): BluetoothManager? =
        activityRef?.get()?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private fun bluetoothGranted(activity: Activity): Boolean =
        permissionsFor(BLUETOOTH_CAPABILITY)!!.all {
            activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    // Scan for BLE-MIDI devices for durationMs. The caller gets
    // {:midi, :bluetooth_scan, :started}, one {:midi, :bluetooth_device, ...}
    // per device found, then {:midi, :bluetooth_scan, :stopped}.
    @JvmStatic
    fun scanBluetooth(pid: Long, durationMs: Int) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "no_activity", 0); return
        }
        val scanner = if (activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            bluetoothManager()?.adapter?.bluetoothLeScanner
        } else {
            null
        }
        if (scanner == null) {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "unsupported", 0); return
        }
        if (!bluetoothGranted(activity)) {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "permission_denied", 0); return
        }
        main.post { startScan(pid, durationMs) }
    }

    @Suppress("MissingPermission")
    private fun startScan(pid: Long, durationMs: Int) {
        stopScan()
        val scanner = bluetoothManager()?.adapter?.bluetoothLeScanner ?: run {
            nativeDeliverMidiError(pid, 0, "scan_bluetooth", "unsupported", 0); return
        }
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                if (!scanSeen.add(device.address)) return
                val name = runCatching { device.name }.getOrNull() ?: result.scanRecord?.deviceName ?: device.address
                nativeDeliverMidiBluetoothDevice(pid, device.address, name)
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
        runCatching { bluetoothManager()?.adapter?.bluetoothLeScanner?.stopScan(cb) }
        nativeDeliverMidiEvent(scanPid, "bluetooth_scan", "stopped")
    }

    // Connect a BLE-MIDI device by address: it becomes a MIDI device (listed,
    // openable) until close(device) disconnects it. The caller gets
    // {:midi, :connected, %{device, address}} or an op: :connect_bluetooth error.
    @JvmStatic
    fun connectBluetooth(pid: Long, address: String) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "no_midi_service", 0); return
        }
        val adapter = bluetoothManager()?.adapter ?: run {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "unsupported", 0); return
        }
        val remote = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "no_such_device", 0); return
        }
        try {
            mm.openBluetoothDevice(remote, { device ->
                if (device == null) {
                    nativeDeliverMidiError(pid, 0, "connect_bluetooth", "open_failed", 0)
                } else {
                    val id = device.info.id
                    val prev = openDevices.putIfAbsent(id, device)
                    if (prev != null) closeQuietly(device)
                    nativeDeliverMidiConnected(pid, id, address)
                }
            }, main)
        } catch (e: SecurityException) {
            nativeDeliverMidiError(pid, 0, "connect_bluetooth", "permission_denied", 0)
        }
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
// res/xml file the <meta-data> points to; see the README), then
// MobMidi.open_virtual(socket, name) subscribes to it. One <service> per
// device: for a second device, declare an empty subclass of this one.
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

    // senders: input ports another app has open; listeners: connections to the
    // output ports.
    override fun onDeviceStatusChanged(status: MidiDeviceStatus) {
        val info = status.deviceInfo
        val senders = (0 until info.inputPortCount).count { status.isInputPortOpen(it) }
        val listeners = (0 until info.outputPortCount).sumOf { status.getOutputPortOpenCount(it) }
        MobMidiBridge.updateVirtualStatus(info.id, senders, listeners)
    }
}
