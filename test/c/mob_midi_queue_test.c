/* Host test for priv/native/android/mob_midi_queue.h, the per-output send
 * queue of mob_midi_core.c; run by test/mob_midi_c_parser_test.exs. Exits
 * non-zero on any failure. */
#include <stdio.h>
#include <string.h>

#include "mob_midi_queue.h"

static int failures = 0;

#define CHECK(cond)                                                                  \
    do {                                                                             \
        if (!(cond)) {                                                               \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                              \
        }                                                                            \
    } while (0)

static mob_midi_queue q;

static int push1(uint8_t b, int64_t at) { return mob_midi_queue_push(&q, &b, 1, at); }

/* One dispatcher round: back from the last send, then take what is due. */
static int round_trip(int64_t now, uint8_t *out, int max, int64_t *stamp) {
    mob_midi_queue_idle(&q);
    return mob_midi_queue_take(&q, now, out, max, stamp);
}

static void test_order(void) {
    uint8_t out[64];
    int64_t stamp = 0;
    mob_midi_queue_reset(&q);
    CHECK(push1(0x30, 300) == MOB_MIDI_OK);
    CHECK(push1(0x10, 100) == MOB_MIDI_OK);
    CHECK(push1(0x20, 200) == MOB_MIDI_OK);
    CHECK(push1(0x11, 100) == MOB_MIDI_OK);

    /* Nothing due yet. */
    CHECK(round_trip(99, out, 64, &stamp) == 0);
    /* Earliest first; equal stamps leave together, FIFO. */
    CHECK(round_trip(1000, out, 64, &stamp) == 2);
    CHECK(stamp == 100 && out[0] == 0x10 && out[1] == 0x11);
    CHECK(round_trip(1000, out, 64, &stamp) == 1);
    CHECK(stamp == 200 && out[0] == 0x20);
    CHECK(round_trip(1000, out, 64, &stamp) == 1);
    CHECK(stamp == 300 && out[0] == 0x30);
    CHECK(q.count == 0);
}

static void test_long_message(void) {
    uint8_t sysex[150], out[1024];
    int64_t stamp = 0;
    mob_midi_queue_reset(&q);
    for (int i = 0; i < 150; i++) sysex[i] = (uint8_t)i;
    CHECK(mob_midi_queue_push(&q, sysex, sizeof sysex, 5) == MOB_MIDI_OK);
    /* 64 + 64 + 22. */
    CHECK(q.count == 3);
    CHECK(round_trip(5, out, (int)sizeof out, &stamp) == 150);
    CHECK(memcmp(out, sysex, sizeof sysex) == 0);
}

static void test_refuses_until_drained(void) {
    uint8_t out[1024];
    int64_t stamp = 0;
    mob_midi_queue_reset(&q);
    for (int i = 0; i < MOB_MIDI_QUEUE_CAPACITY; i++) CHECK(push1(0xF8, 1000 + i) == MOB_MIDI_OK);
    /* The receiver is stuck in a send. */
    CHECK(mob_midi_queue_take(&q, 1000, out, 1, &stamp) == 1);
    CHECK(q.sending);

    CHECK(push1(0xF8, 5000) == MOB_MIDI_OK); /* room for the one taken */
    CHECK(push1(0xF8, 5000) == MOB_MIDI_ERR_QUEUE_FULL);
    CHECK(q.refusing);
    CHECK(!mob_midi_queue_drained(&q));

    /* Back from the stuck send: one chunk of room, yet still refusing. */
    CHECK(round_trip(1001, out, 1, &stamp) == 1);
    CHECK(push1(0xF8, 5000) == MOB_MIDI_ERR_QUEUE_FULL);

    /* Down to the low-water mark one send at a time: drained exactly once. */
    int drained = 0;
    for (int64_t t = 1002; q.count > 0; t++) {
        mob_midi_queue_idle(&q);
        if (mob_midi_queue_drained(&q)) {
            drained++;
            CHECK(q.count == MOB_MIDI_QUEUE_LOW_WATER);
        }
        mob_midi_queue_take(&q, t, out, 1, &stamp);
    }
    mob_midi_queue_idle(&q);
    CHECK(!mob_midi_queue_drained(&q));
    CHECK(drained == 1);
    CHECK(push1(0x90, 0) == MOB_MIDI_OK);
}

static void test_discard(void) {
    uint8_t out[8];
    int64_t stamp = 0;
    mob_midi_queue_reset(&q);
    CHECK(q.generation == 1);
    for (int i = 0; i < MOB_MIDI_QUEUE_CAPACITY; i++) CHECK(push1(0x90, 10) == MOB_MIDI_OK);
    CHECK(mob_midi_queue_take(&q, 10, out, 1, &stamp) == 1); /* stuck in this send */
    CHECK(push1(0x90, 10) == MOB_MIDI_OK);
    CHECK(push1(0x90, 10) == MOB_MIDI_ERR_QUEUE_FULL);

    /* The stale notes go; the port stays refusing while the send is stuck. */
    CHECK(mob_midi_queue_discard(&q) == 2);
    CHECK(q.count == 0);
    CHECK(!mob_midi_queue_drained(&q));
    CHECK(push1(0x90, 10) == MOB_MIDI_ERR_QUEUE_FULL);

    /* The send returns: drained, with the discard's generation. */
    mob_midi_queue_idle(&q);
    CHECK(mob_midi_queue_drained(&q));
    CHECK(q.generation == 2);
    CHECK(push1(0x80, 20) == MOB_MIDI_OK);
    CHECK(round_trip(20, out, 8, &stamp) == 1 && out[0] == 0x80);

    /* A discard of a queue that never refused reports no drain. */
    CHECK(push1(0x90, 30) == MOB_MIDI_OK);
    CHECK(mob_midi_queue_discard(&q) == 3);
    mob_midi_queue_idle(&q);
    CHECK(!mob_midi_queue_drained(&q));

    /* 31-bit generations skip 0 on wrap. */
    q.generation = 0x7fffffffu;
    CHECK(mob_midi_queue_discard(&q) == 1);
}

static void test_abandon(void) {
    mob_midi_queue_reset(&q);
    for (int i = 0; i < MOB_MIDI_QUEUE_CAPACITY; i++) CHECK(push1(0x90, 10) == MOB_MIDI_OK);
    CHECK(push1(0x90, 10) == MOB_MIDI_ERR_QUEUE_FULL);
    /* The last listener left: nothing to drain into, no drain report. */
    mob_midi_queue_abandon(&q);
    CHECK(q.count == 0 && !q.refusing);
    CHECK(q.generation == 2);
    CHECK(!mob_midi_queue_drained(&q));
    CHECK(push1(0x90, 10) == MOB_MIDI_OK);
}

static void test_chunks_count_against_capacity(void) {
    uint8_t big[130] = {0xF0};
    mob_midi_queue_reset(&q);
    for (int i = 0; i < MOB_MIDI_QUEUE_CAPACITY - 2; i++) CHECK(push1(0xF8, 1) == MOB_MIDI_OK);
    /* Three chunks don't fit in two: refused whole, nothing half queued. */
    CHECK(mob_midi_queue_push(&q, big, sizeof big, 1) == MOB_MIDI_ERR_QUEUE_FULL);
    CHECK(q.count == MOB_MIDI_QUEUE_CAPACITY - 2);
}

int main(void) {
    test_order();
    test_long_message();
    test_refuses_until_drained();
    test_discard();
    test_abandon();
    test_chunks_count_against_capacity();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("ok");
    return 0;
}
