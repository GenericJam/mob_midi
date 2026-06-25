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
// FIRST PASS — written against the MidiManager API, not yet device-verified.
// Simplification: a "device id" is MidiDeviceInfo.id and we use port 0 (most
// USB/BLE controllers expose a single port); multi-port devices are a follow-up.
package io.mob.midi

import android.app.Activity
import android.content.Context
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
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

    private var activityRef: WeakReference<Activity>? = null
    private val main = Handler(Looper.getMainLooper())

    private val openDevices = ConcurrentHashMap<Int, MidiDevice>()
    private val outputPorts = ConcurrentHashMap<Int, MidiOutputPort>() // device -> receive port
    private val inputPorts = ConcurrentHashMap<Int, android.media.midi.MidiInputPort>() // -> send

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

    @JvmStatic
    fun listDevices(pid: Long) {
        val mm = midiManager() ?: run {
            nativeDeliverMidiDevices(pid, "[]"); return
        }
        val arr = JSONArray()
        for (info in mm.devices) {
            val name =
                info.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "MIDI"
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

    @JvmStatic
    fun openInput(pid: Long, deviceId: Int) {
        val mm = midiManager() ?: return
        val info = mm.devices.firstOrNull { it.id == deviceId } ?: return
        mm.openDevice(info, { device ->
            if (device == null) return@openDevice
            openDevices[deviceId] = device
            val out = device.openOutputPort(0) ?: return@openDevice
            outputPorts[deviceId] = out
            out.connect(object : MidiReceiver() {
                override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                    val chunk = msg.copyOfRange(offset, offset + count)
                    nativeDeliverMidiRaw(pid, deviceId, chunk)
                }
            })
        }, main)
    }

    @JvmStatic
    fun openOutput(deviceId: Int) {
        val mm = midiManager() ?: return
        val info = mm.devices.firstOrNull { it.id == deviceId } ?: return
        mm.openDevice(info, { device ->
            if (device == null) return@openDevice
            openDevices[deviceId] = device
            device.openInputPort(0)?.let { inputPorts[deviceId] = it }
        }, main)
    }

    @JvmStatic
    fun send(deviceId: Int, bytes: ByteArray) {
        inputPorts[deviceId]?.send(bytes, 0, bytes.size)
    }

    @JvmStatic
    fun close(deviceId: Int) {
        outputPorts.remove(deviceId)?.close()
        inputPorts.remove(deviceId)?.close()
        openDevices.remove(deviceId)?.close()
    }
}
