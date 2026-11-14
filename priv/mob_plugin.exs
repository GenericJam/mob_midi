%{
  name: :mob_midi,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description: "MIDI in + out (USB / BLE) — CoreMIDI on iOS, android.media.midi on Android",
  # On-device proof for `mix mob.selftest` / mob_ci: a read-only
  # midi_list_devices/0 round trip through the NIF (see Mob.Plugin.SelfTest).
  selftest: MobMidi.SelfTest,
  nifs: [
    # Android: zig NIF bridging to the Kotlin MobMidiBridge (android.media.midi).
    # platform: :android so the iOS build skips it.
    %{module: :mob_midi_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: ObjC NIF over CoreMIDI directly (it's a C framework, NIF-friendly).
    # platform: :ios so the Android build skips it. Both share the Erlang stub
    # module src/mob_midi_nif.erl and implement the same midi_* functions.
    %{module: :mob_midi_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  # Runtime permission capability (Android): MobMidiBridge, a
  # MobPermissionProvider, maps :midi_bluetooth to what MobMidi.scan_bluetooth/2
  # and connect_bluetooth/2 need (BLUETOOTH_SCAN + BLUETOOTH_CONNECT + location
  # on 12+, ACCESS_FINE_LOCATION before), so Mob.Permissions.request(socket,
  # :midi_bluetooth) shows the dialog.
  permissions: [
    %{capability: :midi_bluetooth}
  ],
  android: %{
    # USB-MIDI needs no permission. BLE-MIDI: API <= 30 needs BLUETOOTH /
    # BLUETOOTH_ADMIN (install-time) and fine location for scans; API 31+ the
    # Nearby-devices permissions plus location, as mob_dev can't mark
    # BLUETOOTH_SCAN neverForLocation. Requested at runtime as :midi_bluetooth.
    permissions: [
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN",
      "android.permission.ACCESS_FINE_LOCATION",
      "android.permission.ACCESS_COARSE_LOCATION"
    ],
    # Also holds MobMidiDeviceService, the class a host's manifest names for
    # its own virtual MIDI devices (MobMidi.open_virtual/2; README "Virtual
    # devices"): the device's name is the host's, so the <service> and its
    # res/xml device info are the host's to declare.
    bridge_kt: "priv/native/android/MobMidiBridge.kt",
    bridge_class: "io.mob.midi.MobMidiBridge",
    # The byte paths in C (sources, the native sink, the per-output send
    # queues): the functions of priv/include/mob_midi.h, linked into the app
    # library so another static NIF of the app can call them.
    jni_source: "priv/native/android/mob_midi_core.c"
  },
  ios: %{
    frameworks: ["CoreMIDI"],
    plist_keys: %{
      NSBluetoothAlwaysUsageDescription:
        "Bluetooth access is required to connect to wireless (BLE) MIDI devices."
    }
  },
  # Tier-3: demo screens the host auto-lists via Mob.Plugins.screens().
  # Distinct first route segments so a host home that labels screens by the
  # leading segment shows "Midi Keyboard" / "Midi Input" rather than two "Midi".
  screens: [
    %{module: MobMidi.KeyboardScreen, default_route: "/midi_keyboard"},
    %{module: MobMidi.InputScreen, default_route: "/midi_input"}
  ]
}
