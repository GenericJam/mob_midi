/*
 * mob_midi_parser.h — header-only MIDI 1.0 byte-stream parser for native
 * consumers (a synth engine reading MobMidi input without a trip through
 * Elixir). C99, no allocation, nothing beyond <stdint.h> / <stddef.h>.
 *
 * Feed it bytes in whatever packets they arrive in; every complete message
 * goes to the callback as raw status + data bytes:
 *
 *   - Running status: data bytes after a complete channel message reuse its
 *     status. System common messages (0xF0–0xF7) cancel it.
 *   - Real-time bytes (0xF8 0xFA 0xFB 0xFC 0xFE 0xFF) are emitted the moment
 *     they arrive, even between a status and its data or inside SysEx, and
 *     disturb nothing.
 *   - System common: 0xF1 and 0xF3 are 2 bytes, 0xF2 is 3, 0xF6 is 1.
 *   - SysEx is skipped: nothing is emitted from 0xF0 up to its 0xF7 (or the
 *     next non-real-time status byte, which then counts as itself).
 *   - Undefined statuses (0xF4 0xF5 0xF9 0xFD), a lone 0xF7, data bytes with
 *     no status and a message abandoned by a new status byte emit nothing.
 *   - Note On with velocity 0 is NOT rewritten to Note Off (unlike
 *     MobMidi.Parser in Elixir): you get the wire status; treat
 *     (status & 0xF0) == 0x90 && d2 == 0 as a note off.
 *
 * Threads: a parser instance is not thread-safe and holds one stream's state.
 * Use one per source, feed it from one thread, and reset it (memset to 0, or
 * assign a `= {0}` value) when the source's generation changes (closed and
 * reopened, reconnected), so a stale partial message can't merge with new
 * bytes.
 */
#ifndef MOB_MIDI_PARSER_H
#define MOB_MIDI_PARSER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One complete message. len = bytes including status: 1, 2 or 3; unused data
 * bytes are 0. */
typedef struct {
    uint8_t status, d1, d2, len;
} mob_midi_msg;

/* Zero-initialised (= {0} or memset 0) is a fresh parser; that is also the
 * reset. */
typedef struct {
    uint8_t running;  /* status being assembled / running status; 0 = none */
    uint8_t need;     /* data bytes the message takes */
    uint8_t have;     /* data bytes received so far */
    uint8_t d[2];
    uint8_t in_sysex; /* non-zero while skipping a SysEx */
} mob_midi_parser;

typedef void (*mob_midi_emit_fn)(void *ctx, mob_midi_msg msg);

static inline uint8_t mob_midi_data_len(uint8_t status) {
    if (status < 0xF0) {
        uint8_t type = (uint8_t)(status & 0xF0);
        return (uint8_t)(type == 0xC0 || type == 0xD0 ? 1 : 2);
    }
    if (status == 0xF1 || status == 0xF3) return 1;
    if (status == 0xF2) return 2;
    return 0;
}

static inline void mob_midi_emit1(mob_midi_emit_fn emit, void *ctx, uint8_t status) {
    mob_midi_msg m;
    m.status = status;
    m.d1 = 0;
    m.d2 = 0;
    m.len = 1;
    emit(ctx, m);
}

static inline void mob_midi_parse(mob_midi_parser *p, const uint8_t *bytes, size_t len,
                                  mob_midi_emit_fn emit, void *ctx) {
    size_t i;
    for (i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        if (b >= 0xF8) {
            if (b != 0xF9 && b != 0xFD) mob_midi_emit1(emit, ctx, b);
            continue;
        }
        if (b & 0x80) {
            /* Any status byte ends a SysEx and drops a partial message. */
            p->in_sysex = (uint8_t)(b == 0xF0);
            p->have = 0;
            p->running = 0;
            p->need = mob_midi_data_len(b);
            if (b < 0xF0 || p->need > 0) {
                p->running = b;
            } else if (b == 0xF6) {
                mob_midi_emit1(emit, ctx, b);
            }
            continue;
        }
        if (p->in_sysex || !p->running) continue;
        p->d[p->have++] = b;
        if (p->have < p->need) continue;
        {
            mob_midi_msg m;
            m.status = p->running;
            m.d1 = p->d[0];
            m.d2 = p->need > 1 ? p->d[1] : 0;
            m.len = (uint8_t)(1 + p->need);
            p->have = 0;
            /* System common messages don't run. */
            if (p->running >= 0xF0) p->running = 0;
            emit(ctx, m);
        }
    }
}

#ifdef __cplusplus
}
#endif

#endif /* MOB_MIDI_PARSER_H */
