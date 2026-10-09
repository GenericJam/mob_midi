// mob_midi plugin — Android bridge (android.media.midi / MidiManager).
//
// Thin bridge: enumerate MIDI devices, open input (receive) / output (send)
// ports, stream incoming bytes to the BEAM. Message encode/parse lives in
// Elixir (MobMidi); this layer is raw bytes + enumeration only.
//
// The native thunks (nativeRegister + nativeDeliver*) are exported from the
// sibling zig NIF mob_midi_nif.zig. MobPluginBootstrap.registerAll() calls
// register() at startup and hands it the Activity (MobActivityAware).
//
// Simplification: a "device id" is MidiDeviceInfo.id and we use port 0 (most
// USB/BLE controllers expose a single port); multi-port devices are a follow-up.
//
// Opening an output is asynchronous (MidiManager.openDevice calls back on the
// main looper). Sends made between openOutput and that callback are queued
// (bounded, MAX_PENDING_SENDS) and flushed in order once the port exists. The
// opener then gets {:midi, :opened, %{device, direction: :output}}; on failure
// it gets {:midi, :error, %{device, op: :open_output, reason, dropped}} and the
// queue is discarded. A send to a device with no open or opening output
// returns SEND_NOT_OPEN.
package io.mob.midi

import android.app.Activity
import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiInputPort
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

object MobMidiBridge : io.mob.plugin.MobActivityAware {
    @JvmStatic external fun nativeRegister()

    // {:midi, :devices, ...} carries a JSON array of {id, name, direction}.
    @JvmStatic external fun nativeDeliverMidiDevices(pid: Long, json: String)

    // {:midi, :raw, %{device, bytes}} — one incoming MIDI chunk.
    @JvmStatic external fun nativeDeliverMidiRaw(pid: Long, device: Int, bytes: ByteArray)

    // {:midi, :opened, %{device, direction: :output}} — the output port exists.
    @JvmStatic external fun nativeDeliverMidiOpened(pid: Long, device: Int)

    // {:midi, :error, %{device, op, reason, dropped}} — op/reason become atoms.
    @JvmStatic external fun nativeDeliverMidiError(
        pid: Long,
        device: Int,
        op: String,
        reason: String,
        dropped: Int,
    )

    // send() result codes; mob_midi_nif.zig maps them to :ok / :queued /
    // {:error, :not_open | :queue_full | :send_failed}.
    private const val SEND_OK = 0
    private const val SEND_QUEUED = 1
    private const val SEND_NOT_OPEN = 2
    private const val SEND_QUEUE_FULL = 3
    private const val SEND_FAILED = 4

    // Messages buffered per device while its output is opening. A burst larger
    // than this before the port exists is the caller's bug; extra sends get
    // SEND_QUEUE_FULL instead of growing without bound.
    private const val MAX_PENDING_SENDS = 256

    private class PendingOutput(val pids: MutableList<Long>) {
        val queue = ArrayDeque<ByteArray>()
    }

    private var activityRef: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())

    private val openDevices = ConcurrentHashMap<Int, MidiDevice>()
    private val outputPorts = ConcurrentHashMap<Int, MidiOutputPort>() // device -> receive port

    // Guards inputPorts + pendingOutputs together, so a send either goes to the
    // port, joins the queue before the flush, or sees NOT_OPEN — never lost.
    private val sendLock = Any()
    private val inputPorts = HashMap<Int, MidiInputPort>() // device -> send port
    private val pendingOutputs = HashMap<Int, PendingOutput>()

    // Called by the generated MobPluginBootstrap.registerAll BEFORE setActivity,
    // to cache this jclass + the nativeDeliver* method ids.
    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // MobActivityAware: receive the host Activity at startup (instance dispatch,
    // so not @JvmStatic).
    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private fun midiManager(): MidiManager? =
        activityRef?.get()?.getSystemService(Context.MIDI_SERVICE) as? MidiManager

    // Open the device once and share it between input and output, so opening
    // both directions of one device doesn't leak a second MidiDevice.
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

    // An empty list means MidiManager answered with no devices. When there is
    // no MidiManager to ask, the caller gets {:midi, :error, %{op:
    // :list_devices, reason: :no_activity | :no_midi_service}} instead, so
    // "no devices" is never confused with "never asked" (MobMidi.SelfTest
    // relies on this).
    @JvmStatic
    fun listDevices(pid: Long) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverMidiError(pid, 0, "list_devices", "no_activity", 0); return
        }
        // null when the device lacks PackageManager.FEATURE_MIDI.
        val mm = activity.getSystemService(Context.MIDI_SERVICE) as? MidiManager ?: run {
            nativeDeliverMidiError(pid, 0, "list_devices", "no_midi_service", 0); return
        }
        val arr = JSONArray()
        for (info in mm.devices) {
            val name = deviceName(info)
            // A device with output ports can be read from (an input source for us);
            // with input ports it can be written to (an output for us).
            val direction =
                when {
                    info.outputPortCount > 0 && info.inputPortCount > 0 -> "both"
                    info.outputPortCount > 0 -> "input"
                    else -> "output"
                }
            arr.put(JSONObject().put("id", info.id).put("name", name).put("direction", direction))
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
    fun openInput(pid: Long, deviceId: Int) {
        val mm = midiManager() ?: return
        val info = mm.devices.firstOrNull { it.id == deviceId } ?: return
        withDevice(mm, info) { device ->
            if (device == null) return@withDevice
            val out = device.openOutputPort(0) ?: return@withDevice
            closeQuietly(outputPorts.put(deviceId, out))
            out.connect(object : MidiReceiver() {
                override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                    val chunk = msg.copyOfRange(offset, offset + count)
                    nativeDeliverMidiRaw(pid, deviceId, chunk)
                }
            })
        }
    }

    @JvmStatic
    fun openOutput(pid: Long, deviceId: Int) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_output", "no_midi_service", 0); return
        }
        val info = mm.devices.firstOrNull { it.id == deviceId } ?: run {
            nativeDeliverMidiError(pid, deviceId, "open_output", "no_such_device", 0); return
        }
        val alreadyOpen = synchronized(sendLock) {
            when {
                inputPorts.containsKey(deviceId) -> true
                else -> {
                    // A second open while the first is in flight just waits on it.
                    val pending = pendingOutputs[deviceId]
                    if (pending != null) {
                        pending.pids.add(pid); return
                    }
                    pendingOutputs[deviceId] = PendingOutput(mutableListOf(pid))
                    false
                }
            }
        }
        if (alreadyOpen) {
            nativeDeliverMidiOpened(pid, deviceId); return
        }
        withDevice(mm, info) { device -> finishOpenOutput(deviceId, device) }
    }

    private fun finishOpenOutput(deviceId: Int, device: MidiDevice?) {
        val port = device?.openInputPort(0)
        var failure: String? = null
        var dropped = 0
        val pending = synchronized(sendLock) {
            val pending = pendingOutputs.remove(deviceId)
            when {
                // close() ran while we were opening: nobody wants this port.
                pending == null -> closeQuietly(port)
                device == null -> failure = "open_failed"
                port == null -> failure = "no_input_port"
                else ->
                    try {
                        // Flush under the lock so sends racing the open stay in order.
                        while (pending.queue.isNotEmpty()) {
                            val bytes = pending.queue.first()
                            port.send(bytes, 0, bytes.size)
                            pending.queue.removeFirst()
                        }
                        inputPorts[deviceId] = port
                    } catch (e: IOException) {
                        closeQuietly(port)
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
                nativeDeliverMidiOpened(pid, deviceId)
            } else {
                nativeDeliverMidiError(pid, deviceId, "open_output", reason, dropped)
            }
        }
    }

    // Close a device we opened only for an output that didn't survive.
    private fun releaseUnusedDevice(deviceId: Int) {
        val inUse = outputPorts.containsKey(deviceId) ||
            synchronized(sendLock) { inputPorts.containsKey(deviceId) }
        if (!inUse) closeQuietly(openDevices.remove(deviceId))
    }

    @JvmStatic
    fun send(deviceId: Int, bytes: ByteArray): Int = synchronized(sendLock) {
        val port = inputPorts[deviceId]
        if (port != null) {
            try {
                port.send(bytes, 0, bytes.size)
                SEND_OK
            } catch (e: IOException) {
                SEND_FAILED
            }
        } else {
            val pending = pendingOutputs[deviceId]
            when {
                pending == null -> SEND_NOT_OPEN
                pending.queue.size >= MAX_PENDING_SENDS -> SEND_QUEUE_FULL
                else -> {
                    pending.queue.addLast(bytes)
                    SEND_QUEUED
                }
            }
        }
    }

    // close() during an in-flight open cancels it: waiting openers get
    // {:midi, :error, %{reason: :closed, dropped: n}} and the late openDevice
    // callback finds no pending entry and releases the device.
    @JvmStatic
    fun close(deviceId: Int) {
        var cancelled: PendingOutput? = null
        val port = synchronized(sendLock) {
            cancelled = pendingOutputs.remove(deviceId)
            inputPorts.remove(deviceId)
        }
        closeQuietly(port)
        closeQuietly(outputPorts.remove(deviceId))
        closeQuietly(openDevices.remove(deviceId))
        cancelled?.let { pending ->
            for (pid in pending.pids) {
                nativeDeliverMidiError(pid, deviceId, "open_output", "closed", pending.queue.size)
            }
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
