/*
 * mob_midi_queue.h: one output's send queue, for mob_midi_core.c.
 *
 * Plain C with no JNI or ERTS, so test/c/mob_midi_queue_test.c runs it on the
 * host. The caller holds the output's lock around every call.
 *
 * A min-heap of chunks ordered by (due, seq): messages leave in target-time
 * order, FIFO for equal times. Back-pressure follows a refuse-until-drained
 * rule: the first push that doesn't fit answers MOB_MIDI_ERR_QUEUE_FULL and
 * from then on every push does, until the queue has drained, i.e. the
 * dispatcher is no longer inside a send (a stalled receiver let go) and the
 * queue is down to MOB_MIDI_QUEUE_LOW_WATER chunks. mob_midi_queue_drained()
 * reports that moment once, so the opener hears {:midi, :drained, ...}. A
 * sender can't trickle bytes into a port that just refused them, and gets
 * one clear signal to resume on.
 *
 * mob_midi_queue_discard() drops what is queued (stale notes a stalled
 * receiver would otherwise get late) and starts a new generation, which the
 * drained event reports. A batch the dispatcher already handed to Android
 * can't be recalled.
 */
#ifndef MOB_MIDI_QUEUE_H
#define MOB_MIDI_QUEUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "../../include/mob_midi.h"

/* At or below this many chunks a refusing queue has drained. */
#define MOB_MIDI_QUEUE_LOW_WATER (MOB_MIDI_QUEUE_CAPACITY / 2)

/* The longest message: the whole queue. Longer ones are refused with
 * MOB_MIDI_ERR_TOO_LARGE (no refusal state: they could never fit). A take's
 * buffer must hold this much, since a message is never split across takes. */
#define MOB_MIDI_QUEUE_MAX_BYTES (MOB_MIDI_QUEUE_CAPACITY * MOB_MIDI_CHUNK_BYTES)

typedef struct {
    int64_t due;       /* when to hand it over */
    int64_t timestamp; /* the stamp it carries */
    uint64_t seq;      /* FIFO among equal `due` */
    uint16_t msg_len;  /* the whole message's bytes on its first chunk, 0 on the rest */
    uint8_t len;
    uint8_t bytes[MOB_MIDI_CHUNK_BYTES];
} mob_midi_qmsg;

typedef struct {
    uint64_t seq;
    int count;
    bool refusing;       /* refused a push; refuses all until drained */
    bool sending;        /* the dispatcher is inside a send */
    uint32_t generation; /* 1.. (31 bits), bumped by every discard */
    mob_midi_qmsg heap[MOB_MIDI_QUEUE_CAPACITY];
} mob_midi_queue;

static inline void mob_midi_queue_reset(mob_midi_queue *q) {
    q->seq = 0;
    q->count = 0;
    q->refusing = false;
    q->sending = false;
    q->generation = 1;
}

static inline bool mob_midi_queue_before(const mob_midi_qmsg *a, const mob_midi_qmsg *b) {
    return a->due < b->due || (a->due == b->due && a->seq < b->seq);
}

static inline void mob_midi_queue_heap_push(mob_midi_queue *q, const mob_midi_qmsg *m) {
    int i = q->count++;
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (!mob_midi_queue_before(m, &q->heap[parent])) break;
        q->heap[i] = q->heap[parent];
        i = parent;
    }
    q->heap[i] = *m;
}

static inline void mob_midi_queue_heap_pop(mob_midi_queue *q) {
    mob_midi_qmsg last = q->heap[--q->count];
    int i = 0;
    for (;;) {
        int child = 2 * i + 1;
        if (child >= q->count) break;
        if (child + 1 < q->count && mob_midi_queue_before(&q->heap[child + 1], &q->heap[child])) child++;
        if (!mob_midi_queue_before(&q->heap[child], &last)) break;
        q->heap[i] = q->heap[child];
        i = child;
    }
    if (q->count > 0) q->heap[i] = last;
}

/* `len` bytes (> 0) stamped and due at `stamp`, split into chunks. MOB_MIDI_OK,
 * MOB_MIDI_ERR_QUEUE_FULL (nothing queued; refusing from now on) or
 * MOB_MIDI_ERR_TOO_LARGE (over MOB_MIDI_QUEUE_MAX_BYTES). A message's chunks
 * share its due time and take consecutive seqs, so they sit together in heap
 * order: anything due earlier sorts before all of them. */
static inline int mob_midi_queue_push(mob_midi_queue *q, const uint8_t *bytes, size_t len, int64_t stamp) {
    if (len > MOB_MIDI_QUEUE_MAX_BYTES) return MOB_MIDI_ERR_TOO_LARGE;
    if (q->refusing) return MOB_MIDI_ERR_QUEUE_FULL;
    size_t chunks = (len + MOB_MIDI_CHUNK_BYTES - 1) / MOB_MIDI_CHUNK_BYTES;
    if ((size_t)q->count + chunks > MOB_MIDI_QUEUE_CAPACITY) {
        q->refusing = true;
        return MOB_MIDI_ERR_QUEUE_FULL;
    }
    mob_midi_qmsg m;
    m.due = stamp;
    m.timestamp = stamp;
    m.msg_len = (uint16_t)len;
    for (size_t done = 0; done < len;) {
        size_t n = len - done > MOB_MIDI_CHUNK_BYTES ? MOB_MIDI_CHUNK_BYTES : len - done;
        m.seq = q->seq++;
        m.len = (uint8_t)n;
        memcpy(m.bytes, bytes + done, n);
        mob_midi_queue_heap_push(q, &m);
        m.msg_len = 0;
        done += n;
    }
    return MOB_MIDI_OK;
}

/* The dispatcher is back from its last send (or hasn't sent yet). */
static inline void mob_midi_queue_idle(mob_midi_queue *q) { q->sending = false; }

/* True exactly once per refusal, when the queue has drained: admission
 * reopens and the caller reports it. */
static inline bool mob_midi_queue_drained(mob_midi_queue *q) {
    if (!q->refusing || q->sending || q->count > MOB_MIDI_QUEUE_LOW_WATER) return false;
    q->refusing = false;
    return true;
}

/* The earliest message's due time; the queue must not be empty. */
static inline int64_t mob_midi_queue_next_due(const mob_midi_queue *q) { return q->heap[0].due; }

/* Moves the due batch into `out` (the earliest message and the whole
 * messages after it with the same stamp, up to `max` bytes; `max` must be
 * at least MOB_MIDI_QUEUE_MAX_BYTES), its stamp into *stamp; returns the
 * byte count, 0 when nothing is due at `now`. Messages are taken whole, so
 * nothing pushed later can land between two parts of one (a long SysEx). A
 * batch taken marks the dispatcher as sending until mob_midi_queue_idle(). */
static inline int mob_midi_queue_take(mob_midi_queue *q, int64_t now, uint8_t *out, int max, int64_t *stamp) {
    if (q->count == 0 || q->heap[0].due > now) return 0;
    int n = 0;
    int64_t s = q->heap[0].timestamp;
    /* The head is always a message's first chunk. */
    while (q->count > 0 && q->heap[0].timestamp == s && n + q->heap[0].msg_len <= max) {
        for (int left = q->heap[0].msg_len; left > 0;) {
            memcpy(out + n, q->heap[0].bytes, q->heap[0].len);
            n += q->heap[0].len;
            left -= q->heap[0].len;
            mob_midi_queue_heap_pop(q);
        }
    }
    *stamp = s;
    q->sending = n > 0;
    return n;
}

/* Drops everything queued and starts a new generation, which it returns. A
 * refusing queue keeps refusing until it has drained. */
static inline uint32_t mob_midi_queue_discard(mob_midi_queue *q) {
    q->count = 0;
    q->generation = (q->generation + 1) & 0x7fffffffu;
    if (q->generation == 0) q->generation = 1;
    return q->generation;
}

/* Nobody listens any more (an own virtual output): queued bytes are for no
 * one and there is nothing to drain into. No drained report follows. */
static inline void mob_midi_queue_abandon(mob_midi_queue *q) {
    mob_midi_queue_discard(q);
    q->refusing = false;
}

#endif /* MOB_MIDI_QUEUE_H */
