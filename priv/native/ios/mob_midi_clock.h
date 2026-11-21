/*
 * mob_midi_clock.h: the iOS clock of mob_midi, host ticks <-> nanoseconds.
 *
 * Plain C with no CoreMIDI or ERTS, so test/c/mob_midi_clock_test.c runs it
 * on any host. mob_midi_nif.m passes mach_timebase_info()'s numer / denom.
 *
 * mob_midi's iOS clock is mach_absolute_time() in nanoseconds: the clock of
 * CoreMIDI's MIDITimeStamp (host ticks) and of AudioTimeStamp.mHostTime. It
 * stops while the device sleeps (like CLOCK_UPTIME_RAW; Darwin's
 * CLOCK_MONOTONIC keeps counting, so it is NOT this clock). A tick is
 * numer/denom ns: 1/1 on Intel Macs, 125/3 (24 MHz) on Apple silicon and
 * every 64-bit iPhone and iPad.
 *
 * The products are 128-bit, so no timebase overflows them. ns -> ticks
 * rounds up, ticks -> ns down: a tick stamp converted to ns and back is the
 * same tick (a received stamp sent on keeps it), and an ns time converted to
 * ticks and back comes out up to one tick (42 ns at 125/3) late, never early
 * (a message sent `at:` a time is not handed over before it).
 */
#ifndef MOB_MIDI_CLOCK_H
#define MOB_MIDI_CLOCK_H

#include <stdint.h>

__extension__ typedef unsigned __int128 mob_midi_u128;

static inline int64_t mob_midi_ticks_to_ns(uint64_t ticks, uint32_t numer, uint32_t denom) {
    return (int64_t)((mob_midi_u128)ticks * numer / denom);
}

/* A time before the clock's origin (ns <= 0) is tick 0. */
static inline uint64_t mob_midi_ns_to_ticks(int64_t ns, uint32_t numer, uint32_t denom) {
    return ns <= 0 ? 0 : (uint64_t)(((mob_midi_u128)ns * denom + numer - 1) / numer);
}

#endif /* MOB_MIDI_CLOCK_H */
