// An external MIDI client for checking a mob_midi host app on Android: it
// runs outside the app, as the adb shell user (app_process), opens the MIDI
// device whose name is the first argument ("Name*": the first whose name
// starts with "Name"), listens on every one of its output
// ports and, by mode, sends notes into its input port 0. Every send is
// stamped with System.nanoTime (CLOCK_MONOTONIC, MobMidi.now_ns/0's clock),
// so its lines compare directly with the app's own stamps.
//
//   MidiProbe <name> devices
//   MidiProbe <name> listen <seconds>
//   MidiProbe <name> notes <seconds> <count> <gap ms>
//       count note-on/note-off pairs into input port 0, gap ms apart, after
//       500 ms, sent with running status (the note-off is 0x90 velocity 0
//       without a status byte) and a clock byte (0xF8) between the note-on's
//       data bytes, to exercise the receiving parser.
//   MidiProbe <name> stall <seconds>
//       listens on output port 0 but blocks in its first onSend until 3 s
//       before the time is up, then reads again: a client that stops reading
//       for a while.
//
// Output, one line each (times in ns, CLOCK_MONOTONIC):
//
//   DEVICE id=.. name=.. type=.. in=.. out=..
//   OPEN id=.. sending=true|false listening=<ports>
//   SENT <stamp> <hex bytes>
//   RECV <port> <arrival> <stamp> <hex bytes>
//   DONE
//
// Build, push and run with tools/midi_probe.sh. Under app_process there is
// no Context: the platform MidiManager comes from its hidden IMidiManager
// constructor (as Humdinger's and Magpie's probes did).
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiInputPort;
import android.media.midi.MidiManager;
import android.media.midi.MidiOutputPort;
import android.media.midi.MidiReceiver;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

public final class MidiProbe {
    private static final StringBuilder OUT = new StringBuilder();

    @SuppressWarnings("deprecation") // getDevicesForTransport is API 33+
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.out.println("usage: MidiProbe <name> devices | listen <s> | notes <s> <count> <gap ms> | stall <s>");
            System.exit(1);
        }
        String wanted = args[0];
        String mode = args[1];

        MidiManager mm = midiManager();
        MidiDeviceInfo info = null;
        for (MidiDeviceInfo d : mm.getDevices()) {
            String name = d.getProperties().getString(MidiDeviceInfo.PROPERTY_NAME);
            say("DEVICE id=" + d.getId() + " name=" + name + " type=" + d.getType()
                    + " in=" + d.getInputPortCount() + " out=" + d.getOutputPortCount());
            if (info == null && matches(wanted, name)) info = d;
        }
        if (mode.equals("devices")) {
            flush();
            System.exit(info == null ? 2 : 0);
        }
        if (info == null) {
            say("NOT_FOUND " + wanted);
            flush();
            System.exit(2);
        }

        HandlerThread thread = new HandlerThread("midi-probe");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        CountDownLatch opened = new CountDownLatch(1);
        MidiDevice[] device = new MidiDevice[1];
        mm.openDevice(info, d -> {
            device[0] = d;
            opened.countDown();
        }, handler);
        if (!opened.await(10, TimeUnit.SECONDS) || device[0] == null) {
            say("OPEN_FAILED " + wanted);
            flush();
            System.exit(4);
        }

        long seconds = Long.parseLong(args[2]);
        long end = System.nanoTime() + seconds * 1_000_000_000L;
        boolean stall = mode.equals("stall");
        List<MidiOutputPort> listening = new ArrayList<>();
        int ports = stall ? Math.min(1, info.getOutputPortCount()) : info.getOutputPortCount();
        for (int p = 0; p < ports; p++) {
            MidiOutputPort out = device[0].openOutputPort(p);
            if (out == null) continue;
            final int port = p;
            out.connect(new MidiReceiver() {
                @Override
                public void onSend(byte[] msg, int offset, int count, long timestamp) {
                    long arrival = System.nanoTime();
                    StringBuilder line = new StringBuilder("RECV ").append(port).append(' ')
                            .append(arrival).append(' ').append(timestamp);
                    for (int i = offset; i < offset + count; i++) line.append(String.format(" %02x", msg[i] & 0xff));
                    say(line.toString());
                    if (stall) LockSupport.parkNanos(Math.max(0, end - 3_000_000_000L - System.nanoTime()));
                }
            });
            listening.add(out);
        }
        boolean sends = mode.equals("notes");
        MidiInputPort send = sends && info.getInputPortCount() > 0 ? device[0].openInputPort(0) : null;
        say("OPEN id=" + info.getId() + " sending=" + (send != null) + " listening=" + listening.size());
        if (sends && send == null) {
            say("PORT_BUSY " + wanted);
            flush();
            System.exit(5);
        }

        Thread.sleep(500);
        if (sends) notes(send, Integer.parseInt(args[3]), Long.parseLong(args[4]));
        long left = end - System.nanoTime();
        if (left > 0) Thread.sleep(left / 1_000_000L);
        for (MidiOutputPort out : listening) out.close();
        if (send != null) send.close();
        device[0].close();
        say("DONE");
        flush();
        System.exit(0);
    }

    // "Name*" matches by prefix: a name the shell can't carry (an emoji).
    private static boolean matches(String wanted, String name) {
        if (name == null) return false;
        return wanted.endsWith("*") ? name.startsWith(wanted.substring(0, wanted.length() - 1)) : wanted.equals(name);
    }

    // Each pair: 90 nn [F8] 64, then (running status) nn 00, gap ms apart.
    private static void notes(MidiInputPort port, int count, long gapMs) throws Exception {
        long gap = gapMs * 1_000_000L;
        long t = System.nanoTime();
        for (int i = 0; i < count; i++) {
            byte note = (byte) (48 + i % 24);
            waitUntil(t);
            send(port, (byte) 0x90, note, (byte) 0xf8, (byte) 100);
            waitUntil(t + gap / 2);
            send(port, note, (byte) 0);
            t += gap;
        }
    }

    // Sleep to 1 ms before, then spin: sends leave within a few µs of their time.
    private static void waitUntil(long t) {
        for (long left = t - System.nanoTime(); left > 1_500_000L; left = t - System.nanoTime()) {
            LockSupport.parkNanos(left - 1_000_000L);
        }
        while (System.nanoTime() < t) {
            // spin
        }
    }

    private static void send(MidiInputPort port, byte... msg) throws Exception {
        long stamp = System.nanoTime();
        port.send(msg, 0, msg.length, stamp);
        StringBuilder line = new StringBuilder("SENT ").append(stamp);
        for (byte b : msg) line.append(String.format(" %02x", b & 0xff));
        say(line.toString());
    }

    private static MidiManager midiManager() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class)
                .invoke(null, "midi");
        Class<?> iface = Class.forName("android.media.midi.IMidiManager");
        Object service = Class.forName("android.media.midi.IMidiManager$Stub")
                .getMethod("asInterface", IBinder.class)
                .invoke(null, binder);
        Constructor<MidiManager> ctor = MidiManager.class.getDeclaredConstructor(iface);
        ctor.setAccessible(true);
        return ctor.newInstance(service);
    }

    // Buffered and printed at the end, so printing never delays a send or a receive.
    private static void say(String line) {
        synchronized (OUT) {
            OUT.append(line).append('\n');
        }
    }

    private static void flush() {
        synchronized (OUT) {
            System.out.print(OUT);
            System.out.flush();
            OUT.setLength(0);
        }
    }
}
