#!/usr/bin/env bash
# Build tools/MidiProbe.java, push it to a device and run it there as the adb
# shell user (app_process): another process that opens a mob_midi host app's
# virtual device, sends it notes and prints what it sends back, all stamped
# with CLOCK_MONOTONIC. See MidiProbe.java for the modes and the output.
#
#   tools/midi_probe.sh <serial> <device name> devices
#   tools/midi_probe.sh <serial> <device name> listen 10
#   tools/midi_probe.sh <serial> <device name> notes 5 20 50
#   tools/midi_probe.sh <serial> <device name> stall 10
#
# Lease the device first (~/AGENTS.md). Needs JDK 17+ and the Android SDK
# (platforms/android-35, build-tools with d8). PROBE_PUSH_ONLY=1 only builds
# and pushes /data/local/tmp/mob_midi_probe.dex.
set -euo pipefail

serial=${1:?usage: midi_probe.sh <serial> <device name> <mode> [args...]}
shift

sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
android_jar=$sdk/platforms/android-35/android.jar
d8=$(ls -d "$sdk"/build-tools/*/d8 | sort -V | tail -n 1)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

javac --release 17 -classpath "$android_jar" -d "$work" "$here/MidiProbe.java"
"$d8" --min-api 28 --lib "$android_jar" --output "$work" "$work"/*.class
adb -s "$serial" push "$work/classes.dex" /data/local/tmp/mob_midi_probe.dex >/dev/null
[ "${PROBE_PUSH_ONLY:-0}" = 1 ] && exit 0

name=${1:?device name}
shift
adb -s "$serial" shell CLASSPATH=/data/local/tmp/mob_midi_probe.dex \
  app_process /system/bin MidiProbe "'$name'" "$@"
