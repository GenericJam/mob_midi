/* Host test for priv/native/ios/mob_midi_clock.h, the iOS clock conversion
 * (mach_absolute_time ticks <-> ns); run by test/mob_midi_c_parser_test.exs.
 * Exits non-zero on any failure. */
#include <stdio.h>

#include "mob_midi_clock.h"

static int failures = 0;

#define CHECK(cond)                                                                  \
    do {                                                                             \
        if (!(cond)) {                                                               \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                              \
        }                                                                            \
    } while (0)

/* Apple silicon and 64-bit iOS devices (24 MHz), and Intel Macs. */
static const uint32_t TIMEBASES[][2] = {{125, 3}, {1, 1}};

static void test_known_values(void) {
    /* 24 ticks of a 24 MHz clock are 1 us. */
    CHECK(mob_midi_ticks_to_ns(24, 125, 3) == 1000);
    CHECK(mob_midi_ns_to_ticks(1000, 125, 3) == 24);
    /* 1 ns is under a tick: rounded up to one, not down to zero. */
    CHECK(mob_midi_ns_to_ticks(1, 125, 3) == 1);
    CHECK(mob_midi_ns_to_ticks(1001, 125, 3) == 25);
    CHECK(mob_midi_ticks_to_ns(25, 125, 3) == 1041);
    CHECK(mob_midi_ticks_to_ns(0, 125, 3) == 0);
    CHECK(mob_midi_ticks_to_ns(123456789, 1, 1) == 123456789);
    CHECK(mob_midi_ns_to_ticks(123456789, 1, 1) == 123456789);
}

/* ns <= 0 (mob_midi_send's "now", or garbage) never wraps to a huge tick. */
static void test_non_positive(void) {
    CHECK(mob_midi_ns_to_ticks(0, 125, 3) == 0);
    CHECK(mob_midi_ns_to_ticks(-1, 125, 3) == 0);
    CHECK(mob_midi_ns_to_ticks(INT64_MIN, 1, 1) == 0);
}

/* A year of uptime at 125/3, and a timebase where ticks * numer overflows
 * 64 bits: the 128-bit products keep both exact. */
static void test_large(void) {
    const int64_t year_ns = 365LL * 24 * 3600 * 1000000000LL;
    uint64_t ticks = mob_midi_ns_to_ticks(year_ns, 125, 3);
    CHECK(ticks == (uint64_t)(year_ns / 125 * 3));
    CHECK(mob_midi_ticks_to_ns(ticks, 125, 3) == year_ns);
    /* numer large enough that ticks * numer overflows 64 bits. */
    uint64_t big = 1ULL << 40;
    CHECK(mob_midi_ticks_to_ns(big, 1u << 30, 1u << 10) == (int64_t)(big << 20));
}

/* ticks -> ns -> ticks is exact (a received stamp sent on keeps its tick);
 * ns -> ticks -> ns comes back at most one tick late, never early; both
 * directions are monotonic. */
static void test_round_trips(void) {
    for (unsigned t = 0; t < sizeof TIMEBASES / sizeof TIMEBASES[0]; t++) {
        uint32_t n = TIMEBASES[t][0], d = TIMEBASES[t][1];
        int64_t tick_ns = (int64_t)((n + d - 1) / d);
        int64_t base = 3078799357041541LL; /* ~36 days of uptime */
        int64_t last_back = -1;
        uint64_t last_ticks = 0;
        for (int64_t i = 0; i < 100000; i += 7) {
            int64_t ns = base + i;
            uint64_t ticks = mob_midi_ns_to_ticks(ns, n, d);
            int64_t back = mob_midi_ticks_to_ns(ticks, n, d);
            CHECK(back >= ns);
            CHECK(back - ns <= tick_ns);
            CHECK(ticks >= last_ticks);
            CHECK(back >= last_back);
            last_ticks = ticks;
            last_back = back;

            uint64_t tick = (uint64_t)base + (uint64_t)i;
            CHECK(mob_midi_ns_to_ticks(mob_midi_ticks_to_ns(tick, n, d), n, d) == tick);
        }
    }
}

int main(void) {
    test_known_values();
    test_non_positive();
    test_large();
    test_round_trips();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("clock: ok\n");
    return 0;
}
